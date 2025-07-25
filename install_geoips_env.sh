#!/bin/bash
set -e

TARGET="$HOME/miniconda3"

echo "Extracting conda environment to $TARGET"
tar -xzf "$TARGET/geoips-env.tgz" -C "$TARGET"

# Add activation to .bashrc if not already present
grep -q "source $TARGET/bin/activate" "$HOME/.bashrc" || echo "source $TARGET/bin/activate" >> "$HOME/.bashrc"

# Activate and install Jupyter kernel
source "$TARGET/bin/activate"
python -m ipykernel install --user --name geoips --display-name "GeoIPS - Python 3.11"
