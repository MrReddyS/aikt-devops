#!/usr/bin/env bash
set -euo pipefail

# Creates a virtual network with subnets for Application Gateway and internal Container Apps.
# Local names in resources.vnet are expanded to {local}-{client}-{location-suffix}.
#
# Usage:
#   ./create_vnet.sh [--profile <name>] [--resource-group <rg>] [--location <region>]
#
# Requires: Azure CLI; resource group must already exist (see Resource_Group/create_rg.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_network.sh"

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

VNET_LOCAL=""
VNET_PREFIX=""
AGW_SUBNET_LOCAL=""
AGW_SUBNET_PREFIX=""
CAE_SUBNET_LOCAL=""
CAE_SUBNET_PREFIX=""
IFS=$'\t' read -r VNET_LOCAL VNET_PREFIX AGW_SUBNET_LOCAL AGW_SUBNET_PREFIX CAE_SUBNET_LOCAL CAE_SUBNET_PREFIX < <(read_vnet_row "${REPO_ROOT}")
VNET_LOCAL="${VNET_LOCAL//$'\r'/}"
VNET_PREFIX="${VNET_PREFIX//$'\r'/}"
AGW_SUBNET_LOCAL="${AGW_SUBNET_LOCAL//$'\r'/}"
AGW_SUBNET_PREFIX="${AGW_SUBNET_PREFIX//$'\r'/}"
CAE_SUBNET_LOCAL="${CAE_SUBNET_LOCAL//$'\r'/}"
CAE_SUBNET_PREFIX="${CAE_SUBNET_PREFIX//$'\r'/}"

require_config_fields \
  "resources.vnet.name" "${VNET_LOCAL}" \
  "resources.vnet.address-prefix" "${VNET_PREFIX}" \
  "resources.vnet.subnets.app-gateway.name" "${AGW_SUBNET_LOCAL}" \
  "resources.vnet.subnets.app-gateway.prefix" "${AGW_SUBNET_PREFIX}" \
  "resources.vnet.subnets.container-apps.name" "${CAE_SUBNET_LOCAL}" \
  "resources.vnet.subnets.container-apps.prefix" "${CAE_SUBNET_PREFIX}"

VNET_NAME="$(build_azure_resource_name "${VNET_LOCAL}" "${CLIENT}" "${LOCATION}" 64)"
AGW_SUBNET_NAME="$(build_azure_resource_name "${AGW_SUBNET_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"
CAE_SUBNET_NAME="$(build_azure_resource_name "${CAE_SUBNET_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create virtual network (App Gateway + Container Apps subnets) ==="
echo "Config file    : ${REPO_ROOT}/config.yaml"
echo "Profile        : ${PROFILE}"
echo "Client         : ${CLIENT}"
echo "Resource group : ${RG_NAME}"
echo "Location       : ${LOCATION}"
echo "VNet           : ${VNET_NAME}  (local: ${VNET_LOCAL}, ${VNET_PREFIX})"
echo "App GW subnet  : ${AGW_SUBNET_NAME}  (local: ${AGW_SUBNET_LOCAL}, ${AGW_SUBNET_PREFIX})"
echo "CAE subnet     : ${CAE_SUBNET_NAME}  (local: ${CAE_SUBNET_LOCAL}, ${CAE_SUBNET_PREFIX})"
echo

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

require_resource_group "${RG_NAME}"

if az network vnet show --resource-group "${RG_NAME}" --name "${VNET_NAME}" >/dev/null 2>&1; then
  echo "VNet ${VNET_NAME} already exists (skip create)."
else
  echo "Creating VNet ${VNET_NAME}..."
  az network vnet create \
    --resource-group "${RG_NAME}" \
    --name "${VNET_NAME}" \
    --location "${LOCATION}" \
    --address-prefix "${VNET_PREFIX}"
fi

if az network vnet subnet show \
  --resource-group "${RG_NAME}" \
  --vnet-name "${VNET_NAME}" \
  --name "${AGW_SUBNET_NAME}" >/dev/null 2>&1; then
  echo "Subnet ${AGW_SUBNET_NAME} already exists (skip create)."
else
  echo "Creating subnet ${AGW_SUBNET_NAME} (Application Gateway dedicated)..."
  az network vnet subnet create \
    --resource-group "${RG_NAME}" \
    --vnet-name "${VNET_NAME}" \
    --name "${AGW_SUBNET_NAME}" \
    --address-prefix "${AGW_SUBNET_PREFIX}"
fi

if az network vnet subnet show \
  --resource-group "${RG_NAME}" \
  --vnet-name "${VNET_NAME}" \
  --name "${CAE_SUBNET_NAME}" >/dev/null 2>&1; then
  echo "Subnet ${CAE_SUBNET_NAME} already exists; ensuring Microsoft.App/environments delegation..."
  az network vnet subnet update \
    --resource-group "${RG_NAME}" \
    --vnet-name "${VNET_NAME}" \
    --name "${CAE_SUBNET_NAME}" \
    --delegations Microsoft.App/environments >/dev/null
else
  echo "Creating subnet ${CAE_SUBNET_NAME} (internal Container Apps, delegated)..."
  az network vnet subnet create \
    --resource-group "${RG_NAME}" \
    --vnet-name "${VNET_NAME}" \
    --name "${CAE_SUBNET_NAME}" \
    --address-prefix "${CAE_SUBNET_PREFIX}" \
    --delegations Microsoft.App/environments
fi

echo
echo "Done. Verify with:"
echo "  az network vnet show -g ${RG_NAME} -n ${VNET_NAME}"
echo "  az network vnet subnet show -g ${RG_NAME} --vnet-name ${VNET_NAME} -n ${AGW_SUBNET_NAME}"
echo "  az network vnet subnet show -g ${RG_NAME} --vnet-name ${VNET_NAME} -n ${CAE_SUBNET_NAME}"
