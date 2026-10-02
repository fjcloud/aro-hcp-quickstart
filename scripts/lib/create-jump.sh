#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

JUMP_NAME="${CLUSTER_NAME}-jump"
JUMP_NSG="${JUMP_NAME}-nsg"
JUMP_PIP="${JUMP_NAME}-pip"
JUMP_NIC="${JUMP_NAME}-nic"

if "${AZ}" vm show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NAME}" --query name --output tsv >/dev/null 2>&1; then
  echo "Jump box ${JUMP_NAME} already exists"
  exit 0
fi

if ! "${AZ}" network nsg show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NSG}" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network nsg create \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --name "${JUMP_NSG}" \
    --location "${LOCATION}" \
    --output none
fi

if ! "${AZ}" network vnet subnet show \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --vnet-name "${CUSTOMER_VNET_NAME}" \
  --name jumpbox \
  --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network vnet subnet create \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --vnet-name "${CUSTOMER_VNET_NAME}" \
    --name jumpbox \
    --address-prefixes 10.0.2.0/28 \
    --network-security-group "${JUMP_NSG}" \
    --output none
fi

if ! "${AZ}" network public-ip show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_PIP}" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network public-ip create \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --name "${JUMP_PIP}" \
    --location "${LOCATION}" \
    --sku Standard \
    --allocation-method Static \
    --output none
fi

if ! "${AZ}" network nic show --resource-group "${CUSTOMER_RG_NAME}" --name "${JUMP_NIC}" --query name --output tsv >/dev/null 2>&1; then
  "${AZ}" network nic create \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --name "${JUMP_NIC}" \
    --location "${LOCATION}" \
    --vnet-name "${CUSTOMER_VNET_NAME}" \
    --subnet jumpbox \
    --network-security-group "${JUMP_NSG}" \
    --public-ip-address "${JUMP_PIP}" \
    --output none
fi

"${AZ}" vm create \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --name "${JUMP_NAME}" \
  --location "${LOCATION}" \
  --nics "${JUMP_NIC}" \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --os-disk-name "${JUMP_NAME}-osdisk" \
  --output none

echo "Jump box ${JUMP_NAME} is ready"
