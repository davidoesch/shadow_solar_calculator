# GRASS & SAGA Solar Shadow Calculation Tools

Collection of Bash scripts to create a GRASS GIS location from a DEM, precompute slope/aspect, and calculate solar incidence / shadow masks for given day(s) and time ranges using r.sun.

This repository contains three scripts:
- `setup_grass_location.sh` — create a GRASS location from a georeferenced DEM and import the DEM (creates `INPUT_DSM`, sets region, precomputes slope/aspect).
- `calculate_shadows_optimized.sh` — an optimized, safer, and more featureful version tuned for machines with many cores and large memory (180 CPUs / 4 TB RAM in the script example, takes approx 8min for one run for swissALTIRegio). Uses GDAL and TIFF optimizations and removes intermediate rasters to save space.
- `calculate_shadows_PARALLEL_OPTIMIZED.sh ` as above but highly parallelized and with the use of RAMDISK
- `calculate_shadows_sunmask.sh` — only shadowmask, uses r.sunmask (SOLPOS algorithm) for UTC shadow calculation,r.sunmask uses SOLPOS algorithm with explicit timezone parameter tuned for machines with many cores and large memory (180 CPUs / 4 TB RAM in the script example
- `calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh`as above but highly parallelized and with the use of RAMDISK


About
-----
These scripts automate a common workflow for producing per-time-step solar incidence and binary shadow masks using GRASS GIS `r.sun`. Typical use-cases include solar resource assessment, microclimate/shade analysis, and input layers for EO products.

Requirements
------------
- GRASS GIS (7.x or 8.x) installed and on PATH (commands: `grass`)
- GDAL (`gdal`/`r.out.gdal` used by GRASS)
- Bash (POSIX)
- coreutils: `mkdir`, `ls`, `du`, `rm`
- `bc`, `awk`,`parallel`
- Sufficient disk space to store generated GeoTIFFs (see Performance tips)


Files & purpose
----------------
- setup_grass_location.sh
  - Creates `$GRASSDATA` (default: `$HOME/grassdata`) and a `swiss_project` location
  - Imports a georeferenced DEM as `INPUT_DSM`
  - Sets computational region to the DEM extent
  - Precalculates `slope_deg` and `aspect_deg`

- calculate_shadows_optimized.sh
  - Robust version with:
    - `set -euo pipefail`
    - Logging function
    - GDAL and TIFF compression optimizations (ZSTD)
    - Explicit core (NPROCS) and GDAL tuning (GDAL_CACHEMAX, GDAL_NUM_THREADS)
    - Cleanup of intermediate rasters to reduce storage usage
    - Summary statistics (file counts, total size, average time per step)
   
- calculate_shadows_PARALLEL_OPTIMIZED.sh
  - as above but with RAMDISK and parallelized
  - ./calculate_shadows_PARALLEL_OPTIMIZED.sh [day_of_year] [use_ramdisk]
   
- calculate_shadows_sunmask.sh
    - Robust version with:
      - Only shadowmask
      - `set -euo pipefail`
      - Logging function
      - GDAL and TIFF compression optimizations (ZSTD)
      - Explicit core (NPROCS) and GDAL tuning (GDAL_CACHEMAX, GDAL_NUM_THREADS)
      - Cleanup of intermediate rasters to reduce storage usage
      - Summary statistics (file counts, total size, average time per step)   

- calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh
  - as above but with RAMDISK and parallelized
  - ./calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh [day_of_year] [use_ramdisk]

Quick start
-----------
1. Make scripts executable:
   chmod +x setup_grass_location.sh calculate_shadows_optimized.sh calculate_shadows_sunmask.sh calculate_shadows_PARALLEL_OPTIMIZED.sh calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh

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
- Run optimized version for DOY 200:
  ./calculate_shadows_optimized.sh 200

- Run PARALLEL with RAMDISK optimized version for DOY 200:
  ./calculate_shadows_PARALLEL_OPTIMIZED.sh 153 yes

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
- DEM — raster name used inside GRASS (`INPUT_DSM` by default)
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
  - Confirm `INPUT_DSM`, `slope_deg`, `aspect_deg` exist inside the GRASS mapset.
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


# SAGA Shadow & Solar Incidence Calculator

This Python script (`SAGA_shadow_incidence.py`) automates the processing of Digital Elevation Models (DEM) using **SAGA GIS (ta_lighting)**. It allows for batch calculation of solar parameters for specific dates and times.

## Features
The script runs two distinct analyses for every input:
1.  **Cast Shadow Mask** (Method 3): A binary mask where `1` = Shadow and `0`/NoData = Sun.
2.  **Solar Incidence Angle** (Method 0): The angle of incoming light relative to the terrain surface in **Degrees**.

## Prerequisites
*   **Python 3.x**
*   **SAGA GIS** (Version 9.11.0 or compatible)

## Configuration
Before running, you must ensure the path to `saga_cmd.exe` inside `SAGA_shadow_incidence.py` matches your local installation:

```python
# Edit this line in the script:
SAGA_CMD = r"C:\legacySW\shadow_solar_calculator\saga\saga-9.11.0_msw\saga_cmd.exe"
```

## Usage
Run the script from the command line with the following arguments:
```python
python SAGA_shadow_incidence.py <TIMESTAMP> <DEM_PATH> <OUTPUT_DIR>
```
| Argument   | Description                     | Format        | Example                      |
| ---------- | ------------------------------- | ------------- | ---------------------------- |
| TIMESTAMP  | Date/Time for solar position    | YYYYMMDDtHHMM | 20210602t1005                |
| DEM_PATH   | Path to input Elevation GeoTIFF | File path     | LIDAR_MAX_subset_engadin.tif |
| OUTPUT_DIR | Folder to save results          | Folder path   | .\\results                   |

## Example command
Run the script from the command line with the following arguments:
```python
python SAGA_shadow_incidence.py 20210602t1005 "C:\data\LIDAR_MAX_subset_engadin.tif" "C:\data\output"
```

## Output Files
The script generates two GeoTIFF files in your output directory:

```python
shadow_[timestamp]_[dem_name].tif
```
with 
- SAGA Method: 3 (Shadows Only)
- Description: Ray-traced cast shadows. This accounts for mountains blocking the sun from across the valley.
- Note: Calculated with unrestricted radius (uses full DEM extent) for maximum accuracy.

```python
angle_[timestamp]_[dem_name].tif
```
- SAGA Method: 0 (Standard)
- Unit: Degrees (-UNIT 1)
- Description: The local incidence angle.
- 90 = Sun perpendicular to slope (Brightest)
- 0 = Sun grazing surface
- <0 = Self-shadow (Slope facing away)

Comparison table between SAGA's analytical hillshading and GRASS's solar radiation module
------------------------------------------------------------------------------------------

| Feature | SAGA `ta_lighting` 0 (Method 3) | GRASS `r.sun` |
| :-- | :-- | :-- |
| **Primary Goal** | Geometric visualization (Ray tracing). | Physical solar radiation modeling. |
| **Precision** | **Lower.** Typically assumes a flat earth plane (unless specific projection corrections are applied) and calculates simple line-of-sight. | **Higher.** Accounts for **Earth curvature** and **atmospheric refraction**, which significantly affect shadow length at low sun angles (morning/evening) in the Alps [^1]. |
| **Shadowing** | Binary (Shadow/No Shadow). Fast C++ implementation. | Detailed. Can calculate binary shadows or actual irradiance reduction. |
| **Input Data** | Just DEM. Calculates slope and aspect on the fly. | Requires pre-calculated Slope and Aspect maps (usually). |
| **Speed** | Very Fast. | Slower (computationally intensive). |




License
-------
MIT

Acknowledgements
----------------
- GRASS GIS project — for `r.sun`, `r.slope.aspect`, `r.mapcalc`, `r.out.gdal`
- GDAL — for GeoTIFF export and optimizations

