#!/usr/bin/env bash
# Shared helpers for Storage/*.sh — sources repo-wide YAML helpers.

set -euo pipefail

_STORAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${STORAGE_LIB_DIR}/../Resource_Group/_lib_config.sh"

# Prints one line (local names from config):
# sa_local<TAB>replication<TAB>kind<TAB>volume_name<TAB>fileshare<TAB>mount_path<TAB>mount_options
read_storage_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local sa rep kind vol share mp mo
    sa="$(yq -r '.resources.storage-account.name // ""' "${cfg}")"
    rep="$(yq -r '.resources.storage-account.replication // "LRS"' "${cfg}")"
    kind="$(yq -r '.resources.storage-account.kind // "StorageV2"' "${cfg}")"
    vol="$(yq -r '.resources.storage-account.volume.name // ""' "${cfg}")"
    share="$(yq -r '.resources.storage-account.volume.fileshare // ""' "${cfg}")"
    mp="$(yq -r '.resources.storage-account.volume.mount-path // "/app/backend/data"' "${cfg}")"
    mo="$(yq -r '.resources.storage-account.volume.mount-options // "nobrl"' "${cfg}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${sa}" "${rep}" "${kind}" "${vol}" "${share}" "${mp}" "${mo}"
    return 0
  fi

  ensure_devops_python || return 1
  "${DEVOPS_PY[@]}" - "${cfg}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    print("ERROR: install yq or pip install pyyaml", file=sys.stderr)
    sys.exit(1)
path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or {}
resources = data.get("resources") or {}
if not isinstance(resources, dict):
    resources = {}
sa = resources.get("storage-account") or {}
if not isinstance(sa, dict):
    sa = {}
vol = sa.get("volume") or {}
if not isinstance(vol, dict):
    vol = {}

def cell(v):
    return str(v or "").strip().replace("\t", " ")

print(
    f"{cell(sa.get('name'))}\t"
    f"{cell(sa.get('replication') or 'LRS')}\t"
    f"{cell(sa.get('kind') or 'StorageV2')}\t"
    f"{cell(vol.get('name'))}\t"
    f"{cell(vol.get('fileshare'))}\t"
    f"{cell(vol.get('mount-path') or '/app/backend/data')}\t"
    f"{cell(vol.get('mount-options') or 'nobrl')}"
)
PY
}

resolve_storage_account_name() {
  local root="$1"
  local client="$2"
  local location="$3"
  local sa_local
  sa_local="$(read_storage_row "${root}" | cut -f1)"
  sa_local="${sa_local//$'\r'/}"
  build_azure_storage_account_name "${sa_local}" "${client}" "${location}"
}

require_storage_account() {
  local rg="$1"
  local account="$2"
  if ! az storage account show --resource-group "${rg}" --name "${account}" >/dev/null 2>&1; then
    echo "ERROR: storage account \"${account}\" does not exist. Run Storage/create_storage.sh first." >&2
    return 1
  fi
}

require_storage_file_share() {
  local rg="$1"
  local account="$2"
  local share="$3"
  require_storage_account "${rg}" "${account}" || return 1
  if ! az storage share-rm show \
    --resource-group "${rg}" \
    --storage-account "${account}" \
    --name "${share}" >/dev/null 2>&1; then
    echo "ERROR: file share \"${share}\" not found on storage account \"${account}\". Run Storage/create_storage.sh first." >&2
    return 1
  fi
}

# Links an Azure Files share to a Container Apps environment (idempotent).
ensure_cae_azure_file_storage() {
  local rg="$1"
  local cae="$2"
  local storage_link_name="$3"
  local account="$4"
  local share="$5"

  if az containerapp env storage show \
    --resource-group "${rg}" \
    --name "${cae}" \
    --storage-name "${storage_link_name}" >/dev/null 2>&1; then
    echo "CAE storage link ${storage_link_name} already exists (skip)."
    return 0
  fi

  local key
  key="$(az storage account keys list --resource-group "${rg}" --account-name "${account}" --query "[0].value" -o tsv)"
  if [[ -z "${key}" || "${key}" == "null" ]]; then
    echo "ERROR: could not read access key for storage account \"${account}\"." >&2
    return 1
  fi

  echo "Linking file share ${share} to Container Apps environment as ${storage_link_name}..."
  az containerapp env storage set \
    --resource-group "${rg}" \
    --name "${cae}" \
    --access-mode ReadWrite \
    --storage-name "${storage_link_name}" \
    --azure-file-account-name "${account}" \
    --azure-file-account-key "${key}" \
    --azure-file-share-name "${share}"
}
