#!/usr/bin/env bash
set -euo pipefail

# Deletes an Azure resource group (and all resources in it) for the subscription in config.yaml.
#
# Usage:
#   ./delete_rg.sh [--profile <name>] [--name <rg-name>] [--yes]
#
# If --profile is omitted: uses defaults.profile, or the only subscriptions.* key if there is exactly one.
# If --name is omitted: uses defaults.resource_group.name, else project.rg from config.yaml.
# Without --yes, prompts once for confirmation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_config.sh"

PROFILE=""
RG_NAME=""
ASSUME_YES="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --name) RG_NAME="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES="1"; shift ;;
    -h|--help)
      echo "Usage: $0 [--profile <config-profile>] [--name <resource-group-name>] [--yes]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--profile <config-profile>] [--name <resource-group-name>] [--yes]" >&2
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
  echo "ERROR: no resource group name: pass --name or set defaults.resource_group.name or project.rg in config.yaml" >&2
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }

echo "=== Delete resource group ==="
echo "Config file    : ${REPO_ROOT}/config.yaml"
echo "Profile        : ${PROFILE}"
echo "Tenant         : ${TENANT_ID}"
echo "Subscription   : ${SUBSCRIPTION_ID}"
echo "Resource group : ${RG_NAME}"
echo

if [[ "${ASSUME_YES}" != "1" ]]; then
  read -r -p "This permanently deletes the RG and all resources inside it. Type the RG name to confirm: " confirm
  if [[ "${confirm}" != "${RG_NAME}" ]]; then
    echo "Aborted (confirmation did not match)." >&2
    exit 1
  fi
fi

az account show >/dev/null 2>&1 || az login --tenant "${TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

az group delete --name "${RG_NAME}" --yes --no-wait

echo "Deletion started (async). Monitor with:"
echo "  az group wait --deleted -n ${RG_NAME}"
