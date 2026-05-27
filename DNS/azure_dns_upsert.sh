#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./azure_dns_upsert.sh -g rg-providataaikt-prod-westeu -z providata-aikt.net -h aikt.providata-aikt.net -t "TOKEN_FROM_CERTBOT" [-T 60]
#
# What it does:
# - Ensures the TXT record-set exists
# - Adds the TXT value (does NOT delete existing values)
#
# Record-set name rules:
# - Always starts with _acme-challenge
# - If hostname is subdomain (aikt.providata-aikt.net), record-set is _acme-challenge.aikt
# - If hostname is apex (providata-aikt.net), record-set is _acme-challenge

RG=""
ZONE=""
HOSTNAME=""
TOKEN=""
TTL="60"

while getopts ":g:z:h:t:T:" opt; do
  case "$opt" in
    g) RG="$OPTARG" ;;
    z) ZONE="$OPTARG" ;;
    h) HOSTNAME="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    T) TTL="$OPTARG" ;;
    *) echo "Usage: $0 -g <resource-group> -z <zone> -h <hostname> -t <token> [-T <ttl>]" >&2; exit 2 ;;
  esac
done

for v in RG ZONE HOSTNAME TOKEN; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: missing -${v:0:1} (${v}). Usage: $0 -g <rg> -z <zone> -h <hostname> -t <token> [-T <ttl>]" >&2
    exit 2
  fi
done

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

# Ensure logged in (won't error if already logged in)
az account show >/dev/null 2>&1 || az login >/dev/null

# Basic sanity: HOSTNAME should end with ZONE
if [[ "${HOSTNAME}" != "${ZONE}" && "${HOSTNAME}" != *".${ZONE}" ]]; then
  echo "ERROR: hostname '${HOSTNAME}' does not appear to be within zone '${ZONE}'" >&2
  exit 1
fi

# Compute label part (hostname relative to zone)
REL="${HOSTNAME}"
REL="${REL%.}" # trim trailing dot if provided
ZONE_TRIM="${ZONE%.}"

if [[ "${REL}" == "${ZONE_TRIM}" ]]; then
  LABEL=""  # apex
else
  LABEL="${REL%."${ZONE_TRIM}"}"   # e.g. aikt (or a.b)
  LABEL="${LABEL%.}"              # just in case
fi

if [[ -z "${LABEL}" ]]; then
  RECORDSET="_acme-challenge"
else
  RECORDSET="_acme-challenge.${LABEL}"
fi

FQDN="${RECORDSET}.${ZONE_TRIM}"

echo "=== Azure DNS TXT upsert ==="
echo "Resource group : ${RG}"
echo "Zone           : ${ZONE_TRIM}"
echo "Hostname       : ${HOSTNAME}"
echo "Record-set     : ${RECORDSET}"
echo "FQDN           : ${FQDN}"
echo "TTL            : ${TTL}"
echo

# Create record-set if it doesn't exist
if az network dns record-set txt show --resource-group "${RG}" --zone-name "${ZONE_TRIM}" --name "${RECORDSET}" >/dev/null 2>&1; then
  echo "Record-set exists."
else
  echo "Creating record-set..."
  az network dns record-set txt create \
    --resource-group "${RG}" \
    --zone-name "${ZONE_TRIM}" \
    --name "${RECORDSET}" \
    --ttl "${TTL}" >/dev/null
fi

echo "Adding TXT value (token)..."
# Some az versions use --record-set-name, others use --name.
if az network dns record-set txt add-record --help 2>/dev/null | grep -q -- "--record-set-name"; then
  az network dns record-set txt add-record \
    --resource-group "${RG}" \
    --zone-name "${ZONE_TRIM}" \
    --record-set-name "${RECORDSET}" \
    --value "${TOKEN}" >/dev/null
else
  az network dns record-set txt add-record \
    --resource-group "${RG}" \
    --zone-name "${ZONE_TRIM}" \
    --name "${RECORDSET}" \
    --value "${TOKEN}" >/dev/null
fi

echo "Current TXT values for ${FQDN}:"
az network dns record-set txt show \
  --resource-group "${RG}" \
  --zone-name "${ZONE_TRIM}" \
  --name "${RECORDSET}" \
  --query "txtRecords[].value[]" -o tsv

echo
echo "Verify from your machine with:"
echo "  dig TXT ${FQDN}"