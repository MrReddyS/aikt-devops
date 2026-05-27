#!/usr/bin/env bash
set -euo pipefail

# Creates a storage account and Azure Files share in an existing resource group.
# Local names in resources.storage-account are expanded for the account name only
# (alphanumeric, e.g. staccount + test + westeu -> staccounttestwesteu).
#
# Usage:
#   ./create_storage.sh [--profile <name>] [--resource-group <rg>] [--location <region>]
#
# Requires: Azure CLI; resource group must already exist (see Resource_Group/create_rg.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_storage.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../Network/_lib_network.sh"

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
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--profile <config-profile>] [--resource-group <rg>] [--location <azure-region>]" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(find_repo_root_from "${SCRIPT_DIR}")"

local_rg_def=""
local_loc_def=""
IFS=$'\t' read -r local_rg_def local_loc_def < <(read_rg_defaults_from_config "${REPO_ROOT}")
local_rg_def="${local_rg_def//$'\r'/}"
local_loc_def="${local_loc_def//$'\r'/}"

PROFILE="$(resolve_profile_name "${REPO_ROOT}" "${PROFILE}")"
TENANT_ID=""
SUBSCRIPTION_ID=""
DEFAULT_LOCATION=""
read_subscription_profile "${REPO_ROOT}" "${PROFILE}"

if [[ -z "${RG_NAME}" ]]; then
  RG_NAME="${local_rg_def}"
fi
if [[ -z "${RG_NAME}" || "${RG_NAME}" == "null" ]]; then
  echo "ERROR: no resource group: pass --resource-group or set project.rg in config.yaml" >&2
  exit 2
fi

if [[ -z "${LOCATION}" ]]; then
  if [[ -n "${local_loc_def}" && "${local_loc_def}" != "null" ]]; then
    LOCATION="${local_loc_def}"
  else
    LOCATION="${DEFAULT_LOCATION}"
  fi
fi
if [[ -z "${LOCATION}" || "${LOCATION}" == "null" ]]; then
  echo "ERROR: no location: pass --location or set project.location in config.yaml" >&2
  exit 2
fi

CLIENT="$(read_project_client "${REPO_ROOT}")"
CLIENT="${CLIENT//$'\r'/}"
if [[ -z "${CLIENT}" || "${CLIENT}" == "null" ]]; then
  echo "ERROR: project.client must be set in config.yaml (used for resource naming)." >&2
  exit 2
fi

SA_LOCAL=""
REPLICATION=""
KIND=""
VOLUME_NAME=""
FILESHARE=""
MOUNT_PATH=""
MOUNT_OPTIONS=""
IFS=$'\t' read -r SA_LOCAL REPLICATION KIND VOLUME_NAME FILESHARE MOUNT_PATH MOUNT_OPTIONS < <(read_storage_row "${REPO_ROOT}")
SA_LOCAL="${SA_LOCAL//$'\r'/}"
REPLICATION="${REPLICATION//$'\r'/}"
KIND="${KIND//$'\r'/}"
VOLUME_NAME="${VOLUME_NAME//$'\r'/}"
FILESHARE="${FILESHARE//$'\r'/}"
MOUNT_PATH="${MOUNT_PATH//$'\r'/}"
MOUNT_OPTIONS="${MOUNT_OPTIONS//$'\r'/}"

require_config_fields \
  "resources.storage-account.name" "${SA_LOCAL}" \
  "resources.storage-account.volume.name" "${VOLUME_NAME}" \
  "resources.storage-account.volume.fileshare" "${FILESHARE}"

STORAGE_NAME="$(build_azure_storage_account_name "${SA_LOCAL}" "${CLIENT}" "${LOCATION}")"
SKU="Standard_${REPLICATION}"

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create storage account and file share ==="
echo "Config file      : ${REPO_ROOT}/config.yaml"
echo "Profile          : ${PROFILE}"
echo "Client           : ${CLIENT}"
echo "Resource group   : ${RG_NAME}"
echo "Location         : ${LOCATION}"
echo "Storage account  : ${STORAGE_NAME}  (local: ${SA_LOCAL})  sku=${SKU}  kind=${KIND}"
echo "File share       : ${FILESHARE}"
if [[ -n "${VOLUME_NAME}" && "${VOLUME_NAME}" != "null" ]]; then
  echo "Volume label     : ${VOLUME_NAME}"
fi
echo

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

require_resource_group "${RG_NAME}"

if az storage account show --resource-group "${RG_NAME}" --name "${STORAGE_NAME}" >/dev/null 2>&1; then
  echo "Storage account ${STORAGE_NAME} already exists (skip create)."
else
  echo "Creating storage account ${STORAGE_NAME}..."
  az storage account create \
    --resource-group "${RG_NAME}" \
    --name "${STORAGE_NAME}" \
    --location "${LOCATION}" \
    --sku "${SKU}" \
    --kind "${KIND}"
fi

if az storage share-rm show \
  --resource-group "${RG_NAME}" \
  --storage-account "${STORAGE_NAME}" \
  --name "${FILESHARE}" >/dev/null 2>&1; then
  echo "File share ${FILESHARE} already exists (skip create)."
else
  echo "Creating file share ${FILESHARE}..."
  az storage share-rm create \
    --resource-group "${RG_NAME}" \
    --storage-account "${STORAGE_NAME}" \
    --name "${FILESHARE}" \
    --quota 100
fi

echo
echo "Done. Verify with:"
echo "  az storage account show -g ${RG_NAME} -n ${STORAGE_NAME}"
echo "  az storage share-rm show -g ${RG_NAME} --storage-account ${STORAGE_NAME} -n ${FILESHARE}"
