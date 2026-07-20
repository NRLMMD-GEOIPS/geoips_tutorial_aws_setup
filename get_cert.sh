#!/bin/bash
set -Eeuo pipefail

SECRET_ID="${GEOIPS_TLS_SECRET_ID:-GEOIPS_TUTORIAL_TLS}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CERT_PATH=/etc/ssl/certs/jupyterhub.crt
KEY_PATH=/etc/ssl/private/jupyterhub.key

CERT_TMP="$(mktemp)"
KEY_TMP="$(mktemp)"
cleanup() {
  rm -f "$CERT_TMP" "$KEY_TMP"
}
trap cleanup EXIT

# Fetch the secret value from Secrets Manager
RAW_SECRET=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$SECRET_ID" \
  --query SecretString \
  --output text)

# Extract cert and key
CERT=$(jq -er '.cert | select(type == "string" and length > 0)' <<<"$RAW_SECRET")
KEY=$(jq -er '.key | select(type == "string" and length > 0)' <<<"$RAW_SECRET")

mkdir -p /etc/ssl/certs
mkdir -p /etc/ssl/private

# Write and validate temporary files before replacing the active certificate.
printf '%s\n' "$CERT" > "$CERT_TMP"
printf '%s\n' "$KEY" > "$KEY_TMP"

openssl x509 -in "$CERT_TMP" -noout >/dev/null
openssl pkey -in "$KEY_TMP" -noout -check >/dev/null

CERT_PUBLIC_KEY_HASH="$(openssl x509 -in "$CERT_TMP" -pubkey -noout \
  | openssl pkey -pubin -outform DER 2>/dev/null \
  | sha256sum | awk '{print $1}')"
KEY_PUBLIC_KEY_HASH="$(openssl pkey -in "$KEY_TMP" -pubout -outform DER 2>/dev/null \
  | sha256sum | awk '{print $1}')"

if [[ "$CERT_PUBLIC_KEY_HASH" != "$KEY_PUBLIC_KEY_HASH" ]]; then
  echo "Certificate and private key do not match" >&2
  exit 1
fi

install -m 644 -o root -g root "$CERT_TMP" "$CERT_PATH"
install -m 600 -o root -g root "$KEY_TMP" "$KEY_PATH"

# Secure permissions
echo "TLS certificate and private key installed and validated"
