#!/bin/bash
# Script: setup_grass_location.sh
# Creates GRASS GIS location and imports DEM
# Usage: ./setup_grass_location.sh /path/to/your/dem.tif

set -euo pipefail

# ============================================
# Configuration
# ============================================

# Check if DEM path provided
if [ $# -eq 0 ]; then
    echo "ERROR: Please provide path to DEM file"
    echo "Usage: $0 /path/to/dem.tif"
    exit 1
fi

DEM_FILE="$1"

# Check if DEM exists
if [ ! -f "$DEM_FILE" ]; then
    echo "ERROR: DEM file not found: $DEM_FILE"
    exit 1
fi

# GRASS GIS settings
GRASSDATA="${GRASSDATA:-$HOME/grassdata}"
LOCATION="swiss_project"
MAPSET="PERMANENT"

echo "========================================"
echo "GRASS GIS Location Setup"
echo "========================================"
echo "DEM file: $DEM_FILE"
echo "GRASS database: $GRASSDATA"
echo "Location: $LOCATION"
echo "========================================"
echo ""

# ============================================
# Create GRASS Database Directory
# ============================================

mkdir -p "$GRASSDATA"
echo "✓ GRASS database directory created/verified"

# ============================================
# Create Location from DEM
# ============================================

echo ""
echo "Creating GRASS location from DEM..."
echo "This will automatically detect projection from the DEM file."
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
grass -c "$DEM_FILE" "$GRASSDATA/$LOCATION" --exec g.proj -p

echo "✓ Location created successfully"
echo ""

# ============================================
# Import DEM
# ============================================

echo "Importing DEM into GRASS..."
echo ""

grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.in.gdal \
    input="$DEM_FILE" \
    output=dem_wgs84 \
    memory=50000 \
    --overwrite

echo ""
echo "✓ DEM imported as 'dem_wgs84'"
echo ""

# ============================================
# Set Computational Region
# ============================================

echo "Setting computational region to DEM extent..."

grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.region raster=dem_wgs84

echo "✓ Computational region set"
echo ""

# ============================================
# Calculate Slope and Aspect
# ============================================

echo "Pre-calculating slope and aspect (this may take a few minutes)..."
echo ""

grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.slope.aspect \
    elevation=dem_wgs84 \
    slope=slope_deg \
    aspect=aspect_deg \
    format=degrees \
    nprocs=88 \
    memory=50000 \
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

echo "Available rasters:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec g.list type=raster
echo ""

echo "DEM statistics:"
grass "$GRASSDATA/$LOCATION/$MAPSET" --exec r.info map=dem_wgs84
echo ""

echo "========================================"
echo "You can now run the shadow calculation script:"
echo "./calculate_shadows_optimized.sh 100"
echo "========================================"
