#!/bin/bash
# Script: calculate_shadows_optimized.sh
# Optimized for high-core count systems (88 CPUs, 1TB RAM)
# Usage: ./calculate_shadows_optimized.sh [day_of_year]
# Example: ./calculate_shadows_optimized.sh 153

set -euo pipefail

# ============================================
# Configuration
# ============================================

# Get day of year from command line argument, default to day 153
DOY=${1:-153}
YEAR=2021

# GRASS GIS paths
GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
LOCATION="swiss_project"
MAPSET="PERMANENT"

# Input DEM
DEM="dem_wgs84"
SLOPE="slope_deg"
ASPECT="aspect_deg"

# Output directory for exported files
OUTPUT_DIR="./shadow_outputs_doy${DOY}"
mkdir -p "$OUTPUT_DIR"

# Processing settings
# Use 88 cores for r.sun (much faster than 80)
NPROCS=88

# GDAL optimization
export GDAL_CACHEMAX=8192
export GDAL_NUM_THREADS=4

# Time settings (UTC)
START_HOUR=10
END_HOUR=11
INTERVAL_MINUTES=2.5

# Compression settings - ZSTD is much faster than LZW
COMPRESS="COMPRESS=ZSTD,ZLEVEL=1,TILED=YES,BLOCKXSIZE=512,BLOCKYSIZE=512"

# ============================================
# Functions
# ============================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ============================================
# Main Processing
# ============================================

log_message "========================================"
log_message "Optimized Shadow Calculation Script"
log_message "========================================"
log_message "Day of Year: $DOY"
log_message "Year: $YEAR"
log_message "Time range: ${START_HOUR}:00 - ${END_HOUR}:00 UTC"
log_message "Interval: ${INTERVAL_MINUTES} minutes"
log_message "Output directory: $OUTPUT_DIR"
log_message "CPU cores: $NPROCS"
log_message "========================================"
echo ""

# Calculate slope and aspect once (if not already done)
log_message "Checking for slope and aspect maps..."
if ! grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info -e map=$SLOPE &>/dev/null; then
    log_message "Calculating slope and aspect from DEM..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.slope.aspect \
        elevation=$DEM \
        slope=$SLOPE \
        aspect=$ASPECT \
        format=degrees \
        nprocs=$NPROCS \
        --overwrite
else
    log_message "Slope and aspect maps already exist."
fi
echo ""

# Convert interval to decimal hours
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)

# Generate array of time steps with proper rounding
TIME_STEPS=()
STEP_COUNT=0

# Calculate number of steps
NUM_STEPS=$(echo "scale=0; ($END_HOUR - $START_HOUR) / $INTERVAL_HOURS" | bc)

# Generate time steps using integer arithmetic to avoid floating point errors
for ((i=0; i<NUM_STEPS; i++)); do
    CURRENT_TIME=$(echo "scale=6; $START_HOUR + ($i * $INTERVAL_HOURS)" | bc)
    # Round to 4 decimal places to avoid precision issues
    CURRENT_TIME=$(printf "%.4f" $CURRENT_TIME)
    TIME_STEPS+=($CURRENT_TIME)
done

log_message "Total time steps to process: ${#TIME_STEPS[@]}"
echo ""

# Start timing
START_TIME=$(date +%s)

# Process each time step sequentially (safer for GRASS)
for CURRENT_TIME in "${TIME_STEPS[@]}"; do
    
    # Format time for output filename
    HOUR_PART=$(printf "%02d" $(echo "$CURRENT_TIME" | awk '{print int($1)}'))
    MINUTE_PART=$(echo "$CURRENT_TIME" | awk '{mins=($1-int($1))*60; printf "%02d", mins}')
    TIME_STRING="${HOUR_PART}${MINUTE_PART}"
    
    log_message "Processing: DOY=$DOY, Time=$CURRENT_TIME UTC (${HOUR_PART}:${MINUTE_PART})"
    
    # Output raster names
    INCIDENCE_MAP="solar_incidence_doy${DOY}_${TIME_STRING}"
    BEAM_MAP="beam_rad_doy${DOY}_${TIME_STRING}"
    SHADOW_MAP="shadow_mask_doy${DOY}_${TIME_STRING}"
    
    # Run r.sun with all available cores
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.sun \
        elevation=$DEM \
        aspect=$ASPECT \
        slope=$SLOPE \
        day=$DOY \
        time=$CURRENT_TIME \
        beam_rad=$BEAM_MAP \
        incidout=$INCIDENCE_MAP \
        nprocs=$NPROCS \
        --overwrite --quiet
    
    # Create shadow mask (1=shadow, 0=illuminated)
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP = if(isnull($INCIDENCE_MAP), 1, 0)" \
        --overwrite --quiet
    
    # Export shadow mask with optimized compression
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet
    
    # Export solar incidence angle with optimized compression
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$INCIDENCE_MAP \
        output="$OUTPUT_DIR/solar_incidence_doy${DOY}_${TIME_STRING}.tif" \
        format=GTiff \
        type=Float32 \
        createopt="$COMPRESS" \
        nodata=-9999 \
        --overwrite --quiet
    
    # Clean up intermediate rasters to save space
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.remove -f \
        type=raster \
        name=$BEAM_MAP,$INCIDENCE_MAP,$SHADOW_MAP \
        2>/dev/null || true
    
    log_message "✓ Completed ${HOUR_PART}:${MINUTE_PART}"
    
done

# End timing
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
log_message "========================================"
log_message "Processing complete!"
log_message "Time elapsed: ${MINUTES}m ${SECONDS}s"
log_message "Output files saved to: $OUTPUT_DIR"
log_message "========================================"

# Generate summary statistics
echo ""
log_message "Generated files summary:"
SHADOW_COUNT=$(ls -1 "$OUTPUT_DIR"/shadow_mask_*.tif 2>/dev/null | wc -l)
INCIDENCE_COUNT=$(ls -1 "$OUTPUT_DIR"/solar_incidence_*.tif 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

log_message "  Shadow masks: $SHADOW_COUNT files"
log_message "  Incidence maps: $INCIDENCE_COUNT files"
log_message "  Total size: $TOTAL_SIZE"
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / ${#TIME_STEPS[@]}" | bc)s"
