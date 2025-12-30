#!/bin/bash
# Script: calculate_shadows_optimizedC.sh
# Optimized for high-core count systems (180 CPUs, 1TB RAM)
# CORRECTLY CONFIGURED FOR: UTC time (Sentinel-2: 10:00-11:00 UTC)
# 
# IMPORTANT: This script uses civil_time=0 to ensure UTC time interpretation
# 
# Usage: ./calculate_shadows_optimized_UTC.sh [day_of_year] [start_HHMM] [end_HHMM]
# Example: ./calculate_shadows_optimized_UTC.sh 153
# Example: ./calculate_shadows_optimized_UTC.sh 153 1032 1036

set -euo pipefail

# ============================================
# Configuration
# ============================================

# Get day of year from command line argument, default to day 153
DOY=${1:-153}
YEAR=2021

# Parse optional start and end times (HHMM format)
if [ $# -ge 2 ]; then
    # Convert HHMM to decimal hours
    START_HHMM=$2
    START_HH=${START_HHMM:0:2}
    START_MM=${START_HHMM:2:2}
    UTC_START_HOUR=$(echo "scale=6; $START_HH + $START_MM / 60" | bc)
else
    # Use default from script
    UTC_START_HOUR=10
fi

if [ $# -ge 3 ]; then
    # Convert HHMM to decimal hours
    END_HHMM=$3
    END_HH=${END_HHMM:0:2}
    END_MM=${END_HHMM:2:2}
    UTC_END_HOUR=$(echo "scale=6; $END_HH + $END_MM / 60" | bc)
else
    # Use default from script
    UTC_END_HOUR=11
fi

# GRASS GIS paths
GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
LOCATION="swiss_project"
MAPSET="PERMANENT"

# Input DSM
INPUT_DSM="INPUT_DSM"
SLOPE="slope_deg"
ASPECT="aspect_deg"

# Output directory for exported files
OUTPUT_DIR="./shadow_outputs_doy${DOY}"
mkdir -p "$OUTPUT_DIR"

# Processing settings
NPROCS=180

# GDAL optimization for 1TB RAM system
export GDAL_CACHEMAX=16384
export GDAL_NUM_THREADS=8

# Processing interval
INTERVAL_MINUTES=2.0

# CRITICAL: Set civil_time=0 to interpret times as UTC
# This tells r.sun that we're giving it UTC times directly
CIVIL_TIME=0

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
log_message "Shadow Calculation - UTC Mode (CORRECTED)"
log_message "========================================"
log_message "Day of Year: $DOY"
log_message "Year: $YEAR"
log_message "UTC time range: $(printf "%.4f" $UTC_START_HOUR) - $(printf "%.4f" $UTC_END_HOUR) (decimal hours)"
log_message "Interval: ${INTERVAL_MINUTES} minutes"
log_message "civil_time: $CIVIL_TIME (UTC mode)"
log_message "Output directory: $OUTPUT_DIR"
log_message "CPU cores: $NPROCS"
log_message "Input DSM: $INPUT_DSM"
log_message "========================================"
log_message ""
log_message "IMPORTANT: Using civil_time=0 for correct UTC interpretation"
log_message "This ensures shadow calculations match Sentinel-2 UTC timestamps"
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

# Create longitude and latitude rasters (required for civil_time parameter)
log_message "Creating longitude and latitude rasters for civil_time..."
LONGITUDE_MAP="longitude_raster"
LATITUDE_MAP="latitude_raster"

# For LV95/projected coordinates, we need to create lat/lon rasters
# The simplest approach is using r.latlong module or creating them from coordinates

if ! grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info -e map=$LONGITUDE_MAP &>/dev/null; then
    log_message "Generating geographic coordinate rasters..."
    
    # Method: Use GRASS to create longitude/latitude rasters from the current projection
    # This works for any projected coordinate system
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.latlong \
        input=$INPUT_DSM \
        output=$LATITUDE_MAP,$LONGITUDE_MAP \
        --overwrite --quiet 2>/dev/null || {
        
        # Fallback: Manual creation using coordinate transformation
        log_message "Using manual coordinate transformation..."
        
        # Get region info
        eval $(grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.region -pg)
        
        # Create temporary x and y coordinate rasters
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
            "x_coord = x()" --overwrite --quiet
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
            "y_coord = y()" --overwrite --quiet
        
        # Transform to lat/lon using m.proj via r.mapcalc with system calls
        # For Switzerland LV95 (EPSG:2056) approximate center: 8.2°E, 46.8°N
        # This creates approximate lat/lon rasters
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
            "$LONGITUDE_MAP = 5.96 + (x() - 2485000.0) / 111320.0 / cos(0.817)" \
            --overwrite --quiet
        
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
            "$LATITUDE_MAP = 45.82 + (y() - 1075000.0) / 111320.0" \
            --overwrite --quiet
        
        # Clean up temporary rasters
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.remove -f \
            type=raster name=x_coord,y_coord 2>/dev/null || true
    }
else
    log_message "Longitude and latitude rasters already exist."
fi
echo ""

# Convert interval to decimal hours
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)

# Generate array of time steps
TIME_STEPS=()
NUM_STEPS=$(echo "scale=0; ($UTC_END_HOUR - $UTC_START_HOUR) / $INTERVAL_HOURS" | bc)

for ((i=0; i<NUM_STEPS; i++)); do
    CURRENT_TIME=$(echo "scale=6; $UTC_START_HOUR + ($i * $INTERVAL_HOURS)" | bc)
    CURRENT_TIME=$(printf "%.4f" $CURRENT_TIME)
    TIME_STEPS+=($CURRENT_TIME)
done

log_message "Total time steps to process: ${#TIME_STEPS[@]}"
echo ""

# Start timing
START_TIME=$(date +%s)

# Process each time step
for CURRENT_TIME in "${TIME_STEPS[@]}"; do
    
    # FIXED: Format time for output filename - properly calculate minutes
    # Extract hour part (integer)
    HOUR_PART=$(echo "$CURRENT_TIME" | awk '{print int($1)}')
    HOUR_PART=$(printf "%02d" $HOUR_PART)
    
    # Calculate minutes from decimal fraction
    # (CURRENT_TIME - integer_hour) * 60 gives minutes
    MINUTE_PART=$(echo "$CURRENT_TIME" | awk '{mins=($1-int($1))*60; printf "%02d", int(mins+0.5)}')
    
    TIME_STRING="${HOUR_PART}${MINUTE_PART}"
    
    log_message "Processing: UTC ${HOUR_PART}:${MINUTE_PART} (DOY=$DOY, decimal time=$CURRENT_TIME)"
    
    # Output raster names
    INCIDENCE_MAP="solar_incidence_doy${DOY}_UTC${TIME_STRING}"
    INCIDENCE_8BIT="solar_incidence_8bit_doy${DOY}_UTC${TIME_STRING}"
    BEAM_MAP="beam_rad_doy${DOY}_UTC${TIME_STRING}"
    SHADOW_MAP="shadow_mask_doy${DOY}_UTC${TIME_STRING}"
    
    # Run r.sun with all available cores and civil_time parameter
    # CRITICAL: civil_time requires lon and lat parameters
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.sun \
        elevation=$INPUT_DSM \
        aspect=$ASPECT \
        slope=$SLOPE \
        day=$DOY \
        time=$CURRENT_TIME \
        civil_time=$CIVIL_TIME \
        lon=$LONGITUDE_MAP \
        lat=$LATITUDE_MAP \
        beam_rad=$BEAM_MAP \
        incidout=$INCIDENCE_MAP \
        nprocs=$NPROCS \
        --overwrite --quiet
    
    # Create shadow mask (1=shadow, 0=illuminated)
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP = if(isnull($INCIDENCE_MAP), 1, 0)" \
        --overwrite --quiet
    
    # Convert solar incidence angle to 8-bit (0-90 degrees -> 0-254)
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
        "$INCIDENCE_8BIT = if(isnull($INCIDENCE_MAP), 255, int(min(round($INCIDENCE_MAP * 255.0 / 90.0), 254)))" \
        --overwrite --quiet
    
    # Export shadow mask
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet
    
    # Export solar incidence angle as 8-bit
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$INCIDENCE_8BIT \
        output="$OUTPUT_DIR/solar_incidence_8bit_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        nodata=255 \
        --overwrite --quiet
    
    # Clean up intermediate rasters
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.remove -f \
        type=raster \
        name=$BEAM_MAP,$INCIDENCE_MAP,$INCIDENCE_8BIT,$SHADOW_MAP \
        2>/dev/null || true
    
    log_message "✓ Completed UTC ${HOUR_PART}:${MINUTE_PART}"
    
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
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / ${#TIME_STEPS[@]}" | bc)s"
echo ""
log_message "========================================"
log_message "UTC Time Configuration (CORRECTED)"
log_message "========================================"
log_message "civil_time: $CIVIL_TIME (UTC mode - no timezone offset)"
log_message "UTC time processed: $(printf "%.4f" $UTC_START_HOUR) - $(printf "%.4f" $UTC_END_HOUR) (decimal hours)"
log_message "Output filenames: *_UTC${HOUR_PART}${MINUTE_PART}.tif"
log_message ""
log_message "This configuration ensures shadows are calculated for"
log_message "the EXACT UTC time matching Sentinel-2 timestamps"
log_message "========================================"
echo ""
log_message "Note: Solar incidence angles are scaled to 8-bit:"
log_message "  Value 0-254: Incidence angle 0-90° (scaled)"
log_message "  Value 255: No data (shadowed areas)"
log_message "  To convert back: angle_degrees = (value * 90.0) / 255.0"
