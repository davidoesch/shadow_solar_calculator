#!/bin/bash
# Script: calculate_shadows_sunmask_PARALLEL_OPTIMIZED_v2.sh
# IMPROVED VERSION: Uses mapsets instead of copying full GRASS databases
# Optimized for 180 CPUs, 1TB RAM with parallel processing
# MUCH LOWER disk/RAM usage!
# 
# Usage: ./calculate_shadows_sunmask_PARALLEL_OPTIMIZED_v2.sh [day_of_year] [use_ramdisk]
# Example: ./calculate_shadows_sunmask_PARALLEL_OPTIMIZED_v2.sh 153 yes

set -euo pipefail

# ============================================
# Configuration
# ============================================

DOY=${1:-153}
USE_RAMDISK=${2:-no}
YEAR=2021

# Calculate month and day from DOY
case $DOY in
    153) MONTH=6; DAY=2;;
    181) MONTH=6; DAY=30;;
    213) MONTH=8; DAY=1;;
    50)  MONTH=2; DAY=19;;
    15)  MONTH=1; DAY=15;;
    *)
        MONTH=$(date -d "2021-01-01 +$(($DOY - 1)) days" +%m)
        DAY=$(date -d "2021-01-01 +$(($DOY - 1)) days" +%d)
        ;;
esac

# r.sunmask is single-threaded, so run many in parallel
NUM_PARALLEL_JOBS=30
RAMDISK_SIZE="150G"  # Much smaller since we don't duplicate

# GRASS GIS paths
if [[ "$USE_RAMDISK" == "yes" ]]; then
    GRASSDATA="/mnt/ramdisk/grassdata"
else
    GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
fi

LOCATION="swiss_project"
MAPSET="PERMANENT"
INPUT_DSM="INPUT_DSM"

OUTPUT_DIR="./shadow_outputs_doy${DOY}_sunmask"
mkdir -p "$OUTPUT_DIR"

# OPTIMIZED GDAL settings
export GDAL_CACHEMAX=32768
export GDAL_NUM_THREADS=ALL_CPUS
export GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR

# UTC TIME SETTINGS
UTC_START_HOUR=10
UTC_END_HOUR=11
INTERVAL_MINUTES=2.0
TIMEZONE=0

COMPRESS="COMPRESS=ZSTD,ZLEVEL=1,TILED=YES,BLOCKXSIZE=512,BLOCKYSIZE=512"

# ============================================
# Functions
# ============================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

process_timestep() {
    local TIME_STEP=$1
    local DOY=$2
    local YEAR=$3
    local MONTH=$4
    local DAY=$5
    local WORKER_ID=$6
    
    local WORKER_MAPSET="worker${WORKER_ID}"
    
    IFS=':' read -r HOUR MINUTE <<< "$TIME_STEP"
    
    local HOUR_STR=$(printf "%02d" $HOUR)
    local MINUTE_STR=$(printf "%02d" $MINUTE)
    local TIME_STRING="${HOUR_STR}${MINUTE_STR}"
    
    log_message "[Worker $WORKER_ID] Processing UTC ${HOUR_STR}:${MINUTE_STR}"
    
    local SHADOW_MAP="shadow_sunmask_w${WORKER_ID}_${TIME_STRING}"
    local SHADOW_MAP_INVERTED="${SHADOW_MAP}_inverted"
    
    grass "$GRASSDATA/$LOCATION/$WORKER_MAPSET" --exec r.sunmask \
        elevation=$INPUT_DSM@PERMANENT \
        output=$SHADOW_MAP \
        year=$YEAR \
        month=$MONTH \
        day=$DAY \
        hour=$HOUR \
        minute=$MINUTE \
        timezone=$TIMEZONE \
        --overwrite --quiet 2>/dev/null
    
    grass "$GRASSDATA/$LOCATION/$WORKER_MAPSET" --exec r.mapcalc \
        "$SHADOW_MAP_INVERTED = if(isnull($SHADOW_MAP), 0, 1)" \
        --overwrite --quiet 2>/dev/null
    
    grass "$GRASSDATA/$LOCATION/$WORKER_MAPSET" --exec r.out.gdal \
        input=$SHADOW_MAP_INVERTED \
        output="$OUTPUT_DIR/shadow_mask_doy${DOY}_UTC${TIME_STRING}.tif" \
        format=GTiff \
        type=Byte \
        createopt="$COMPRESS" \
        --overwrite --quiet 2>/dev/null
    
    grass "$GRASSDATA/$LOCATION/$WORKER_MAPSET" --exec g.remove -f \
        type=raster \
        name=$SHADOW_MAP,$SHADOW_MAP_INVERTED \
        2>/dev/null || true
    
    log_message "[Worker $WORKER_ID] ✓ Completed UTC ${HOUR_STR}:${MINUTE_STR}"
}

export -f process_timestep
export -f log_message
export GRASSDATA LOCATION MAPSET INPUT_DSM DOY YEAR MONTH DAY TIMEZONE OUTPUT_DIR COMPRESS

# ============================================
# Setup Phase
# ============================================

log_message "========================================"
log_message "PARALLEL r.sunmask v2 (IMPROVED)"
log_message "========================================"
log_message "Day of Year: $DOY (${YEAR}-${MONTH}-${DAY})"
log_message "Parallel jobs: $NUM_PARALLEL_JOBS"
log_message "RAMDisk: $USE_RAMDISK"
log_message "Method: Shared GRASS database with worker mapsets"
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
    
    if [[ ! -d "$GRASSDATA/$LOCATION" ]]; then
        log_message "Copying GRASS database to RAMDisk..."
        mkdir -p "$GRASSDATA"
        
        SOURCE_SIZE=$(du -sh "$HOME/grassdata/$LOCATION" | cut -f1)
        log_message "Source size: $SOURCE_SIZE"
        
        cp -r "$HOME/grassdata/$LOCATION" "$GRASSDATA/"
        log_message "GRASS database copied"
        
        df -h /mnt/ramdisk
    fi
fi

# Create lightweight worker mapsets
log_message "Creating worker mapsets..."
for ((i=1; i<=NUM_PARALLEL_JOBS; i++)); do
    WORKER_MAPSET="worker${i}"
    MAPSET_PATH="$GRASSDATA/$LOCATION/$WORKER_MAPSET"
    
    if [[ ! -d "$MAPSET_PATH" ]]; then
        mkdir -p "$MAPSET_PATH"
        cp "$GRASSDATA/$LOCATION/PERMANENT/WIND" "$MAPSET_PATH/"
        cp "$GRASSDATA/$LOCATION/PERMANENT/DEFAULT_WIND" "$MAPSET_PATH/" 2>/dev/null || true
        
        mkdir -p "$MAPSET_PATH"/{cell,cellhd,cats,colr,hist,cell_misc}
        
        if (( i % 5 == 0 )); then
            log_message "Created $i/$NUM_PARALLEL_JOBS worker mapsets..."
        fi
    fi
done
log_message "Worker mapsets ready"
echo ""

# Generate timesteps
INTERVAL_HOURS=$(echo "scale=6; $INTERVAL_MINUTES / 60" | bc)
TIME_STEPS=()
NUM_STEPS=$(echo "scale=0; ($UTC_END_HOUR - $UTC_START_HOUR) / $INTERVAL_HOURS" | bc)

for ((i=0; i<NUM_STEPS; i++)); do
    CURRENT_HOUR_DEC=$(echo "scale=6; $UTC_START_HOUR + ($i * $INTERVAL_HOURS)" | bc)
    HOUR=$(echo "$CURRENT_HOUR_DEC" | awk '{print int($1)}')
    MINUTE=$(echo "$CURRENT_HOUR_DEC" | awk '{mins=($1-int($1))*60; printf "%d", int(mins+0.5)}')
    TIME_STEPS+=("$HOUR:$MINUTE")
done

log_message "Total time steps: ${#TIME_STEPS[@]}"
log_message "Batches needed: $(echo "(${#TIME_STEPS[@]} + $NUM_PARALLEL_JOBS - 1) / $NUM_PARALLEL_JOBS" | bc)"
echo ""

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
echo ""

if ! command -v parallel &> /dev/null; then
    log_message "ERROR: GNU parallel not found!"
    log_message "Install with: sudo apt-get install parallel"
    exit 1
fi

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

SHADOW_COUNT=$(ls -1 "$OUTPUT_DIR"/shadow_mask_*.tif 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)

log_message "Generated files:"
log_message "  Shadow masks: $SHADOW_COUNT"
log_message "  Total size: $TOTAL_SIZE"
log_message "  Average time per step: $(echo "scale=2; $ELAPSED / ${#TIME_STEPS[@]}" | bc)s"
log_message "  Effective speedup: ${NUM_PARALLEL_JOBS}x"
echo ""

if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "Final RAMDisk usage:"
    df -h /mnt/ramdisk
    echo ""
fi

log_message "Cleaning up worker mapsets..."
for ((i=1; i<=NUM_PARALLEL_JOBS; i++)); do
    rm -rf "$GRASSDATA/$LOCATION/worker${i}" 2>/dev/null || true
done

if [[ "$USE_RAMDISK" == "yes" ]]; then
    log_message "========================================"
    log_message "RAMDisk is still mounted at /mnt/ramdisk"
    log_message "To clean up: ./cleanup_ramdisk.sh"
    log_message "========================================"
fi

log_message "Done!"
