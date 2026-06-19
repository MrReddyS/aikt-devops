#!/usr/bin/env bash
set -euo pipefail

# Creates a virtual network with a Container Apps environment subnet (and optional App Gateway).
#
# Usage:
#   ./create_vnet.sh [--profile <name>] [--resource-group <rg>] [--location <region>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_network.sh"

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

VNET_LOCAL="" VNET_PREFIX="" AGW_SUBNET_LOCAL="" AGW_SUBNET_PREFIX=""
CAE_SUBNET_LOCAL="" CAE_SUBNET_PREFIX=""
IFS=$'\t' read -r VNET_LOCAL VNET_PREFIX AGW_SUBNET_LOCAL AGW_SUBNET_PREFIX CAE_SUBNET_LOCAL CAE_SUBNET_PREFIX \
  < <(read_vnet_row "${REPO_ROOT}")
VNET_PREFIX="$(strip_cr "${VNET_PREFIX}")"
AGW_SUBNET_PREFIX="$(strip_cr "${AGW_SUBNET_PREFIX}")"
CAE_SUBNET_PREFIX="$(strip_cr "${CAE_SUBNET_PREFIX}")"

require_config_fields \
  "resources.vnet.name" "${VNET_LOCAL}" \
  "resources.vnet.address-prefix" "${VNET_PREFIX}" \
  "resources.vnet.subnets.container-apps.name" "${CAE_SUBNET_LOCAL}" \
  "resources.vnet.subnets.container-apps.prefix" "${CAE_SUBNET_PREFIX}"

GATEWAY_ENABLED="$(read_app_gateway_enabled "${REPO_ROOT}")"
if [[ "${GATEWAY_ENABLED}" == "true" ]]; then
  require_config_fields \
    "resources.vnet.subnets.app-gateway.name" "${AGW_SUBNET_LOCAL}" \
    "resources.vnet.subnets.app-gateway.prefix" "${AGW_SUBNET_PREFIX}"
fi

VNET_NAME="$(build_azure_resource_name "${VNET_LOCAL}" "${CLIENT}" "${LOCATION}" 64)"
CAE_SUBNET_NAME="$(build_azure_resource_name "${CAE_SUBNET_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"
AGW_SUBNET_NAME=""
if [[ "${GATEWAY_ENABLED}" == "true" ]]; then
  AGW_SUBNET_NAME="$(build_azure_resource_name "${AGW_SUBNET_LOCAL}" "${CLIENT}" "${LOCATION}" 80)"
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create virtual network (Container Apps subnet${GATEWAY_ENABLED:+ + App Gateway}) ==="
echo "Resource group : ${RG_NAME}"
echo "Location       : ${LOCATION}"
echo "VNet           : ${VNET_NAME}  (${VNET_PREFIX})"
echo "CAE subnet     : ${CAE_SUBNET_NAME}  (${CAE_SUBNET_PREFIX})"
echo

ensure_az_account "${TENANT_ID}" "${SUBSCRIPTION_ID}"
require_resource_group "${RG_NAME}"

if ! run_az network vnet show -g "${RG_NAME}" -n "${VNET_NAME}" >/dev/null 2>&1; then
  echo "Creating VNet ${VNET_NAME}..."
  run_az network vnet create \
    --resource-group "${RG_NAME}" \
    --name "${VNET_NAME}" \
    --location "${LOCATION}" \
    --address-prefix "${VNET_PREFIX}" >/dev/null
else
  echo "VNet ${VNET_NAME} already exists."
fi

if [[ "${GATEWAY_ENABLED}" == "true" ]]; then
  if ! run_az network vnet subnet show -g "${RG_NAME}" --vnet-name "${VNET_NAME}" -n "${AGW_SUBNET_NAME}" >/dev/null 2>&1; then
    run_az network vnet subnet create \
      -g "${RG_NAME}" --vnet-name "${VNET_NAME}" -n "${AGW_SUBNET_NAME}" \
      --address-prefix "${AGW_SUBNET_PREFIX}" >/dev/null
  fi
fi

if run_az network vnet subnet show -g "${RG_NAME}" --vnet-name "${VNET_NAME}" -n "${CAE_SUBNET_NAME}" >/dev/null 2>&1; then
  echo "Subnet ${CAE_SUBNET_NAME} exists; ensuring Microsoft.App/environments delegation..."
  run_az network vnet subnet update \
    -g "${RG_NAME}" --vnet-name "${VNET_NAME}" -n "${CAE_SUBNET_NAME}" \
    --delegations Microsoft.App/environments >/dev/null
else
  echo "Creating subnet ${CAE_SUBNET_NAME} (Container Apps, /23+ recommended)..."
  run_az network vnet subnet create \
    -g "${RG_NAME}" --vnet-name "${VNET_NAME}" -n "${CAE_SUBNET_NAME}" \
    --address-prefix "${CAE_SUBNET_PREFIX}" \
    --delegations Microsoft.App/environments >/dev/null
fi

echo "Done."
