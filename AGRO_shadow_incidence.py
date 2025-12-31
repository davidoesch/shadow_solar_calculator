#!/usr/bin/env python3
"""
Simplified shadow and sun incidence angle calculation without tiling/multiprocessing.
Based on: https://github.com/tomderuijter/python-dem-shadows

FINAL CORRECTED VERSION:
- Timestamp interpreted as UTC (not local time)
- Shadow: 0 = shadow, 1 = no shadow (8-bit)
- Sun incidence: 0-99 (8-bit, scaled percentage)
"""

import sys
import numpy as np
import rasterio
from datetime import datetime, timezone
from pathlib import Path

# ==============================================================================
# CONFIGURATION
# ==============================================================================
CONFIG = {
    "DEFAULT_TS": "20210602t1005",
    "DEFAULT_DEM": "LIDAR_MAX_subset_engadin.tif",
    "DEFAULT_OUT": "./output_results",
    
    # Location for sun position (Central Switzerland reference)
    "REF_LAT": 46.8182,
    "REF_LON": 8.2275,
    
    "COMPRESSION": "deflate",
    "PREDICTOR": 2,
}

# ==============================================================================
# SOLAR POSITION FUNCTIONS (from solar.py)
# ==============================================================================

def to_juliandate(d):
    """Convert a datetime object to a julian date."""
    seconds_per_day = 86400
    return d.timestamp() / seconds_per_day + 2440587.5


def _equation_of_time(julian_date):
    """Calculate the equation of time."""
    jdc = (julian_date - 2451545.0) / 36525.0
    sec = 21.448 - jdc * (46.8150 + jdc * (0.00059 - jdc * 0.001813))
    e0 = 23.0 + (26.0 + (sec / 60.0)) / 60.0
    oblcorr = e0 + 0.00256 * np.cos(np.deg2rad(125.04 - 1934.136 * jdc))
    l0 = 280.46646 + jdc * (36000.76983 + jdc * 0.0003032)
    l0 = (l0 - 360 * (l0 // 360)) % 360
    gmas = np.deg2rad(357.52911 + jdc * (35999.05029 - 0.0001537 * jdc))
    ecc = 0.016708634 - jdc * (0.000042037 + 0.0000001267 * jdc)
    y = (np.tan(np.deg2rad(oblcorr) / 2)) ** 2
    rl0 = np.deg2rad(l0)
    EqTime = (y * np.sin(2 * rl0) - 
              2.0 * ecc * np.sin(gmas) + 
              4.0 * ecc * y * np.sin(gmas) * np.cos(2 * rl0) - 
              0.5 * y * y * np.sin(4 * rl0) - 
              1.25 * ecc * ecc * np.sin(2 * gmas))
    return np.rad2deg(EqTime) * 4


def sun_declination(julian_date):
    """Compute the declination of the sun on a given day."""
    jdc = (julian_date - 2451545.0) / 36525.0
    sec = 21.448 - jdc * (46.8150 + jdc * (0.00059 - jdc * .001813))
    e0 = 23.0 + (26.0 + (sec / 60.0)) / 60.0
    oblcorr = e0 + 0.00256 * np.cos(np.deg2rad(125.04 - 1934.136 * jdc))
    l0 = 280.46646 + jdc * (36000.76983 + jdc * 0.0003032)
    l0 = (l0 - 360 * (l0 // 360)) % 360
    gmas = 357.52911 + jdc * (35999.05029 - 0.0001537 * jdc)
    gmas = np.deg2rad(gmas)
    seqcent = (np.sin(gmas) * (1.914602 - jdc * (0.004817 + 0.000014 * jdc)) + 
               np.sin(2 * gmas) * (0.019993 - 0.000101 * jdc) + 
               np.sin(3 * gmas) * 0.000289)
    suntl = l0 + seqcent
    sal = suntl - 0.00569 - 0.00478 * np.sin(np.deg2rad(125.04 - 1934.136 * jdc))
    delta = np.arcsin(np.sin(np.deg2rad(oblcorr)) * np.sin(np.deg2rad(sal)))
    return np.rad2deg(delta)


def _hour_angle(julian_date, longitude):
    """Internal function for solar position calculation using UTC."""
    # Julian day starts at NOON, not midnight!
    # Get fractional day (0.0 = noon, 0.5 = midnight)
    fractional_day = julian_date - np.floor(julian_date)
    # Convert to hours since noon (0 = noon, 12 = midnight, 24 = next noon)
    hour_since_noon = fractional_day * 24
    # Convert to UTC hour (0-24, where 0 = midnight)
    hour_utc = (hour_since_noon + 12) % 24
    
    time_offset = _equation_of_time(julian_date)
    
    # Convert longitude to time offset (degrees to hours)
    # Positive longitude (East) = sun arrives earlier
    longitude_time = longitude / 15.0  # 15 degrees per hour
    
    # Solar time = UTC + longitude offset + equation of time
    solar_time = hour_utc + longitude_time + time_offset / 60.0
    
    # Hour angle: 0 at solar noon, negative before noon, positive after
    omega_r = np.pi * ((solar_time / 12.0) - 1.0)
    return omega_r


def sun_vector(julian_date, latitude, longitude):
    """Calculate a unit vector in the direction of the sun using UTC time."""
    omega_r = _hour_angle(julian_date, longitude)
    delta_r = np.deg2rad(sun_declination(julian_date))
    lambda_r = np.deg2rad(latitude)
    
    svx = -np.sin(omega_r) * np.cos(delta_r)
    svy = np.sin(lambda_r) * np.cos(omega_r) * np.cos(delta_r) - np.cos(lambda_r) * np.sin(delta_r)
    svz = np.cos(lambda_r) * np.cos(omega_r) * np.cos(delta_r) + np.sin(lambda_r) * np.sin(delta_r)
    return np.array([svx, svy, svz])

# ==============================================================================
# GRADIENT FUNCTIONS (from gradient.py)
# ==============================================================================

def gradient(grid, length_x, length_y=None):
    """Calculate the numerical gradient of a matrix in X, Y and Z directions."""
    if length_y is None:
        length_y = length_x

    assert len(grid.shape) == 2, "Grid should be a matrix."

    grad = np.empty((*grid.shape, 3))
    grad[:] = np.nan
    grad[:-1, :-1, 0] = 0.5 * length_y * (
        grid[:-1, :-1] - grid[:-1, 1:] + grid[1:, :-1] - grid[1:, 1:]
    )
    grad[:-1, :-1, 1] = 0.5 * length_x * (
        grid[:-1, :-1] + grid[:-1, 1:] - grid[1:, :-1] - grid[1:, 1:]
    )
    grad[:-1, :-1, 2] = length_x * length_y

    # Copy last row and column
    grad[-1, :, :] = grad[-2, :, :]
    grad[:, -1, :] = grad[:, -2, :]

    area = np.sqrt(
        grad[:, :, 0] ** 2 +
        grad[:, :, 1] ** 2 +
        grad[:, :, 2] ** 2
    )
    for i in range(3):
        grad[:, :, i] /= area
    return grad


def incidence_angle(grad, sun_vector):
    """
    Compute the incidence angle of sunlight on a surface.
    
    Returns angle in degrees (0-90°):
    - 0° = light perpendicular to surface (maximum illumination)
    - 90° = light parallel to surface (no illumination)
    """
    # Dot product gives cosine of incidence angle
    cos_incidence = (
        grad[:, :, 0] * sun_vector[0] +
        grad[:, :, 1] * sun_vector[1] +
        grad[:, :, 2] * sun_vector[2]
    )
    
    # Clip to valid range [-1, 1] to avoid numerical errors in arccos
    cos_incidence = np.clip(cos_incidence, -1.0, 1.0)
    
    # Calculate angle in radians, then convert to degrees
    angle_rad = np.arccos(cos_incidence)
    angle_deg = np.rad2deg(angle_rad)
    
    # For surfaces facing away from sun (angle > 90°), set to 90° (no light)
    angle_deg = np.clip(angle_deg, 0, 90)
    
    return angle_deg

# ==============================================================================
# SHADOW PROJECTION FUNCTIONS (from shadows.py)
# ==============================================================================

def _normalize_sun_vector(sun_vector):
    """Normalize sun vector for shadow calculation."""
    normal_sun_vector = np.zeros(3)
    normal_sun_vector[2] = np.sqrt(sun_vector[0] ** 2 + sun_vector[1] ** 2)
    if normal_sun_vector[2] == 0:
        # Sun is directly overhead or below horizon
        return np.array([0, 0, 1])
    normal_sun_vector[0] = -sun_vector[0] * sun_vector[2] / normal_sun_vector[2]
    normal_sun_vector[1] = -sun_vector[1] * sun_vector[2] / normal_sun_vector[2]
    return normal_sun_vector


def _invert_sun_vector(sun_vector):
    """Invert sun vector for shadow calculation."""
    max_xy = max(abs(sun_vector[0]), abs(sun_vector[1]))
    if max_xy == 0:
        return np.array([0, 0, -1])
    return -sun_vector / max_xy


def _cast_shadow(row, col, rows, cols, dl, in_sun, inverse_sun_vector,
                 normal_sun_vector, z):
    """Cast shadow from a single starting point."""
    n = 0
    z_previous = -1e20  # Very large negative number

    while True:
        # Calculate projection offset
        dx = inverse_sun_vector[0] * n
        dy = inverse_sun_vector[1] * n
        col_dx = int(round(col + dx))
        row_dy = int(round(row + dy))
        
        if (col_dx < 0) or (col_dx >= cols) or (row_dy < 0) or (row_dy >= rows):
            break

        vector_to_origin = np.zeros(3)
        vector_to_origin[0] = dx * dl
        vector_to_origin[1] = dy * dl
        vector_to_origin[2] = z[col_dx, row_dy]
        z_projection = np.dot(vector_to_origin, normal_sun_vector)

        if z_projection < z_previous:
            in_sun[col_dx, row_dy] = 0
        else:
            z_previous = z_projection
        n += 1


def project_shadows(dem, sun_vector, dx, dy=None):
    """Cast shadows on the DEM from a given sun position."""
    if dy is None:
        dy = dx

    inverse_sun_vector = _invert_sun_vector(sun_vector)
    normal_sun_vector = _normalize_sun_vector(sun_vector)

    rows, cols = dem.shape
    z = dem.T

    # Determine sun direction
    if sun_vector[0] < 0:
        # The sun shines from the West
        start_col = 1
    else:
        # The sun shines from the East
        start_col = cols - 1

    if sun_vector[1] < 0:
        # The sun shines from the North
        start_row = 1
    else:
        # The sun shines from the South
        start_row = rows - 1

    in_sun = np.ones_like(z)
    
    # Project West-East
    row = start_row
    for col in range(cols):
        _cast_shadow(row, col, rows, cols, dx, in_sun, inverse_sun_vector,
                     normal_sun_vector, z)

    # Project North-South
    col = start_col
    for row in range(rows):
        _cast_shadow(row, col, rows, cols, dy, in_sun, inverse_sun_vector,
                     normal_sun_vector, z)
    
    return in_sun.T

# ==============================================================================
# MAIN PROCESSING
# ==============================================================================

def main():
    # Parse command line arguments
    if len(sys.argv) == 1:
        ts_str = CONFIG["DEFAULT_TS"]
        dem_in = CONFIG["DEFAULT_DEM"]
        out_dir = CONFIG["DEFAULT_OUT"]
    elif len(sys.argv) == 4:
        ts_str = sys.argv[1]
        dem_in = sys.argv[2]
        out_dir = sys.argv[3]
    else:
        print("Usage: python shadow_utc.py [timestamp] [dem_file] [output_dir]")
        print("Example: python shadow_utc.py 20210602t1005 dem.tif ./output")
        print("\nTimestamp format: YYYYMMDDtHHMM (UTC time)")
        print("  20210602t1005 = June 2, 2021 at 10:05 UTC")
        sys.exit(1)

    dem_path = Path(dem_in)
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    
    # Parse timestamp - interpret as UTC
    dt = datetime.strptime(ts_str.replace('t', ' '), '%Y%m%d %H%M')
    dt = dt.replace(tzinfo=timezone.utc)
    print(f"Processing datetime: {dt.strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"Location: Lat {CONFIG['REF_LAT']:.4f}°, Lon {CONFIG['REF_LON']:.4f}°")
    
    # Calculate sun position
    jd = to_juliandate(dt)
    sv = sun_vector(jd, CONFIG["REF_LAT"], CONFIG["REF_LON"])
    
    sun_alt = np.rad2deg(np.arcsin(sv[2]))
    sun_az = np.rad2deg(np.arctan2(sv[0], sv[1]))
    if sun_az < 0:
        sun_az += 360
    
    print(f"\n=== SUN POSITION ===")
    print(f"Sun altitude: {sun_alt:.2f}° (0° = horizon, 90° = zenith)")
    print(f"Sun azimuth: {sun_az:.2f}° (0° = North, 90° = East, 180° = South, 270° = West)")
    print(f"Sun vector: [{sv[0]:.4f}, {sv[1]:.4f}, {sv[2]:.4f}]")
    
    if sun_alt < 0:
        print("\n⚠️  WARNING: Sun is below horizon! Shadows may not be meaningful.")
        print(f"   Sun altitude: {sun_alt:.2f}° (negative means night time)")
    elif sun_alt < 5:
        print(f"\n⚠️  WARNING: Sun is very low ({sun_alt:.2f}°). Shadows will be very long.")
    else:
        print(f"\n✓ Sun is above horizon at {sun_alt:.2f}° - good for shadow calculation")
    
    # Read DEM
    print(f"\n=== READING DEM ===")
    print(f"DEM file: {dem_path}")
    with rasterio.open(dem_path) as src:
        dem = src.read(1)
        meta = src.meta
        res = src.res[0]  # Assuming square pixels
        
    print(f"DEM shape: {dem.shape[0]} rows × {dem.shape[1]} cols")
    print(f"Resolution: {res} m")
    print(f"DEM elevation range: {np.nanmin(dem):.1f} to {np.nanmax(dem):.1f} m")
    
    # Calculate gradient
    print("\n=== CALCULATING TERRAIN PROPERTIES ===")
    print("Calculating gradient...")
    grad = gradient(dem, res)
    
    # Calculate incidence angle (0-90°)
    print("Calculating incidence angle...")
    inc_angle = incidence_angle(grad, sv)
    
    # Calculate shadows
    print("Calculating shadows (this may take a while)...")
    shadow_mask = project_shadows(dem, sv, res)
    
    # For shadowed areas, set incidence angle to 90° (no light)
    print("Combining shadow and incidence angle...")
    inc_angle_with_shadow = inc_angle.copy()
    inc_angle_with_shadow[shadow_mask == 0] = 90.0
    
    # Statistics
    shadow_pct = (np.sum(shadow_mask == 0) / shadow_mask.size) * 100
    mean_inc_angle = np.mean(inc_angle)
    mean_inc_angle_illuminated = np.mean(inc_angle[shadow_mask == 1])
    
    print(f"\n=== RESULTS ===")
    print(f"Shadowed pixels: {shadow_pct:.1f}%")
    print(f"Illuminated pixels: {100-shadow_pct:.1f}%")
    print(f"Mean incidence angle (all): {mean_inc_angle:.1f}°")
    print(f"Mean incidence angle (illuminated only): {mean_inc_angle_illuminated:.1f}°")
    
    # Prepare output metadata for 8-bit
    out_meta = meta.copy()
    out_meta.update({
        'dtype': 'uint8',
        'count': 1,
        'compress': CONFIG["COMPRESSION"],
        'predictor': CONFIG["PREDICTOR"],
        'nodata': None,  # No nodata value for 8-bit
    })
    
    # Save shadow mask (0 = shadow, 1 = no shadow) as 8-bit
    shadow_8bit = (1 - shadow_mask).astype(np.uint8)  # Invert: 0=shadow, 1=no shadow
    shadow_out = out_path / f"shadow_{ts_str}_{dem_path.stem}.tif"
    print(f"\n=== SAVING OUTPUTS ===")
    print(f"Shadow mask: {shadow_out}")
    print(f"  Format: 8-bit, 0 = shadow, 1 = no shadow")
    with rasterio.open(shadow_out, 'w', **out_meta) as dst:
        dst.write(shadow_8bit, 1)
        dst.set_band_description(1, "Shadow: 0=shadow, 1=no shadow")
    
    # Save incidence angle (0-90°) as 8-bit
    inc_angle_8bit = np.clip(inc_angle_with_shadow, 0, 90).astype(np.uint8)
    incidence_out = out_path / f"incidence_angle_{ts_str}_{dem_path.stem}.tif"
    print(f"Incidence angle: {incidence_out}")
    print(f"  Format: 8-bit, 0-90° (0°=perpendicular/max light, 90°=parallel/no light)")
    with rasterio.open(incidence_out, 'w', **out_meta) as dst:
        dst.write(inc_angle_8bit, 1)
        dst.set_band_description(1, "Incidence angle: 0-90 degrees")
    
    print("\n✓ Processing complete!")
    print("\nOutput files:")
    print(f"  1. Shadow mask (8-bit): 0=shadow, 1=no shadow")
    print(f"  2. Incidence angle (8-bit): 0-90° (0°=perpendicular, 90°=no light)")
    print(f"     - Shadowed areas are set to 90°")
    print(f"\nTimestamp was interpreted as UTC: {dt.strftime('%Y-%m-%d %H:%M UTC')}")


if __name__ == "__main__":
    import sys
    main()