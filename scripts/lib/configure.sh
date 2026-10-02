#!/usr/bin/env bash
# Configure the Red Hat pull secret and Entra ID console login.
# The API is private, so this uses a short-lived jump box and then deletes it.
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-${HOME}/pull_secret.json}"
WORKDIR="$(mktemp -d)"
JUMP_CREATED=0

cleanup() {
  local status=$?
  rm -rf "${WORKDIR}"
  if [[ "${JUMP_CREATED}" == "1" ]]; then
    "${ROOT}/scripts/lib/delete-jump.sh" || echo "Jump box cleanup failed." >&2
  fi
  exit "${status}"
}
trap cleanup EXIT

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ "${AUTH_CONFIGURED:-}" == "yes" ]]; then
  echo "Pull secret and console auth are already configured"
  trap - EXIT
  rm -rf "${WORKDIR}"
  exit 0
fi

if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
  echo "Pull secret file not found: ${PULL_SECRET_FILE}" >&2
  exit 1
fi

python3 - "${PULL_SECRET_FILE}" "${WORKDIR}/pull.json" <<'PY'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
auths = json.load(open(src)).get("auths", {})
keep = {}
for name in ("registry.redhat.io", "registry.connect.redhat.com", "quay.io"):
    if name in auths:
        keep[name] = auths[name]
missing = [name for name in ("registry.redhat.io", "registry.connect.redhat.com") if name not in keep]
if missing:
    sys.exit("pull secret is missing: " + ", ".join(missing))
json.dump({"auths": keep}, open(dest, "w"))
PY

TENANT_ID="$("${AZ}" account show --query tenantId --output tsv)"
ADMIN_USER="${CLUSTER_ADMIN_USER:-$("${AZ}" account show --query user.name --output tsv)}"
CONSOLE_URL="$("${AZ}" aro hcp cluster show \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --name "${CLUSTER_NAME}" \
  --subscription "${SUBSCRIPTION_ID}" \
  --query properties.console.url --output tsv)"
CONSOLE_URL="${CONSOLE_URL%/}"

upsert_env() {
  python3 - "${ENV_FILE}" "$1" "$2" <<'PY'
import sys
from pathlib import Path
path, key, value = sys.argv[1:]
file = Path(path)
lines = file.read_text().splitlines() if file.exists() else []
out, found = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={value}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}")
file.write_text("\n".join(out) + "\n")
PY
}

create_app() {
  local display_name="$1"
  local kind="$2"
  local app_id
  app_id="$("${AZ}" ad app list --display-name "${display_name}" --query "[0].appId" --output tsv)"
  if [[ -z "${app_id}" || "${app_id}" == "null" ]]; then
    if [[ "${kind}" == "console" ]]; then
      app_id="$("${AZ}" ad app create \
        --display-name "${display_name}" \
        --sign-in-audience AzureADMyOrg \
        --web-redirect-uris "${CONSOLE_URL}/auth/callback" \
        --enable-id-token-issuance true \
        --query appId --output tsv)"
    else
      app_id="$("${AZ}" ad app create \
        --display-name "${display_name}" \
        --sign-in-audience AzureADMyOrg \
        --is-fallback-public-client true \
        --public-client-redirect-uris "http://localhost:8080" "http://127.0.0.1:8080" \
        --query appId --output tsv)"
    fi
  fi
  "${AZ}" ad sp create --id "${app_id}" --output none >/dev/null 2>&1 || true
  "${AZ}" rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications(appId='${app_id}')" \
    --headers "Content-Type=application/json" \
    --body '{"api":{"requestedAccessTokenVersion":2},"optionalClaims":{"idToken":[{"name":"email","essential":false},{"name":"preferred_username","essential":false},{"name":"upn","essential":false}]}}' \
    --output none >/dev/null
  printf '%s' "${app_id}"
}

echo "Creating Entra applications"
CONSOLE_APP_ID="$(create_app "${CLUSTER_NAME}-console" console)"
CLI_APP_ID="$(create_app "${CLUSTER_NAME}-cli" cli)"
upsert_env CONSOLE_APP_ID "${CONSOLE_APP_ID}"
upsert_env CLI_APP_ID "${CLI_APP_ID}"
upsert_env CLUSTER_ADMIN_USER "${ADMIN_USER}"
upsert_env CONSOLE_URL "${CONSOLE_URL}"

CLIENT_SECRET="$("${AZ}" ad app credential reset \
  --id "${CONSOLE_APP_ID}" \
  --display-name console \
  --years 1 \
  --query password --output tsv)"
printf '%s' "${CLIENT_SECRET}" > "${WORKDIR}/client-secret"
chmod 600 "${WORKDIR}/client-secret"

if ! "${AZ}" aro hcp cluster external-auth show \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --cluster-name "${CLUSTER_NAME}" \
  --name entra \
  --subscription "${SUBSCRIPTION_ID}" \
  --query name --output tsv >/dev/null 2>&1; then
  echo "Creating external auth entra"
  python3 - "${WORKDIR}/audiences.json" "${WORKDIR}/clients.json" "${CONSOLE_APP_ID}" "${CLI_APP_ID}" <<'PY'
import json, sys
audiences, clients, console_id, cli_id = sys.argv[1:]
json.dump([console_id, cli_id], open(audiences, "w"))
json.dump([
    {
        "client-id": console_id,
        "type": "Confidential",
        "component": {"name": "console", "auth-client-namespace": "openshift-console"},
    },
    {
        "client-id": cli_id,
        "type": "Public",
        "component": {"name": "cli", "auth-client-namespace": "openshift-console"},
    },
], open(clients, "w"))
PY
  "${AZ}" aro hcp cluster external-auth create \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --cluster-name "${CLUSTER_NAME}" \
    --name entra \
    --subscription "${SUBSCRIPTION_ID}" \
    --issuer-url "https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
    --issuer-audience "@${WORKDIR}/audiences.json" \
    --username-claim preferred_username \
    --username-prefix-policy NoPrefix \
    --clients "@${WORKDIR}/clients.json" \
    --query name --output tsv
fi

echo "Creating temporary jump box"
JUMP_CREATED=1
"${ROOT}/scripts/lib/create-jump.sh"

"${AZ}" aro hcp cluster request-credential --admin \
  --name "${CLUSTER_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --subscription "${SUBSCRIPTION_ID}" \
  --file "${WORKDIR}/kubeconfig" \
  --overwrite-existing \
  --output none

python3 - "${WORKDIR}" "${ADMIN_USER}" <<'PY'
import base64, pathlib, sys
work, admin = sys.argv[1], sys.argv[2]
root = pathlib.Path(work)
kube = root.joinpath("kubeconfig").read_text()
kube = kube[kube.find("apiVersion:"):]
pull = root.joinpath("pull.json").read_bytes()
secret = root.joinpath("client-secret").read_text().strip().encode()

def b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode()

script = f"""#!/bin/bash
set -eu
export KUBECONFIG=/root/kubeconfig
if ! command -v oc >/dev/null 2>&1; then
  curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.22/openshift-client-linux.tar.gz | tar -C /usr/local/bin -xz oc kubectl
fi
umask 077
echo {b64(kube.encode())} | base64 -d > /root/kubeconfig
echo {b64(pull)} | base64 -d > /root/pull.json
echo {b64(secret)} | base64 -d > /root/client-secret
oc wait --for=condition=Ready nodes --all --timeout=900s
oc apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: additional-pull-secret
  namespace: kube-system
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {b64(pull)}
EOF
echo "==== PULL SECRET ===="
for i in $(seq 1 30); do
  regs=$(oc get secret global-pull-secret -n kube-system -o jsonpath='{{.data.\\.dockerconfigjson}}' 2>/dev/null | base64 -d | python3 -c 'import json,sys
try:
    print(",".join(sorted(json.load(sys.stdin).get("auths",{{}}))))
except Exception:
    print("")' || true)
  echo "registries=${{regs:-none}} try=$i"
  case "$regs" in
    *registry.redhat.io*) break ;;
  esac
  sleep 10
done
oc create secret generic entra-console-openshift-console -n openshift-config --from-file=clientSecret=/root/client-secret --dry-run=client -o yaml | oc apply -f -
echo "==== RBAC ===="
oc adm policy add-cluster-role-to-user cluster-admin '{admin}'
echo "==== CONSOLE ===="
for i in $(seq 1 40); do
  available=$(oc get co console -o jsonpath='{{.status.conditions[?(@.type=="Available")].status}}' 2>/dev/null || true)
  degraded=$(oc get co console -o jsonpath='{{.status.conditions[?(@.type=="Degraded")].status}}' 2>/dev/null || true)
  echo "available=$available degraded=$degraded try=$i"
  if [ "$available" = "True" ] && [ "$degraded" = "False" ]; then
    break
  fi
  sleep 15
done
rm -f /root/kubeconfig /root/pull.json /root/client-secret
if [ "$available" != "True" ] || [ "$degraded" != "False" ]; then
  exit 1
fi
"""
path = root.joinpath("remote.sh")
path.write_text(script)
path.chmod(0o600)
PY

echo "Applying pull secret and console auth"
"${AZ}" vm run-command invoke \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --name "${CLUSTER_NAME}-jump" \
  --command-id RunShellScript \
  --scripts "@${WORKDIR}/remote.sh" \
  --query "value[0].message" \
  --output tsv

code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "${CONSOLE_URL}" || true)"
echo "console_http=${code}"
if [[ "${code}" != "200" ]]; then
  echo "Console did not return HTTP 200." >&2
  exit 1
fi

upsert_env AUTH_CONFIGURED yes
echo "CONFIGURE_DONE user=${ADMIN_USER} console=${CONSOLE_URL}"
