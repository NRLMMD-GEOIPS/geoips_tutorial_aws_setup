#!/usr/bin/env bash
set -e

# This file is used as a custom command when JupyterHub spawns a JupyterLab
# instance. It sets up the environment prior to starting JupyterLab. This allows
# %%bash blocks to run in the JupyterLab environment with the correct conda
# environment activated.
#
# In the context of the GeoIPS tutorials, this script should be installed in
# /opt/start-jupyterlab.sh and the JupyterHub configuration should set
# c.Spawner.cmd = [f"/opt/start-jupyterlab.sh"].


source "$HOME/.bashrc"
exec /opt/jupyterhub/bin/jupyterhub-singleuser "$@"
