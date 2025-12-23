#!/bin/bash
# Script: calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh
# FULLY OPTIMIZED r.sunmask for 180 CPUs, 1TB RAM with parallel processing
# Uses r.sunmask (SOLPOS algorithm) for UTC shadow calculation
# Processes MULTIPLE timesteps simultaneously for massive speedup!
# 
# Features:
# - Parallel timestep processing (30 simultaneous jobs - r.sunmask is single-threaded!)
# - Optional RAMDisk support for extreme speed
# - Optimized GDAL/GRASS settings
# - Progress monitoring
#
# Usage: ./calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh [day_of_year] [use_ramdisk]
# Example: ./calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh 153 yes
# Example: ./calculate_shadows_sunmask_PARALLEL_OPTIMIZED.sh 153 no

set -euo pipefail

# ============================================
# Configuration
# ============================================

DOY=${1:-153}
USE_RAMDISK=${2:-no}  # yes/no
YEAR=2021

# Calculate month and day from DOY
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

# CRITICAL: r.sunmask is SINGLE-THREADED!
# We can run MANY jobs in parallel since each uses only 1 CPU
NUM_PARALLEL_JOBS=30  # Process 30 timesteps simultaneously (since r.sunmask uses 1 CPU each)
# With 30 parallel jobs, we have 150 CPUs left for system overhead

# GRASS GIS paths
if [[ "$USE_RAMDISK" == "yes" ]]; then
    GRASSDATA="/mnt/ramdisk/grassdata"
    echo "===> Using RAMDisk: $GRASSDATA"
else
    GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
fi

LOCATION="swiss_project"
MAPSET="PERMANENT"

INPUT_DSM="INPUT_DSM"

OUTPUT_DIR="./shadow_outputs_doy${DOY}_sunmask"
mkdir -p "$OUTPUT_DIR"

# OPTIMIZED: More aggressive GDAL settings for 1TB RAM
export GDAL_CACHEMAX=32768  # 32GB cache
export GDAL_NUM_THREADS=ALL_CPUS
export GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR

# UTC TIME SETTINGS
UTC_START_HOUR=10
UTC_END_HOUR=11
INTERVAL_MINUTES=2.0
TIMEZONE=0

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
    local TIME_STEP=$1
    local DOY=$2
    local YEAR=$3
    local MONTH=$4
    local DAY=$5
    local WORKER_ID=$6
    
    # Use separate GRASS location for this worker to avoid locks
    local WORKER_GRASSDATA="$GRASSDATA"
    local WORKER_LOCATION="${LOCATION}_worker${WORKER_ID}"
    
    # Parse hour and minute
    IFS=':' read -r HOUR MINUTE <<< "$TIME_STEP"
    
    # Format for output filename
    local HOUR_STR=$(printf "%02d" $HOUR)
    local MINUTE_STR=$(printf "%02d" $MINUTE)
    local TIME_STRING="${HOUR_STR}${MINUTE_STR}"
    
    log_message "[Worker $WORKER_ID] Processing UTC ${HOUR_STR}:${MINUTE_STR}"
    
    # Output raster names (unique per worker)
    local SHADOW_MAP="shadow_sunmask_w${WORKER_ID}_${TIME_STRING}"
    local SHADOW_MAP_INVERTED="${SHADOW_MAP}_inverted"
    
    # Run r.sunmask (single-threaded, but we have many in parallel!)
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$MAPSET" --exec r.sunmask \
        elevation=$INPUT_DSM \
        output=$SHADOW_MAP \
        year=$YEAR \
        month=$MONTH \
        day=$DAY \
        hour=$HOUR \
        minute=$MINUTE \
        timezone=$TIMEZONE \
        --overwrite --quiet 2>/dev/null
    
    # Invert: r.sunmask outputs 0=shadow, NULL=sunlight
    # We want: 1=shadow, 0=illuminated
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP_INVERTED = if(isnull($SHADOW_MAP), 0, 1)" \
        --overwrite --quiet 2>/dev/null
    
    # Export shadow mask
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP_INVERTED \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet 2>/dev/null
    
    # Clean up
    grass "$WORKER_GRASSDATA/$WORKER_LOCATION/$MAPSET" --exec g.remove -f \
        type=raster \
        name=$SHADOW_MAP,$SHADOW_MAP_INVERTED \
        2>/dev/null || true
    
    log_message "[Worker $WORKER_ID] ✓ Completed UTC ${HOUR_STR}:${MINUTE_STR}"
}

# Export function so GNU parallel can use it
export -f process_timestep
export -f log_message
export GRASSDATA LOCATION MAPSET INPUT_DSM DOY YEAR MONTH DAY TIMEZONE OUTPUT_DIR COMPRESS

# ============================================
# Setup Phase
# ============================================

log_message "========================================"
log_message "PARALLEL r.sunmask (OPTIMIZED)"
log_message "========================================"
log_message "Day of Year: $DOY (${YEAR}-${MONTH}-${DAY})"
log_message "Parallel jobs: $NUM_PARALLEL_JOBS"
log_message "CPUs per job: 1 (r.sunmask is single-threaded)"
log_message "Total CPUs used: ~$NUM_PARALLEL_JOBS of 180"
log_message "RAMDisk: $USE_RAMDISK"
log_message "GDAL Cache: 32GB"
log_message "========================================"
log_message ""
log_message "NOTE: r.sunmask is single-threaded, so we run"
log_message "      MANY jobs in parallel to utilize all CPUs!"
log_message "========================================"
echo ""

# Setup RAMDisk if requested
if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "Setting up RAMDisk..."
    
    if ! mountpoint -q /mnt/ramdisk; then
        sudo mkdir -p /mnt/ramdisk
        sudo mount -t tmpfs -o size=100G tmpfs /mnt/ramdisk
        log_message "RAMDisk mounted: 100GB at /mnt/ramdisk"
    else
        log_message "RAMDisk already mounted"
    fi
    
    # Copy GRASS database to RAMDisk
    if [[ ! -d "$GRASSDATA/$LOCATION" ]]; then
        log_message "Copying GRASS database to RAMDisk..."
        mkdir -p "$GRASSDATA"
        cp -r "$HOME/grassdata/$LOCATION" "$GRASSDATA/"
        log_message "GRASS database copied to RAMDisk"
    fi
fi

# Create worker locations (separate GRASS databases to avoid locks)
log_message "Creating worker GRASS locations..."
for ((i=1; i<=NUM_PARALLEL_JOBS; i++)); do
    WORKER_LOCATION="${LOCATION}_worker${i}"
    if [[ ! -d "$GRASSDATA/$WORKER_LOCATION" ]]; then
        cp -r "$GRASSDATA/$LOCATION" "$GRASSDATA/$WORKER_LOCATION"
        log_message "Created worker location: $WORKER_LOCATION ($(( (i * 100) / NUM_PARALLEL_JOBS ))%)"
    fi
done
echo ""

# Generate timesteps
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)
TIME_STEPS=()
NUM_STEPS=$(echo "scale=0; ($UTC_END_HOUR - $UTC_START_HOUR) / $INTERVAL_HOURS" | bc)

for ((i=0; i<NUM_STEPS; i++)); do
    CURRENT_HOUR_DEC=$(echo "scale=6; $UTC_START_HOUR + ($i * $INTERVAL_HOURS)" | bc)
    
    # Split into hour and minute with proper rounding
    HOUR=$(echo "$CURRENT_HOUR_DEC" | awk '{print int($1)}')
    MINUTE=$(echo "$CURRENT_HOUR_DEC" | awk '{mins=($1-int($1))*60; printf "%d", int(mins+0.5)}')
    
    TIME_STEPS+=("$HOUR:$MINUTE")
done

log_message "Total time steps: ${#TIME_STEPS[@]}"
log_message "Expected parallel batches: $(echo "(${#TIME_STEPS[@]} + $NUM_PARALLEL_JOBS - 1) / $NUM_PARALLEL_JOBS" | bc)"
echo ""

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
    'process_timestep {} '"$DOY"' '"$YEAR"' '"$MONTH"' '"$DAY"' $((({%} - 1) % '"$NUM_PARALLEL_JOBS"' + 1))'

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
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

log_message "Generated files:"
log_message "  Shadow masks: $SHADOW_COUNT"
log_message "  Total size: $TOTAL_SIZE"
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / ${#TIME_STEPS[@]}" | bc)s"
log_message "  Effective speedup: ${NUM_PARALLEL_JOBS}x"
echo ""

# Cleanup worker locations
if [[ "$USE_RAMDISK" == "no" ]]; then
    log_message "Cleaning up worker locations..."
    for ((i=1; i<=NUM_PARALLEL_JOBS; i++)); do
        rm -rf "$GRASSDATA/${LOCATION}_worker${i}" 2>/dev/null || true
    done
fi

# RAMDisk cleanup notice
if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "========================================"
    log_message "RAMDisk Notice"
    log_message "========================================"
    log_message "RAMDisk is still mounted at /mnt/ramdisk"
    log_message "To unmount: sudo umount /mnt/ramdisk"
    log_message "Worker locations will be lost after unmount"
fi

log_message "========================================"
log_message "r.sunmask Configuration"
log_message "========================================"
log_message "Algorithm: SOLPOS (NREL)"
log_message "Timezone: $TIMEZONE (UTC/GMT - no offset)"
log_message "UTC time processed: ${UTC_START_HOUR}:00 - ${UTC_END_HOUR}:00"
log_message "Date: ${YEAR}-${MONTH}-${DAY} (DOY $DOY)"
log_message ""
log_message "Shadow mask format:"
log_message "  Value 1: Shadow"
log_message "  Value 0: Illuminated"
log_message "========================================"
log_message "Done!"
