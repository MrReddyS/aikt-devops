#!/usr/bin/env bash
set -euo pipefail

# Creates storage account + Azure Files share for Open WebUI DATA_DIR persistence.
#
# Usage:
#   ./create_storage.sh [--profile <name>] [--resource-group <rg>] [--location <region>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_storage.sh"

PROFILE=""
RG_NAME=""
LOCATION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --resource-group|-g) RG_NAME="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--profile <config-profile>] [--resource-group <rg>] [--location <azure-region>]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(find_repo_root_from "${SCRIPT_DIR}")"
local_rg_def="" local_loc_def=""
IFS=$'\t' read -r local_rg_def local_loc_def < <(read_rg_defaults_from_config "${REPO_ROOT}")

PROFILE="$(resolve_profile_name "${REPO_ROOT}" "${PROFILE}")"
TENANT_ID="" SUBSCRIPTION_ID="" DEFAULT_LOCATION=""
read_subscription_profile "${REPO_ROOT}" "${PROFILE}"

if [[ -z "${RG_NAME}" ]]; then RG_NAME="${local_rg_def}"; fi
if [[ -z "${LOCATION}" ]]; then LOCATION="${local_loc_def:-${DEFAULT_LOCATION}}"; fi
RG_NAME="$(strip_cr "${RG_NAME}")"
LOCATION="$(strip_cr "${LOCATION}")"

CLIENT="$(read_project_client "${REPO_ROOT}")"
ST_LOCAL="" REP="" KIND="" _VOL="" FILESHARE="" _MOUNT=""
IFS=$'\t' read -r ST_LOCAL REP KIND _VOL FILESHARE _MOUNT < <(read_storage_row "${REPO_ROOT}")
ST_NAME="$(resolve_storage_account_name "${REPO_ROOT}" "${CLIENT}" "${LOCATION}")"

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create storage (Azure Files) ==="
echo "Resource group : ${RG_NAME}"
echo "Storage account: ${ST_NAME}"
echo "File share     : ${FILESHARE}"
echo

ensure_az_account "${TENANT_ID}" "${SUBSCRIPTION_ID}"
require_resource_group "${RG_NAME}"

if run_az storage account show -g "${RG_NAME}" -n "${ST_NAME}" >/dev/null 2>&1; then
  echo "Storage account ${ST_NAME} already exists (skip create)."
else
  echo "Creating storage account ${ST_NAME}..."
  run_az storage account create \
    --resource-group "${RG_NAME}" \
    --name "${ST_NAME}" \
    --location "${LOCATION}" \
    --sku "Standard_${REP}" \
    --kind "${KIND}" \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 >/dev/null
fi

if run_az storage share show --account-name "${ST_NAME}" --name "${FILESHARE}" >/dev/null 2>&1; then
  echo "File share ${FILESHARE} already exists (skip create)."
else
  echo "Creating file share ${FILESHARE}..."
  run_az storage share create \
    --account-name "${ST_NAME}" \
    --name "${FILESHARE}" \
    --quota 100 >/dev/null
fi

echo "Done."
