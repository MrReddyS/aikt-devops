#!/usr/bin/env bash
set -euo pipefail

# Creates an internal Container Apps environment (VNet-integrated) and two apps with
# internal ingress only. Public access is via Application Gateway (Gateway/create_gateway.sh).
#
# Usage:
#   ./create_apps.sh [--profile <name>] [--resource-group <rg>] [--location <region>]
#
# Requires: Azure CLI, containerapp extension, VNet (Network/create_vnet.sh).
# Open WebUI also requires storage (Storage/create_storage.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_apps.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../Storage/_lib_storage.sh"
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

IFS=$'\t' read -r RAW_CLIENT _ DOCLING_IMAGE OWUI_IMAGE < <(read_container_apps_project_row "${REPO_ROOT}")
RAW_CLIENT="${RAW_CLIENT//$'\r'/}"
DOCLING_IMAGE="${DOCLING_IMAGE//$'\r'/}"
OWUI_IMAGE="${OWUI_IMAGE//$'\r'/}"

if [[ -z "${RAW_CLIENT}" || "${RAW_CLIENT}" == "null" ]]; then
  echo "ERROR: project.client must be set in config.yaml (used for app and environment names)." >&2
  exit 2
fi

PREFIX="$(sanitize_azure_name_segment "${RAW_CLIENT}" 20)"
if [[ -z "${PREFIX}" ]]; then
  echo "ERROR: project.client sanitizes to an empty string; use letters/numbers." >&2
  exit 2
fi

CAE_NAME="$(resolve_cae_name "${REPO_ROOT}" "${RAW_CLIENT}" "${LOCATION}")"
DOC_APP="${PREFIX}-docling-app"
OWUI_APP="${PREFIX}-owui-app"

if [[ -z "${DOCLING_IMAGE}" || "${DOCLING_IMAGE}" == "null" ]]; then
  DOCLING_IMAGE="${DEFAULT_DOCLING_IMAGE}"
fi
if [[ -z "${OWUI_IMAGE}" || "${OWUI_IMAGE}" == "null" ]]; then
  OWUI_IMAGE="${DEFAULT_OPENWEBUI_IMAGE}"
fi

VNET_LOCAL=""
VNET_PREFIX=""
AGW_SUBNET_LOCAL=""
AGW_SUBNET_PREFIX=""
CAE_SUBNET_LOCAL=""
CAE_SUBNET_PREFIX=""
IFS=$'\t' read -r VNET_LOCAL VNET_PREFIX AGW_SUBNET_LOCAL AGW_SUBNET_PREFIX CAE_SUBNET_LOCAL CAE_SUBNET_PREFIX < <(read_vnet_row "${REPO_ROOT}")
VNET_LOCAL="${VNET_LOCAL//$'\r'/}"
CAE_SUBNET_LOCAL="${CAE_SUBNET_LOCAL//$'\r'/}"

if [[ -z "${VNET_LOCAL}" || "${VNET_LOCAL}" == "null" || -z "${CAE_SUBNET_LOCAL}" || "${CAE_SUBNET_LOCAL}" == "null" ]]; then
  echo "ERROR: resources.vnet and resources.vnet.subnets.container-apps must be set in config.yaml" >&2
  exit 2
fi

VNET_NAME="$(build_azure_resource_name "${VNET_LOCAL}" "${RAW_CLIENT}" "${LOCATION}" 64)"
CAE_SUBNET_NAME="$(build_azure_resource_name "${CAE_SUBNET_LOCAL}" "${RAW_CLIENT}" "${LOCATION}" 80)"

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

if ! az containerapp env create -h >/dev/null 2>&1; then
  echo "ERROR: Azure CLI 'containerapp' commands unavailable. Install the extension:" >&2
  echo "  az extension add --name containerapp --upgrade" >&2
  exit 1
fi

echo "=== Create internal Container Apps (Docling + Open WebUI) ==="
echo "Config file        : ${REPO_ROOT}/config.yaml"
echo "Profile            : ${PROFILE}"
echo "Resource group     : ${RG_NAME}"
echo "Location           : ${LOCATION}"
echo "VNet / CAE subnet  : ${VNET_NAME} / ${CAE_SUBNET_NAME}"
echo "Environment        : ${CAE_NAME}  (internal-only)"
echo "Docling app        : ${DOC_APP}  image=${DOCLING_IMAGE}  ingress=internal"
echo "Open WebUI app     : ${OWUI_APP}  image=${OWUI_IMAGE}  ingress=internal"
echo
echo "Apps are not public. Route traffic through Application Gateway only."
echo

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

require_vnet_subnet "${RG_NAME}" "${VNET_NAME}" "${CAE_SUBNET_NAME}"
CAE_SUBNET_ID="$(resolve_subnet_resource_id "${RG_NAME}" "${VNET_NAME}" "${CAE_SUBNET_NAME}")"

if az containerapp env show -g "${RG_NAME}" -n "${CAE_NAME}" >/dev/null 2>&1; then
  echo "Container Apps environment ${CAE_NAME} already exists (skip create)."
else
  echo "Creating internal Container Apps environment ${CAE_NAME}..."
  run_az containerapp env create \
    --name "${CAE_NAME}" \
    --resource-group "${RG_NAME}" \
    --location "${LOCATION}" \
    --infrastructure-subnet-resource-id "${CAE_SUBNET_ID}" \
    --internal-only \
    --logs-destination none
fi

if az containerapp show -g "${RG_NAME}" -n "${DOC_APP}" >/dev/null 2>&1; then
  echo "Docling app ${DOC_APP} already exists (skip create)."
else
  echo "Creating Docling app (internal ingress :5001)..."
  az containerapp create \
    --name "${DOC_APP}" \
    --resource-group "${RG_NAME}" \
    --environment "${CAE_NAME}" \
    --image "${DOCLING_IMAGE}" \
    --target-port 5001 \
    --ingress internal \
    --transport auto \
    --cpu 2.0 \
    --memory 4.0Gi \
    --min-replicas 1 \
    --max-replicas 2
fi

STORAGE_NAME="$(resolve_storage_account_name "${REPO_ROOT}" "${RAW_CLIENT}" "${LOCATION}")"
VOLUME_LINK=""
FILESHARE=""
MOUNT_PATH=""
MOUNT_OPTIONS=""
IFS=$'\t' read -r _ _ _ VOLUME_LINK FILESHARE MOUNT_PATH MOUNT_OPTIONS < <(read_storage_row "${REPO_ROOT}")
VOLUME_LINK="${VOLUME_LINK//$'\r'/}"
FILESHARE="${FILESHARE//$'\r'/}"
MOUNT_PATH="${MOUNT_PATH//$'\r'/}"
MOUNT_OPTIONS="${MOUNT_OPTIONS//$'\r'/}"

if [[ -z "${VOLUME_LINK}" || "${VOLUME_LINK}" == "null" ]]; then
  echo "ERROR: resources.storage-account.volume.name must be set in config.yaml" >&2
  exit 2
fi

require_storage_file_share "${RG_NAME}" "${STORAGE_NAME}" "${FILESHARE}"

ENV_ID="$(az containerapp env show -g "${RG_NAME}" -n "${CAE_NAME}" --query id -o tsv)"
ensure_cae_azure_file_storage "${RG_NAME}" "${CAE_NAME}" "${VOLUME_LINK}" "${STORAGE_NAME}" "${FILESHARE}"

if az containerapp show -g "${RG_NAME}" -n "${OWUI_APP}" >/dev/null 2>&1; then
  echo "Open WebUI app ${OWUI_APP} already exists (skip create)."
else
  echo "Creating Open WebUI app (internal ingress :8080, persistent data at ${MOUNT_PATH})..."
  owui_yaml="$(mktemp "${TMPDIR:-/tmp}/owui-ca.XXXXXX.yaml")"
  trap 'rm -f "${owui_yaml}"' EXIT
  cat >"${owui_yaml}" <<EOF
properties:
  managedEnvironmentId: ${ENV_ID}
  configuration:
    ingress:
      external: false
      targetPort: 8080
      transport: auto
  template:
    containers:
    - name: openwebui
      image: ${OWUI_IMAGE}
      resources:
        cpu: 1.0
        memory: 2.0Gi
      volumeMounts:
      - volumeName: owui-data
        mountPath: ${MOUNT_PATH}
    scale:
      minReplicas: 1
      maxReplicas: 2
    volumes:
    - name: owui-data
      storageType: AzureFile
      storageName: ${VOLUME_LINK}
      mountOptions: ${MOUNT_OPTIONS}
EOF
  az containerapp create \
    --name "${OWUI_APP}" \
    --resource-group "${RG_NAME}" \
    --yaml "${owui_yaml}"
  rm -f "${owui_yaml}"
  trap - EXIT
fi

echo
echo "Done."
echo "Internal FQDNs (configure as App Gateway backend pool targets):"
doc_fqdn="$(az containerapp show -g "${RG_NAME}" -n "${DOC_APP}" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || true)"
ow_fqdn="$(az containerapp show -g "${RG_NAME}" -n "${OWUI_APP}" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || true)"
if [[ -n "${doc_fqdn}" && "${doc_fqdn}" != "null" ]]; then
  echo "  Docling:    ${doc_fqdn}  (port 5001)"
fi
if [[ -n "${ow_fqdn}" && "${ow_fqdn}" != "null" ]]; then
  echo "  Open WebUI: ${ow_fqdn}  (port 8080)"
fi
