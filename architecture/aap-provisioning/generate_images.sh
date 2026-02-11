#!/bin/bash
# Script to generate PNG images from PlantUML diagrams
# Requires: Docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGRAMS_DIR="$SCRIPT_DIR/diagrams"
IMAGES_DIR="$SCRIPT_DIR/images"

echo "Generating images from PlantUML diagrams..."
echo "Source: $DIAGRAMS_DIR"
echo "Target: $IMAGES_DIR"

# Run PlantUML via Docker to convert all .puml files to PNG
docker run --rm \
  -v "$DIAGRAMS_DIR:/data:Z" \
  docker.io/plantuml/plantuml:latest \
  -tpng \
  -o /data \
  /data/*.puml

# Move generated PNGs to images directory
mv "$DIAGRAMS_DIR"/*.png "$IMAGES_DIR/" 2>/dev/null || true

echo ""
echo "Done! Generated images:"
ls -lh "$IMAGES_DIR"/*.png
