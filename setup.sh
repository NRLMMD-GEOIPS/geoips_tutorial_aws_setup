#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: setup.sh failed at line ${LINENO}" >&2' ERR

# Validate input
NUM_USERS_INPUT="${1:-}"
if [[ $# -ne 1 || ! "$NUM_USERS_INPUT" =~ ^[0-9]+$ || "$NUM_USERS_INPUT" -lt 1 ]]; then
  echo "Usage: $0 <num_users (positive integer)>"
  exit 1
fi

NUM_USERS="$NUM_USERS_INPUT"
MAX_PARALLEL_USER_SETUPS="${MAX_PARALLEL_USER_SETUPS:-8}"
if [[ ! "$MAX_PARALLEL_USER_SETUPS" =~ ^[0-9]+$ || "$MAX_PARALLEL_USER_SETUPS" -lt 1 ]]; then
    echo "MAX_PARALLEL_USER_SETUPS must be a positive integer" >&2
    exit 1
fi

# --- Settings ---
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
ROOT_HOME=/root
TUTORIAL_REPO_URL=https://github.com/NRLMMD-GEOIPS/geoips_tutorials.git

# --- Disable SELinux ---
# Doing this until I have time to figure out how to set it up properly.
if command -v getenforce >/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    setenforce 0
fi

# --- Install system-level software ---
dnf install -y ca-certificates curl git jq openssl python3 python3-pip shadow-utils wget rsync nginx unzip tree

# Rocky 10 provides a sufficiently new system Python. Rocky 9 needs its
# parallel-installable Python 3.11 packages for the current Jupyter stack.
HUB_PYTHON=python3
if ! "$HUB_PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
    dnf install -y python3.11 python3.11-pip
    HUB_PYTHON=python3.11
fi
# Remove any existing AppStream or conflicting versions
dnf remove -y nodejs npm nsolid
dnf module reset -y nodejs || true
# Set up NodeSource Node.js 24 LTS repo
NODESOURCE_SETUP="$(mktemp /tmp/nodesource-setup.XXXXXX.sh)"
curl -fsSL https://rpm.nodesource.com/setup_24.x -o "$NODESOURCE_SETUP"
bash "$NODESOURCE_SETUP"
rm -f "$NODESOURCE_SETUP"
# Install Node.js 24 (npm is bundled)
dnf install -y nodejs
node --version
npm --version

# --- Detect environment (EC2 or Docker) ---
# If EC2, we will fetch the SSL certificate and key from AWS Secrets Manager.
# If Docker, we will skip this step since it is not needed.
IMDS_TOKEN="$(curl -fsS --connect-timeout 2 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token || true)"

if [[ -n "$IMDS_TOKEN" ]] && curl -fsS --connect-timeout 2 \
    -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id >/dev/null; then
    echo "🖥️ Detected EC2 or systemd host"
    echo "    Doing full setup including RAID, SSL, and Nginx"
    if ! command -v aws &> /dev/null; then
        echo "Installing AWS CLI"
        AWS_CLI_TMP="$(mktemp -d /tmp/awscliv2.XXXXXX)"
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
            -o "$AWS_CLI_TMP/awscliv2.zip"
        unzip -q "$AWS_CLI_TMP/awscliv2.zip" -d "$AWS_CLI_TMP"
        "$AWS_CLI_TMP/aws/install"
        rm -rf "$AWS_CLI_TMP"
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
    install -m 644 "$SCRIPT_DIR/jupyterhub.conf" /etc/nginx/conf.d/jupyterhub.conf
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
else
    echo "🛠️ Detected Docker container or Local host"
    echo "Doing less invasive setup"
    echo "    No RAID setup"
    echo "    No SSL certificate/key setup"
    echo "    No Nginx setup"
fi


# --- Install a reproducible JupyterHub and notebook server stack ---
JUPYTERHUB_VENV=/opt/jupyterhub
"$HUB_PYTHON" -m venv "$JUPYTERHUB_VENV"
"$JUPYTERHUB_VENV/bin/python" -m pip install --upgrade pip
"$JUPYTERHUB_VENV/bin/python" -m pip install \
    jupyterhub==5.5.0 \
    jupyterlab==4.6.1 \
    jupyterlab_widgets==3.0.16 \
    notebook==7.6.0
npm install -g configurable-http-proxy@5.3.0

# --- Create users ---
usernames=()
for unum in $(seq 1 "${NUM_USERS}"); do
    user=$(printf "user%02d" "$unum")
    pass=$(printf "geoips_pass%02d" "$unum")
    if ! id "${user}" >/dev/null 2>&1; then
        useradd -m "${user}"
    fi
    echo "${user}:${pass}" | chpasswd
    usernames+=("${user}")
done

# --- Copy JupyterLab start script ---
install -m 755 "$SCRIPT_DIR/start_jupyterlab.sh" /opt/start_jupyterlab.sh

# --- Download and install miniconda in /opt/miniconda-ref ---
# This section runs in a subshell to avoid polluting the root environment
# with conda variables and paths. When done, the environment will revert
# to its original state.
#
# Later, the resulting conda installation will be copied to each user's home directory.
(
    MINICONDA_INSTALLER=Miniconda3-py311_26.5.3-1-Linux-x86_64.sh
    MINICONDA_SHA256=f1d308a450763ce617f4e4f1609521358f663b2d1c097cfcc11a1c1f09baf680
    wget "https://repo.anaconda.com/miniconda/$MINICONDA_INSTALLER" -O /opt/miniconda_installer.sh
    echo "$MINICONDA_SHA256  /opt/miniconda_installer.sh" | sha256sum --check
    chmod u+x /opt/miniconda_installer.sh
    /opt/miniconda_installer.sh -b -u -p /opt/miniconda-ref
    : > "$ROOT_HOME/conda_bashrc"
    echo "export CONDA_ACCEPT_LICENSES=true" >> "$ROOT_HOME/conda_bashrc"
    echo "eval \"\$(/opt/miniconda-ref/bin/conda shell.bash hook)\"" >> "$ROOT_HOME/conda_bashrc"
    source "$ROOT_HOME/conda_bashrc"
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
    conda create -n geoips -c conda-forge python=3.11 conda-pack -y
    conda activate geoips
    # python -m pip install --upgrade pip
    python -m pip install --force-reinstall --no-deps setuptools
    python -m pip install \
        "geoips @ git+https://github.com/NRLMMD-GEOIPS/geoips.git@main" \
        geoips_clavrx==1.18.1 \
        ipykernel==7.3.0 \
        ipywidgets==8.1.8

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
    mkdir -p /tmp/geoips_outdirs /tmp/geoips_testdata_dir /tmp/cartopy
    aws s3 sync s3://geoips-tutorial/geoips_outdirs/ /tmp/geoips_outdirs/ --delete
    aws s3 sync s3://geoips-tutorial/geoips_testdata_dir/ /tmp/geoips_testdata_dir/ --delete
    aws s3 sync s3://geoips-tutorial/cartopy/ /tmp/cartopy/ --delete
)

# This function copies the conda environment to each user's home directory
# and sets up their .bashrc to activate the environment.
# It also installs the geoips kernel for Jupyter.
setup_user_env() {
    local user="$1"
    local user_home="/home/${user}"
    local target="${user_home}/miniconda3"
    local custom_css_dir="${user_home}/.jupyter/custom"
    echo "Setting up conda environment for ${user}"

    # Create target directory and copy env
    mkdir -p "${target}"
    install -m 644 /opt/geoips-env.tgz "${target}/geoips-env.tgz"
    install -m 700 "$SCRIPT_DIR/install_geoips_env.sh" "${user_home}/install_geoips_env.sh"
    install -d -m 755 -o "${user}" -g "${user}" "${custom_css_dir}"
    install -m 644 -o "${user}" -g "${user}" "$SCRIPT_DIR/jupyter_custom.css" "${custom_css_dir}/custom.css"

    chown -R "${user}:${user}" "${target}"
    chown "${user}:${user}" "${user_home}/install_geoips_env.sh"

    # Modify user's .bashrc

    # Add environment activation to bashrc and install kernel
    su - "${user}" -c "bash ${user_home}/install_geoips_env.sh"

    # Configure git user
    su - "${user}" -c "git config --global user.name 'GeoIPS User ${user}'"
    su - "${user}" -c "git config --global user.email 'geoips_${user}@geoips-tutorial.org'"

    # Copy data to user's home directory
    mkdir -p "${user_home}/geoips_outdirs" "${user_home}/geoips_test_data" "${user_home}/cartopy"
    rsync -a --delete /tmp/geoips_outdirs/ "${user_home}/geoips_outdirs/"
    rsync -a --delete /tmp/geoips_testdata_dir/ "${user_home}/geoips_test_data/"
    rsync -a --delete /tmp/cartopy/ "${user_home}/cartopy/"
    chown -R "${user}:${user}" "${user_home}/geoips_outdirs"
    chown -R "${user}:${user}" "${user_home}/geoips_test_data"
    chown -R "${user}:${user}" "${user_home}/cartopy"
}

# Export to make available in subshells
export SCRIPT_DIR
export -f setup_user_env

# --- Copy conda environment to each user's home directory ---
# Also add conda initialization and geoips environment activation to each user's .bashrc
printf "%s\n" "${usernames[@]}" | xargs -r -P"$MAX_PARALLEL_USER_SETUPS" -I{} \
    bash -Eeuo pipefail -c 'setup_user_env "$@"' _ {}
