#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./txt_challenge.sh -h aikt.providata-aikt.net [-e you@domain.com]
#
# Notes:
# - This runs certbot in manual DNS mode.
# - Certbot will PRINT the TXT record name + value you must create in Azure DNS.
# - Do not close the terminal until validation completes.

EMAIL=""
HOSTNAME=""

while getopts ":h:e:" opt; do
  case "$opt" in
    h) HOSTNAME="$OPTARG" ;;
    e) EMAIL="$OPTARG" ;;
    *) echo "Usage: sudo $0 -h <hostname> [-e <email>]" >&2; exit 2 ;;
  esac
done

if [[ -z "${HOSTNAME}" ]]; then
  echo "ERROR: hostname is required. Usage: sudo $0 -h <hostname> [-e <email>]" >&2
  exit 2
fi

# Ensure certbot exists
command -v certbot >/dev/null 2>&1 || { echo "ERROR: certbot not found. Install: sudo apt install certbot" >&2; exit 1; }

echo "=== Starting Let's Encrypt manual DNS challenge for: ${HOSTNAME} ==="
echo "Certbot will now show you the TXT record name + value to add in DNS."
echo "Keep this terminal open. You'll add the TXT record using Script B, then come back and press ENTER."

if [[ -n "${EMAIL}" ]]; then
  sudo certbot certonly \
    --manual \
    --preferred-challenges dns \
    --email "${EMAIL}" \
    --agree-tos \
    --no-eff-email \
    -d "${HOSTNAME}"
else
  sudo certbot certonly \
    --manual \
    --preferred-challenges dns \
    -d "${HOSTNAME}"
fi

echo "=== Done. Certificate files are under: /etc/letsencrypt/live/${HOSTNAME}/ ==="
echo "Next step (optional): export PFX for Azure Application Gateway:"
echo "  sudo openssl pkcs12 -export -out /tmp/${HOSTNAME}.pfx \\"
echo "    -inkey /etc/letsencrypt/live/${HOSTNAME}/privkey.pem \\"
echo "    -in /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"