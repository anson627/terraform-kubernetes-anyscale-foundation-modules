#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
SUBSCRIPTION="${SUBSCRIPTION:-c0d4b923-b5ea-4f8f-9b56-5390a9bf2248}"
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-multi-region-rg}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-aksmultiregionsa}"
STORAGE_CONTAINER="${STORAGE_CONTAINER:-aks-multi-region-blob}"
USER_IDENTITY_NAME="${USER_IDENTITY_NAME:-aks-multi-region-anyscale-operator-mi}"

LOCATION="${LOCATION:-eastus}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-aks-$LOCATION}"
VNET_NAME="${VNET_NAME:-${AKS_CLUSTER_NAME}-vnet}"
VNET_CIDR="10.192.0.0/10"
SUBNET_NAME="${SUBNET_NAME:-aks-nodes}"
SUBNET_CIDR="10.192.0.0/10"
POD_CIDR="10.128.0.0/11"
NAT_PIP_NAME="${NAT_PIP_NAME:-${AKS_CLUSTER_NAME}-nat-pip}"
NAT_GW_NAME="${NAT_GW_NAME:-${AKS_CLUSTER_NAME}-nat-gw}"
AKS_VERSION="${AKS_VERSION:-1.33.3}"
SYSTEM_VM_SIZE="Standard_D16_v5"
SYSTEM_COUNT="3"
USER_POOL_VM_SIZE="Standard_NC24ads_A100_v4"
USER_POOLS="${USER_POOLS:-gpu}"
USER_POOL_COUNT="${USER_POOL_COUNT:-3}"
TAGS="${TAGS:-deletion_due_time=2025-11-17T00:00:00Z,SkipAKSCluster=1,SkipASB_Audit=true}"

# ===== TAGS TO CLI FORMAT =====
tag_args=(--tags)
IFS=',' read -r -a tag_items <<<"$TAGS"
for kv in "${tag_items[@]}"; do
  # Skip empty entries defensively
  [[ -z "$kv" ]] && continue
  tag_args+=("$kv")
done

# echo "==> 1. Resource Group"
# az account set -s "$SUBSCRIPTION"
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

# echo "==> 3. User Assigned Identity"
# IDENTITY_JSON=$(az identity create -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME" "${tag_args[@]}")
IDENTITY_JSON=$(az identity show -g "$RESOURCE_GROUP" -n "$USER_IDENTITY_NAME")
IDENTITY_CLIENT_ID=$(echo "$IDENTITY_JSON" | jq -r '.clientId')
IDENTITY_PRINCIPAL_ID=$(echo "$IDENTITY_JSON" | jq -r '.principalId')
IDENTITY_ID=$(echo "$IDENTITY_JSON" | jq -r '.id')

# echo "==> 4. Role Assignment (Blob Data Contributor)"
# STORAGE_ACCOUNT_ID=$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query id -o tsv)
# az role assignment create \
#   --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
#   --assignee-principal-type ServicePrincipal \
#   --role "Storage Blob Data Contributor" \
#   --scope "$STORAGE_ACCOUNT_ID" >/dev/null

echo "==> 5. Networking (VNet + Subnet)"
az network vnet create \
  --location "$LOCATION" \
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
  --location "$LOCATION" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NAT_PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  "${tag_args[@]}"

az network nat gateway create \
  --location "$LOCATION" \
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
  --node-vm-size "$SYSTEM_VM_SIZE"

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

echo "==> 10. Install ingress controller"
az aks get-credentials -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --overwrite-existing

helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx.yaml \
  --create-namespace \
  --install
  
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update

ANYSCALE_CLI_TOKEN="aph0_CkgwRgIhAPsWK5X-_YExKmea9blodb6P-MRBI6vqbTD6kfKRiybIAiEA2XB8VsXMEjXlbVmVc0sHqzj8sRcRi9m_9G8xf66NUDsSYxIgpOw-Cm7cYDWxuseSE3XepzyoWwMNv9NnmqEV3MLj7GEYASIedXNyX2FicHNjNzQ1bGo3ZWNzYmVienBwcGQ0ZWp5OgwI6f6tyAYQwL6CowJCDAi9h4nIBhDAvoKjAvIBAA"
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=cldrsrc_si6emilxuqeuhthzftxr3yk55a  \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.anyscaleCliToken=$ANYSCALE_CLI_TOKEN \
  --set-string global.auth.iamIdentity=$IDENTITY_CLIENT_ID \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  -i

echo "==> 11. Outputs"
echo "AKS Cluster Name: $AKS_CLUSTER_NAME"
echo "Resource Group:   $RESOURCE_GROUP"
echo "Storage Account:  $STORAGE_ACCOUNT"
echo "Blob Container:   $STORAGE_CONTAINER"
echo "Identity Client ID: $IDENTITY_CLIENT_ID"
echo "Federated Cred Name: $FED_CRED_NAME"
echo "OIDC Issuer: $OIDC_ISSUER"
echo "azure.workload.identity/client-id: $IDENTITY_CLIENT_ID"
