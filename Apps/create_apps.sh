#!/usr/bin/env bash
set -euo pipefail

# Creates Open WebUI + Docling on Azure Container Apps with Azure Files persistence.
#
# Usage:
#   ./create_apps.sh [--profile <name>] [--resource-group <rg>] [--location <region>]
#
# Prerequisites: create_rg.sh, create_vnet.sh, create_storage.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_apps.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../Storage/_lib_storage.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../Network/_lib_network.sh"

PROFILE="" RG_NAME="" LOCATION=""

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

ENV_LOCAL="" OW_LOCAL="" OW_CPU="" OW_MEM="" OW_IMAGE="" OW_PORT=""
DOC_LOCAL="" DOC_CPU="" DOC_MEM="" DOC_PROFILE="" DOC_IMAGE="" DOC_PORT=""
IFS=$'\t' read -r ENV_LOCAL OW_LOCAL OW_CPU OW_MEM OW_IMAGE OW_PORT \
  DOC_LOCAL DOC_CPU DOC_MEM DOC_PROFILE DOC_IMAGE DOC_PORT \
  < <(read_container_apps_row "${REPO_ROOT}")

[[ -z "${OW_IMAGE}" || "${OW_IMAGE}" == "null" ]] && OW_IMAGE="${DEFAULT_OPENWEBUI_IMAGE}"
[[ -z "${DOC_IMAGE}" || "${DOC_IMAGE}" == "null" ]] && DOC_IMAGE="${DEFAULT_DOCLING_IMAGE}"
[[ -z "${OW_PORT}" || "${OW_PORT}" == "null" ]] && OW_PORT="${DEFAULT_OPENWEBUI_PORT}"
[[ -z "${DOC_PORT}" || "${DOC_PORT}" == "null" ]] && DOC_PORT="${DEFAULT_DOCLING_PORT}"
[[ -z "${DOC_PROFILE}" || "${DOC_PROFILE}" == "null" ]] && DOC_PROFILE="${DEFAULT_DOC_WORKLOAD_PROFILE}"

UVICORN_WORKERS="" MAX_SYNC_WAIT=""
IFS=$'\t' read -r UVICORN_WORKERS MAX_SYNC_WAIT < <(read_docling_env_row "${REPO_ROOT}")

VNET_LOCAL="" VNET_PREFIX="" _="" _="" CAE_SUBNET_LOCAL="" CAE_SUBNET_PREFIX=""
IFS=$'\t' read -r VNET_LOCAL VNET_PREFIX _ _ CAE_SUBNET_LOCAL CAE_SUBNET_PREFIX < <(read_vnet_row "${REPO_ROOT}")

ST_LOCAL="" _="" _="" VOL_LOCAL="" FILESHARE="" MOUNT_PATH=""
IFS=$'\t' read -r ST_LOCAL _ _ VOL_LOCAL FILESHARE MOUNT_PATH < <(read_storage_row "${REPO_ROOT}")
MOUNT_PATH="${MOUNT_PATH:-${OPENWEBUI_DATA_MOUNT}}"

CAE_NAME="$(resolve_cae_name "${ENV_LOCAL}" "${CLIENT}" "${LOCATION}")"
OW_APP="$(resolve_container_app_name "${OW_LOCAL}" "${CLIENT}" "${LOCATION}")"
DOC_APP="$(resolve_container_app_name "${DOC_LOCAL}" "${CLIENT}" "${LOCATION}")"
VNET_NAME="$(build_azure_resource_name "${VNET_LOCAL}" "${CLIENT}" "${LOCATION}" 64)"
CAE_SUBNET_NAME="$(build_azure_resource_name "${CAE_SUBNET_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"
ST_NAME="$(resolve_storage_account_name "${REPO_ROOT}" "${CLIENT}" "${LOCATION}")"
VOL_LINK="$(resolve_storage_volume_link_name "${REPO_ROOT}" "${CLIENT}" "${LOCATION}")"

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create Container Apps (Open WebUI + Docling) ==="
echo "Resource group : ${RG_NAME}"
echo "Location       : ${LOCATION}  (change in config.yaml to try other regions)"
echo "Environment    : ${CAE_NAME}"
echo "Open WebUI     : ${OW_APP}  cpu=${OW_CPU} memory=${OW_MEM}"
echo "Docling        : ${DOC_APP}  cpu=${DOC_CPU} memory=${DOC_MEM} profile=${DOC_PROFILE}"
echo "Storage mount  : ${ST_NAME}/${FILESHARE} -> ${MOUNT_PATH}"
echo

ensure_containerapp_extension
ensure_az_account "${TENANT_ID}" "${SUBSCRIPTION_ID}"

require_resource_group "${RG_NAME}"
require_vnet_subnet "${RG_NAME}" "${VNET_NAME}" "${CAE_SUBNET_NAME}"
require_storage_file_share "${RG_NAME}" "${ST_NAME}" "${FILESHARE}"

SUBNET_ID="$(resolve_subnet_resource_id "${RG_NAME}" "${VNET_NAME}" "${CAE_SUBNET_NAME}")"
ST_KEY="$(get_storage_account_key "${RG_NAME}" "${ST_NAME}")"

ensure_container_apps_environment \
  "${RG_NAME}" "${CAE_NAME}" "${LOCATION}" "${SUBNET_ID}" "${DOC_PROFILE}"

ensure_cae_storage_volume "${RG_NAME}" "${CAE_NAME}" "${VOL_LINK}" "${ST_NAME}" "${FILESHARE}" "${ST_KEY}"

ensure_docling_container_app \
  "${RG_NAME}" "${CAE_NAME}" "${DOC_APP}" "${DOC_IMAGE}" "${DOC_PORT}" \
  "${DOC_CPU}" "${DOC_MEM}" "${DOC_PROFILE}" "${UVICORN_WORKERS}" "${MAX_SYNC_WAIT}"

DOC_URL="$(container_app_ingress_fqdn "${RG_NAME}" "${DOC_APP}")"
WEBUI_SECRET="$(generate_webui_secret_key)"

ensure_openwebui_container_app \
  "${RG_NAME}" "${CAE_NAME}" "${OW_APP}" "${OW_IMAGE}" "${OW_PORT}" \
  "${OW_CPU}" "${OW_MEM}" "${MOUNT_PATH}" "${VOL_LINK}" "${WEBUI_SECRET}" "${DOC_URL}"

OW_URL="$(container_app_ingress_fqdn "${RG_NAME}" "${OW_APP}")"

echo
echo "Done."
echo "  Open WebUI (public) : ${OW_URL}"
echo "  Docling (internal)  : ${DOC_URL}"
echo
echo "Full DATA_DIR persists on Azure Files (${FILESHARE}). Change project.location and re-run to test other regions."
