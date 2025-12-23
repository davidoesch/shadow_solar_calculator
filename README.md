# GRASS Solar Shadow Calculation Tools

Collection of Bash scripts to create a GRASS GIS location from a DEM, precompute slope/aspect, and calculate solar incidence / shadow masks for given day(s) and time ranges using r.sun.

This repository contains three scripts:
- `setup_grass_location.sh` — create a GRASS location from a georeferenced DEM and import the DEM (creates `INPUT_DEM`, sets region, precomputes slope/aspect).
- `calculate_shadows_loop.sh` — simple time-looped runner that calls `r.sun` for time steps and exports shadow masks and incidence rasters to GeoTIFF.
- `calculate_shadows_optimized.sh` — an optimized, safer, and more featureful version tuned for machines with many cores and large memory (88 CPUs / 1 TB RAM in the script example, takes approx 8min for one run for swissALTIRegio). Uses GDAL and TIFF optimizations and removes intermediate rasters to save space.


About
-----
These scripts automate a common workflow for producing per-time-step solar incidence and binary shadow masks using GRASS GIS `r.sun`. Typical use-cases include solar resource assessment, microclimate/shade analysis, and input layers for EO products.

Requirements
------------
- GRASS GIS (7.x or 8.x) installed and on PATH (commands: `grass`)
- GDAL (`gdal`/`r.out.gdal` used by GRASS)
- Bash (POSIX)
- coreutils: `mkdir`, `ls`, `du`, `rm`
- `bc`, `awk`
- Sufficient disk space to store generated GeoTIFFs (see Performance tips)

Files & purpose
----------------
- setup_grass_location.sh
  - Creates `$GRASSDATA` (default: `$HOME/grassdata`) and a `swiss_project` location
  - Imports a georeferenced DEM as `INPUT_DEM`
  - Sets computational region to the DEM extent
  - Precalculates `slope_deg` and `aspect_deg`

- calculate_shadows_loop.sh
  - Lightweight looped implementation that:
    - Checks/creates slope & aspect
    - Runs `r.sun` for each time step between `START_HOUR` and `END_HOUR` at `INTERVAL_MINUTES`
    - Writes shadow mask (`1` = shadow, `0` = illuminated) and solar incidence GeoTIFFs into `./shadow_outputs_doy<DOY>/`

- calculate_shadows_optimized.sh
  - Robust version with:
    - `set -euo pipefail`
    - Logging function
    - GDAL and TIFF compression optimizations (ZSTD)
    - Explicit core (NPROCS) and GDAL tuning (GDAL_CACHEMAX, GDAL_NUM_THREADS)
    - Cleanup of intermediate rasters to reduce storage usage
    - Summary statistics (file counts, total size, average time per step)

Quick start
-----------
1. Make scripts executable:
   chmod +x setup_grass_location.sh calculate_shadows_loop.sh calculate_shadows_optimized.sh

2. Create a GRASS location and import DEM:
   ./setup_grass_location.sh /path/to/Thinout_highest_object_10m_LV95_LHN95_ref.tif

   - By default, the scripts use GRASS database at $HOME/grassdata and location `swiss_project`.
   - You can override GRASSDATA before running:
     export GRASSDATA=/data/grassdb

3. Run the optimized shadow calculation (recommended):
   ./calculate_shadows_optimized.sh 153

   - This will process day-of-year 153 (change the DOY argument as needed).
   - Outputs are written to `./shadow_outputs_doy153/`.

Usage examples
--------------
- Run loop version for DOY 153:
  ./calculate_shadows_loop.sh 153

- Run optimized version for DOY 200:
  ./calculate_shadows_optimized.sh 200

- Use a custom GRASS database location:
  export GRASSDATA=/mnt/grassdata
  ./setup_grass_location.sh /path/to/dem.tif
  ./calculate_shadows_optimized.sh 153

- Run on a smaller system: edit `NPROCS`, `GDAL_CACHEMAX`, and `COMPRESS` variables at the top of `calculate_shadows_optimized.sh` to suit available resources.

Configuration / important variables
----------------------------------
- DOY — day of year (argument to scripts, defaults in scripts if not provided)
- YEAR — calendar year (not currently used in r.sun invocation but kept for metadata)
- GRASSDATA — GRASS database path, default `$HOME/grassdata` (can be exported in environment)
- LOCATION — GRASS location name (default: `swiss_project`)
- MAPSET — GRASS mapset (default: `PERMANENT`)
- DEM — raster name used inside GRASS (`INPUT_DEM` by default)
- SLOPE / ASPECT — derived rasters names (`slope_deg`, `aspect_deg`)
- NPROCS — cores passed to r.sun / r.slope.aspect (set according to your CPU count)
- GDAL_CACHEMAX, GDAL_NUM_THREADS — GDAL tuning (in optimized script)
- COMPRESS — GDAL/TIFF creation options (optimized script suggests ZSTD)

Output format & naming convention
--------------------------------
- Output directory: ./shadow_outputs_doy<DOY>/
- Shadow mask files:
  - shadow_mask_doy<DOY>_<HHMM>.tif
  - Binary map: 1=shadow, 0=illuminated
- Solar incidence files:
  - solar_incidence_doy<DOY>_<HHMM>.tif
  - Units: degrees (as produced by r.sun / incidout)
- Intermediate GRASS raster names follow the pattern:
  - beam_rad_doy<DOY>_<HHMM>
  - solar_incidence_doy<DOY>_<HHMM>
  - shadow_mask_doy<DOY>_<HHMM>

Notes on time formatting:
- Time string is created from a floating-hour value; e.g., 10.00 -> 1000, 10.25 -> 1025.
- The scripts calculate INTERVAL_HOURS = INTERVAL_MINUTES / 60 and loop from START_HOUR to END_HOUR (exclusive).

# Quick Guide: Matching Satellite Overpass Times

## Your Configuration
✅ **Script is configured for Sentinel-2 UTC times (10:00-11:00 UTC)**
✅ **Automatic time zone detection** (summer/winter)
✅ **2-minute intervals**

**Default Settings**: START_HOUR=12, END_HOUR=13
- Summer (UTC+2): Processes **10:00-11:00 UTC** ✅
- Winter (UTC+1): Change to START_HOUR=11, END_HOUR=12 for **10:00-11:00 UTC**

---

## How It Works

### Automatic Time Zone Detection
The script automatically sets `CIVIL_TIME` based on your Day of Year (DOY):

| DOY Range | Season | Time Zone | UTC Offset | CIVIL_TIME |
|-----------|--------|-----------|------------|------------|
| 80-304 | Summer | CEST | UTC+2 | 2 |
| 1-79, 305-365 | Winter | CET | UTC+1 | 1 |

**DOY 153** (June 2) → **Summer** → **UTC+2**

---

## Converting Satellite UTC Times

### The Formula
```
START_HOUR = UTC_satellite_time + CIVIL_TIME
```

### Examples for Summer (DOY 153, CIVIL_TIME=2)

| Satellite UTC Time | START_HOUR | END_HOUR | Command |
|-------------------|------------|----------|---------|
| 08:00 UTC | 10 | 11 | Edit script: `START_HOUR=10 END_HOUR=11` |
| 09:00 UTC | 11 | 12 | Edit script: `START_HOUR=11 END_HOUR=12` |
| 10:00 UTC | 12 | 13 | `./calculate_shadows_optimized.sh 153` **(default - Sentinel-2)** ✅ |
| 10:30 UTC | 12.5 | 13.5 | Edit script: `START_HOUR=12.5 END_HOUR=13.5` |

### Examples for Winter (DOY 50, CIVIL_TIME=1)

| Satellite UTC Time | START_HOUR | END_HOUR | Command |
|-------------------|------------|----------|---------|
| 09:00 UTC | 10 | 11 | Edit script: `START_HOUR=10 END_HOUR=11` |
| 10:00 UTC | 11 | 12 | Edit script: `START_HOUR=11 END_HOUR=12` **(Sentinel-2)** ✅ |

---

## Quick Start for Your Sentinel-2 Data

### Your Sentinel-2 Overpass Time
**10:00-11:00 UTC** (typical Sentinel-2 timestamp: "2025-12-23 10:11:29")

### For Summer Days (DOY 80-304, like DOY 153)
```
DOY 153 = Summer = CIVIL_TIME = 2
START_HOUR = 10 (UTC time) + 2 (offset) = 12 ✅ (already set as default)
END_HOUR = 11 (UTC time) + 2 (offset) = 13 ✅ (already set as default)
```

### For Winter Days (DOY 1-79, 305-365)
Edit the script and change lines 61-62:
```bash
START_HOUR=11
END_HOUR=12
```

### Run the Script
```bash
./calculate_shadows_optimized.sh 153  # For summer (DOY 153)
./calculate_shadows_optimized.sh 50   # For winter (DOY 50) - remember to edit START_HOUR first!
```

---

## Output Files

Files will be named with **both** local and UTC times:
```
shadow_mask_doy153_1200_UTC1000.tif
solar_incidence_8bit_doy153_1200_UTC1000.tif
```

This makes it easy to verify you have the correct Sentinel-2 time (10:00 UTC)!

---

## Verification

When the script runs, check the log output:
```
Time zone: UTC+2 (summer)
Local time range: 12:00 - 13:00
UTC time range: 10:00 - 11:00 (for satellite matching)
```

The UTC time range should **match your Sentinel-2 overpass time (10:00-11:00 UTC)**. ✅

---

## Common Satellite Platforms

### Landsat 8/9
- Overpass time: ~10:00-11:00 UTC (similar to Sentinel-2)
- For Switzerland summer: ~12:00-13:00 local
- Set: `START_HOUR=12 END_HOUR=13` (same as default)

### Sentinel-2 ✅ (YOUR DATA)
- **Overpass time: 10:00-11:00 UTC**
- For Switzerland summer: 12:00-13:00 local (UTC+2)
- For Switzerland winter: 11:00-12:00 local (UTC+1)
- **Summer setting: `START_HOUR=12 END_HOUR=13`** (default) ✅
- **Winter setting: `START_HOUR=11 END_HOUR=12`** (edit script)

### MODIS Terra
- Overpass time: ~10:30 AM local time
- For Switzerland summer: ~08:30 UTC
- Set: `START_HOUR=10.5 END_HOUR=11.5`

### MODIS Aqua
- Overpass time: ~01:30 PM local time
- For Switzerland summer: ~11:30 UTC
- Set: `START_HOUR=13.5 END_HOUR=14.5`

---

## Troubleshooting

### My UTC times look wrong
Check your DOY season detection:
- DOY 80-304 → Summer (UTC+2)
- DOY 1-79, 305-365 → Winter (UTC+1)

### I need times before 00:00 UTC
For early morning UTC times in summer (e.g., 00:30 UTC = 02:30 local):
```bash
START_HOUR=2.5
END_HOUR=3.5
```

### Output filename shows wrong UTC time
The filename UTC time is calculated as: `LOCAL_TIME - CIVIL_TIME`
If it doesn't match your satellite time, adjust `START_HOUR`.

---

## Summary

✅ **Configured for Sentinel-2 (10:00-11:00 UTC)**  
✅ **No manual time zone configuration needed** - automatic detection  
✅ **Default settings** match Sentinel-2 in summer (START_HOUR=12)  
✅ **For winter**: Change to START_HOUR=11, END_HOUR=12  
✅ **Filenames include both local and UTC times** for easy verification  

**For DOY 153 (June 2) with default settings, you're processing 10:00-11:00 UTC** ✅

Performance tips
----------------
- Use `calculate_shadows_optimized.sh` on multi-core systems. Tune:
  - NPROCS to the number of available CPU cores (but leave some for system tasks)
  - GDAL_CACHEMAX (in MB) to give more memory for GDAL caching (e.g., 4096, 8192)
  - COMPRESS: ZSTD with low zlevel (e.g., ZLEVEL=1) gives fast compression and small files
- Exporting and writing many GeoTIFFs can be I/O-bound; use local fast SSD when possible.
- Clean intermediate rasters (`g.remove`) to avoid filling GRASS DB with many temporary raster maps.
- If processing many DOYs, consider parallelizing across DOYs (but be careful accessing the same GRASS mapset concurrently).

Troubleshooting
---------------
- GRASS command not found:
  - Ensure GRASS is installed and `grass` is on PATH. You may need to load a module or source GRASS environment.
- Permission errors writing output:
  - Check that the current user has write permissions to the working directory and $GRASSDATA.
- r.sun fails or returns zeros/nulls:
  - Confirm `INPUT_DEM`, `slope_deg`, `aspect_deg` exist inside the GRASS mapset.
  - Run a single r.sun call interactively inside the GRASS session to debug parameters.
- Time precision/loop rounding:
  - If you see odd minute strings (due to floating point), reduce floating point usage or adjust INTERVAL_MINUTES to integer-minute intervals.

Recommendations / next improvements
----------------------------------
- Adapt it to LV95
- Add a CLI parameter parser (getopts) to configure START_HOUR, END_HOUR, INTERVAL, NPROCS, OUTPUT_DIR without editing scripts.
- Add unit tests / dry-run mode to validate configuration without launching heavy computation.
- Optionally add an aggregate step to combine shadow masks across time or produce daily shadow frequency rasters.
- Consider using a GRASS session wrapper (e.g., start an interactive GRASS session and run commands) to reduce repeated mapset startup cost for many time steps.
  

License
-------
MIT

Acknowledgements
----------------
- GRASS GIS project — for `r.sun`, `r.slope.aspect`, `r.mapcalc`, `r.out.gdal`
- GDAL — for GeoTIFF export and optimizations


