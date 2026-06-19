#!/usr/bin/env bash
# Shared helpers for Apps/*.sh — Azure Container Apps (Open WebUI + Docling).

set -euo pipefail

_APPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_APPS_LIB_DIR}/../Resource_Group/_lib_config.sh"

readonly DEFAULT_OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.9.6"
readonly DEFAULT_DOCLING_IMAGE="quay.io/docling-project/docling-serve:latest"
readonly DEFAULT_OPENWEBUI_PORT="8080"
readonly DEFAULT_DOCLING_PORT="5001"
readonly DEFAULT_OWUI_CPU="2"
readonly DEFAULT_OWUI_MEMORY="8Gi"
readonly DEFAULT_DOC_CPU="4"
readonly DEFAULT_DOC_MEMORY="16Gi"
readonly DEFAULT_DOC_WORKLOAD_PROFILE="D4"
readonly OPENWEBUI_DATA_MOUNT="/app/backend/data"
readonly OPENWEBUI_AZUREFILE_MOUNT_OPTIONS="nobrl"

ensure_containerapp_extension() {
  if ! az extension show --name containerapp >/dev/null 2>&1; then
    echo "Installing Azure CLI containerapp extension..."
    run_az extension add --name containerapp --upgrade
  fi
}

# env_local<TAB>ow_name<TAB>ow_cpu<TAB>ow_mem<TAB>ow_image<TAB>ow_port<TAB>
# doc_name<TAB>doc_cpu<TAB>doc_mem<TAB>doc_profile<TAB>doc_image<TAB>doc_port
read_container_apps_row() {
  local root="$1"
  local cfg="${root}/config.yaml"

  if command -v yq >/dev/null 2>&1; then
    local env ow doc
    env="$(yq -r '.resources["container-apps"].environment.name // "cae"' "${cfg}")"
    ow="$(yq -r '.resources["container-apps"].apps.openwebui.name // "ca-openwebui"' "${cfg}")"
    local owcpu owmem owimg owport
    owcpu="$(yq -r '.resources["container-apps"].apps.openwebui.cpu // 2' "${cfg}")"
    owmem="$(yq -r '.resources["container-apps"].apps.openwebui.memory // "8Gi"' "${cfg}")"
    owimg="$(yq -r '.resources["container-apps"].apps.openwebui.image // ""' "${cfg}")"
    owport="$(yq -r '.resources["container-apps"].apps.openwebui.port // 8080' "${cfg}")"
    doc="$(yq -r '.resources["container-apps"].apps.docling.name // "ca-docling"' "${cfg}")"
    local dcpu dmem dprof dimg dport
    dcpu="$(yq -r '.resources["container-apps"].apps.docling.cpu // 4' "${cfg}")"
    dmem="$(yq -r '.resources["container-apps"].apps.docling.memory // "16Gi"' "${cfg}")"
    dprof="$(yq -r '.resources["container-apps"].apps.docling.workload-profile // "D4"' "${cfg}")"
    dimg="$(yq -r '.resources["container-apps"].apps.docling.image // ""' "${cfg}")"
    dport="$(yq -r '.resources["container-apps"].apps.docling.port // 5001' "${cfg}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "${env}" "${ow}" "${owcpu}" "${owmem}" "${owimg}" "${owport}" \
      "${doc}" "${dcpu}" "${dmem}" "${dprof}" "${dimg}" "${dport}"
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
ca = (data.get("resources") or {}).get("container-apps") or {}
env = ca.get("environment") or {}
apps = ca.get("apps") or {}
ow = apps.get("openwebui") or {}
doc = apps.get("docling") or {}

def cell(v, default=""):
    if v is None or v == "":
        return str(default).strip().replace("\t", " ")
    return str(v).strip().replace("\t", " ")

print(
    f"{cell(env.get('name'), 'cae')}\t"
    f"{cell(ow.get('name'), 'ca-openwebui')}\t{cell(ow.get('cpu'), 2)}\t"
    f"{cell(ow.get('memory'), '8Gi')}\t{cell(ow.get('image'))}\t{cell(ow.get('port'), 8080)}\t"
    f"{cell(doc.get('name'), 'ca-docling')}\t{cell(doc.get('cpu'), 4)}\t"
    f"{cell(doc.get('memory'), '16Gi')}\t{cell(doc.get('workload-profile'), 'D4')}\t"
    f"{cell(doc.get('image'))}\t{cell(doc.get('port'), 5001)}"
)
PY
}

read_docling_env_row() {
  local root="$1"
  local cfg="${root}/config.yaml"
  if command -v yq >/dev/null 2>&1; then
    printf '%s\t%s' \
      "$(yq -r '.resources.docling["uvicorn-workers"] // 1' "${cfg}")" \
      "$(yq -r '.resources.docling["max-sync-wait"] // 220' "${cfg}")"
    return 0
  fi
  ensure_devops_python || return 1
  "${DEVOPS_PY[@]}" - "$(python_path "${cfg}")" <<'PY'
import sys
from pathlib import Path
import yaml
doc = (yaml.safe_load(Path(sys.argv[1]).read_text()) or {}).get("resources", {}).get("docling") or {}
print(f"{doc.get('uvicorn-workers', 1)}\t{doc.get('max-sync-wait', 220)}")
PY
}

resolve_cae_name() {
  local local_name="$1" client="$2" location="$3"
  build_azure_resource_name "${local_name}" "${client}" "${location}" 32
}

resolve_container_app_name() {
  local local_name="$1" client="$2" location="$3"
  build_azure_resource_name "${local_name}" "${client}" "${location}" 32
}

generate_webui_secret_key() {
  local secret=""
  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -hex 32)"
  fi
  if [[ -z "${secret}" ]]; then
    echo "ERROR: openssl required to generate WEBUI_SECRET_KEY." >&2
    return 1
  fi
  printf '%s' "${secret}"
}

ensure_container_apps_environment() {
  local rg="$1" env="$2" location="$3" subnet_id="$4" doc_profile="$5"

  if run_az containerapp env show -g "${rg}" -n "${env}" >/dev/null 2>&1; then
    echo "Container Apps environment ${env} already exists."
  else
    echo "Creating Container Apps environment ${env}..."
    run_az containerapp env create \
      --resource-group "${rg}" \
      --name "${env}" \
      --location "${location}" \
      --infrastructure-subnet-resource-id "${subnet_id}" \
      --enable-workload-profiles >/dev/null
  fi

  if run_az containerapp env workload-profile list -g "${rg}" -n "${env}" \
    --query "[?name=='${doc_profile}'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
    echo "Workload profile ${doc_profile} already exists on ${env}."
  else
    echo "Adding workload profile ${doc_profile} to ${env}..."
    run_az containerapp env workload-profile add \
      --resource-group "${rg}" \
      --name "${env}" \
      --workload-profile-name "${doc_profile}" \
      --workload-profile-type "${doc_profile}" \
      --min-nodes 1 \
      --max-nodes 3 >/dev/null
  fi
}

ensure_cae_storage_volume() {
  local rg="$1" env="$2" storage_name="$3" account="$4" share="$5" account_key="$6"

  if run_az containerapp env storage show -g "${rg}" -n "${env}" --storage-name "${storage_name}" >/dev/null 2>&1; then
    echo "CAE storage ${storage_name} already registered."
    return 0
  fi
  echo "Registering Azure Files volume ${storage_name} on environment..."
  run_az containerapp env storage set \
    --resource-group "${rg}" \
    --name "${env}" \
    --storage-name "${storage_name}" \
    --azure-file-account-name "${account}" \
    --azure-file-account-key "${account_key}" \
    --azure-file-share-name "${share}" \
    --access-mode ReadWrite >/dev/null
}

ensure_docling_container_app() {
  local rg="$1" env="$2" app="$3" image="$4" port="$5" cpu="$6" memory="$7" profile="$8"
  local workers="$9" max_wait="${10}"

  if run_az containerapp show -g "${rg}" -n "${app}" >/dev/null 2>&1; then
    echo "Container app ${app} already exists; updating..."
    run_az containerapp update \
      --resource-group "${rg}" \
      --name "${app}" \
      --image "${image}" \
      --cpu "${cpu}" \
      --memory "${memory}" \
      --workload-profile-name "${profile}" \
      --set-env-vars \
        "UVICORN_WORKERS=${workers}" \
        "DOCLING_SERVE_MAX_SYNC_WAIT=${max_wait}" \
      --min-replicas 1 \
      --max-replicas 1 >/dev/null
    return 0
  fi

  echo "Creating Docling container app ${app} (${cpu} CPU, ${memory}, profile ${profile})..."
  run_az containerapp create \
    --resource-group "${rg}" \
    --name "${app}" \
    --environment "${env}" \
    --image "${image}" \
    --cpu "${cpu}" \
    --memory "${memory}" \
    --workload-profile-name "${profile}" \
    --target-port "${port}" \
    --ingress internal \
    --transport http \
    --allow-insecure \
    --env-vars \
      "UVICORN_WORKERS=${workers}" \
      "DOCLING_SERVE_MAX_SYNC_WAIT=${max_wait}" \
    --min-replicas 1 \
    --max-replicas 1 >/dev/null
}

write_openwebui_app_yaml() {
  local yaml_file="$1" rg="$2" env="$3" app="$4" image="$5" port="$6"
  local cpu="$7" memory="$8" mount_path="$9" storage_vol="${10}" secret="${11}" docling_url="${12}"

  local env_id
  env_id="$(run_az containerapp env show -g "${rg}" -n "${env}" --query id -o tsv)"
  env_id="$(strip_cr "${env_id}")"

  cat >"${yaml_file}" <<YAML
properties:
  managedEnvironmentId: ${env_id}
  configuration:
    ingress:
      external: true
      targetPort: ${port}
      transport: http
      allowInsecure: true
  template:
    containers:
    - name: openwebui
      image: ${image}
      resources:
        cpu: ${cpu}
        memory: ${memory}
      env:
      - name: WEBUI_SECRET_KEY
        value: "${secret}"
      - name: WEBUI_AUTH
        value: "true"
      - name: ENABLE_WEBSOCKET_SUPPORT
        value: "false"
      - name: DOCLING_SERVER_URL
        value: "${docling_url}"
      volumeMounts:
      - volumeName: data
        mountPath: ${mount_path}
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: data
      storageType: AzureFile
      storageName: ${storage_vol}
      mountOptions: ${OPENWEBUI_AZUREFILE_MOUNT_OPTIONS}
YAML
}

ensure_openwebui_container_app() {
  local rg="$1" env="$2" app="$3" image="$4" port="$5" cpu="$6" memory="$7"
  local mount_path="$8" storage_vol="$9" secret="${10}" docling_url="${11}"

  local yaml_file yaml_for_az
  yaml_file="$(mktemp "${TMPDIR:-/tmp}/owui-ca.XXXXXX.yaml")"
  yaml_for_az="$(python_path "${yaml_file}")"

  write_openwebui_app_yaml \
    "${yaml_file}" "${rg}" "${env}" "${app}" "${image}" "${port}" \
    "${cpu}" "${memory}" "${mount_path}" "${storage_vol}" "${secret}" "${docling_url}"

  if run_az containerapp show -g "${rg}" -n "${app}" >/dev/null 2>&1; then
    echo "Container app ${app} already exists; updating..."
    run_az containerapp update \
      --resource-group "${rg}" \
      --name "${app}" \
      --yaml "${yaml_for_az}" >/dev/null
  else
    echo "Creating Open WebUI container app ${app} (${cpu} CPU, ${memory})..."
    run_az containerapp create \
      --resource-group "${rg}" \
      --name "${app}" \
      --yaml "${yaml_for_az}" >/dev/null
  fi

  rm -f "${yaml_file}"
}

container_app_ingress_fqdn() {
  local rg="$1" app="$2"
  local fqdn
  fqdn="$(run_az containerapp show -g "${rg}" -n "${app}" \
    --query properties.configuration.ingress.fqdn -o tsv 2>/dev/null || true)"
  fqdn="${fqdn//$'\r'/}"
  if [[ -z "${fqdn}" || "${fqdn}" == "null" ]]; then
    echo "ERROR: no ingress FQDN for container app \"${app}\"." >&2
    return 1
  fi
  printf 'http://%s' "${fqdn}"
}
