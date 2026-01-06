# GRASS, SAGA \& Python Solar Shadow Calculation Tools

Collection of Bash and Python tools to create shadow masks and calculate solar incidence angles from a DEM. This repository offers multiple approaches: optimized GRASS GIS workflows (r.sun/r.sunmask), a pure Python implementation, and a SAGA GIS wrapper.

This repository contains the following main tools:

- `setup_grass_location.sh` — Creates a GRASS location from a georeferenced DEM.
- `calculate_shadows_optimized.sh` — High-performance GRASS script using `r.sun` with UTC timing and 8-bit compressed output.
- `calculate_shadows_sunmask.sh` — GRASS script using `r.sunmask` (SOLPOS algorithm) for binary shadow masks.
- `AGRO_shadow_incidence.py` — Pure Python implementation for shadow and incidence angle calculation.
- `SAGA_shadow_incidence.py` — Wrapper script to run SAGA GIS shadow analysis.


## Requirements

### General

- Bash (POSIX)
- coreutils (mkdir, ls, du, rm), bc, awk


### For GRASS Scripts

- GRASS GIS (7.x or 8.x)
- GDAL (used by GRASS for import/export)


### For Python Scripts

- Python 3.8+
- See `AGRO_requirements.txt` for specific packages:
    - numpy
    - rasterio
    - pvlib
    - pandas


### For SAGA Script

- SAGA GIS (tested with 9.11.0)
- `saga_cmd` executable accessible or path configured in script


## Files \& Purpose

### setup_grass_location.sh

- Creates `$GRASSDATA` (default: `$HOME/grassdata`) and a `swiss_project` location.
- Imports a georeferenced DEM as `INPUT_DSM`.
- Sets computational region to the DEM extent.
- Precalculates `slope_deg` and `aspect_deg` to save time during processing.


### calculate_shadows_optimized.sh

- **Algorithm**: Uses `r.sun` with `civil_time=0` for strict UTC interpretation.
- **Outputs**:
    - Shadow Mask: 1 = Illuminated, 0 = Shadow.
    - Solar Incidence: 8-bit encoded (0-254).
- **Features**:
    - Optimized for multi-core systems (NPROCS tuning).
    - RAMDISK and GDAL caching support.
    - Compresses outputs using ZSTD to save disk space.
    - **Incidence Encoding**: The output is scaled to 8-bit to reduce file size.
        - Value 0: 0 degrees (perpendicular, max light)
        - Value 254: 90 degrees (parallel, no light)
        - Value 255: No Data
        - Conversion formula: `angle_deg = (value * 90.0) / 254.0`


### calculate_shadows_sunmask.sh

- **Algorithm**: Uses `r.sunmask` with SOLPOS algorithm.
- **Outputs**:
    - Shadow Mask: 1 = Shadow, 0 = Illuminated.
- **Features**:
    - Uses explicit timezone=0 for UTC.
    - Faster than `r.sun` if only binary shadows are needed.


### AGRO_shadow_incidence.py

- **Algorithm**: Custom Python implementation using numpy/rasterio.
- **Outputs**:
    - Shadow mask (8-bit): 1 = No shadow (Illuminated), 0 = Shadow.
    - Incidence angle (8-bit): 0-90 degrees (0 = perpendicular). Shadowed areas are set to 90 degrees.
- **Features**:
    - Single-file solution without GRASS dependency.
    - Interprets timestamps as UTC.


### SAGA_shadow_incidence.py

- **Algorithm**: Wrapper for SAGA GIS `ta_lighting` module.
- **Outputs**:
    - Shadow mask (Method 3).
    - Incidence angle (Method 1).
- **Usage**: Expects path to `saga_cmd` to be configured or available.


## Quick Start

### 1. Setup GRASS Environment (Bash Scripts)

Make scripts executable and initialize the location:

```bash
chmod +x *.sh
./setup_grass_location.sh /path/to/dem_LV95.tif
```


### 2. Run Shadow Calculations

**Option A: Optimized GRASS r.sun (Recommended)**
Calculate shadows and incidence for Day of Year 153 between 10:00 and 11:00 UTC:

```bash
# Usage: ./calculate_shadows_optimized.sh [DOY] [START_HHMM] [END_HHMM]
./calculate_shadows_optimized.sh 153 1000 1100
```

Outputs are saved to `./shadow_outputs_doy153/`.

**Option B: Python Implementation**
Run the AGRO python script (ensure requirements are installed):

```bash
pip install -r AGRO_requirements.txt
python AGRO_shadow_incidence.py
```

*Note: Check the CONFIG section at the top of the script for input paths and timestamps.*

**Option C: SAGA GIS**
Run the SAGA wrapper:

```bash
# Usage: python SAGA_shadow_incidence.py [YYYYMMDDtHHMM] [DEM_PATH] [OUTPUT_DIR]
python SAGA_shadow_incidence.py 20210602t1005 ./data/dem.tif ./output_results
```


## Configuration

### GRASS Scripts Variables

Adjust these variables at the top of the Bash scripts to match your hardware:

- `NPROCS`: Number of CPU cores (e.g., 180).
- `GDAL_CACHEMAX`: Memory for GDAL in MB (e.g., 16384).
- `GRASSDATA`: Path to GRASS database.
- `COMPRESS`: GeoTIFF compression settings (default: ZSTD).


### Python Config

For `AGRO_shadow_incidence.py`, edit the `CONFIG` dictionary at the top of the file:

- `DEFAULT_TS`: Timestamp string (YYYYMMDDtHHMM).
- `DEFAULT_DEM`: Path to input DEM.
- `REF_LAT` / `REF_LON`: Reference location for solar calculation.


## Output Formats and Interpretation

| Tool | Shadow Value 0 | Shadow Value 1 | Incidence Angle Format |
| :-- | :-- | :-- | :-- |
| **calculate_shadows_optimized.sh** | Shadow | **Illuminated** | 8-bit scaled (0=0deg, 254=90deg) |
| **calculate_shadows_sunmask.sh** | **Illuminated** | Shadow | N/A |
| **AGRO_shadow_incidence.py** | Shadow | **Illuminated** | 8-bit (0-90 raw values) |
| **SAGA_shadow_incidence.py** | varies (check SAGA ver) | varies | Float/Grid |

**Important Note on Incidence Angles:**

- The optimized GRASS script inverts and scales the angle to fit into 8-bit storage efficiently.
- 0 corresponds to maximum illumination (sun perpendicular to surface).
- 254 corresponds to no illumination (sun parallel to surface or behind).


## Troubleshooting

- **GRASS command not found**: Ensure GRASS is installed and added to your PATH.
- **Permission errors**: Check write permissions for output directories and `$GRASSDATA`.
- **SAGA path error**: Update `SAGA_CMD` in `SAGA_shadow_incidence.py` to point to your local `saga_cmd` executable.
- **Python import errors**: Install dependencies using `pip install -r AGRO_requirements.txt`.

