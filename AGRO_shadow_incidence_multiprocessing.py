#!/usr/bin/env python3
"""
High-performance shadow and sun incidence angle calculation
with GeoPackage boundary masking and configurable buffer.

A buffer (default 10 000 m) is applied ON-THE-FLY to the raw geometries
in the GeoPackage.  The output raster bbox equals the bbox of that
buffered boundary.  Pixels outside the buffer polygon receive nodata=255.

Performance strategy:
  1. Buffer the GeoPackage geometry -> compute its bbox -> that is the
     only region written to the output raster (much smaller than full DEM).
  2. Numba JIT compiles the inner shadow-casting loop  (~100x vs pure Python).
  3. Tile-based multiprocessing across all available cores.
  4. Each tile reads a halo from the FULL DEM (not clipped to boundary)
     so that shadows cast by terrain outside CH are physically correct.
  5. Polygon mask applied per-tile; outside pixels -> nodata (255).

Requirements:
  pip install numba rasterio numpy geopandas shapely

Usage:
  python shadow_fast.py <timestamp> <dem.tif> <boundary.gpkg> <output_dir> [buffer_m]

  python shadow_fast.py 20210602t1005 ^
      "M:/...DSM_10m_EPSG2056_CH_clipped_10km.tif" ^
      "D:/temp/github/.../swissboundary_buffer_5000m_22.gpkg" ^
      ./output ^
      10000

  buffer_m is optional; defaults to 10000 (10 km).
  Pass 0 to use the raw geometry with no additional buffer.

Timestamp format: YYYYMMDDtHHMM  (interpreted as UTC)
"""

import sys
import os
import warnings
import multiprocessing
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import rasterio
from rasterio.windows import Window
from rasterio.features import geometry_mask
import geopandas as gpd
from shapely.ops import unary_union

try:
    from numba import njit, prange
    NUMBA_AVAILABLE = True
except ImportError:
    NUMBA_AVAILABLE = False
    warnings.warn(
        "numba not found -- install with: pip install numba\n"
        "Falling back to pure-Python shadow calculation (much slower)."
    )

# ==============================================================================
# CONFIGURATION
# ==============================================================================
CONFIG = {
    "DEFAULT_TS":   "20210602t1005",
    "DEFAULT_DEM":  "LIDAR_MAX_subset_engadin.tif",
    "DEFAULT_GPKG": "swissboundary_buffer_5000m_22.gpkg",
    "DEFAULT_OUT":  "./output_results",

    # Solar reference -- centre of Switzerland
    "REF_LAT":  46.8182,
    "REF_LON":   8.2275,

    "COMPRESSION": "deflate",
    "PREDICTOR":    2,

    # Tile size in output pixels.
    # 4096x4096 Float64 ~ 128 MB per tile before halo; tune to your RAM/worker budget.
    "TILE_SIZE": 4096,

    # None -> os.cpu_count()
    "N_WORKERS": None,

    # Value written for pixels outside the boundary polygon
    "OUT_NODATA": 255,

    # Buffer applied ON-THE-FLY to the raw GeoPackage geometry (metres).
    # The gpkg may already contain a pre-buffered boundary; this adds on top.
    # Set to 0 to use the gpkg geometry as-is.
    # Can be overridden by passing a 5th CLI argument.
    "BUFFER_M": 10_000,
}

# ==============================================================================
# SOLAR POSITION
# ==============================================================================

def to_juliandate(d):
    return d.timestamp() / 86400.0 + 2440587.5


def _equation_of_time(jd):
    jdc = (jd - 2451545.0) / 36525.0
    sec = 21.448 - jdc * (46.8150 + jdc * (0.00059 - jdc * 0.001813))
    e0  = 23.0 + (26.0 + sec / 60.0) / 60.0
    oblcorr = e0 + 0.00256 * np.cos(np.deg2rad(125.04 - 1934.136 * jdc))
    l0 = 280.46646 + jdc * (36000.76983 + jdc * 0.0003032)
    l0 = (l0 - 360 * (l0 // 360)) % 360
    gmas = np.deg2rad(357.52911 + jdc * (35999.05029 - 0.0001537 * jdc))
    ecc  = 0.016708634 - jdc * (0.000042037 + 0.0000001267 * jdc)
    y    = (np.tan(np.deg2rad(oblcorr) / 2)) ** 2
    rl0  = np.deg2rad(l0)
    EqTime = (
        y * np.sin(2 * rl0)
        - 2.0 * ecc * np.sin(gmas)
        + 4.0 * ecc * y * np.sin(gmas) * np.cos(2 * rl0)
        - 0.5 * y * y * np.sin(4 * rl0)
        - 1.25 * ecc * ecc * np.sin(2 * gmas)
    )
    return np.rad2deg(EqTime) * 4


def sun_declination(jd):
    jdc = (jd - 2451545.0) / 36525.0
    sec = 21.448 - jdc * (46.8150 + jdc * (0.00059 - jdc * 0.001813))
    e0  = 23.0 + (26.0 + sec / 60.0) / 60.0
    oblcorr = e0 + 0.00256 * np.cos(np.deg2rad(125.04 - 1934.136 * jdc))
    l0 = 280.46646 + jdc * (36000.76983 + jdc * 0.0003032)
    l0 = (l0 - 360 * (l0 // 360)) % 360
    gmas = np.deg2rad(357.52911 + jdc * (35999.05029 - 0.0001537 * jdc))
    seqcent = (
        np.sin(gmas)       * (1.914602 - jdc * (0.004817 + 0.000014 * jdc))
        + np.sin(2 * gmas) * (0.019993 - 0.000101 * jdc)
        + np.sin(3 * gmas) * 0.000289
    )
    suntl = l0 + seqcent
    sal   = suntl - 0.00569 - 0.00478 * np.sin(np.deg2rad(125.04 - 1934.136 * jdc))
    delta = np.arcsin(np.sin(np.deg2rad(oblcorr)) * np.sin(np.deg2rad(sal)))
    return np.rad2deg(delta)


def sun_vector(jd, latitude, longitude):
    frac        = jd - np.floor(jd)
    hour_utc    = (frac * 24 + 12) % 24
    time_offset = _equation_of_time(jd)
    solar_time  = hour_utc + longitude / 15.0 + time_offset / 60.0
    omega_r     = np.pi * (solar_time / 12.0 - 1.0)
    delta_r     = np.deg2rad(sun_declination(jd))
    lambda_r    = np.deg2rad(latitude)
    svx = -np.sin(omega_r) * np.cos(delta_r)
    svy =  np.sin(lambda_r) * np.cos(omega_r) * np.cos(delta_r) - np.cos(lambda_r) * np.sin(delta_r)
    svz =  np.cos(lambda_r) * np.cos(omega_r) * np.cos(delta_r) + np.sin(lambda_r) * np.sin(delta_r)
    return np.array([svx, svy, svz])

# ==============================================================================
# GRADIENT & INCIDENCE ANGLE
# ==============================================================================

def gradient(grid, length_x, length_y=None):
    if length_y is None:
        length_y = length_x
    grad = np.empty((*grid.shape, 3))
    grad[:] = np.nan
    grad[:-1, :-1, 0] = 0.5 * length_y * (
        grid[:-1, :-1] - grid[:-1, 1:] + grid[1:, :-1] - grid[1:, 1:]
    )
    grad[:-1, :-1, 1] = 0.5 * length_x * (
        grid[:-1, :-1] + grid[:-1, 1:] - grid[1:, :-1] - grid[1:, 1:]
    )
    grad[:-1, :-1, 2] = length_x * length_y
    grad[-1, :, :] = grad[-2, :, :]
    grad[:, -1, :] = grad[:, -2, :]
    area = np.sqrt(grad[:, :, 0]**2 + grad[:, :, 1]**2 + grad[:, :, 2]**2)
    for i in range(3):
        grad[:, :, i] /= area
    return grad


def incidence_angle(grad, sv):
    cos_inc = grad[:,:,0]*sv[0] + grad[:,:,1]*sv[1] + grad[:,:,2]*sv[2]
    cos_inc = np.clip(cos_inc, -1.0, 1.0)
    return np.clip(np.rad2deg(np.arccos(cos_inc)), 0, 90)

# ==============================================================================
# SHADOW CASTING
# ==============================================================================

if NUMBA_AVAILABLE:
    @njit(parallel=True, cache=True)
    def _project_shadows_numba(dem_T, inv_sv, norm_sv, rows, cols, dx):
        in_sun = np.ones((cols, rows), dtype=np.uint8)
        # West-East pass
        start_col = 0 if inv_sv[0] >= 0 else cols - 1
        for row in prange(rows):
            z_prev = -1e30
            n = 0
            while True:
                dx_off = inv_sv[0] * n
                dy_off = inv_sv[1] * n
                c = int(round(start_col + dx_off))
                r = int(round(row       + dy_off))
                if c < 0 or c >= cols or r < 0 or r >= rows:
                    break
                z_proj = (dx_off * dx * norm_sv[0]
                          + dy_off * dx * norm_sv[1]
                          + dem_T[c, r]  * norm_sv[2])
                if z_proj < z_prev:
                    in_sun[c, r] = 0
                else:
                    z_prev = z_proj
                n += 1
        # North-South pass
        start_row = 0 if inv_sv[1] >= 0 else rows - 1
        for col in prange(cols):
            z_prev = -1e30
            n = 0
            while True:
                dx_off = inv_sv[0] * n
                dy_off = inv_sv[1] * n
                c = int(round(col       + dx_off))
                r = int(round(start_row + dy_off))
                if c < 0 or c >= cols or r < 0 or r >= rows:
                    break
                z_proj = (dx_off * dx * norm_sv[0]
                          + dy_off * dx * norm_sv[1]
                          + dem_T[c, r]  * norm_sv[2])
                if z_proj < z_prev:
                    in_sun[c, r] = 0
                else:
                    z_prev = z_proj
                n += 1
        return in_sun


def _build_sv_helpers(sv):
    max_xy = max(abs(sv[0]), abs(sv[1]))
    if max_xy == 0:
        return np.array([0.0, 0.0, -1.0]), np.array([0.0, 0.0, 1.0])
    inv_sv = (-sv / max_xy).astype(np.float64)
    norm_z = np.sqrt(sv[0]**2 + sv[1]**2)
    if norm_z == 0:
        norm_sv = np.array([0.0, 0.0, 1.0])
    else:
        norm_sv = np.array(
            [-sv[0]*sv[2]/norm_z, -sv[1]*sv[2]/norm_z, norm_z],
            dtype=np.float64
        )
    return inv_sv, norm_sv


def project_shadows(dem, sv, dx):
    inv_sv, norm_sv = _build_sv_helpers(sv)
    if NUMBA_AVAILABLE:
        rows, cols = dem.shape
        dem_T = np.ascontiguousarray(dem.T, dtype=np.float64)
        return _project_shadows_numba(dem_T, inv_sv, norm_sv, rows, cols, float(dx)).T
    # --- Pure-Python fallback ---
    rows, cols = dem.shape
    z      = dem.T
    in_sun = np.ones_like(z)
    start_col = 1 if sv[0] < 0 else cols - 1
    start_row = 1 if sv[1] < 0 else rows - 1
    def cast(row, col):
        n, z_prev = 0, -1e20
        while True:
            ddx = inv_sv[0] * n
            ddy = inv_sv[1] * n
            c = int(round(col + ddx))
            r = int(round(row + ddy))
            if c < 0 or c >= cols or r < 0 or r >= rows:
                break
            z_proj = ddx*dx*norm_sv[0] + ddy*dx*norm_sv[1] + z[c, r]*norm_sv[2]
            if z_proj < z_prev:
                in_sun[c, r] = 0
            else:
                z_prev = z_proj
            n += 1
    for col in range(cols):
        cast(start_row, col)
    for row in range(rows):
        cast(row, start_col)
    return in_sun.T

# ==============================================================================
# TILE WORKER  (runs in a subprocess)
# ==============================================================================

def _process_tile(args):
    """
    Process one tile.

    Coordinate conventions
    ----------------------
    tile_row / tile_col   : position within the OUTPUT window (= CH bbox window)
    abs_r0  / abs_c0      : same position in the full DEM pixel grid
    halo_r0 / halo_c0     : top-left of the halo block in the full DEM grid
    off_r   / off_c       : offset to strip halo from the result block
    """
    (dem_path, shadow_path, incidence_path,
     tile_row, tile_col, tile_h, tile_w,
     out_rows, out_cols,
     win_row_off, win_col_off,
     full_rows, full_cols,
     halo,
     sv_list, res, dem_nodata,
     out_nodata,
     poly_wkts,
     dem_origin_x, dem_origin_y) = args

    import numpy as np
    import rasterio
    from rasterio.windows import Window
    from rasterio.features import geometry_mask
    from shapely import wkt as shapely_wkt

    sv = np.array(sv_list)

    # Absolute DEM pixel position of this tile's top-left corner
    abs_r0 = win_row_off + tile_row
    abs_c0 = win_col_off + tile_col

    # Halo block in full-DEM pixel space
    halo_r0 = max(0, abs_r0 - halo)
    halo_c0 = max(0, abs_c0 - halo)
    halo_r1 = min(full_rows, abs_r0 + tile_h + halo)
    halo_c1 = min(full_cols, abs_c0 + tile_w + halo)

    off_r = abs_r0 - halo_r0
    off_c = abs_c0 - halo_c0

    # Read DEM halo block
    with rasterio.open(dem_path) as src:
        win = Window(halo_c0, halo_r0, halo_c1 - halo_c0, halo_r1 - halo_r0)
        dem_block = src.read(1, window=win).astype(np.float64)

    # Replace DEM nodata with neighbour fill
    if dem_nodata is not None:
        bad = dem_block == dem_nodata
        if bad.any():
            try:
                from scipy.ndimage import generic_filter
                nd = dem_nodata
                def _fill(x):
                    c = x[len(x)//2]
                    if c == nd:
                        v = x[x != nd]
                        return float(v.mean()) if len(v) else 0.0
                    return c
                dem_block = generic_filter(dem_block, _fill, size=3)
            except ImportError:
                dem_block[bad] = 0.0

    # Shadow + incidence on halo block
    grad_block   = gradient(dem_block, res)
    inc_block    = incidence_angle(grad_block, sv)
    shadow_block = project_shadows(dem_block, sv, res)

    inc_combined = inc_block.copy()
    inc_combined[shadow_block == 0] = 90.0

    # Extract core tile (strip halo)
    shadow_tile = shadow_block[off_r:off_r + tile_h, off_c:off_c + tile_w].astype(np.uint8)
    inc_tile    = np.clip(
        inc_combined[off_r:off_r + tile_h, off_c:off_c + tile_w], 0, 90
    ).astype(np.uint8)

    # Build polygon mask for this tile
    # Geotransform origin for the core tile in the DEM CRS
    tile_west  = dem_origin_x + abs_c0 * res
    tile_north = dem_origin_y - abs_r0 * res   # origin_y is north; pixel rows go south
    tile_transform = rasterio.transform.from_origin(tile_west, tile_north, res, res)

    geoms = [shapely_wkt.loads(w) for w in poly_wkts]
    outside_mask = geometry_mask(
        geoms,
        transform=tile_transform,
        invert=False,          # False -> True where OUTSIDE polygon
        out_shape=(tile_h, tile_w),
    )

    shadow_tile[outside_mask] = out_nodata
    inc_tile   [outside_mask] = out_nodata

    # Write tile to pre-created output rasters
    write_win = Window(tile_col, tile_row, tile_w, tile_h)
    with rasterio.open(shadow_path,    'r+') as dst:
        dst.write(shadow_tile, 1, window=write_win)
    with rasterio.open(incidence_path, 'r+') as dst:
        dst.write(inc_tile,    1, window=write_win)

    return tile_row, tile_col, tile_h, tile_w

# ==============================================================================
# MAIN
# ==============================================================================

def main():
    if len(sys.argv) == 1:
        ts_str   = CONFIG["DEFAULT_TS"]
        dem_in   = CONFIG["DEFAULT_DEM"]
        gpkg_in  = CONFIG["DEFAULT_GPKG"]
        out_dir  = CONFIG["DEFAULT_OUT"]
        buffer_m = CONFIG["BUFFER_M"]
    elif len(sys.argv) in (5, 6):
        ts_str   = sys.argv[1]
        dem_in   = sys.argv[2]
        gpkg_in  = sys.argv[3]
        out_dir  = sys.argv[4]
        buffer_m = float(sys.argv[5]) if len(sys.argv) == 6 else CONFIG["BUFFER_M"]
    else:
        print("Usage: python shadow_fast.py <timestamp> <dem.tif> <boundary.gpkg> <output_dir> [buffer_m]")
        print("  timestamp : YYYYMMDDtHHMM  (UTC)")
        print("  buffer_m  : buffer in metres applied to gpkg geometry (default 10000)")
        sys.exit(1)

    dem_path  = Path(dem_in)
    gpkg_path = Path(gpkg_in)
    out_path  = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    # ---- Timestamp -----------------------------------------------------------
    dt = datetime.strptime(ts_str.replace('t', ' '), '%Y%m%d %H%M')
    dt = dt.replace(tzinfo=timezone.utc)
    print(f"Datetime (UTC): {dt.strftime('%Y-%m-%d %H:%M')}")

    # ---- Sun position --------------------------------------------------------
    jd = to_juliandate(dt)
    sv = sun_vector(jd, CONFIG["REF_LAT"], CONFIG["REF_LON"])
    sun_alt = np.rad2deg(np.arcsin(sv[2]))
    sun_az  = (np.rad2deg(np.arctan2(sv[0], sv[1])) + 360) % 360
    print(f"Sun altitude : {sun_alt:.2f}   azimuth: {sun_az:.2f}")
    if sun_alt < 0:
        print("  Sun is below the horizon -- output will be all-shadow.")
    elif sun_alt < 5:
        print(f"  Sun very low ({sun_alt:.2f}); shadows will be extremely long.")

    # ---- DEM metadata --------------------------------------------------------
    with rasterio.open(dem_path) as src:
        full_rows, full_cols = src.height, src.width
        dem_meta      = src.meta.copy()
        res           = src.res[0]
        dem_crs       = src.crs
        dem_transform = src.transform
        dem_nodata    = src.nodata

    # DEM origin (top-left corner of top-left pixel, in CRS units)
    dem_origin_x = dem_transform.c   # west
    dem_origin_y = dem_transform.f   # north

    print(f"\nDEM : {full_rows} rows x {full_cols} cols,  res={res} m,  CRS=EPSG:{dem_crs.to_epsg()}")
    print(f"DEM origin (west, north): ({dem_origin_x:.1f}, {dem_origin_y:.1f})")

    # ---- Load GeoPackage boundary and apply buffer --------------------------
    print(f"\nLoading boundary: {gpkg_path}")
    gdf = gpd.read_file(gpkg_path)
    if gdf.crs != dem_crs:
        print(f"  Reprojecting boundary: EPSG:{gdf.crs.to_epsg()} -> EPSG:{dem_crs.to_epsg()}")
        gdf = gdf.to_crs(dem_crs)

    # Dissolve all features into one polygon (removes internal boundaries)
    raw_boundary = unary_union(gdf.geometry)

    # Apply buffer on-the-fly.
    # Note: the gpkg may already be pre-buffered (e.g. 5 km); this adds on top.
    # If buffer_m == 0 the geometry is used as-is.
    if buffer_m > 0:
        print(f"  Applying {buffer_m/1000:.1f} km buffer to gpkg geometry ...")
        buffered_boundary = raw_boundary.buffer(buffer_m)
    else:
        print("  No additional buffer applied (buffer_m=0).")
        buffered_boundary = raw_boundary

    minx, miny, maxx, maxy = buffered_boundary.bounds
    print(f"  Buffered boundary bbox:  X [{minx:.0f}, {maxx:.0f}]   Y [{miny:.0f}, {maxy:.0f}]")
    print(f"  Buffer applied: {buffer_m/1000:.1f} km")

    # Serialise the BUFFERED geometry as WKT for pickle-safe transfer to workers
    # Use a single unified polygon for the mask (faster than many features)
    poly_wkts = [buffered_boundary.wkt]

    # ---- Snap bbox to DEM pixel grid -> output window -----------------------
    win_col_off = max(0, int(np.floor((minx - dem_origin_x) / res)))
    win_row_off = max(0, int(np.floor((dem_origin_y - maxy) / res)))
    win_col_end = min(full_cols, int(np.ceil((maxx - dem_origin_x) / res)) + 1)
    win_row_end = min(full_rows, int(np.ceil((dem_origin_y - miny) / res)) + 1)

    out_cols = win_col_end - win_col_off
    out_rows = win_row_end - win_row_off

    print(f"\n  Output window (DEM pixel coords):")
    print(f"    cols [{win_col_off}, {win_col_end})  rows [{win_row_off}, {win_row_end})")
    print(f"    size: {out_rows} rows x {out_cols} cols  ({out_rows * out_cols / 1e6:.1f} Mpx)")

    # ---- Halo size -----------------------------------------------------------
    TILE_SIZE = CONFIG["TILE_SIZE"]
    if sun_alt > 0:
        max_shadow_px = min(
            int(3500 / (res * np.tan(np.deg2rad(max(sun_alt, 1.0)))) + 0.5),
            TILE_SIZE
        )
    else:
        max_shadow_px = TILE_SIZE
    halo = max_shadow_px
    print(f"\nTile size: {TILE_SIZE} px,  halo: {halo} px")
    if NUMBA_AVAILABLE:
        print("Numba JIT: enabled")
    else:
        print("Numba JIT: NOT available (install numba for ~100x speedup)")

    # ---- Create output rasters -----------------------------------------------
    # IMPORTANT: workers write tiles concurrently.
    # Compressed (DEFLATE/LZW) tiled GeoTIFFs are NOT safe for concurrent
    # random writes -- the tile-offset index gets corrupted, causing
    # "IReadBlock failed / TIFFReadEncodedTile failed" and stripe artefacts.
    #
    # Solution: write to UNCOMPRESSED strip GeoTIFFs during processing
    # (strip layout = sequential byte offsets, safe for concurrent writes),
    # then recompress to a final tiled DEFLATE GeoTIFF in one serial pass.
    out_transform = rasterio.transform.from_origin(
        dem_origin_x + win_col_off * res,
        dem_origin_y - win_row_off * res,
        res, res
    )
    out_nodata = CONFIG["OUT_NODATA"]

    # Shared base metadata
    base_meta = dem_meta.copy()
    base_meta.update({
        'driver':    'GTiff',
        'dtype':     'uint8',
        'count':      1,
        'height':     out_rows,
        'width':      out_cols,
        'transform':  out_transform,
        'nodata':     out_nodata,
    })

    # Uncompressed strip layout for safe concurrent writes
    tmp_meta = base_meta.copy()
    tmp_meta.update({'compress': 'none', 'tiled': False})
    tmp_meta.pop('blockxsize', None)
    tmp_meta.pop('blockysize', None)
    tmp_meta.pop('predictor',  None)

    # Final compressed tiled layout (written serially at the end)
    final_meta = base_meta.copy()
    final_meta.update({
        'compress':   CONFIG["COMPRESSION"],
        'predictor':  CONFIG["PREDICTOR"],
        'tiled':      True,
        'blockxsize': 256,
        'blockysize': 256,
    })

    stem = f"{ts_str}_{dem_path.stem}_CH_buf{int(buffer_m)}m"
    shadow_tmp     = str(out_path / f"shadow_{stem}_tmp.tif")
    incidence_tmp  = str(out_path / f"incidence_angle_{stem}_tmp.tif")
    shadow_path    = str(out_path / f"shadow_{stem}.tif")
    incidence_path = str(out_path / f"incidence_angle_{stem}.tif")

    fill = np.full((out_rows, out_cols), out_nodata, dtype=np.uint8)
    for p in [shadow_tmp, incidence_tmp]:
        with rasterio.open(p, 'w', **tmp_meta) as dst:
            dst.write(fill, 1)

    print(f"\nTemp (uncompressed) files created:")
    print(f"  {shadow_tmp}")
    print(f"  {incidence_tmp}")

    # ---- Build tile list (coordinates relative to output window) ------------
    # Workers write to the UNCOMPRESSED tmp files (safe for concurrent access)
    tiles = []
    r = 0
    while r < out_rows:
        tile_h = min(TILE_SIZE, out_rows - r)
        c = 0
        while c < out_cols:
            tile_w = min(TILE_SIZE, out_cols - c)
            tiles.append((
                str(dem_path), shadow_tmp, incidence_tmp,   # <-- tmp paths
                r, c, tile_h, tile_w,
                out_rows, out_cols,
                win_row_off, win_col_off,
                full_rows, full_cols,
                halo,
                sv.tolist(), float(res), dem_nodata,
                out_nodata,
                poly_wkts,
                float(dem_origin_x), float(dem_origin_y),
            ))
            c += tile_w
        r += tile_h

    n_tiles   = len(tiles)
    n_workers = CONFIG["N_WORKERS"] or os.cpu_count()
    print(f"\nDispatching {n_tiles} tiles across {n_workers} workers ...")

    # ---- Parallel tile processing (writes to uncompressed tmp files) --------
    completed = 0
    failed    = 0
    with ProcessPoolExecutor(max_workers=n_workers) as pool:
        futures = {pool.submit(_process_tile, t): t for t in tiles}
        for fut in as_completed(futures):
            try:
                tr, tc, th, tw = fut.result()
                completed += 1
                pct = 100.0 * completed / n_tiles
                print(
                    f"  [{completed:4d}/{n_tiles}]  {pct:5.1f}%  "
                    f"row={tr:5d}  col={tc:5d}  {th}x{tw}",
                    flush=True
                )
            except Exception as exc:
                t = futures[fut]
                print(f"  ERROR  row={t[3]}  col={t[4]}: {exc}")
                failed += 1

    status = "Done" if failed == 0 else f"Done with {failed} failed tiles"
    print(f"\n{status}  ({completed}/{n_tiles} tiles OK)")

    # ---- Serial recompression pass ------------------------------------------
    # Read each uncompressed tmp file and write final compressed tiled COG.
    # Fast sequential I/O only -- no computation, typically < 1 min.
    print("\nRecompressing to final tiled DEFLATE GeoTIFFs ...")
    for tmp_p, final_p, label in [
        (shadow_tmp,    shadow_path,    "shadow"),
        (incidence_tmp, incidence_path, "incidence"),
    ]:
        print(f"  {label}: {Path(final_p).name} ...", end=" ", flush=True)
        with rasterio.open(tmp_p) as src:
            data = src.read(1)
        with rasterio.open(final_p, 'w', **final_meta) as dst:
            dst.write(data, 1)
        try:
            os.remove(tmp_p)
        except OSError:
            pass
        print("done")

    print(f"\nFinal outputs (nodata={out_nodata} outside boundary polygon):")
    print(f"  shadow     : 0=shadow  1=lit  {out_nodata}=outside boundary")
    print(f"  incidence  : 0-90 deg  90 in shadow  {out_nodata}=outside boundary")
    print(f"  {shadow_path}")
    print(f"  {incidence_path}")


if __name__ == "__main__":
    multiprocessing.freeze_support()   # required on Windows

    # ------------------------------------------------------------------ #
    # VS Code / direct-run override                                        #
    # When running from the IDE (no CLI args), inject args here instead    #
    # of relying on sys.argv.  Comment out when running from the terminal. #
    # ------------------------------------------------------------------ #
    if len(sys.argv) == 1:
        sys.argv = [
            "shadow_fast.py",
            "20251228t1014",
            r"D:\temp\github\topo-satromo-v2\local_assets\DSM_10m_EPSG2056_CH_clipped_10km.tif",
            r"D:\temp\github\topo-satromo-v2\assets\swissboundary_buffer_5000m_22.gpkg",
            r"D:\temp\shadow_output",
            "10000",   # buffer in metres
        ]

    main()