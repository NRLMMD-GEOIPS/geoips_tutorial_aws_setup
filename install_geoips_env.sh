#!/bin/bash
set -Eeuo pipefail

TARGET="$HOME/miniconda3"

echo "Extracting conda environment to $TARGET"
mkdir -p "$TARGET"
tar -xzf "$TARGET/geoips-env.tgz" -C "$TARGET"
rm -f "$TARGET/geoips-env.tgz"
"$TARGET/bin/conda-unpack"

# Add activation to .bashrc if not already present
grep -q "source $TARGET/bin/activate" "$HOME/.bashrc" || echo "source $TARGET/bin/activate" >> "$HOME/.bashrc"
grep -qFx 'export GEOIPS_REBUILD_REGISTRIES=true' "$HOME/.bashrc" \
    || echo 'export GEOIPS_REBUILD_REGISTRIES=true' >> "$HOME/.bashrc"

# Install the Jupyter kernel with this environment's Python directly. Sourcing
# activate under `set -u` can fail when Conda references an unset CONDA_PREFIX
# during the initial activation.
"$TARGET/bin/python" -m ipykernel install \
    --user \
    --name geoips \
    --display-name "GeoIPS - Python 3.11"

echo "Generating GeoIPS plugin registries"
"$TARGET/bin/geoips" config create-registries
