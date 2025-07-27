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
  user="user$i"
  su - "$user" -c '
    cd "$HOME/geoips_tutorials" &&
    git checkout tutorial-devel &&
    pip install .[test] &&
    cd notebooks &&
    python ../profile_notebook.py ./scripting_with_geoips.ipynb
  ' &
done

wait  # Wait for all background jobs to finish