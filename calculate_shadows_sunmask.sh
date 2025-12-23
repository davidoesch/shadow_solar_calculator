#!/bin/bash
# Script: calculate_shadows_sunmask.sh
# Uses r.sunmask (SOLPOS algorithm) for UTC shadow calculation
# Optimized for high-core count systems (180 CPUs, 1TB RAM)
# CORRECTLY CONFIGURED FOR: UTC time (Sentinel-2: 10:00-11:00 UTC)
# 
# ADVANTAGE: r.sunmask uses SOLPOS algorithm with explicit timezone parameter
# 
# Usage: ./calculate_shadows_sunmask.sh [day_of_year]
# Example: ./calculate_shadows_sunmask.sh 153

set -euo pipefail

# ============================================
# Configuration
# ============================================

# Get day of year from command line argument
DOY=${1:-153}
YEAR=2021

# Calculate month and day from DOY
# Simple lookup for common DOYs (expand as needed)
case $DOY in
    153) MONTH=6; DAY=2;;  # June 2
    181) MONTH=6; DAY=30;; # June 30
    213) MONTH=8; DAY=1;;  # August 1
    50)  MONTH=2; DAY=19;; # Feb 19
    15)  MONTH=1; DAY=15;; # Jan 15
    *)
        # Generic calculation for other DOYs (works for non-leap years)
        MONTH=$(date -d "2021-01-01 +$(($DOY - 1)) days" +%m)
        DAY=$(date -d "2021-01-01 +$(($DOY - 1)) days" +%d)
        ;;
esac

# GRASS GIS paths
GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
LOCATION="swiss_project"
MAPSET="PERMANENT"

# Input DSM
INPUT_DSM="INPUT_DSM"

# Output directory for exported files
OUTPUT_DIR="./shadow_outputs_doy${DOY}_sunmask"
mkdir -p "$OUTPUT_DIR"

# GDAL optimization
export GDAL_CACHEMAX=16384
export GDAL_NUM_THREADS=8

# UTC TIME SETTINGS - Sentinel-2 overpass times
UTC_START_HOUR=10
UTC_END_HOUR=11
INTERVAL_MINUTES=2.0

# CRITICAL: timezone=0 for UTC (no offset from GMT)
TIMEZONE=0

# Compression settings
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
log_message "Shadow Calculation - r.sunmask (SOLPOS)"
log_message "========================================"
log_message "Day of Year: $DOY (${YEAR}-${MONTH}-${DAY})"
log_message "Year: $YEAR, Month: $MONTH, Day: $DAY"
log_message "UTC time range: ${UTC_START_HOUR}:00 - ${UTC_END_HOUR}:00"
log_message "Interval: ${INTERVAL_MINUTES} minutes"
log_message "Timezone: $TIMEZONE (UTC/GMT)"
log_message "Output directory: $OUTPUT_DIR"
log_message "Input DSM: $INPUT_DSM"
log_message "========================================"
log_message ""
log_message "IMPORTANT: Using r.sunmask with SOLPOS algorithm"
log_message "timezone=0 ensures UTC interpretation"
log_message "========================================"
echo ""

# Convert interval to decimal hours
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)

# Generate array of time steps
TIME_STEPS=()
NUM_STEPS=$(echo "scale=0; ($UTC_END_HOUR - $UTC_START_HOUR) / $INTERVAL_HOURS" | bc)

for ((i=0; i<NUM_STEPS; i++)); do
    CURRENT_HOUR_DEC=$(echo "scale=6; $UTC_START_HOUR + ($i * $INTERVAL_HOURS)" | bc)
    
    # Split into hour and minute for r.sunmask
    HOUR=$(echo "$CURRENT_HOUR_DEC" | awk '{print int($1)}')
    MINUTE=$(echo "$CURRENT_HOUR_DEC" | awk '{mins=($1-int($1))*60; printf "%d", mins}')
    
    TIME_STEPS+=("$HOUR:$MINUTE")
done

log_message "Total time steps to process: ${#TIME_STEPS[@]}"
echo ""

# Start timing
START_TIME=$(date +%s)

# Process each time step
for TIME_STEP in "${TIME_STEPS[@]}"; do
    
    # Parse hour and minute
    IFS=':' read -r HOUR MINUTE <<< "$TIME_STEP"
    
    # Format for output filename
    HOUR_STR=$(printf "%02d" $HOUR)
    MINUTE_STR=$(printf "%02d" $MINUTE)
    TIME_STRING="${HOUR_STR}${MINUTE_STR}"
    
    log_message "Processing: UTC ${HOUR_STR}:${MINUTE_STR} (${YEAR}-${MONTH}-${DAY})"
    
    # Output raster name
    SHADOW_MAP="shadow_sunmask_doy${DOY}_UTC${TIME_STRING}"
    
    # Run r.sunmask with explicit date/time and timezone
    # CRITICAL: timezone=0 means UTC (no offset from GMT)
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.sunmask \
        elevation=$INPUT_DSM \
        output=$SHADOW_MAP \
        year=$YEAR \
        month=$MONTH \
        day=$DAY \
        hour=$HOUR \
        minute=$MINUTE \
        timezone=$TIMEZONE \
        --overwrite --quiet
    
    # r.sunmask outputs: 0=shadow, NULL=sunlight
    # We want: 1=shadow, 0=illuminated (consistent with r.sun approach)
    SHADOW_MAP_INVERTED="${SHADOW_MAP}_inverted"
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP_INVERTED = if(isnull($SHADOW_MAP), 0, 1)" \
        --overwrite --quiet
    
    # Export shadow mask
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP_INVERTED \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet
    
    # Clean up intermediate rasters
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.remove -f \
        type=raster \
        name=$SHADOW_MAP,$SHADOW_MAP_INVERTED \
        2>/dev/null || true
    
    log_message "✓ Completed UTC ${HOUR_STR}:${MINUTE_STR}"
    
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
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

log_message "  Shadow masks: $SHADOW_COUNT files"
log_message "  Total size: $TOTAL_SIZE"
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / ${#TIME_STEPS[@]}" | bc)s"
echo ""
log_message "========================================"
log_message "r.sunmask Configuration"
log_message "========================================"
log_message "Algorithm: SOLPOS (NREL)"
log_message "Timezone: $TIMEZONE (UTC/GMT - no offset)"
log_message "UTC time processed: ${UTC_START_HOUR}:00 - ${UTC_END_HOUR}:00"
log_message "Date: ${YEAR}-${MONTH}-${DAY} (DOY $DOY)"
log_message ""
log_message "NOTE: r.sunmask only produces shadow masks (binary)"
log_message "For solar incidence angles, use calculate_shadows_optimized_UTC.sh"
log_message "========================================"
echo ""
log_message "Shadow mask format:"
log_message "  Value 1: Shadow"
log_message "  Value 0: Illuminated"
