#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
RESOURCE_GROUP="${RESOURCE_GROUP:-anyscale-test-rg}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-anyscaletestsa}"
STORAGE_CONTAINER="${STORAGE_CONTAINER:-anyscale-test-blob}"
USER_IDENTITY_NAME="${USER_IDENTITY_NAME:-anyscale-test-anyscale-operator-mi}"

AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-anyscale-test}"
LOCATION="${LOCATION:-eastus2}"
VNET_NAME="${VNET_NAME:-${AKS_CLUSTER_NAME}-vnet}"
VNET_CIDR="10.192.0.0/10"
SUBNET_NAME="${SUBNET_NAME:-aks-nodes}"
SUBNET_CIDR="10.192.0.0/10"
POD_CIDR="10.128.0.0/11"
NAT_PIP_NAME="${NAT_PIP_NAME:-${AKS_CLUSTER_NAME}-nat-pip}"
NAT_GW_NAME="${NAT_GW_NAME:-${AKS_CLUSTER_NAME}-nat-gw}"
AKS_VERSION="${AKS_VERSION:-1.33.3}"
SYSTEM_VM_SIZE="Standard_D16ds_v5"
SYSTEM_COUNT="3"
USER_POOL_VM_SIZE="Standard_D16_v3"
USER_POOLS="${USER_POOLS:-user1}"
USER_POOL_COUNT="${USER_POOL_COUNT:-3}"
TAGS="${TAGS:-Environment=dev,Test=true,SkipAKSCluster=1,SkipASB_Audit=true}"

# ===== TAGS TO CLI FORMAT =====
tag_args=(--tags)
IFS=',' read -r -a tag_items <<<"$TAGS"
for kv in "${tag_items[@]}"; do
  # Skip empty entries defensively
  [[ -z "$kv" ]] && continue
  tag_args+=("$kv")
done

# echo "==> 1. Resource Group"
# az group create --name "$RESOURCE_GROUP" --location "$LOCATION" "${tag_args[@]}"

# echo "==> 2. Storage Account + Container"
# az storage account create \
#   --name "$STORAGE_ACCOUNT" \
#   --resource-group "$RESOURCE_GROUP" \
#   --location "$LOCATION" \
#   --sku Standard_LRS \
#   --kind StorageV2 \
#   --allow-blob-public-access false \
#   "${tag_args[@]}"

# SA_KEY=$(az storage account keys list -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)

# az storage container create \
#   --name "$STORAGE_CONTAINER" \
#   --account-name "$STORAGE_ACCOUNT" \
#   --account-key "$SA_KEY" \
#   --public-access off >/dev/null

echo "==> 3. User Assigned Identity"
IDENTITY_JSON=$(az identity create -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME" "${tag_args[@]}")
# IDENTITY_JSON=$(az identity show -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME")
IDENTITY_CLIENT_ID=$(echo "$IDENTITY_JSON" | jq -r '.clientId')
IDENTITY_PRINCIPAL_ID=$(echo "$IDENTITY_JSON" | jq -r '.principalId')
IDENTITY_ID=$(echo "$IDENTITY_JSON" | jq -r '.id')

echo "==> 4. Role Assignment (Blob Data Contributor)"
STORAGE_ACCOUNT_ID=$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ACCOUNT_ID" >/dev/null

echo "==> 5. Networking (VNet + Subnet)"
az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --address-prefixes "$VNET_CIDR" \
  "${tag_args[@]}"

az network vnet subnet create \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --address-prefixes "$SUBNET_CIDR"

echo "==> 6. NAT Gateway + Public IP"
az network public-ip create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NAT_PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  "${tag_args[@]}"

az network nat gateway create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NAT_GW_NAME" \
  --public-ip-addresses "$NAT_PIP_NAME" \
  --idle-timeout 10 \
  "${tag_args[@]}"

az network vnet subnet update \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --nat-gateway "$NAT_GW_NAME"

SUBNET_ID=$(az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" --query id -o tsv)

echo "==> 7. AKS Cluster (OIDC + Workload Identity + Overlay + NAT outbound)"
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER_NAME" \
  --location "$LOCATION" \
  --tier Standard \
  --kubernetes-version "$AKS_VERSION" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --pod-cidr "$POD_CIDR" \
  --outbound-type userAssignedNATGateway \
  --vnet-subnet-id "$SUBNET_ID" \
  --nodepool-name sys \
  --nodepool-tags "${TAGS// /,}" \
  --node-count "$SYSTEM_COUNT" \
  --node-vm-size "$SYSTEM_VM_SIZE" \
  --aks-custom-headers "OverrideControlplaneResources=W3siY29udGFpbmVyTmFtZSI6Imt1YmUtYXBpc2VydmVyIiwiY3B1TGltaXQiOiIzMCIsImNwdVJlcXVlc3QiOiIyNyIsIm1lbW9yeUxpbWl0IjoiNjRHaSIsIm1lbW9yeVJlcXVlc3QiOiI2NEdpIiwiZ29tYXhwcm9jcyI6MzB9XSAg,ControlPlaneUnderlay=hcp-underlay-eastus2-cx-382,AKSHTTPCustomFeatures=OverrideControlplaneResources"

echo "==> 8. Federated Credential (ServiceAccount -> Identity)"
OIDC_ISSUER=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)
FED_CRED_NAME="${FED_CRED_NAME:-${AKS_CLUSTER_NAME}-operator-fic}"
ANYSPACE_NS="${ANYSPACE_NS:-anyscale-operator}"

az identity federated-credential create \
  --name "$FED_CRED_NAME" \
  --identity-name "$USER_IDENTITY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --issuer "$OIDC_ISSUER" \
  --subject "system:serviceaccount:${ANYSPACE_NS}:anyscale-operator" \
  --audiences "api://AzureADTokenExchange"

echo "==> 9. Add User Node Pools"
for pool in $USER_POOLS; do
  echo "----> Adding user pool: $pool"
  az aks nodepool add \
    --resource-group "$RESOURCE_GROUP" \
    --cluster-name "$AKS_CLUSTER_NAME" \
    --name "$pool" \
    --node-count "$USER_POOL_COUNT" \
    --node-vm-size "$USER_POOL_VM_SIZE" \
    --labels node.anyscale.com/capacity-type=ON_DEMAND \
    --tags "${TAGS// /,}"
done

echo "==> 10. Outputs"
echo "AKS Cluster Name: $AKS_CLUSTER_NAME"
echo "Resource Group:   $RESOURCE_GROUP"
echo "Storage Account:  $STORAGE_ACCOUNT"
echo "Blob Container:   $STORAGE_CONTAINER"
echo "Identity Client ID: $IDENTITY_CLIENT_ID"
echo "Federated Cred Name: $FED_CRED_NAME"
echo "OIDC Issuer: $OIDC_ISSUER"
echo ""
echo "ServiceAccount annotation to use:"
echo "azure.workload.identity/client-id: $IDENTITY_CLIENT_ID"
echo ""
echo "Login to cluster:"
az aks get-credentials -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --overwrite-existing
