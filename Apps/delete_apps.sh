#!/usr/bin/env bash
set -euo pipefail

# Deletes the two Container Apps (Docling + Open WebUI) and their shared environment.
# Names match create_apps.sh (from project.client and optional project.container_apps.environment_name).
#
# Usage:
#   ./delete_apps.sh [--profile <name>] [--resource-group <rg>] [--yes]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_apps.sh"

PROFILE=""
RG_NAME=""
ASSUME_YES="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --resource-group|-g) RG_NAME="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES="1"; shift ;;
    -h|--help)
      echo "Usage: $0 [--profile <config-profile>] [--resource-group <rg>] [--yes]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--profile <config-profile>] [--resource-group <rg>] [--yes]" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(find_repo_root_from "${SCRIPT_DIR}")"

local_rg_def=""
IFS=$'\t' read -r local_rg_def _ < <(read_rg_defaults_from_config "${REPO_ROOT}")
local_rg_def="${local_rg_def//$'\r'/}"

PROFILE="$(resolve_profile_name "${REPO_ROOT}" "${PROFILE}")"
TENANT_ID=""
SUBSCRIPTION_ID=""
DEFAULT_LOCATION=""
read_subscription_profile "${REPO_ROOT}" "${PROFILE}"

if [[ -z "${RG_NAME}" ]]; then
  RG_NAME="${local_rg_def}"
fi
if [[ -z "${RG_NAME}" || "${RG_NAME}" == "null" ]]; then
  echo "ERROR: no resource group: pass --resource-group or set project.rg / defaults.resource_group.name in config.yaml" >&2
  exit 2
fi

IFS=$'\t' read -r RAW_CLIENT _ _ _ < <(read_container_apps_project_row "${REPO_ROOT}")
RAW_CLIENT="${RAW_CLIENT//$'\r'/}"

if [[ -z "${RAW_CLIENT}" || "${RAW_CLIENT}" == "null" ]]; then
  echo "ERROR: project.client must be set in config.yaml." >&2
  exit 2
fi

PREFIX="$(sanitize_azure_name_segment "${RAW_CLIENT}" 20)"
if [[ -z "${PREFIX}" ]]; then
  echo "ERROR: project.client sanitizes to an empty string." >&2
  exit 2
fi

local_loc_def=""
IFS=$'\t' read -r _ local_loc_def < <(read_rg_defaults_from_config "${REPO_ROOT}")
local_loc_def="${local_loc_def//$'\r'/}"
LOCATION="${local_loc_def}"
if [[ -z "${LOCATION}" || "${LOCATION}" == "null" ]]; then
  read_subscription_profile "${REPO_ROOT}" "${PROFILE}"
  LOCATION="${DEFAULT_LOCATION}"
fi

CAE_NAME="$(resolve_cae_name "${REPO_ROOT}" "${RAW_CLIENT}" "${LOCATION}")"

DOC_APP="${PREFIX}-docling-app"
OWUI_APP="${PREFIX}-owui-app"

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

if ! az containerapp delete -h >/dev/null 2>&1; then
  echo "ERROR: Azure CLI 'containerapp' commands unavailable. Install: az extension add --name containerapp --upgrade" >&2
  exit 1
fi

echo "=== Delete Container Apps (Docling + Open WebUI) ==="
echo "Resource group : ${RG_NAME}"
echo "Environment    : ${CAE_NAME}"
echo "Apps           : ${DOC_APP}, ${OWUI_APP}"
echo

if [[ "${ASSUME_YES}" != "1" ]]; then
  read -r -p "Type the Container Apps environment name to confirm deletion: " confirm
  if [[ "${confirm}" != "${CAE_NAME}" ]]; then
    echo "Aborted (confirmation did not match)." >&2
    exit 1
  fi
fi

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

echo "Deleting apps..."
if az containerapp show -g "${RG_NAME}" -n "${DOC_APP}" &>/dev/null; then
  az containerapp delete --name "${DOC_APP}" --resource-group "${RG_NAME}" --yes
else
  echo "  (not found, skip) ${DOC_APP}"
fi
if az containerapp show -g "${RG_NAME}" -n "${OWUI_APP}" &>/dev/null; then
  az containerapp delete --name "${OWUI_APP}" --resource-group "${RG_NAME}" --yes
else
  echo "  (not found, skip) ${OWUI_APP}"
fi

echo "Deleting environment ${CAE_NAME}..."
if az containerapp env show -g "${RG_NAME}" -n "${CAE_NAME}" &>/dev/null; then
  az containerapp env delete --name "${CAE_NAME}" --resource-group "${RG_NAME}" --yes
else
  echo "  (not found, skip) ${CAE_NAME}"
fi

echo "Done."
