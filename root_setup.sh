#!/bin/env bash

# Settings
NUM_USERS=4
TUTORIAL_REPO_URL=https://github.com/NRLMMD-GEOIPS/geoips_tutorials.git

# Install system-level software
dnf update -y
dnf install -y git nodejs npm shadow-utils wget rsync

# Create users
usernames=()
for unum in $(seq -w 1 "${NUM_USERS}"); do
    user="user${unum}"
    pass="geoips_pass${unum}"
    useradd -m "${user}"
    echo "${user}:${pass}" | chpasswd
    usernames+=("${user}")
done

# Download miniconda installer and install for each user
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /opt/miniconda_installer.sh
chmod u+x /opt/miniconda_installer.sh
/opt/miniconda_installer.sh -b -p /opt/miniconda-ref
echo "export CONDA_ACCEPT_LICENSES=true" >> "$HOME/.bashrc"
echo "eval \"\$(/opt/miniconda-ref/bin/conda shell.bash hook)\"" >> "$HOME/.bashrc"
source "$HOME/.bashrc"
conda init --all
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
source "$HOME/.bashrc"
conda create -n geoips -c conda-forge python=3.11 -y
conda activate geoips
pip install --upgrade pip
pip install geoips geoips_clavrx

export MINICONDA_SRC=/opt/miniconda-ref
printf "%s\n" "${usernames[@]}" | xargs -P"${NUM_USERS}" -I{} bash -c '
    TARGET="/home/{}/miniconda3"
    mkdir "$TARGET"
    rsync -a "$MINICONDA_SRC/" "$TARGET/"
    chown -R {}:{} "$TARGET"
    echo "eval \"\$($TARGET/bin/conda shell.bash hook)\"" >> "/home/{}/.bashrc"
    echo "conda activate geoips" >> "/home/{}/.bashrc"
'