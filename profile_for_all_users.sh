#!/bin/bash
# Run as root

set -e

# Validate input
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <num_users (integer)>"
  exit 1
fi

num_users=$1

for i in $(seq 1 "$num_users"); do
  user=$(printf "user%02d" "$i")
  su - "$user" -c '
    if [ ! -d "$HOME/geoips_tutorials" ]; then
        git clone https://github.com/nrlmmd-geoips/geoips_tutorials.git "$HOME/geoips_tutorials"
    fi
    cd "$HOME/geoips_tutorials" &&
    git checkout 2026-workshop-updates &&
    pip install .[test] &&
    cd notebooks &&
    export GEOIPS_OUTDIRS="$HOME/geoips_outdirs" &&
    export GEOIPS_TESTDATA_DIR="$HOME/geoips_test_data" &&
    python ../profile_notebook.py ./scripting_with_geoips.ipynb
  ' &
done

wait  # Wait for all background jobs to finish
