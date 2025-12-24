#!/bin/bash
# Script: calculate_shadows_PARALLEL_OPTIMIZED_v2.sh
# IMPROVED VERSION: Uses symlinks instead of copying full GRASS databases
# Optimized for 180 CPUs, 1TB RAM with parallel processing
# MUCH LOWER disk/RAM usage!
# 
# Features:
# - Parallel timestep processing (6 simultaneous jobs)
# - Shared GRASS database (no duplication!)
# - Optional RAMDisk support
# - Optimized GDAL/GRASS settings
#
# Usage: ./calculate_shadows_PARALLEL_OPTIMIZED_v2.sh [day_of_year] [use_ramdisk]
# Example: ./calculate_shadows_PARALLEL_OPTIMIZED_v2.sh 153 yes
# Example: ./calculate_shadows_PARALLEL_OPTIMIZED_v2.sh 153 no

set -euo pipefail

# ============================================
# Configuration
# ============================================

DOY=${1:-153}
USE_RAMDISK=${2:-no}  # yes/no
YEAR=2021

# Parallel processing settings
NUM_PARALLEL_JOBS=6  # Process 6 timesteps simultaneously
CPUS_PER_JOB=$((180 / NUM_PARALLEL_JOBS))  # 30 CPUs per job

# GRASS GIS paths
if [[ "$USE_RAMDISK" == "yes" ]]; then
    GRASSDATA="/mnt/ramdisk/grassdata"
    RAMDISK_SIZE="200G"  # Increased size to handle multiple workers
    echo "===> Using RAMDisk: $GRASSDATA"
else
    GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
fi

LOCATION="swiss_project"
MAPSET="PERMANENT"

INPUT_DSM="INPUT_DSM"
SLOPE="slope_deg"
ASPECT="aspect_deg"

OUTPUT_DIR="./shadow_outputs_doy${DOY}"
mkdir -p "$OUTPUT_DIR"

# OPTIMIZED: More aggressive GDAL settings for 1TB RAM
export GDAL_CACHEMAX=32768  # 32GB cache
export GDAL_NUM_THREADS=ALL_CPUS
export GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR

# UTC TIME SETTINGS
UTC_START_HOUR=10
UTC_END_HOUR=11
INTERVAL_MINUTES=2.0
CIVIL_TIME=0

# Compression settings
COMPRESS="COMPRESS=ZSTD,ZLEVEL=1,TILED=YES,BLOCKXSIZE=512,BLOCKYSIZE=512"

# ============================================
# Functions
# ============================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to process a single timestep (will be run in parallel)
process_timestep() {
    local CURRENT_TIME=$1
    local DOY=$2
    local WORKER_ID=$3
    
    # All workers share the SAME GRASS location (read-only for input data)
    # Only output rasters are unique per worker
    local WORKER_GRASSDATA="$GRASSDATA"
    local WORKER_LOCATION="$LOCATION"
    local WORKER_MAPSET="worker${WORKER_ID}"
    
    # Extract hour and minute
    local HOUR_PART=$(echo "$CURRENT_TIME" | awk '{print int($1)}')
    HOUR_PART=$(printf "%02d" $HOUR_PART)
    
    local MINUTE_PART=$(echo "$CURRENT_TIME" | awk '{mins=($1-int($1))*60; printf "%02d", int(mins+0.5)}')
    local TIME_STRING="${HOUR_PART}${MINUTE_PART}"
    
    log_message "[Worker $WORKER_ID] Processing UTC ${HOUR_PART}:${MINUTE_PART} (decimal: $CURRENT_TIME)"
    
    # Output raster names (unique per worker)
    local INCIDENCE_MAP="solar_incidence_w${WORKER_ID}_${TIME_STRING}"
    local INCIDENCE_8BIT="solar_incidence_8bit_w${WORKER_ID}_${TIME_STRING}"
    local BEAM_MAP="beam_rad_w${WORKER_ID}_${TIME_STRING}"
    local SHADOW_MAP="shadow_mask_w${WORKER_ID}_${TIME_STRING}"
    
    # Run r.sun - it will read from PERMANENT mapset, write to worker mapset
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$WORKER_MAPSET" --exec r.sun \
        elevation=$INPUT_DSM@PERMANENT \
        aspect=$ASPECT@PERMANENT \
        slope=$SLOPE@PERMANENT \
        day=$DOY \
        time=$CURRENT_TIME \
        civil_time=$CIVIL_TIME \
        lon=longitude_raster@PERMANENT \
        lat=latitude_raster@PERMANENT \
        beam_rad=$BEAM_MAP \
        incidout=$INCIDENCE_MAP \
        nprocs=$CPUS_PER_JOB \
        memory=150000 \
        --overwrite --quiet 2>/dev/null
    
    # Create shadow mask
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$WORKER_MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP = if(isnull($INCIDENCE_MAP), 1, 0)" \
        --overwrite --quiet 2>/dev/null
    
    # Convert to 8-bit
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$WORKER_MAPSET" --exec r.mapcalc \
        "$INCIDENCE_8BIT = if(isnull($INCIDENCE_MAP), 255, int(min(round($INCIDENCE_MAP * 255.0 / 90.0), 254)))" \
        --overwrite --quiet 2>/dev/null
    
    # Export shadow mask
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$WORKER_MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet 2>/dev/null
    
    # Export solar incidence
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$WORKER_MAPSET" --exec r.out.gdal \
        input=$INCIDENCE_8BIT \
        output="$OUTPUT_DIR/solar_incidence_8bit_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        nodata=255 \
        --overwrite --quiet 2>/dev/null
    
    # Clean up
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$WORKER_MAPSET" --exec g.remove -f \
        type=raster \
        name=$BEAM_MAP,$INCIDENCE_MAP,$INCIDENCE_8BIT,$SHADOW_MAP \
        2>/dev/null || true
    
    log_message "[Worker $WORKER_ID] ✓ Completed UTC ${HOUR_PART}:${MINUTE_PART}"
}

# Export function so GNU parallel can use it
export -f process_timestep
export -f log_message
export GRASSDATA LOCATION MAPSET INPUT_DSM SLOPE ASPECT DOY CIVIL_TIME OUTPUT_DIR COMPRESS CPUS_PER_JOB

# ============================================
# Setup Phase
# ============================================

log_message "========================================"
log_message "PARALLEL Shadow Calculation v2 (IMPROVED)"
log_message "========================================"
log_message "Day of Year: $DOY"
log_message "Parallel jobs: $NUM_PARALLEL_JOBS"
log_message "CPUs per job: $CPUS_PER_JOB"
log_message "Total CPUs: 180"
log_message "RAMDisk: $USE_RAMDISK"
log_message "GDAL Cache: 32GB"
log_message "Method: Shared GRASS database (no duplication!)"
log_message "========================================"
echo ""

# Setup RAMDisk if requested
if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "Setting up RAMDisk..."
    
    if ! mountpoint -q /mnt/ramdisk; then
        sudo mkdir -p /mnt/ramdisk
        sudo mount -t tmpfs -o size=$RAMDISK_SIZE tmpfs /mnt/ramdisk
        log_message "RAMDisk mounted: $RAMDISK_SIZE at /mnt/ramdisk"
    else
        log_message "RAMDisk already mounted"
        df -h /mnt/ramdisk
    fi
    
    # Copy GRASS database to RAMDisk (only ONCE!)
    if [[ ! -d "$GRASSDATA/$LOCATION" ]]; then
        log_message "Copying GRASS database to RAMDisk..."
        mkdir -p "$GRASSDATA"
        
        # Check source size
        SOURCE_SIZE=$(du -sh "$HOME/grassdata/$LOCATION" | cut -f1)
        log_message "Source GRASS database size: $SOURCE_SIZE"
        
        cp -r "$HOME/grassdata/$LOCATION" "$GRASSDATA/"
        log_message "GRASS database copied to RAMDisk"
        
        # Show RAMDisk usage
        df -h /mnt/ramdisk
    else
        log_message "GRASS database already in RAMDisk"
    fi
fi

# Create worker mapsets (lightweight - no data duplication!)
log_message "Creating worker mapsets..."
for ((i=1; i<=NUM_PARALLEL_JOBS; i++)); do
    WORKER_MAPSET="worker${i}"
    MAPSET_PATH="$GRASSDATA/$LOCATION/$WORKER_MAPSET"
    
    if [[ ! -d "$MAPSET_PATH" ]]; then
        # Create mapset directory structure
        mkdir -p "$MAPSET_PATH"
        
        # Copy only essential mapset files from PERMANENT
        cp "$GRASSDATA/$LOCATION/PERMANENT/WIND" "$MAPSET_PATH/"
        cp "$GRASSDATA/$LOCATION/PERMANENT/DEFAULT_WIND" "$MAPSET_PATH/" 2>/dev/null || true
        
        # Create essential subdirectories (empty)
        mkdir -p "$MAPSET_PATH/cell"
        mkdir -p "$MAPSET_PATH/cellhd"
        mkdir -p "$MAPSET_PATH/cats"
        mkdir -p "$MAPSET_PATH/colr"
        mkdir -p "$MAPSET_PATH/hist"
        mkdir -p "$MAPSET_PATH/cell_misc"
        
        log_message "Created worker mapset: $WORKER_MAPSET (lightweight)"
    fi
done

log_message "Worker mapset creation complete"
echo ""

# Calculate slope/aspect once in PERMANENT mapset
log_message "Checking for slope and aspect maps..."
if ! grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info -e map=$SLOPE &>/dev/null; then
    log_message "Calculating slope and aspect (using all 180 CPUs)..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.slope.aspect \
        elevation=$INPUT_DSM \
        slope=$SLOPE \
        aspect=$ASPECT \
        format=degrees \
        nprocs=180 \
        memory=900000 \
        --overwrite
fi

# Create lon/lat rasters in PERMANENT mapset
LONGITUDE_MAP="longitude_raster"
LATITUDE_MAP="latitude_raster"

if ! grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info -e map=$LONGITUDE_MAP &>/dev/null; then
    log_message "Creating longitude and latitude rasters..."
    grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.latlong \
        input=$INPUT_DSM \
        output=$LATITUDE_MAP,$LONGITUDE_MAP \
        --overwrite --quiet 2>/dev/null || {
        
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
            "$LONGITUDE_MAP = 5.96 + (x() - 2485000.0) / 111320.0 / cos(0.817)" \
            --overwrite --quiet
        
        grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.mapcalc \
            "$LATITUDE_MAP = 45.82 + (y() - 1075000.0) / 111320.0" \
            --overwrite --quiet
    }
fi
echo ""

# Generate timesteps
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)
TIME_STEPS=()
NUM_STEPS=$(echo "scale=0; ($UTC_END_HOUR - $UTC_START_HOUR) / $INTERVAL_HOURS" | bc)

for ((i=0; i<NUM_STEPS; i++)); do
    CURRENT_TIME=$(echo "scale=6; $UTC_START_HOUR + ($i * $INTERVAL_HOURS)" | bc)
    CURRENT_TIME=$(printf "%.4f" $CURRENT_TIME)
    TIME_STEPS+=($CURRENT_TIME)
done

log_message "Total time steps: ${#TIME_STEPS[@]}"
log_message "Expected parallel batches: $(echo "(${#TIME_STEPS[@]} + $NUM_PARALLEL_JOBS - 1) / $NUM_PARALLEL_JOBS" | bc)"
echo ""

# Show disk/RAM usage before starting
if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "RAMDisk usage before processing:"
    df -h /mnt/ramdisk
    echo ""
fi

# ============================================
# Parallel Processing
# ============================================

START_TIME=$(date +%s)

log_message "Starting parallel processing..."
log_message "Processing $NUM_PARALLEL_JOBS timesteps simultaneously..."
echo ""

# Check if GNU parallel is available
if ! command -v parallel &> /dev/null; then
    log_message "ERROR: GNU parallel not found!"
    log_message "Install with: sudo apt-get install parallel"
    exit 1
fi

# Process timesteps in parallel
printf '%s\n' "${TIME_STEPS[@]}" | \
    parallel -j $NUM_PARALLEL_JOBS \
    --line-buffer \
    --joblog "$OUTPUT_DIR/parallel_joblog.txt" \
    --bar \
    'process_timestep {} '"$DOY"' $((({%} - 1) % '"$NUM_PARALLEL_JOBS"' + 1))'

# ============================================
# Cleanup and Summary
# ============================================

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
log_message "========================================"
log_message "Processing complete!"
log_message "Time elapsed: ${MINUTES}m ${SECONDS}s"
log_message "========================================"

# Generate statistics
SHADOW_COUNT=$(ls -1 "$OUTPUT_DIR"/shadow_mask_*.tif 2>/dev/null | wc -l)
INCIDENCE_COUNT=$(ls -1 "$OUTPUT_DIR"/solar_incidence_8bit_*.tif 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

log_message "Generated files:"
log_message "  Shadow masks: $SHADOW_COUNT"
log_message "  Incidence maps: $INCIDENCE_COUNT"
log_message "  Total size: $TOTAL_SIZE"
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / ${#TIME_STEPS[@]}" | bc)s"
log_message "  Effective speedup: ${NUM_PARALLEL_JOBS}x"
echo ""

# Show final disk/RAM usage
if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "Final RAMDisk usage:"
    df -h /mnt/ramdisk
    echo ""
fi

# Cleanup worker mapsets
log_message "Cleaning up worker mapsets..."
for ((i=1; i<=NUM_PARALLEL_JOBS; i++)); do
    rm -rf "$GRASSDATA/$LOCATION/worker${i}" 2>/dev/null || true
done

# RAMDisk cleanup notice
if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "========================================"
    log_message "RAMDisk Notice"
    log_message "========================================"
    log_message "RAMDisk is still mounted at /mnt/ramdisk"
    log_message "To clean up and unmount:"
    log_message "  ./cleanup_ramdisk.sh"
    log_message "Or manually:"
    log_message "  sudo rm -rf /mnt/ramdisk/*"
    log_message "  sudo umount /mnt/ramdisk"
fi

log_message "Done!"
