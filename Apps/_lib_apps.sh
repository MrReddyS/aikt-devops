#!/usr/bin/env bash
# Shared helpers for Apps/*.sh — sources repo-wide YAML helpers from Resource_Group.

set -euo pipefail

_APPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_APPS_LIB_DIR}/../Resource_Group/_lib_config.sh"

# Default public images (override via project.container_apps in config.yaml)
readonly DEFAULT_DOCLING_IMAGE="quay.io/docling-project/docling-serve:latest"
readonly DEFAULT_OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"

# Resolves Container Apps environment name: resources.container-app-environment.name
# expanded as {local}-{client}-{location-suffix}, else {client-prefix}-cae.
resolve_cae_name() {
  local root="$1"
  local client="$2"
  local location="$3"
  local cfg="${root}/config.yaml"
  local local_name override prefix

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local_name="$(yq -r '.resources.container-app-environment.name // ""' "${cfg}")"
    override="$(yq -r '(.project.container_apps // {}) | .environment_name // ""' "${cfg}")"
  else
    ensure_devops_python || return 1
    read -r local_name override < <("${DEVOPS_PY[@]}" - "${cfg}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.exit(1)
data = yaml.safe_load(Path(sys.argv[1]).read_text()) or {}
resources = data.get("resources") or {}
cae = resources.get("container-app-environment") or {}
proj = data.get("project") or {}
ca = proj.get("container_apps") or {}
print(str(cae.get("name") or "").strip(), str(ca.get("environment_name") or "").strip())
PY
)
  fi

  local_name="${local_name//$'\r'/}"
  override="${override//$'\r'/}"

  if [[ -n "${override}" && "${override}" != "null" ]]; then
    echo "${override}"
    return 0
  fi
  if [[ -n "${local_name}" && "${local_name}" != "null" ]]; then
    build_azure_resource_name "${local_name}" "${client}" "${location}" 40
    return 0
  fi

  prefix="$(sanitize_azure_name_segment "${client}" 20)"
  echo "${prefix}-cae"
}

# Prints one line: client<TAB>environment_name_override<TAB>docling_image<TAB>openwebui_image
# Empty fields mean "use defaults" (except client must be set for naming).
read_container_apps_project_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if [[ ! -f "${cfg}" ]]; then
    echo "ERROR: missing ${cfg}" >&2
    return 1
  fi

  if command -v yq >/dev/null 2>&1; then
    local c env doc ow
    c="$(yq -r '.project.client // ""' "${cfg}")"
    env="$(yq -r '(.project.container_apps // {}) | .environment_name // ""' "${cfg}")"
    doc="$(yq -r '(.project.container_apps // {}) | .docling_image // ""' "${cfg}")"
    ow="$(yq -r '(.project.container_apps // {}) | .openwebui_image // ""' "${cfg}")"
    printf '%s\t%s\t%s\t%s' "${c}" "${env}" "${doc}" "${ow}"
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
ca = proj.get("container_apps") or {}
if not isinstance(ca, dict):
    ca = {}
client = str(proj.get("client") or "").strip().replace("\t", " ")
envn = str(ca.get("environment_name") or "").strip().replace("\t", " ")
doc = str(ca.get("docling_image") or "").strip().replace("\t", " ")
ow = str(ca.get("openwebui_image") or "").strip().replace("\t", " ")
print(f"{client}\t{envn}\t{doc}\t{ow}")
PY
}
