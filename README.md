# GRASS Solar Shadow Calculation Tools

Collection of Bash scripts to create a GRASS GIS location from a DSM, precompute slope/aspect, and calculate solar incidence / shadow masks for given day(s) and time ranges using r.sun. **Optimized for Sentinel-2 satellite overpass time matching (10:00-11:00 UTC).**

This repository contains three scripts:
- `setup_grass_location.sh` — create a GRASS location from a georeferenced DSM and import the DSM (creates `INPUT_DSM`, sets region, precomputes slope/aspect).
- `calculate_shadows_loop.sh` — time-looped runner that calls `r.sun` for time steps and exports shadow masks and 8-bit incidence rasters to GeoTIFF with UTC time matching.
- `calculate_shadows_optimized.sh` — an optimized, safer, and more featureful version tuned for machines with many cores and large memory (180 CPUs / 1 TB RAM in the script example). Uses GDAL and TIFF optimizations (ZSTD compression) and removes intermediate rasters to save space.

## About

These scripts automate a common workflow for producing per-time-step solar incidence and binary shadow masks using GRASS GIS `r.sun`. Typical use-cases include solar resource assessment, microclimate/shade analysis, and input layers for EO products.

**Key Features:**
- ✅ Automatic UTC time zone detection (Switzerland CET/CEST)
- ✅ Configured for Sentinel-2 overpass times (10:00-11:00 UTC)
- ✅ 8-bit binned solar incidence angles (0-90° → 0-254)
- ✅ Output filenames include both local and UTC times
- ✅ Optimized for high-performance servers (180 CPUs, 1TB RAM)
- ✅ ZSTD compression for fast I/O and small file sizes

## Requirements

- GRASS GIS (7.x or 8.x) installed and on PATH (commands: `grass`)
- GDAL (`gdal`/`r.out.gdal` used by GRASS)
- Bash (POSIX)
- coreutils: `mkdir`, `ls`, `du`, `rm`
- `bc`, `awk`
- Sufficient disk space to store generated GeoTIFFs (see Performance tips)

## Files & Purpose

### setup_grass_location.sh
- Creates `$GRASSDATA` (default: `$HOME/grassdata`) and a `swiss_project` location
- Imports a georeferenced DSM (Digital Surface Model) as `INPUT_DSM`
- Automatically detects projection from input file (CH1903+ / LV95 for Swiss data)
- Sets computational region to the DSM extent
- Precalculates `slope_deg` and `aspect_deg` using all available CPU cores
- Optimized for 180 CPUs and 1TB RAM

### calculate_shadows_loop.sh
- Lightweight looped implementation that:
  - Checks/creates slope & aspect
  - Runs `r.sun` for each time step between `START_HOUR` and `END_HOUR` at `INTERVAL_MINUTES`
  - Automatically handles UTC time conversion with `civil_time` parameter
  - Writes shadow mask (`1` = shadow, `0` = illuminated) and 8-bit solar incidence GeoTIFFs
  - Output directory: `./shadow_outputs_doy<DOY>/`
  - Filenames include both local and UTC times for easy satellite matching

### calculate_shadows_optimized.sh
- Robust version with:
  - `set -euo pipefail` for safety
  - Timestamped logging function
  - GDAL and TIFF compression optimizations (ZSTD)
  - Explicit core (NPROCS=180) and GDAL tuning (GDAL_CACHEMAX=16384, GDAL_NUM_THREADS=8)
  - Cleanup of intermediate rasters to reduce storage usage
  - Summary statistics (file counts, total size, average time per step)
  - Array-based time step generation for precise timing
  - Automatic summer/winter time zone detection

## Quick Start

### 1. Make Scripts Executable
```bash
chmod +x setup_grass_location.sh calculate_shadows_loop.sh calculate_shadows_optimized.sh
```

### 2. Create a GRASS Location and Import DSM
```bash
./setup_grass_location.sh /path/to/Thinout_highest_object_10m_LV95_LHN95_ref.tif
```

- By default, the scripts use GRASS database at `$HOME/grassdata` and location `swiss_project`.
- You can override GRASSDATA before running:
  ```bash
  export GRASSDATA=/data/grassdb
  ```

### 3. Run the Optimized Shadow Calculation (Recommended)
```bash
./calculate_shadows_optimized.sh 153
```

- This will process day-of-year 153 (June 2)
- Automatically detects summer time zone (UTC+2)
- Processes 10:00-11:00 UTC (Sentinel-2 overpass time)
- Outputs are written to `./shadow_outputs_doy153/`
- 30 time steps at 2-minute intervals

## Usage Examples

### Run Loop Version for DOY 153
```bash
./calculate_shadows_loop.sh 153
```

### Run Optimized Version for DOY 200
```bash
./calculate_shadows_optimized.sh 200
```

### Use a Custom GRASS Database Location
```bash
export GRASSDATA=/mnt/grassdata
./setup_grass_location.sh /path/to/dsm.tif
./calculate_shadows_optimized.sh 153
```

### Process Winter Day (Adjusts to UTC+1 Automatically)
```bash
./calculate_shadows_optimized.sh 50
```
Note: For winter, you may need to edit START_HOUR in the script (see Configuration section)

## Configuration / Important Variables

### Common Variables (All Scripts)
- `DOY` — day of year (argument to scripts, defaults to 153 if not provided)
- `YEAR` — calendar year (kept for metadata, currently 2021)
- `GRASSDATA` — GRASS database path, default `$HOME/grassdata` (can be exported in environment)
- `LOCATION` — GRASS location name (default: `swiss_project`)
- `MAPSET` — GRASS mapset (default: `PERMANENT`)
- `INPUT_DSM` — raster name used inside GRASS (Digital Surface Model)
- `SLOPE` / `ASPECT` — derived rasters names (`slope_deg`, `aspect_deg`)

### Time Configuration (Shadow Calculation Scripts)
- `START_HOUR` — local time to start processing (default: 12 for summer, matches 10:00 UTC)
- `END_HOUR` — local time to end processing (default: 13 for summer, matches 11:00 UTC)
- `INTERVAL_MINUTES` — time step interval (default: 2.0 minutes, 30 steps per hour)
- `CIVIL_TIME` — automatically set based on DOY:
  - Summer (DOY 80-304): `CIVIL_TIME=2` (CEST = UTC+2)
  - Winter (DOY 1-79, 305-365): `CIVIL_TIME=1` (CET = UTC+1)

### Performance Settings
- `NPROCS` — cores passed to r.sun / r.slope.aspect (default: 180)
- `GDAL_CACHEMAX` — GDAL memory cache in MB (default: 16384 = ~16GB)
- `GDAL_NUM_THREADS` — GDAL thread count (default: 8)
- `COMPRESS` — GDAL/TIFF creation options (default: ZSTD with ZLEVEL=1, tiled)

### For Different Satellite Overpass Times

To match different satellite overpass times, use the formula:
```
START_HOUR = UTC_satellite_time + CIVIL_TIME
```

**Example for 09:00 UTC in summer:**
```bash
# Edit the script and change:
START_HOUR=11  # 9 + 2 (summer offset)
END_HOUR=12
```

**Example for 10:00 UTC in winter:**
```bash
# Edit the script and change:
START_HOUR=11  # 10 + 1 (winter offset)
END_HOUR=12
```

## Output Format & Naming Convention

### Output Directory
```
./shadow_outputs_doy<DOY>/
```

### Shadow Mask Files
```
shadow_mask_doy<DOY>_<HHMM>_UTC<HHMM>.tif
```
- Example: `shadow_mask_doy153_1200_UTC1000.tif`
  - `doy153` = Day of year 153 (June 2)
  - `1200` = 12:00 local time (CEST = UTC+2)
  - `UTC1000` = 10:00 UTC (Sentinel-2 overpass time)
- Binary map: `1` = shadow, `0` = illuminated
- Data type: Byte (8-bit)
- Compression: ZSTD

### Solar Incidence Files (8-bit Binned)
```
solar_incidence_8bit_doy<DOY>_<HHMM>_UTC<HHMM>.tif
```
- Example: `solar_incidence_8bit_doy153_1200_UTC1000.tif`
- Values: 0-254 represent incidence angles scaled from 0-90°
- Value 255 = NoData (shadowed areas)
- Data type: Byte (8-bit)
- Compression: ZSTD
- **To convert back to degrees:** `angle_degrees = (pixel_value × 90.0) / 255.0`

### Benefits of 8-bit Incidence Angles
- **75% file size reduction** compared to Float32
- **Faster I/O** operations
- **Sufficient precision** for most analyses (~0.35° resolution)
- **NoData handling** built into format (value 255)

### Intermediate GRASS Raster Names
These are created during processing and cleaned up after export:
- `beam_rad_doy<DOY>_<HHMM>`
- `solar_incidence_doy<DOY>_<HHMM>`
- `solar_incidence_8bit_doy<DOY>_<HHMM>`
- `shadow_mask_doy<DOY>_<HHMM>`

## UTC Time Matching for Satellites

### Automatic Time Zone Detection

The scripts automatically detect the appropriate time zone based on DOY:

| DOY Range | Season | Time Zone | UTC Offset | CIVIL_TIME |
|-----------|--------|-----------|------------|------------|
| 80-304 | Summer | CEST | UTC+2 | 2 |
| 1-79, 305-365 | Winter | CET | UTC+1 | 1 |

### Sentinel-2 Configuration (Default)

The scripts are **pre-configured for Sentinel-2** overpass times:
- **Sentinel-2 UTC time:** 10:00-11:00 UTC
- **Summer (DOY 80-304):** `START_HOUR=12, END_HOUR=13` → processes 10:00-11:00 UTC ✅
- **Winter (DOY 1-79, 305-365):** Edit script to `START_HOUR=11, END_HOUR=12` → processes 10:00-11:00 UTC

### Verification

When the script runs, check the log output:
```
Time zone: UTC+2 (summer)
Local time range: 12:00 - 13:00
UTC time range: 10:00 - 11:00 (for satellite matching)
```

The UTC time range should match your satellite overpass time.

### Output Filenames Include UTC Time

Output files include both local and UTC times in the filename, making it easy to verify you've matched the correct satellite time:
```
shadow_mask_doy153_1200_UTC1000.tif
                    ^^^^     ^^^^
                    Local    UTC
```

## Performance Tips

### For High-Performance Servers (Like Yours: 180 CPUs, 1TB RAM)
- Use `calculate_shadows_optimized.sh` (already configured)
- Default settings (`NPROCS=180`, `GDAL_CACHEMAX=16384`) are optimized for your system
- ZSTD compression (`ZLEVEL=1`) provides fast compression with good size reduction
- Processing one hour (30 time steps) takes approximately 8-10 minutes

### For Smaller Systems
Edit these variables in the script:
- `NPROCS` — set to number of available CPU cores minus 2-4 for system
- `GDAL_CACHEMAX` — set to 25-50% of available RAM in MB (e.g., 4096 for 16GB RAM)
- `GDAL_NUM_THREADS` — set to 2-4
- Consider `COMPRESS="COMPRESS=LZW"` for broader compatibility

### Storage Optimization
- **8-bit incidence angles** save ~75% space vs Float32
- ZSTD compression reduces file sizes by ~50% vs uncompressed
- Intermediate rasters are automatically cleaned up
- For 30 time steps (1 hour), expect ~2-4 GB output (depends on DSM size)

### I/O Optimization
- Use local fast SSD when possible
- ZSTD with `ZLEVEL=1` is optimized for speed over maximum compression
- Tiled GeoTIFFs (`BLOCKXSIZE=512, BLOCKYSIZE=512`) improve read performance

### Parallel Processing
- Single DOY uses all cores internally via `nprocs` parameter
- To process multiple DOYs: run separate script instances for different DOYs
- **Warning:** Don't access the same GRASS mapset concurrently

## Troubleshooting

### GRASS Command Not Found
- Ensure GRASS is installed and `grass` is on PATH
- You may need to load a module or source GRASS environment

### Permission Errors Writing Output
- Check that the current user has write permissions to the working directory and `$GRASSDATA`

### r.sun Fails or Returns Zeros/Nulls
- Confirm `INPUT_DSM`, `slope_deg`, `aspect_deg` exist inside the GRASS mapset
- Run a single r.sun call interactively inside the GRASS session to debug parameters
- Check that DSM has valid data and proper projection

### UTC Times Look Wrong in Output
- Verify DOY is in correct season range (80-304 for summer)
- Check log output for detected time zone
- Verify formula: `LOCAL_TIME - CIVIL_TIME = UTC_TIME`
- Example: 12:00 local - 2 (summer) = 10:00 UTC ✅

### Time Precision/Loop Rounding Issues
- Use integer or simple decimal minutes (1.0, 2.0, 2.5, 5.0)
- Avoid complex decimals that cause floating point errors
- Current default (2.0 minutes) works perfectly

### Output Files Are Too Large
- Check that ZSTD compression is enabled (`COMPRESS` variable)
- Verify 8-bit output is being created (not Float32)
- Use `gdalinfo` on output files to check compression and data type

### Processing Is Too Slow
- Increase `NPROCS` (but leave some cores for system)
- Increase `GDAL_CACHEMAX` if you have more RAM
- Use faster storage (SSD vs HDD)
- Check if system is I/O bound vs CPU bound (use `htop` and `iotop`)

## Notes on Time Formatting

- Time string is created from a floating-hour value
  - 10.00 → `1000` (10:00)
  - 10.25 → `1025` (10:15)
  - 12.5 → `1230` (12:30)
- The scripts calculate `INTERVAL_HOURS = INTERVAL_MINUTES / 60`
- Loop runs from `START_HOUR` to `END_HOUR` (exclusive)
- UTC time is calculated as: `UTC_TIME = LOCAL_TIME - CIVIL_TIME`

## Projection Information

### Swiss Coordinate System (Default)
The scripts are configured for Swiss data using:
- **Projection:** CH1903+ / LV95 (EPSG:2056)
- **Vertical datum:** LHN95
- **Units:** Meters
- **Extent:** Switzerland and Liechtenstein

The projection is automatically detected from your input DSM file.

### For Other Projections
The scripts should work with any projected coordinate system. GRASS will automatically detect the projection from your georeferenced input file during location creation.

## Recommendations / Future Improvements

- ✅ ~~Adapt for LV95~~ (Done - automatic projection detection)
- Add CLI parameter parser (getopts) to configure START_HOUR, END_HOUR, INTERVAL, NPROCS, OUTPUT_DIR without editing scripts
- Add unit tests / dry-run mode to validate configuration without launching heavy computation
- Add aggregate step to combine shadow masks across time or produce daily shadow frequency rasters
- Consider using a GRASS session wrapper to reduce repeated mapset startup cost for many time steps
- Add support for multiple DOYs in a single run
- Create visualization scripts for output files

## Example Workflow: Processing Sentinel-2 Scenes

### 1. Prepare Your DSM
```bash
# Verify your DSM projection and extent
gdalinfo Thinout_highest_object_10m_LV95_LHN95_ref.tif
```

### 2. Set Up GRASS Location
```bash
./setup_grass_location.sh Thinout_highest_object_10m_LV95_LHN95_ref.tif
```

### 3. Process Multiple Dates
```bash
# Summer scenes (June-August)
./calculate_shadows_optimized.sh 153  # June 2
./calculate_shadows_optimized.sh 181  # June 30
./calculate_shadows_optimized.sh 213  # August 1

# Winter scene (January) - remember to edit START_HOUR to 11 first!
./calculate_shadows_optimized.sh 15   # January 15
```

### 4. Verify Output
```bash
# Check output directory
ls -lh shadow_outputs_doy153/

# Verify a file
gdalinfo shadow_outputs_doy153/shadow_mask_doy153_1200_UTC1000.tif
```

## System Requirements for Different Scales

### Small DSM (< 1000 x 1000 pixels)
- **CPU:** 4+ cores
- **RAM:** 8 GB
- **Storage:** 1 GB per hour processed
- **Processing time:** ~5-10 minutes per hour

### Medium DSM (1000-10000 pixels, like 5000x5000)
- **CPU:** 16+ cores
- **RAM:** 32 GB
- **Storage:** 5 GB per hour processed
- **Processing time:** ~10-20 minutes per hour

### Large DSM (> 10000 pixels, like 34901x22101 Swiss example)
- **CPU:** 80-180 cores
- **RAM:** 500 GB - 1 TB
- **Storage:** 10-20 GB per hour processed
- **Processing time:** ~8-10 minutes per hour (with 180 cores)

## License

MIT

## Acknowledgements

- **GRASS GIS project** — for `r.sun`, `r.slope.aspect`, `r.mapcalc`, `r.out.gdal`
- **GDAL** — for GeoTIFF export and optimizations
- **Sentinel-2 mission** — for reliable 10:00-11:00 UTC overpass times

## Contact & Support

For issues or questions:
1. Check the Troubleshooting section above
2. Verify your configuration matches the examples
3. Check GRASS GIS documentation: https://grass.osgeo.org/grass-stable/manuals/r.sun.html
4. Review the TIME_ZONE_GUIDE.md for detailed UTC time matching information

## Version History

- **v2.0** (Current)
  - Added automatic UTC time zone detection
  - Configured for Sentinel-2 overpass times
  - Implemented 8-bit binned solar incidence angles
  - Added UTC times to output filenames
  - Optimized for 180 CPUs and 1TB RAM
  - Changed from LZW to ZSTD compression
  - Renamed DEM to INPUT_DSM
  - Added comprehensive logging
  
- **v1.0** (Original)
  - Basic shadow calculation workflow
  - 88 CPU optimization
  - LZW compression
