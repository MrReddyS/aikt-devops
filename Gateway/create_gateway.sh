#!/usr/bin/env bash
set -euo pipefail

# Creates a Standard_v2 Application Gateway and public IP in an existing VNet subnet.
# HTTPS, listeners, and backend pools are configured manually after create.
#
# Usage:
#   ./create_gateway.sh [--profile <name>] [--resource-group <rg>] [--location <region>]
#
# Requires: Azure CLI; resource group and VNet (Network/create_vnet.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

GATEWAY_ENABLED="$(read_app_gateway_enabled "${REPO_ROOT}")"
GATEWAY_ENABLED="${GATEWAY_ENABLED//$'\r'/}"
if [[ "${GATEWAY_ENABLED}" != "true" ]]; then
  echo "Application Gateway is disabled in config (resources.app-gateway.enabled: false)."
  echo "Set enabled: true and re-run to deploy a gateway."
  exit 0
fi

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

VNET_LOCAL=""
VNET_PREFIX=""
AGW_SUBNET_LOCAL=""
AGW_SUBNET_PREFIX=""
IFS=$'\t' read -r VNET_LOCAL VNET_PREFIX AGW_SUBNET_LOCAL AGW_SUBNET_PREFIX _ _ < <(read_vnet_row "${REPO_ROOT}")

GW_LOCAL=""
GW_SKU=""
GW_CAPACITY=""
PIP_LOCAL=""
IFS=$'\t' read -r GW_LOCAL GW_SKU GW_CAPACITY PIP_LOCAL < <(read_app_gateway_row "${REPO_ROOT}")

VNET_LOCAL="${VNET_LOCAL//$'\r'/}"
VNET_PREFIX="${VNET_PREFIX//$'\r'/}"
AGW_SUBNET_LOCAL="${AGW_SUBNET_LOCAL//$'\r'/}"
AGW_SUBNET_PREFIX="${AGW_SUBNET_PREFIX//$'\r'/}"
GW_LOCAL="${GW_LOCAL//$'\r'/}"
GW_SKU="${GW_SKU//$'\r'/}"
GW_CAPACITY="${GW_CAPACITY//$'\r'/}"
PIP_LOCAL="${PIP_LOCAL//$'\r'/}"

require_config_fields \
  "resources.vnet.name" "${VNET_LOCAL}" \
  "resources.vnet.subnets.app-gateway.name" "${AGW_SUBNET_LOCAL}" \
  "resources.app-gateway.name" "${GW_LOCAL}" \
  "resources.app-gateway.public-ip.name" "${PIP_LOCAL}"

VNET_NAME="$(build_azure_resource_name "${VNET_LOCAL}" "${CLIENT}" "${LOCATION}" 64)"
SUBNET_NAME="$(build_azure_resource_name "${AGW_SUBNET_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"
GW_NAME="$(build_azure_resource_name "${GW_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"
PIP_NAME="$(build_azure_resource_name "${PIP_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"

if [[ "${GW_SKU}" != "Standard_v2" && "${GW_SKU}" != "WAF_v2" ]]; then
  echo "ERROR: resources.app-gateway.sku must be Standard_v2 or WAF_v2 (got: ${GW_SKU})" >&2
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create Application Gateway ==="
echo "Config file    : ${REPO_ROOT}/config.yaml"
echo "Profile        : ${PROFILE}"
echo "Client         : ${CLIENT}"
echo "Resource group : ${RG_NAME}"
echo "Location       : ${LOCATION}"
echo "Gateway        : ${GW_NAME}  (local: ${GW_LOCAL})  sku=${GW_SKU}  capacity=${GW_CAPACITY}"
echo "Public IP      : ${PIP_NAME}  (local: ${PIP_LOCAL})"
echo "VNet / subnet  : ${VNET_NAME} / ${SUBNET_NAME}"
echo
echo "Note: HTTPS, listeners, and backend pools are configured manually after create."
echo

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

require_resource_group "${RG_NAME}"
require_vnet_subnet "${RG_NAME}" "${VNET_NAME}" "${SUBNET_NAME}"

if az network public-ip show --resource-group "${RG_NAME}" --name "${PIP_NAME}" >/dev/null 2>&1; then
  echo "Public IP ${PIP_NAME} already exists (skip create)."
else
  echo "Creating Standard static public IP ${PIP_NAME}..."
  az network public-ip create \
    --resource-group "${RG_NAME}" \
    --name "${PIP_NAME}" \
    --location "${LOCATION}" \
    --sku Standard \
    --allocation-method Static
fi

if az network application-gateway show --resource-group "${RG_NAME}" --name "${GW_NAME}" >/dev/null 2>&1; then
  echo "Application Gateway ${GW_NAME} already exists (skip create)."
else
  echo "Creating Application Gateway ${GW_NAME}..."
  az network application-gateway create \
    --resource-group "${RG_NAME}" \
    --name "${GW_NAME}" \
    --location "${LOCATION}" \
    --sku "${GW_SKU}" \
    --capacity "${GW_CAPACITY}" \
    --vnet-name "${VNET_NAME}" \
    --subnet "${SUBNET_NAME}" \
    --public-ip-address "${PIP_NAME}" \
    --priority 100 \
    --servers 127.0.0.1
fi

pip_addr="$(az network public-ip show -g "${RG_NAME}" -n "${PIP_NAME}" --query ipAddress -o tsv 2>/dev/null || true)"

echo
echo "Done."
if [[ -n "${pip_addr}" && "${pip_addr}" != "null" ]]; then
  echo "Public IP: ${pip_addr}"
fi
