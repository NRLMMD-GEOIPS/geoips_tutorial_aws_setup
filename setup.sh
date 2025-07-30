#!/bin/env bash
set -e

set -e

# Validate input
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <num_users (integer)>"
  exit 1
fi

NUM_USERS=$1

# --- Settings ---
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
HOME=/root
TUTORIAL_REPO_URL=https://github.com/NRLMMD-GEOIPS/geoips_tutorials.git

# --- Disable SELinux ---
# Doing this until I have time to figure out how to set it up properly.
setenforce 0

# --- Install system-level software ---
dnf update -y
# Remove any existing AppStream or conflicting versions
dnf remove -y nodejs npm nsolid
# Set up NodeSource Node.js 18 repo
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
# Install Node.js 18 (npm is bundled)
dnf install -y nodejs
# Install required tools (excluding npm since it's bundled)
dnf install -y python3-pip git shadow-utils wget rsync nginx unzip

# --- Detect environment (EC2 or Docker) ---
# If EC2, we will fetch the SSL certificate and key from AWS Secrets Manager.
# If Docker, we will skip this step since it is not needed.
if curl --connect-timeout 1 -s http://169.254.169.254/latest/meta-data/ > /dev/null; then
    echo "🖥️ Detected EC2 or systemd host"
    echo "    Doing full setup including RAID, SSL, and Nginx"
    if ! command -v aws &> /dev/null; then
        echo "Installing AWS CLI"
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        ./aws/install
    else
        echo "✅ AWS CLI already installed. Skipping installation."
    fi

    # --- Create RAID 0 if applicable ---
    echo "Setting up RAID 0 if applicable"
    if [ -f "$SCRIPT_DIR/create_raid-0.sh" ]; then
        $SCRIPT_DIR/create_raid-0.sh
    else
        echo "Warning: create_raid-0.sh not found, skipping RAID setup"
    fi

    # --- Collect cert and key from AWS Secrets Manager ---
    echo "Collecting SSL certificate and key"
    if [ -f "$SCRIPT_DIR/get_cert.sh" ]; then
        $SCRIPT_DIR/get_cert.sh
    else
        echo "Warning: get_cert.sh not found, skipping SSL setup"
    fi

    # --- Set up Nginx ---
    systemctl enable --now nginx
    cp $SCRIPT_DIR/jupyterhub.conf /etc/nginx/conf.d/jupyterhub.conf
    systemctl restart nginx
else
    echo "🛠️ Detected Docker container or Local host"
    echo "Doing less invasive setup"
    echo "    No RAID setup"
    echo "    No SSL certificate/key setup"
    echo "    No Nginx setup"
fi


# --- Install JupyterHub and notebook server ---
python3 -m pip install jupyterhub notebook jupyterlab
npm install -g configurable-http-proxy

# --- Create users ---
usernames=()
for unum in $(seq -w 1 "${NUM_USERS}"); do
    user="user${unum}"
    pass="geoips_pass${unum}"
    useradd -m "${user}" || true
    echo "${user}:${pass}" | chpasswd
    usernames+=("${user}")
done

# --- Copy JupyterLab start script ---
cp "$SCRIPT_DIR/start_jupyterlab.sh" /opt/start_jupyterlab.sh
chmod +x /opt/start_jupyterlab.sh

# --- Download and install miniconda in /opt/miniconda-ref ---
# This section runs in a subshell to avoid polluting the root environment
# with conda variables and paths. When done, the environment will revert
# to its original state.
#
# Later, the resulting conda installation will be copied to each user's home directory.
(
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /opt/miniconda_installer.sh
    chmod u+x /opt/miniconda_installer.sh
    /opt/miniconda_installer.sh -b -u -p /opt/miniconda-ref
    echo "export CONDA_ACCEPT_LICENSES=true" >> "$HOME/conda_bashrc"
    echo "eval \"\$(/opt/miniconda-ref/bin/conda shell.bash hook)\"" >> "$HOME/conda_bashrc"
    source "$HOME/conda_bashrc"
    conda init --all
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
    source "$HOME/conda_bashrc"
    conda create -n geoips -c conda-forge python=3.11 conda-pack -y
    conda activate geoips
    # python -m pip install --upgrade pip
    python -m pip install --force-reinstall --no-deps setuptools
    python -m pip install geoips geoips_clavrx ipykernel 

    # This creates a copy of the current conda environment for distribution to
    # other locations (i.e. user home directories). When unpacked, it acts as a
    # virtual environment with no conda installation. All packages already
    # installed are included as well as pip.
    #
    # --ignore-missing-files is used here because something is causing problems
    # with setuptools. However, we don't ever use setuptools beyond this point,
    # so I'm just going to ignore it.
    rm -f /opt/geoips-env.tgz
    conda-pack -n geoips -o /opt/geoips-env.tgz --ignore-missing-files

    # Install data from s3 bucket
    aws s3 cp s3://geoips-tutorial/geoips_outdirs /opt/geoips_outdirs --recursive
    aws s3 cp s3://geoips-tutorial/geoips_testdata_dir /opt/geoips_testdata_dir --recursive
)

# This function copies the conda environment to each user's home directory
# and sets up their .bashrc to activate the environment.
# It also installs the geoips kernel for Jupyter.
setup_user_env() {
    local user="$1"
    local user_home="/home/${user}"
    target="${user_home}/miniconda3"
    SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

    echo "Setting up conda environment for ${user}"

    # Create target directory and copy env
    mkdir -p "${target}"
    cp /opt/geoips-env.tgz "${target}/"
    cp $SCRIPT_DIR/install_geoips_env.sh "${user_home}/install_geoips_env.sh"

    chown -R "${user}:${user}" "${target}"
    chown "${user}:${user}" "${user_home}/install_geoips_env.sh"
    chmod 700 "${user_home}/install_geoips_env.sh"

    # Modify user's .bashrc

    # Add environment activation to bashrc and install kernel
    su - "${user}" -c "bash ${user_home}/install_geoips_env.sh"

    # Copy data to user's home directory
    cp -r /opt/geoips_outdirs/ "${user_home}/geoips_outdirs"
    cp -r /opt/geoips_testdata_dir/ "${user_home}/geoips_test_data"
    chown -R "${user}:${user}" "${user_home}/geoips_outdirs"
    chown -R "${user}:${user}" "${user_home}/geoips_test_data"
}

# Export to make available in subshells
export -f setup_user_env

# --- Copy conda environment to each user's home directory ---
# Also add conda initialization and geoips environment activation to each user's .bashrc
printf "%s\n" "${usernames[@]}" | xargs -P"$NUM_USERS" -I{} bash -c 'setup_user_env "$@"' _ {}
