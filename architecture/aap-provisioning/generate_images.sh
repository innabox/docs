#!/bin/bash
# Script to generate PNG images from PlantUML diagrams
# Requires: Docker or Podman

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGRAMS_DIR="$SCRIPT_DIR/diagrams"
IMAGES_DIR="$SCRIPT_DIR/images"

echo "Generating images from PlantUML diagrams..."
echo "Source: $DIAGRAMS_DIR"
echo "Target: $IMAGES_DIR"

# Detect container runtime (prefer docker, fallback to podman)
if command -v docker &> /dev/null; then
  CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
  CONTAINER_CMD="podman"
else
  echo "Error: Neither docker nor podman found. Please install one of them."
  exit 1
fi

echo "Using container runtime: $CONTAINER_CMD"

# Run PlantUML via container to convert all .puml files to PNG
$CONTAINER_CMD run --rm \
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
