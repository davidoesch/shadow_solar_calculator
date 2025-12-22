#!/bin/bash
# Script: setup_grass_location.sh
# Creates GRASS GIS location and imports DSM for Swiss CH1903+ / LV95 projection
# Usage: ./setup_grass_location.sh /path/to/your/dsm.tif

set -euo pipefail

# ============================================
# Configuration
# ============================================

# Check if DSM path provided
if [ $# -eq 0 ]; then
    echo "ERROR: Please provide path to DSM file"
    echo "Usage: $0 /path/to/Thinout_highest_object_10m_LV95_LHN95_ref.tif"
    exit 1
fi

DSM_FILE="$1"

# Check if DSM exists
if [ ! -f "$DSM_FILE" ]; then
    echo "ERROR: DSM file not found: $DSM_FILE"
    exit 1
fi

# GRASS GIS settings
GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
LOCATION="swiss_project"
MAPSET="PERMANENT"

# Server specifications (adjust if needed)
NPROCS=180
MEMORY=900000  # ~900GB in MB (leaving some for system)

echo "========================================"
echo "GRASS GIS Location Setup"
echo "========================================"
echo "DSM file: $DSM_FILE"
echo "GRASS database: $GRASSDATA"
echo "Location: $LOCATION"
echo "Using $NPROCS CPUs"
echo "Memory allocation: ${MEMORY}MB"
echo "========================================"
echo ""

# ============================================
# Create GRASS Database Directory
# ============================================

mkdir -p "$GRASSDATA"
echo "✓ GRASS database directory created/verified"

# ============================================
# Create Location from DSM
# ============================================

echo ""
echo "Creating GRASS location from DSM..."
echo "Projection: CH1903+ / LV95 (EPSG:2056)"
echo ""

# Remove existing location if it exists
if [ -d "$GRASSDATA/$LOCATION" ]; then
    echo "WARNING: Location $LOCATION already exists"
    read -p "Do you want to overwrite it? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Removing existing location..."
        rm -rf "$GRASSDATA/$LOCATION"
    else
        echo "Aborted. Please choose a different location name."
        exit 1
    fi
fi

# Create location from georeferenced file
grass -c "$DSM_FILE" "$GRASSDATA/$LOCATION" --exec g.proj -p

echo "✓ Location created successfully"
echo ""

# ============================================
# Import DSM
# ============================================

echo "Importing DSM into GRASS..."
echo "Size: 34901 x 22101 pixels (10m resolution)"
echo "Extent: 2485000-2834010 E, 1075000-1296010 N"
echo ""

grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.in.gdal \
    input="$DSM_FILE" \
    output=INPUT_DSM \
    memory=$MEMORY \
    --overwrite

echo ""
echo "✓ DSM imported as 'INPUT_DSM'"
echo ""

# ============================================
# Set Computational Region
# ============================================

echo "Setting computational region to DSM extent..."

grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.region raster=INPUT_DSM

echo "✓ Computational region set"
echo ""

# Display region info
echo "Region information:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.region -p
echo ""

# ============================================
# Calculate Slope and Aspect
# ============================================

echo "Pre-calculating slope and aspect..."
echo "Using $NPROCS processors with ${MEMORY}MB memory"
echo "This may take a few minutes for this large dataset..."
echo ""

grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.slope.aspect \
    elevation=INPUT_DSM \
    slope=slope_deg \
    aspect=aspect_deg \
    format=degrees \
    nprocs=$NPROCS \
    memory=$MEMORY \
    --overwrite

echo ""
echo "✓ Slope and aspect calculated"
echo ""

# ============================================
# Display Information
# ============================================

echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Location details:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.proj -p
echo ""

echo "Computational region:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.region -p
echo ""

echo "Available rasters:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.list type=raster
echo ""

echo "DSM statistics:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info map=INPUT_DSM
echo ""

echo "========================================"
echo "Ready for processing!"
echo "Your DSM is imported as: INPUT_DSM"
echo "Derived maps: slope_deg, aspect_deg"
echo ""
echo "Next steps:"
echo "  - Run shadow calculations"
echo "  - Run viewshed analysis"
echo "  - Run terrain analysis"
echo "========================================"