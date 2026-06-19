#!/usr/bin/env bash
set -euo pipefail

# Deletes Container Apps and environment.
#
# Usage:
#   ./delete_apps.sh [--profile <name>] [--resource-group <rg>] [--yes]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_lib_apps.sh"

PROFILE="" RG_NAME="" ASSUME_YES="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --resource-group|-g) RG_NAME="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES="1"; shift ;;
    -h|--help)
      echo "Usage: $0 [--profile <config-profile>] [--resource-group <rg>] [--yes]"
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
CLIENT="$(read_project_client "${REPO_ROOT}")"
LOCATION="${local_loc_def:-${DEFAULT_LOCATION}}"

ENV_LOCAL="" OW_LOCAL="" _owcpu="" _owmem="" _owimg="" _owport=""
DOC_LOCAL="" _dc="" _dm="" _dp="" _di="" _dport=""
IFS=$'\t' read -r ENV_LOCAL OW_LOCAL _owcpu _owmem _owimg _owport \
  DOC_LOCAL _dc _dm _dp _di _dport \
  < <(read_container_apps_row "${REPO_ROOT}")

CAE_NAME="$(resolve_cae_name "${ENV_LOCAL}" "${CLIENT}" "${LOCATION}")"
OW_APP="$(resolve_container_app_name "${OW_LOCAL}" "${CLIENT}" "${LOCATION}")"
DOC_APP="$(resolve_container_app_name "${DOC_LOCAL}" "${CLIENT}" "${LOCATION}")"

ensure_containerapp_extension
ensure_az_account "${TENANT_ID}" "${SUBSCRIPTION_ID}"

echo "=== Delete Container Apps ==="
echo "Resource group : ${RG_NAME}"
echo "Apps           : ${OW_APP}, ${DOC_APP}"
echo "Environment    : ${CAE_NAME}"
echo

if [[ "${ASSUME_YES}" != "1" ]]; then
  read -r -p "Type the Open WebUI app name to confirm: " confirm
  [[ "${confirm}" == "${OW_APP}" ]] || { echo "Aborted." >&2; exit 1; }
fi

for app in "${OW_APP}" "${DOC_APP}"; do
  if run_az containerapp show -g "${RG_NAME}" -n "${app}" >/dev/null 2>&1; then
    run_az containerapp delete -g "${RG_NAME}" -n "${app}" --yes
  else
    echo "  (skip) ${app}"
  fi
done

if run_az containerapp env show -g "${RG_NAME}" -n "${CAE_NAME}" >/dev/null 2>&1; then
  run_az containerapp env delete -g "${RG_NAME}" -n "${CAE_NAME}" --yes
else
  echo "  (skip env) ${CAE_NAME}"
fi

echo "Done."
