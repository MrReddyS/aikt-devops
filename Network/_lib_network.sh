#!/usr/bin/env bash
# Shared helpers for Network/*.sh and Gateway/*.sh — sources repo-wide YAML helpers.

set -euo pipefail

_NETWORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${NETWORK_LIB_DIR}/../Resource_Group/_lib_config.sh"

# Exit 1 if the resource group does not exist in the current subscription context.
require_resource_group() {
  local rg="$1"
  if ! az group show --name "${rg}" >/dev/null 2>&1; then
    echo "ERROR: resource group \"${rg}\" does not exist. Run Resource_Group/create_rg.sh first." >&2
    return 1
  fi
}

require_vnet() {
  local rg="$1"
  local vnet="$2"
  if ! az network vnet show --resource-group "${rg}" --name "${vnet}" >/dev/null 2>&1; then
    echo "ERROR: virtual network \"${vnet}\" does not exist. Run Network/create_vnet.sh first." >&2
    return 1
  fi
}

require_vnet_subnet() {
  local rg="$1"
  local vnet="$2"
  local subnet="$3"
  require_vnet "${rg}" "${vnet}" || return 1
  if ! az network vnet subnet show \
    --resource-group "${rg}" \
    --vnet-name "${vnet}" \
    --name "${subnet}" >/dev/null 2>&1; then
    echo "ERROR: subnet \"${subnet}\" not found in VNet \"${vnet}\". Run Network/create_vnet.sh first." >&2
    return 1
  fi
}

resolve_subnet_resource_id() {
  local rg="$1"
  local vnet="$2"
  local subnet="$3"
  az network vnet subnet show \
    --resource-group "${rg}" \
    --vnet-name "${vnet}" \
    --name "${subnet}" \
    --query id -o tsv
}

# Prints one line (local names from config):
# vnet_local<TAB>vnet_prefix<TAB>agw_subnet_local<TAB>agw_subnet_prefix<TAB>cae_subnet_local<TAB>cae_subnet_prefix
read_vnet_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local vn vp asn asp csn csp
    vn="$(yq -r '.resources.vnet.name // ""' "${cfg}")"
    vp="$(yq -r '.resources.vnet.address-prefix // ""' "${cfg}")"
    asn="$(yq -r '.resources.vnet.subnets.app-gateway.name // ""' "${cfg}")"
    asp="$(yq -r '.resources.vnet.subnets.app-gateway.prefix // ""' "${cfg}")"
    csn="$(yq -r '.resources.vnet.subnets.container-apps.name // ""' "${cfg}")"
    csp="$(yq -r '.resources.vnet.subnets.container-apps.prefix // ""' "${cfg}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s' "${vn}" "${vp}" "${asn}" "${asp}" "${csn}" "${csp}"
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
vnet = resources.get("vnet") or {}
if not isinstance(vnet, dict):
    vnet = {}
subnets = vnet.get("subnets") or {}
if not isinstance(subnets, dict):
    subnets = {}
agw = subnets.get("app-gateway") or {}
cae = subnets.get("container-apps") or {}
if not isinstance(agw, dict):
    agw = {}
if not isinstance(cae, dict):
    cae = {}

def cell(v):
    return str(v or "").strip().replace("\t", " ")

print(
    f"{cell(vnet.get('name'))}\t{cell(vnet.get('address-prefix'))}\t"
    f"{cell(agw.get('name'))}\t{cell(agw.get('prefix'))}\t"
    f"{cell(cae.get('name'))}\t{cell(cae.get('prefix'))}"
)
PY
}

# Prints one line (local names from config):
# gw_name<TAB>sku<TAB>capacity<TAB>pip_name
read_app_gateway_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local gn sk cap pip
    gn="$(yq -r '.resources.app-gateway.name // ""' "${cfg}")"
    sk="$(yq -r '.resources.app-gateway.sku // "Standard_v2"' "${cfg}")"
    cap="$(yq -r '.resources.app-gateway.capacity // 1' "${cfg}")"
    pip="$(yq -r '.resources.app-gateway.public-ip.name // ""' "${cfg}")"
    printf '%s\t%s\t%s\t%s' "${gn}" "${sk}" "${cap}" "${pip}"
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
agw = resources.get("app-gateway") or {}
if not isinstance(agw, dict):
    agw = {}
pip = agw.get("public-ip") or {}
if not isinstance(pip, dict):
    pip = {}

def cell(v):
    return str(v or "").strip().replace("\t", " ")

print(
    f"{cell(agw.get('name'))}\t"
    f"{cell(agw.get('sku') or 'Standard_v2')}\t"
    f"{cell(agw.get('capacity') or 1)}\t"
    f"{cell(pip.get('name'))}"
)
PY
}
