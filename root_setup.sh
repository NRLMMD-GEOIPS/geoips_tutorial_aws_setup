#!/bin/env bash

# --- Settings ---
HOME=/root
NUM_USERS=4
TUTORIAL_REPO_URL=https://github.com/NRLMMD-GEOIPS/geoips_tutorials.git
# --- Install system-level software ---
dnf update -y
dnf install -y python3-pip git nodejs npm shadow-utils wget rsync
dnf remove -y nodejs  # Remove Node 16
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
dnf install -y nodejs

# --- Install JupyterHub and notebook server ---
python3 -m pip install jupyterhub notebook jupyterlab ipykernel
npm install -g configurable-http-proxy

# --- Create users ---
usernames=()
for unum in $(seq -w 1 "${NUM_USERS}"); do
    user="user${unum}"
    pass="geoips_pass${unum}"
    useradd -m "${user}"
    echo "${user}:${pass}" | chpasswd
    usernames+=("${user}")
done

# --- Download and install miniconda in /opt/miniconda-ref ---
# This section runs in a subshell to avoid polluting the root environment
# with conda variables and paths. When done, the environment will revert
# to its original state.
#
# Later, the resulting conda installation will be copied to each user's home directory.
(
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /opt/miniconda_installer.sh
    chmod u+x /opt/miniconda_installer.sh
    /opt/miniconda_installer.sh -b -p /opt/miniconda-ref
    echo "export CONDA_ACCEPT_LICENSES=true" >> "$HOME/conda_bashrc"
    echo "eval \"\$(/opt/miniconda-ref/bin/conda shell.bash hook)\"" >> "$HOME/conda_bashrc"
    source "$HOME/conda_bashrc"
    conda init --all
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
    source "$HOME/conda_bashrc"
    conda create -n geoips -c conda-forge python=3.11 -y
    conda activate geoips
    python -m pip install --upgrade pip
    python -m pip install geoips geoips_clavrx ipykernel
)

# --- Copy conda environment to each user's home directory ---
# Also add conda initialization and geoips environment activation to each user's .bashrc
export MINICONDA_SRC=/opt/miniconda-ref
printf "%s\n" "${usernames[@]}" | xargs -P"${NUM_USERS}" -I{} bash -c '
    TARGET="/home/{}/miniconda3"
    ENV_BIN="$TARGET/envs/geoips/bin"
    KERNEL_DISPLAY_NAME="GeoIPS - Python 3.11"

    mkdir "$TARGET"
    rsync -a "$MINICONDA_SRC/" "$TARGET/"
    chown -R {}:{} "$TARGET"
    echo "eval \"\$($TARGET/bin/conda shell.bash hook)\"" >> "/home/{}/.bashrc"
    echo "conda activate geoips" >> "/home/{}/.bashrc"

    su - {} -c "
        source \"$TARGET/bin/activate\" geoips && \
        python -m ipykernel install --user --name geoips --display-name \"$KERNEL_DISPLAY_NAME\"
    "
'
