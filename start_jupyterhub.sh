#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: start_jupyterhub.sh failed at line ${LINENO}" >&2' ERR

# Validate arguments
NUM_USERS_INPUT="${1:-}"
if [[ $# -lt 1 || $# -gt 2 || ! "$NUM_USERS_INPUT" =~ ^[0-9]+$ || "$NUM_USERS_INPUT" -lt 1 || ( $# -eq 2 && "${2:-}" != "--nginx" ) ]]; then
  echo "Usage: $0 <num_users (positive integer)> [--nginx]"
  exit 1
fi

# Store number of users
NUM_USERS="$NUM_USERS_INPUT"

# If --nginx is passed as an argument, we will assume nginx exists and is configured.
# If not, we will skip nginx setup and bind JupyterHub to all interfaces.  Using --nginx
# is useful when running in a production environment with Nginx as a reverse proxy.  If
# not using Nginx, JupyterHub will bind to 0.0.0.0:8000.
# Set NGINX flag
if [[ "${2:-}" == "--nginx" ]]; then
  NGINX=true
else
  NGINX=false
fi

# --- Settings ---
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
TUTORIAL_REPO_URL=https://github.com/NRLMMD-GEOIPS/geoips_tutorials.git

# --- Create usernames ---
usernames=()
for unum in $(seq 1 "${NUM_USERS}"); do
    usernames+=("user$(printf "%02d" "$unum")")
done

# --- Build quoted user list ---
quoted_users=$(printf "'%s', " "${usernames[@]}")
quoted_users="set([${quoted_users%, }])"

mkdir -p /srv/jupyterhub
chown -R root:root /srv/jupyterhub
chmod 755 /srv/jupyterhub

mkdir -p /tmp/geoips_tutorial_tempdirs
chmod 1777 /tmp/geoips_tutorial_tempdirs

cat > /srv/jupyterhub/jupyterhub_config.py <<EOF
import os
import pwd
import grp
import subprocess

cert_file = '/etc/ssl/certs/jupyterhub.crt'
key_file = '/etc/ssl/private/jupyterhub.key'


def recursive_chown(path: str, user: str, group: str):
    """
    Recursively change ownership of a file or directory.

    Args:
        path (str): Path to the file or directory.
        user (str): Username to assign ownership to.
        group (str): Group name to assign ownership to.
    """
    # Resolve UID and GID from names
    uid = pwd.getpwnam(user).pw_uid
    gid = grp.getgrnam(group).gr_gid

    # Walk through directory tree (or handle file)
    if os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            # Change directory itself
            os.chown(root, uid, gid)
            # Change all directories
            for d in dirs:
                os.chown(os.path.join(root, d), uid, gid)
            # Change all files
            for f in files:
                os.chown(os.path.join(root, f), uid, gid)
    else:
        # If it's a single file
        os.chown(path, uid, gid)


def pre_spawn_hook(spawner):
    username = spawner.user.name
    home_dir = os.path.expanduser(f"~{username}")
    user_info = pwd.getpwnam(username)
    uid = user_info.pw_uid
    gid = user_info.pw_gid
    repo_url = "${TUTORIAL_REPO_URL}"
    clone_dir = os.path.join(home_dir, "geoips_tutorials")

    if not os.path.exists(clone_dir):
        subprocess.run(["git", "clone", repo_url, clone_dir], cwd=home_dir, check=True)
        subprocess.run(["git", "checkout", "tutorial-devel"], cwd=clone_dir, check=True)
        for root, dirs, files in os.walk(clone_dir):
            os.chown(root, uid, gid)
            for d in dirs:
                os.chown(os.path.join(root, d), uid, gid)
            for f in files:
                os.chown(os.path.join(root, f), uid, gid)
    spawner.notebook_dir = home_dir

    # Set up GeoIPS environment variables
    spawner.environment["GEOIPS_REPO_URL"] = "https://github.com/nrlmmd-geoips"
    spawner.environment["GEOIPS_REBUILD_REGISTRIES"] = "true"
    spawner.environment["GEOIPS_OUTDIRS"] = os.path.join(home_dir, "geoips_outdirs")
    spawner.environment["GEOIPS_TESTDATA_DIR"] = os.path.join(home_dir, "geoips_test_data")
    spawner.environment["GEOIPS_PACKAGES_DIR"] = home_dir
    spawner.environment["MY_PKG_NAME"] = "cool_plugins"
    spawner.environment["MY_PKG_DIR"] = os.path.join(home_dir, "cool_plugins")
    spawner.environment["CARTOPY_DATA_DIR"] = os.path.join(home_dir, "cartopy")

    # Ensure output and test data directories exist
    os.makedirs(spawner.environment["GEOIPS_OUTDIRS"], exist_ok=True)
    os.makedirs(spawner.environment["GEOIPS_TESTDATA_DIR"], exist_ok=True)

    recursive_chown(spawner.environment["GEOIPS_OUTDIRS"], username, username)
    recursive_chown(spawner.environment["GEOIPS_TESTDATA_DIR"], username, username)

c.Spawner.cmd = [f"/opt/start_jupyterlab.sh"]
c.Spawner.pre_spawn_hook = pre_spawn_hook
c.Spawner.default_url = '/lab'
c.Authenticator.allowed_users = $quoted_users

# Allow additional output
c.Spawner.args = [
    "--ServerApp.iopub_msg_rate_limit=10000",
    "--ServerApp.rate_limit_window=3.0"
]

EOF

# If NGINX is not enabled, bind JupyterHub to all interfaces
# This is for use in a Docker container or local host where NGINX is not used.
if [[ "${NGINX,,}" != "true" ]]; then
cat >> /srv/jupyterhub/jupyterhub_config.py <<EOF
c.JupyterHub.bind_url = "http://0.0.0.0:8000"
c.JupyterHub.hub_bind_url = 'http://0.0.0.0:8081'
c.JupyterHub.hub_connect_url = 'http://0.0.0.0:8081'
EOF
# If NGINX is enabled, set the bind URL to localhost
# This is for use in a production environment like an EC2 instance where NGINX
# is used as a reverse proxy.
else
cat >> /srv/jupyterhub/jupyterhub_config.py <<EOF
c.JupyterHub.bind_url = 'http://127.0.0.1:8000'
c.JupyterHub.hub_bind_url = 'http://127.0.0.1:8081'
c.JupyterHub.hub_connect_url = 'http://127.0.0.1:8081'

# Trust the proxy (Nginx)
c.JupyterHub.trusted_downstream_ips = ['127.0.0.1']
EOF
fi

chmod 644 /srv/jupyterhub/jupyterhub_config.py
/opt/jupyterhub/bin/python -m py_compile /srv/jupyterhub/jupyterhub_config.py

# --- Detect container environment ---
in_container=false
if grep -qE '/docker/|/lxc/' /proc/1/cgroup || [ -f /.dockerenv ]; then
    in_container=true
fi

JHUB_EXEC=/opt/jupyterhub/bin/jupyterhub
JHUB_CONFIG=/srv/jupyterhub/jupyterhub_config.py

if [[ ! -x "$JHUB_EXEC" ]]; then
    echo "JupyterHub executable not found at $JHUB_EXEC" >&2
    exit 1
fi

if $in_container; then
    echo "🪣 Detected Docker container"
    echo "🚀 Starting JupyterHub in foreground"
    exec "$JHUB_EXEC" --config "$JHUB_CONFIG"
else
    echo "🖥️ Detected EC2 or systemd host"

    # Ensure systemd is present
    if ! command -v systemctl &> /dev/null; then
        echo "❌ systemctl not found; falling back to nohup"
        nohup "$JHUB_EXEC" --config "$JHUB_CONFIG" > /var/log/jupyterhub.log 2>&1 &
        exit 0
    fi

    echo "📝 Creating systemd service for JupyterHub"
    rm -f /var/lib/geoips-workshop-ready
    cat > /etc/systemd/system/jupyterhub.service <<EOF
[Unit]
Description=JupyterHub
Wants=network-online.target
After=network-online.target

[Service]
User=root
WorkingDirectory=/srv/jupyterhub
ExecStart=${JHUB_EXEC} --config ${JHUB_CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    echo "🔄 Reloading systemd and enabling JupyterHub service"
    systemctl daemon-reload
    systemctl enable jupyterhub
    systemctl restart jupyterhub
    systemctl status jupyterhub --no-pager -l

    echo "Waiting for JupyterHub health endpoint"
    curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-connrefused \
        http://127.0.0.1:8000/hub/health >/dev/null
    touch /var/lib/geoips-workshop-ready
    echo "JupyterHub is ready"
fi
