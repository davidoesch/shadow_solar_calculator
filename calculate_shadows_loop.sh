#!/bin/bash
# Script: calculate_shadows_loop.sh
# Optimized for high-core count systems (180 CPUs, 1TB RAM)
# CONFIGURED FOR: Sentinel-2 overpass time matching (10:00-11:00 UTC)
# Usage: ./calculate_shadows_loop.sh [day_of_year]
# Example: ./calculate_shadows_loop.sh 153

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

# Input DSM (renamed from dem_wgs84)
INPUT_DSM="INPUT_DSM"
SLOPE="slope_deg"
ASPECT="aspect_deg"

# Output directory for exported files
OUTPUT_DIR="./shadow_outputs_doy${DOY}"
mkdir -p "$OUTPUT_DIR"

# Processing settings
# Use 180 cores for r.sun (maximizing your server capacity)
NPROCS=180

# GDAL optimization for 1TB RAM system
export GDAL_CACHEMAX=16384
export GDAL_NUM_THREADS=8

# Time settings
# Sentinel-2 overpass times: 10:00-11:00 UTC
# For summer (UTC+2): START_HOUR = 10 + 2 = 12
# For winter (UTC+1): START_HOUR = 10 + 1 = 11
START_HOUR=12
END_HOUR=13
INTERVAL_MINUTES=2.0

# Automatic time zone detection based on DOY
# Switzerland time zones:
# - Summer (CEST): UTC+2 (approximately DOY 80-304: March 21 - October 31)
# - Winter (CET): UTC+1 (approximately DOY 1-79, 305-365)
if [ "$DOY" -ge 80 ] && [ "$DOY" -le 304 ]; then
    CIVIL_TIME=2  # Summer (CEST = UTC+2)
    SEASON="summer"
else
    CIVIL_TIME=1  # Winter (CET = UTC+1)
    SEASON="winter"
fi

# Calculate actual UTC times being processed
UTC_START=$(echo "$START_HOUR - $CIVIL_TIME" | bc)
UTC_END=$(echo "$END_HOUR - $CIVIL_TIME" | bc)

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
log_message "Shadow Calculation for Sentinel-2 Matching"
log_message "========================================"
log_message "Day of Year: $DOY ($SEASON)"
log_message "Year: $YEAR"
log_message "Time zone: UTC+${CIVIL_TIME} (${SEASON} time)"
log_message "Local time range: ${START_HOUR}:00 - ${END_HOUR}:00"
log_message "UTC time range: ${UTC_START}:00 - ${UTC_END}:00 (for Sentinel-2 matching)"
log_message "Interval: ${INTERVAL_MINUTES} minutes"
log_message "Output directory: $OUTPUT_DIR"
log_message "CPU cores: $NPROCS"
log_message "Input DSM: $INPUT_DSM"
log_message "========================================"
echo ""

# Calculate slope and aspect once (if not already done)
log_message "Checking for slope and aspect maps..."
if ! grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info -e map=$SLOPE &>/dev/null; then
    log_message "Calculating slope and aspect from DSM..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.slope.aspect \
        elevation=$INPUT_DSM \
        slope=$SLOPE \
        aspect=$ASPECT \
        format=degrees \
        nprocs=$NPROCS \
        memory=900000 \
        --overwrite
else
    log_message "Slope and aspect maps already exist."
fi
echo ""

# Convert interval to decimal hours
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)

# Start timing
START_TIME=$(date +%s)

# Loop through time steps
CURRENT_TIME=$START_HOUR
STEP_COUNT=0

log_message "Starting time loop..."
echo ""

while (( $(echo "$CURRENT_TIME < $END_HOUR" | bc -l) )); do
    
    # Format time for output filename
    HOUR_PART=$(printf "%02d" $(echo "$CURRENT_TIME" | awk '{print int($1)}'))
    MINUTE_PART=$(echo "$CURRENT_TIME" | awk '{mins=($1-int($1))*60; printf "%02d", mins}')
    TIME_STRING="${HOUR_PART}${MINUTE_PART}"
    
    # Calculate UTC time for this step
    UTC_TIME=$(echo "$CURRENT_TIME - $CIVIL_TIME" | bc)
    UTC_HOUR=$(printf "%02d" $(echo "$UTC_TIME" | awk '{print int($1)}'))
    UTC_MINUTE=$(echo "$UTC_TIME" | awk '{mins=($1-int($1))*60; printf "%02d", mins}')
    
    log_message "Processing: Local=${HOUR_PART}:${MINUTE_PART}, UTC=${UTC_HOUR}:${UTC_MINUTE} (DOY=$DOY)"
    
    # Output raster names
    INCIDENCE_MAP="solar_incidence_doy${DOY}_${TIME_STRING}"
    INCIDENCE_8BIT="solar_incidence_8bit_doy${DOY}_${TIME_STRING}"
    BEAM_MAP="beam_rad_doy${DOY}_${TIME_STRING}"
    SHADOW_MAP="shadow_mask_doy${DOY}_${TIME_STRING}"
    
    # Run r.sun with all available cores and civil_time parameter
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.sun \
        elevation=$INPUT_DSM \
        aspect=$ASPECT \
        slope=$SLOPE \
        day=$DOY \
        time=$CURRENT_TIME \
        civil_time=$CIVIL_TIME \
        beam_rad=$BEAM_MAP \
        incidout=$INCIDENCE_MAP \
        nprocs=$NPROCS \
        --overwrite --quiet
    
    # Create shadow mask (1=shadow, 0=illuminated)
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP = if(isnull($INCIDENCE_MAP), 1, 0)" \
        --overwrite --quiet
    
    # Convert solar incidence angle to 8-bit (0-90 degrees -> 0-255)
    # Incidence angles range from 0° (perpendicular) to 90° (horizon)
    # Scale: 0-90° mapped to 0-254, with 255 reserved for nodata
    # Formula: round(incidence * 255.0 / 90.0), capped at 254
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
        "$INCIDENCE_8BIT = if(isnull($INCIDENCE_MAP), 255, int(min(round($INCIDENCE_MAP * 255.0 / 90.0), 254)))" \
        --overwrite --quiet
    
    # Export shadow mask with optimized compression (Byte type)
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_${TIME_STRING}_UTC${UTC_HOUR}${UTC_MINUTE}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet
    
    # Export solar incidence angle as 8-bit with optimized compression
    # Value 255 represents nodata (shadowed areas)
    # Values 0-254 represent incidence angles scaled from 0-90 degrees
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$INCIDENCE_8BIT \
        output="$OUTPUT_DIR/solar_incidence_8bit_doy${DOY}_${TIME_STRING}_UTC${UTC_HOUR}${UTC_MINUTE}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        nodata=255 \
        --overwrite --quiet
    
    # Clean up intermediate rasters to save space
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.remove -f \
        type=raster \
        name=$BEAM_MAP,$INCIDENCE_MAP,$INCIDENCE_8BIT,$SHADOW_MAP \
        2>/dev/null || true
    
    log_message "✓ Completed Local=${HOUR_PART}:${MINUTE_PART} UTC=${UTC_HOUR}:${UTC_MINUTE}"
    
    # Increment time
    CURRENT_TIME=$(echo "$CURRENT_TIME + $INTERVAL_HOURS" | bc)
    STEP_COUNT=$((STEP_COUNT + 1))
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
INCIDENCE_COUNT=$(ls -1 "$OUTPUT_DIR"/solar_incidence_8bit_*.tif 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

log_message "  Shadow masks: $SHADOW_COUNT files"
log_message "  Incidence maps (8-bit): $INCIDENCE_COUNT files"
log_message "  Total size: $TOTAL_SIZE"
log_message "  Total time steps processed: $STEP_COUNT"
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / $STEP_COUNT" | bc)s"
echo ""
log_message "========================================"
log_message "Sentinel-2 Matching Information"
log_message "========================================"
log_message "Time zone used: UTC+${CIVIL_TIME} ($SEASON)"
log_message "Local time processed: ${START_HOUR}:00 - ${END_HOUR}:00"
log_message "UTC time processed: ${UTC_START}:00 - ${UTC_END}:00"
log_message ""
log_message "Output filenames include both local and UTC times:"
log_message "Format: *_doy${DOY}_HHMM_UTCHHMM.tif"
log_message "========================================"
echo ""
log_message "Note: Solar incidence angles are scaled to 8-bit:"
log_message "  Value 0-254: Incidence angle 0-90° (scaled)"
log_message "  Value 255: No data (shadowed areas)"
log_message "  To convert back: angle_degrees = (value * 90.0) / 255.0"
echo ""

# Optional: List first few output files
log_message "Sample output files:"
ls -lh "$OUTPUT_DIR" | head -n 10
