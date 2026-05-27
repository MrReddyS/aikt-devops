#!/usr/bin/env bash
set -euo pipefail

# Creates an Azure resource group using tenant + subscription from repo-root config.yaml.
#
# Usage:
#   ./create_rg.sh [--profile <name>] [--name <rg-name>] [--location <region>]
#
# If --profile is omitted: uses defaults.profile, or the only subscriptions.* key if there is exactly one.
# If --name is omitted: uses defaults.resource_group.name, else project.rg from config.yaml.
# If --location is omitted: uses defaults.resource_group.location, else project.location, else defaults.location.
#
# Example (from any cwd):
#   ./Resource_Group/create_rg.sh
#   ./Resource_Group/create_rg.sh --name rg-myapp-prod-weu --location westeurope

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_config.sh"

PROFILE=""
RG_NAME=""
LOCATION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --name) RG_NAME="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--profile <config-profile>] [--name <resource-group-name>] [--location <azure-region>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--profile <config-profile>] [--name <resource-group-name>] [--location <azure-region>]" >&2
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
  echo "ERROR: no resource group name: pass --name or set defaults.resource_group.name or project.rg in config.yaml" >&2
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
  echo "ERROR: no location: pass --location or set defaults.resource_group.location, project.location, or defaults.location in config.yaml" >&2
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Create resource group ==="
echo "Config file    : ${REPO_ROOT}/config.yaml"
echo "Profile        : ${PROFILE}"
echo "Tenant         : ${TENANT_ID}"
echo "Subscription   : ${SUBSCRIPTION_ID}"
echo "Resource group : ${RG_NAME}"
echo "Location       : ${LOCATION}"
echo

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

az group create --name "${RG_NAME}" --location "${LOCATION}"

echo
echo "Done. Verify with: az group show -n ${RG_NAME}"
