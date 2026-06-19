#!/usr/bin/env bash
# Shared helpers for Storage/*.sh — Azure Files for Open WebUI persistence.

set -euo pipefail

_STORAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_STORAGE_LIB_DIR}/../Resource_Group/_lib_config.sh"

# st_local<TAB>replication<TAB>kind<TAB>volume_name<TAB>fileshare<TAB>mount_path
read_storage_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if command -v yq >/dev/null 2>&1; then
    local st rep kind vol share mount
    st="$(yq -r '.resources["storage-account"].name // ""' "${cfg}")"
    rep="$(yq -r '.resources["storage-account"].replication // "LRS"' "${cfg}")"
    kind="$(yq -r '.resources["storage-account"].kind // "StorageV2"' "${cfg}")"
    vol="$(yq -r '.resources["storage-account"].volume.name // "volsmb"' "${cfg}")"
    share="$(yq -r '.resources["storage-account"].volume.fileshare // ""' "${cfg}")"
    mount="$(yq -r '.resources["storage-account"].volume.mount-path // "/app/backend/data"' "${cfg}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s' "${st}" "${rep}" "${kind}" "${vol}" "${share}" "${mount}"
    return 0
  fi

  ensure_devops_python || return 1
  "${DEVOPS_PY[@]}" - "$(python_path "${cfg}")" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit(1)
data = yaml.safe_load(Path(sys.argv[1]).read_text()) or {}
st = (data.get("resources") or {}).get("storage-account") or {}
vol = st.get("volume") or {}

def cell(v, default=""):
    if v is None or v == "":
        return str(default).strip().replace("\t", " ")
    return str(v).strip().replace("\t", " ")

print(
    f"{cell(st.get('name'))}\t{cell(st.get('replication'), 'LRS')}\t"
    f"{cell(st.get('kind'), 'StorageV2')}\t{cell(vol.get('name'), 'volsmb')}\t"
    f"{cell(vol.get('fileshare'))}\t{cell(vol.get('mount-path'), '/app/backend/data')}"
)
PY
}

resolve_storage_account_name() {
  local root="$1" client="$2" location="$3" local_name
  IFS=$'\t' read -r local_name _ _ _ _ _ < <(read_storage_row "${root}")
  build_azure_storage_account_name "${local_name//$'\r'/}" "${client}" "${location}"
}

resolve_storage_volume_link_name() {
  local root="$1" client="$2" location="$3" vol_local
  IFS=$'\t' read -r _ _ _ vol_local _ _ < <(read_storage_row "${root}")
  build_azure_resource_name "${vol_local//$'\r'/}" "${client}" "${location}" 64
}

require_storage_file_share() {
  local rg="$1" account="$2" share="$3"
  if ! run_az storage share show --account-name "${account}" --name "${share}" >/dev/null 2>&1; then
    echo "ERROR: file share \"${share}\" not found on \"${account}\". Run Storage/create_storage.sh first." >&2
    return 1
  fi
}

get_storage_account_key() {
  local rg="$1" account="$2"
  local key
  key="$(run_az storage account keys list \
    --resource-group "${rg}" \
    --account-name "${account}" \
    --query '[0].value' -o tsv 2>/dev/null || true)"
  key="${key//$'\r'/}"
  if [[ -z "${key}" || "${key}" == "null" ]]; then
    echo "ERROR: could not read storage key for \"${account}\"." >&2
    return 1
  fi
  printf '%s' "${key}"
}
