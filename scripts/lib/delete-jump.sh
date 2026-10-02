#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  exit 0
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

JUMP_NAME="${CLUSTER_NAME}-jump"

if "${AZ}" vm show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}" --query name --output tsv >/dev/null 2>&1; then
  echo "Deleting jump box ${JUMP_NAME}"
  "${AZ}" vm delete --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}" --yes --output none
fi

if "${AZ}" network nic show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-nic" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network nic delete --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-nic" --output none
fi

if "${AZ}" network public-ip show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-pip" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network public-ip delete --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-pip" --output none
fi

if "${AZ}" disk show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-osdisk" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" disk delete --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-osdisk" --yes --output none
fi

if "${AZ}" network vnet subnet show \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --vnet-name "${CUSTOMER_VNET_NAME}" \
  --name jumpbox --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network vnet subnet delete \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --vnet-name "${CUSTOMER_VNET_NAME}" \
    --name jumpbox \
    --output none
fi

if "${AZ}" network nsg show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-nsg" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network nsg delete --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}-nsg" --output none
fi
