#!/usr/bin/env bash
# Shared helpers for Network/*.sh and Gateway/*.sh — sources repo-wide YAML helpers.

set -euo pipefail

_NETWORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_NETWORK_LIB_DIR}/../Resource_Group/_lib_config.sh"

require_vnet() {
  local rg="$1"
  local vnet="$2"
  if ! run_az network vnet show --resource-group "${rg}" --name "${vnet}" >/dev/null 2>&1; then
    echo "ERROR: virtual network \"${vnet}\" does not exist. Run Network/create_vnet.sh first." >&2
    return 1
  fi
}

require_vnet_subnet() {
  local rg="$1"
  local vnet="$2"
  local subnet="$3"
  require_vnet "${rg}" "${vnet}" || return 1
  if ! run_az network vnet subnet show \
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
  run_az network vnet subnet show \
    --resource-group "${rg}" \
    --vnet-name "${vnet}" \
    --name "${subnet}" \
    --query id -o tsv
}

# Prints the subnet addressPrefix from Azure (e.g. 10.0.3.0/24).
read_subnet_address_prefix() {
  local rg="$1"
  local vnet="$2"
  local subnet="$3"
  local prefix
  prefix="$(run_az network vnet subnet show \
    --resource-group "${rg}" \
    --vnet-name "${vnet}" \
    --name "${subnet}" \
    --query addressPrefix -o tsv 2>/dev/null || true)"
  prefix="${prefix//$'\r'/}"
  if [[ -z "${prefix}" || "${prefix}" == "null" ]]; then
    echo "ERROR: could not read address prefix for subnet \"${subnet}\"." >&2
    return 1
  fi
  printf '%s' "${prefix}"
}

# Prints one line: openwebui_subnet_local<TAB>openwebui_subnet_prefix
read_openwebui_subnet_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local asn asp
    asn="$(yq -r '.resources.vnet.subnets.openwebui.name // ""' "${cfg}")"
    asp="$(yq -r '.resources.vnet.subnets.openwebui.prefix // ""' "${cfg}")"
    printf '%s\t%s' "${asn}" "${asp}"
    return 0
  fi

  ensure_devops_python || return 1
  "${DEVOPS_PY[@]}" - "$(python_path "${cfg}")" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    print("ERROR: install yq or pip install pyyaml", file=sys.stderr)
    sys.exit(1)
path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or {}
subnets = ((data.get("resources") or {}).get("vnet") or {}).get("subnets") or {}
ow = subnets.get("openwebui") or {}

def cell(v):
    return str(v or "").strip().replace("\t", " ")

print(f"{cell(ow.get('name'))}\t{cell(ow.get('prefix'))}")
PY
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
    csn="$(yq -r '.resources.vnet.subnets["container-apps"].name // ""' "${cfg}")"
    csp="$(yq -r '.resources.vnet.subnets["container-apps"].prefix // ""' "${cfg}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s' "${vn}" "${vp}" "${asn}" "${asp}" "${csn}" "${csp}"
    return 0
  fi

  ensure_devops_python || return 1
  "${DEVOPS_PY[@]}" - "$(python_path "${cfg}")" <<'PY'
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

# Prints one line: enabled (true/false)
read_app_gateway_enabled() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    yq -r '.resources["app-gateway"].enabled // false' "${cfg}"
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
agw = (data.get("resources") or {}).get("app-gateway") or {}
print("true" if agw.get("enabled") else "false")
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
  "${DEVOPS_PY[@]}" - "$(python_path "${cfg}")" <<'PY'
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
