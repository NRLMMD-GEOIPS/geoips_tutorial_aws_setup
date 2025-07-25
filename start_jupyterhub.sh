#!/bin/env bash
set -e

# --- Settings ---
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
HOME=/root
NUM_USERS=4
TUTORIAL_REPO_URL=https://github.com/NRLMMD-GEOIPS/geoips_tutorials.git

# --- Create usernames ---
usernames=()
for unum in $(seq -w 1 "${NUM_USERS}"); do
    usernames+=("user${unum}")
done

# --- Build quoted user list ---
quoted_users=$(printf "'%s', " "${usernames[@]}")
quoted_users="set([${quoted_users%, }])"

mkdir -p /srv/jupyterhub
chown -R root:root /srv/jupyterhub
chmod 755 /srv/jupyterhub

cat > /srv/jupyterhub/jupyterhub_config.py <<EOF
import os
import pwd
import subprocess

cert_file = '/etc/ssl/certs/jupyterhub.crt'
key_file = '/etc/ssl/private/jupyterhub.key'

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
        for root, dirs, files in os.walk(clone_dir):
            os.chown(root, uid, gid)
            for d in dirs:
                os.chown(os.path.join(root, d), uid, gid)
            for f in files:
                os.chown(os.path.join(root, f), uid, gid)
    spawner.notebook_dir = clone_dir

c.Spawner.cmd = [f"/opt/start_jupyterlab.sh"]
c.Spawner.pre_spawn_hook = pre_spawn_hook
c.Spawner.default_url = '/lab'
c.Authenticator.allowed_users = $quoted_users
c.JupyterHub.bind_url = 'http://127.0.0.1:8000'
c.JupyterHub.hub_bind_url = 'http://127.0.0.1:8081'
c.JupyterHub.hub_connect_url = 'http://127.0.0.1:8081'

# Trust the proxy (Nginx)
c.JupyterHub.trusted_downstream_ips = ['127.0.0.1']

# c.JupyterHub.bind_url = "http://0.0.0.0:8000"
# 
# if os.path.exists(cert_file) and os.path.exists(key_file):
#     c.JupyterHub.ssl_cert = cert_file
#     c.JupyterHub.ssl_key = key_file
#     c.JupyterHub.bind_url = 'http://127.0.0.1:8000'
#     c.JupyterHub.hub_bind_url = 'http://127.0.0.1:8081'
#     c.JupyterHub.hub_connect_url = 'http://127.0.0.1:8081'
# 
#     # Trust the proxy (Nginx)
#     c.JupyterHub.trusted_downstream_ips = ['127.0.0.1']
# else:
#     print("Warning: SSL certificate or key not found. JupyterHub will run without SSL.")
EOF
chmod 644 /srv/jupyterhub/jupyterhub_config.py

# --- Detect container environment ---
in_container=false
if grep -qE '/docker/|/lxc/' /proc/1/cgroup || [ -f /.dockerenv ]; then
    in_container=true
fi

JHUB_EXEC=$(command -v jupyterhub)
JHUB_CONFIG=/srv/jupyterhub/jupyterhub_config.py

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
    cat > /etc/systemd/system/jupyterhub.service <<EOF
[Unit]
Description=JupyterHub
After=network.target

[Service]
User=root
ExecStart=${JHUB_EXEC} --config ${JHUB_CONFIG}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    echo "🔄 Reloading systemd and enabling JupyterHub service"
    systemctl daemon-reexec
    systemctl enable jupyterhub
    systemctl start jupyterhub
    systemctl status jupyterhub --no-pager -l
fi