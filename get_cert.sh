#!/bin/bash
set -e

# Fetch the secret value from Secrets Manager
RAW_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id GEOIPS_TUTORIAL_TLS \
  --query SecretString \
  --output text)

# Extract the inner JSON string
INNER_JSON=$(echo "$RAW_SECRET" | jq -r '.GEOIPS_TUTORIAL_TLS')

# Extract cert and key
CERT=$(echo "$INNER_JSON" | jq -r '.cert')
KEY=$(echo "$INNER_JSON" | jq -r '.key')

mkdir -p /etc/ssl/certs
mkdir -p /etc/ssl/private

# Write to disk
echo "$CERT" > /etc/ssl/certs/jupyterhub.crt
echo "$KEY" > /etc/ssl/private/jupyterhub.key

# Secure permissions
chmod 600 /etc/ssl/private/jupyterhub.key
chown root:root /etc/ssl/private/jupyterhub.key
