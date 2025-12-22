#!/bin/bash
# Script: calculate_shadows_loop.sh
# Usage: ./calculate_shadows_loop.sh [day_of_year]
# Example: ./calculate_shadows_loop.sh 153

# ============================================
# Configuration
# ============================================

# Get day of year from command line argument, default to day 153 (June 1 in leap year)
DOY=${1:-153}
YEAR=2021

# GRASS GIS paths
GRASSDATA="$HOME/grassdata"
LOCATION="swiss_project"
MAPSET="PERMANENT"

# Input DEM (should already be imported as INPUT_DSM)
DEM="INPUT_DSM"
SLOPE="slope_deg"
ASPECT="aspect_deg"

# Output directory for exported files
OUTPUT_DIR="./shadow_outputs_doy${DOY}"
mkdir -p "$OUTPUT_DIR"

# Number of processors to use
NPROCS=80

# Time settings (UTC)
START_HOUR=10
END_HOUR=11
INTERVAL_MINUTES=2.5

# ============================================
# Main Processing Loop
# ============================================

echo "========================================"
echo "Shadow Calculation Script"
echo "========================================"
echo "Day of Year: $DOY"
echo "Year: $YEAR"
echo "Time range: ${START_HOUR}:00 - ${END_HOUR}:00 UTC"
echo "Interval: ${INTERVAL_MINUTES} minutes"
echo "Output directory: $OUTPUT_DIR"
echo "========================================"
echo ""

# Calculate slope and aspect once (if not already done)
echo "Checking for slope and aspect maps..."
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info -e map=$SLOPE 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Calculating slope and aspect from DEM..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.slope.aspect elevation=$DEM slope=$SLOPE aspect=$ASPECT
else
    echo "Slope and aspect maps already exist."
fi
echo ""

# Convert interval to decimal hours
INTERVAL_HOURS=$(echo "scale=4; $INTERVAL_MINUTES / 60" | bc)

# Loop through time steps
CURRENT_TIME=$START_HOUR

while (( $(echo "$CURRENT_TIME < $END_HOUR" | bc -l) )); do
    
    # Format time for output filename (e.g., 1000 for 10:00, 1025 for 10:25)
    HOUR_PART=$(printf "%02d" $(echo "$CURRENT_TIME" | awk '{print int($1)}'))
    MINUTE_PART=$(echo "$CURRENT_TIME" | awk '{mins=($1-int($1))*60; printf "%02d", mins}')
    TIME_STRING="${HOUR_PART}${MINUTE_PART}"
    
    echo "Processing: DOY=$DOY, Time=$CURRENT_TIME UTC (${HOUR_PART}:${MINUTE_PART})"
    
    # Output raster names
    INCIDENCE_MAP="solar_incidence_doy${DOY}_${TIME_STRING}"
    BEAM_MAP="beam_rad_doy${DOY}_${TIME_STRING}"
    SHADOW_MAP="shadow_mask_doy${DOY}_${TIME_STRING}"
    
    # Run r.sun within GRASS environment
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
    
    # Export shadow mask as GeoTIFF
    echo "  Exporting shadow mask..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_${TIME_STRING}.tif" \
        format=GTiff \
        createopt="COMPRESS=LZW,TILED=YES" \
        --overwrite --quiet
    
    # Export solar incidence angle as GeoTIFF
    echo "  Exporting solar incidence angle..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.out.gdal \
        input=$INCIDENCE_MAP \
        output="$OUTPUT_DIR/solar_incidence_doy${DOY}_${TIME_STRING}.tif" \
        format=GTiff \
        createopt="COMPRESS=LZW,TILED=YES" \
        nodata=-9999 \
        --overwrite --quiet
    
    echo "  ✓ Completed ${HOUR_PART}:${MINUTE_PART}"
    echo ""
    
    # Increment time
    CURRENT_TIME=$(echo "$CURRENT_TIME + $INTERVAL_HOURS" | bc)
done

echo "========================================"
echo "Processing complete!"
echo "Output files saved to: $OUTPUT_DIR"
echo "========================================"

# Optional: List output files
echo ""
echo "Generated files:"
ls -lh "$OUTPUT_DIR"
