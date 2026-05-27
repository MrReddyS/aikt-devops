#!/usr/bin/env bash
# Sourced by create/delete RG scripts. Resolves repo root (config.yaml) and reads profile fields.

set -euo pipefail

# Command prefix to run Python with PyYAML, e.g. (python3) or (py -3). Set by ensure_devops_python.
declare -a DEVOPS_PY=()

_is_windowsapps_python_alias() {
  local p
  p="$(command -v "$1" 2>/dev/null)" || return 1
  case "${p}" in
    *[Ww]indows[Aa]pps* | *[Mm]icrosoft/[Ww]indowsApps/*) return 0 ;;
    *) return 1 ;;
  esac
}

_try_devops_python_bin() {
  local bin="$1"
  command -v "${bin}" >/dev/null 2>&1 || return 1
  if _is_windowsapps_python_alias "${bin}"; then
    return 1
  fi
  "${bin}" -c "import yaml" >/dev/null 2>&1 || return 1
  DEVOPS_PY=("${bin}")
  return 0
}

_try_devops_py_launcher() {
  command -v py >/dev/null 2>&1 || return 1
  py -3 -c "import yaml" >/dev/null 2>&1 || return 1
  DEVOPS_PY=(py -3)
  return 0
}

# Ensures DEVOPS_PY is set to a working Python that can import yaml.
ensure_devops_python() {
  if [[ ${#DEVOPS_PY[@]} -gt 0 ]]; then
    return 0
  fi
  if _try_devops_python_bin python3; then return 0; fi
  if _try_devops_python_bin python; then return 0; fi
  if _try_devops_py_launcher; then return 0; fi
  echo "ERROR: need yq (https://github.com/mikefarah/yq), or Python 3 with PyYAML." >&2
  echo "  Windows: install Python from https://www.python.org/downloads/ (check 'Add to PATH'), then: py -3 -m pip install pyyaml" >&2
  echo "  Or install yq and omit Python." >&2
  return 1
}

# Git Bash on Windows rewrites /subscriptions/... CLI args to C:/Program Files/Git/...
# Use this wrapper for any az command that passes Azure resource IDs as arguments.
run_az() {
  MSYS_NO_PATHCONV=1 az "$@"
}

# Lowercase [a-z0-9-], collapse repeats, trim hyphens; then cut for Azure name length limits.
sanitize_azure_name_segment() {
  local s="${1:-}"
  s="$(echo "${s}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-\|-$//g')"
  echo "${s}" | cut -c1-"${2:-20}"
}

# westeurope -> westeu, northeurope -> northeu; other regions are sanitized and truncated.
azure_location_suffix() {
  local loc
  loc="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
  if [[ "${loc}" == *europe ]]; then
    echo "${loc%europe}eu"
  else
    echo "${loc}" | cut -c1-12
  fi
}

# Builds Azure resource name: {local}-{client}-{location-suffix}, e.g. vnet-test-westeu.
build_azure_resource_name() {
  local local_name="${1:-}"
  local client="${2:-}"
  local location="${3:-}"
  local max_len="${4:-64}"
  local loc_suffix client_seg local_seg

  loc_suffix="$(azure_location_suffix "${location}")"
  client_seg="$(sanitize_azure_name_segment "${client}" 20)"
  local_seg="$(sanitize_azure_name_segment "${local_name}" 40)"

  if [[ -z "${local_seg}" || -z "${client_seg}" || -z "${loc_suffix}" ]]; then
    echo "ERROR: cannot build resource name from local=${local_name} client=${client} location=${location}" >&2
    return 1
  fi

  echo "${local_seg}-${client_seg}-${loc_suffix}" | cut -c1-"${max_len}"
}

# Storage accounts: lowercase alphanumeric only, 3-24 chars, globally unique.
# Concatenates {local}{client}{location-suffix}, e.g. staccount + test + westeu -> staccounttestwesteu.
build_azure_storage_account_name() {
  local local_name="${1:-}"
  local client="${2:-}"
  local location="${3:-}"
  local loc_suffix client_seg local_seg combined

  loc_suffix="$(azure_location_suffix "${location}" | tr -cd 'a-z0-9')"
  client_seg="$(sanitize_azure_name_segment "${client}" 10 | tr -cd 'a-z0-9')"
  local_seg="$(sanitize_azure_name_segment "${local_name}" 12 | tr -cd 'a-z0-9')"
  combined="${local_seg}${client_seg}${loc_suffix}"
  combined="$(echo "${combined}" | tr -cd 'a-z0-9' | cut -c1-24)"

  if [[ ${#combined} -lt 3 ]]; then
    echo "ERROR: storage account name too short from local=${local_name} client=${client} location=${location}" >&2
    return 1
  fi
  echo "${combined}"
}

# Usage: require_config_fields label1 value1 label2 value2 ...
require_config_fields() {
  local label value
  while [[ $# -gt 0 ]]; do
    label="${1:-}"
    value="${2:-}"
    if [[ $# -lt 2 ]]; then
      echo "ERROR: require_config_fields: missing value for ${label}" >&2
      return 1
    fi
    shift 2
    if [[ -z "${value}" || "${value}" == "null" ]]; then
      echo "ERROR: ${label} must be set in config.yaml" >&2
      return 1
    fi
  done
}

# Prints project.client (required for resource naming).
read_project_client() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    yq -r '.project.client // ""' "${cfg}"
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
proj = data.get("project") or {}
if not isinstance(proj, dict):
    proj = {}
print(str(proj.get("client") or "").strip())
PY
}

# Pass the directory of the script that invoked you (e.g. SCRIPT_DIR from create_rg.sh).
find_repo_root_from() {
  local dir
  dir="$(cd "$1" && pwd)"
  while [[ "${dir}" != "/" ]]; do
    if [[ -f "${dir}/config.yaml" ]]; then
      echo "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  echo "ERROR: config.yaml not found in any parent of $1" >&2
  return 1
}

# Prints the subscription profile key to use. explicit may be empty.
# Order: non-empty explicit -> defaults.profile -> single subscriptions.* key; else error.
resolve_profile_name() {
  local root="$1"
  local explicit="$2"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if [[ -n "${explicit}" ]]; then
    if command -v yq >/dev/null 2>&1; then
      local tid
      tid="$(yq -r ".subscriptions[\"${explicit}\"].tenant_id // \"\"" "${cfg}")"
      if [[ -z "${tid}" || "${tid}" == "null" ]]; then
        echo "ERROR: unknown or incomplete profile \"${explicit}\" under subscriptions in ${cfg}" >&2
        return 1
      fi
    elif ensure_devops_python; then
      "${DEVOPS_PY[@]}" - "${cfg}" "${explicit}" <<'PY' >/dev/null || return 1
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    print("ERROR: install yq or pip install pyyaml", file=sys.stderr)
    sys.exit(1)
cfg_path, name = Path(sys.argv[1]), sys.argv[2]
data = yaml.safe_load(cfg_path.read_text()) or {}
subs = data.get("subscriptions") or {}
if name not in subs or not (subs.get(name) or {}).get("tenant_id"):
    print(f"ERROR: unknown or incomplete profile {name!r} under subscriptions in {cfg_path}", file=sys.stderr)
    sys.exit(1)
PY
    else
      echo "ERROR: need yq or Python with PyYAML to validate --profile" >&2
      return 1
    fi
    echo "${explicit}"
    return 0
  fi

  if command -v yq >/dev/null 2>&1; then
    local def
    def="$(yq -r '.defaults.profile // ""' "${cfg}")"
    if [[ -n "${def}" && "${def}" != "null" ]]; then
      local tid
      tid="$(yq -r ".subscriptions[\"${def}\"].tenant_id // \"\"" "${cfg}")"
      if [[ -z "${tid}" || "${tid}" == "null" ]]; then
        echo "ERROR: defaults.profile \"${def}\" has no matching subscriptions.${def} in ${cfg}" >&2
        return 1
      fi
      echo "${def}"
      return 0
    fi
    local -a keys=()
    mapfile -t keys < <(yq -r '.subscriptions | keys | .[]' "${cfg}")
    if [[ ${#keys[@]} -eq 1 ]]; then
      echo "${keys[0]}"
      return 0
    fi
    if [[ ${#keys[@]} -eq 0 ]]; then
      echo "ERROR: no subscriptions.* entries in ${cfg}" >&2
      return 1
    fi
    echo "ERROR: specify --profile or set defaults.profile (multiple subscriptions in ${cfg}: ${keys[*]})" >&2
    return 1
  fi

  if ensure_devops_python; then
    "${DEVOPS_PY[@]}" - "${cfg}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    print("ERROR: install yq or pip install pyyaml", file=sys.stderr)
    sys.exit(1)
cfg_path = Path(sys.argv[1])
data = yaml.safe_load(cfg_path.read_text()) or {}
subs = data.get("subscriptions") or {}
if not isinstance(subs, dict):
    subs = {}
defaults = data.get("defaults") or {}

defp = str(defaults.get("profile") or "").strip()
if defp:
    if defp not in subs or not (subs.get(defp) or {}).get("tenant_id"):
        print(f"ERROR: defaults.profile {defp!r} missing or incomplete under subscriptions in {cfg_path}", file=sys.stderr)
        sys.exit(1)
    print(defp)
    sys.exit(0)

keys = list(subs.keys())
if len(keys) == 1:
    print(keys[0])
    sys.exit(0)
if len(keys) == 0:
    print(f"ERROR: no subscriptions defined in {cfg_path}", file=sys.stderr)
    sys.exit(1)
print(f"ERROR: specify --profile or set defaults.profile ({len(keys)} subscriptions: {', '.join(keys)})", file=sys.stderr)
sys.exit(1)
PY
    return 0
  fi

  echo "ERROR: need yq or Python with PyYAML to read ${cfg}" >&2
  return 1
}

# Prints one line: "<default_rg_name><TAB><default_rg_location_override>"
# Name: defaults.resource_group.name, else project.rg
# Location override: defaults.resource_group.location, else project.location (empty if neither; caller falls back to defaults.location)
read_rg_defaults_from_config() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local n lo
    n="$(yq -r '(.defaults.resource_group // {}) | .name // ""' "${cfg}")"
    if [[ -z "${n}" || "${n}" == "null" ]]; then
      n="$(yq -r '.project.rg // ""' "${cfg}")"
    fi
    lo="$(yq -r '(.defaults.resource_group // {}) | .location // ""' "${cfg}")"
    if [[ -z "${lo}" || "${lo}" == "null" ]]; then
      lo="$(yq -r '.project.location // ""' "${cfg}")"
    fi
    printf '%s\t%s' "${n}" "${lo}"
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
defaults = data.get("defaults") or {}
rg_blk = defaults.get("resource_group") or {}
if not isinstance(rg_blk, dict):
    rg_blk = {}
proj = data.get("project") or {}
if not isinstance(proj, dict):
    proj = {}
name = str(rg_blk.get("name") or proj.get("rg") or "").strip().replace("\t", " ")
loc = str(rg_blk.get("location") or proj.get("location") or "").strip().replace("\t", " ")
print(f"{name}\t{loc}")
PY
}

# shellcheck disable=SC2034
read_subscription_profile() {
  local root="$1"
  local profile="$2"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    TENANT_ID="$(yq -r ".subscriptions[\"${profile}\"].tenant_id // \"\"" "${cfg}")"
    SUBSCRIPTION_ID="$(yq -r ".subscriptions[\"${profile}\"].subscription_id // \"\"" "${cfg}")"
    DEFAULT_LOCATION="$(yq -r ".defaults.location // \"\"" "${cfg}")"
  elif ensure_devops_python; then
    read -r TENANT_ID SUBSCRIPTION_ID DEFAULT_LOCATION < <("${DEVOPS_PY[@]}" - "${cfg}" "${profile}" <<'PY'
import sys
from pathlib import Path
cfg_path = Path(sys.argv[1])
profile = sys.argv[2]
try:
    import yaml
except ImportError:
    print("ERROR: install yq (https://github.com/mikefarah/yq) or pip install pyyaml", file=sys.stderr)
    sys.exit(1)
data = yaml.safe_load(cfg_path.read_text()) or {}
subs = data.get("subscriptions") or {}
p = subs.get(profile) or {}
defaults = data.get("defaults") or {}
tenant = p.get("tenant_id") or ""
sub = p.get("subscription_id") or ""
loc = defaults.get("location") or ""
print(tenant, sub, loc)
PY
)
  else
    echo "ERROR: need yq or Python with PyYAML to read ${cfg}" >&2
    return 1
  fi

  if [[ -z "${TENANT_ID}" || "${TENANT_ID}" == "null" ]]; then
    echo "ERROR: subscriptions.${profile}.tenant_id missing or empty in ${cfg}" >&2
    return 1
  fi
  if [[ -z "${SUBSCRIPTION_ID}" || "${SUBSCRIPTION_ID}" == "null" ]]; then
    echo "ERROR: subscriptions.${profile}.subscription_id missing or empty in ${cfg}" >&2
    return 1
  fi
}
