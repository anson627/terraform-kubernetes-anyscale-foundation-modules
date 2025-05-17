###############################################################################
# AKS CLUSTER – control-plane + "system" pool
###############################################################################
#trivy:ignore:avd-azu-0040
#trivy:ignore:avd-azu-0041
#trivy:ignore:avd-azu-0042
resource "azurerm_kubernetes_cluster" "aks" {

  #checkov:skip=CKV_AZURE_170: "Ensure that AKS use the Paid Sku for its SLA"
  #checkov:skip=CKV_AZURE_172: "Ensure autorotation of Secrets Store CSI Driver secrets for AKS clusters"
  #checkov:skip=CKV_AZURE_141: "Ensure AKS local admin account is disabled"
  #checkov:skip=CKV_AZURE_115: "Ensure that AKS enables private clusters"
  #checkov:skip=CKV_AZURE_117: "Ensure that AKS uses disk encryption set"
  #checkov:skip=CKV_AZURE_232: "Ensure that only critical system pods run on system nodes"
  #checkov:skip=CKV_AZURE_226: "Ensure ephemeral disks are used for OS disks"
  #checkov:skip=CKV_AZURE_116: "Ensure that AKS uses Azure Policies Add-on"
  #checkov:skip=CKV_AZURE_6: "Ensure AKS has an API Server Authorized IP Ranges enabled"
  #checkov:skip=CKV_AZURE_171: "Ensure AKS cluster upgrade channel is chosen"
  #checkov:skip=CKV_AZURE_168: "Ensure Azure Kubernetes Cluster (AKS) nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_4: "Ensure AKS logging to Azure Monitoring is Configured"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows between Compute and Storage resources"

  name                = var.aks_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # lets kubectl talk to the API over the public FQDN
  dns_prefix = "${var.aks_cluster_name}-dns"

  # workload identity federation
  oidc_issuer_enabled       = true # publishes an OIDC issuer URL
  workload_identity_enabled = true # lets pods use AAD tokens

  #########################################################################
  # default (system) node‑pool
  #########################################################################
  default_node_pool {
    name            = "sys"
    vm_size         = "Standard_D2s_v5"
    vnet_subnet_id  = azurerm_subnet.nodes.id
    os_disk_size_gb = 64
    type            = "VirtualMachineScaleSets"

    # autoscaler
    auto_scaling_enabled = true
    min_count            = 1
    max_count            = 3

  }

  #########################################################################
  # identities, networking, tags
  #########################################################################
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  tags = var.tags
}

###############################################################################
# CPU NODE POOL (Standard_D16s_v5) OnDemand
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "ondemand_cpu" {

  #checkov:skip=CKV_AZURE_168: "Ensure Azure Kubernetes Cluster (AKS) nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows between Compute and Storage resources"

  name                  = "cpu16"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = "Standard_D16s_v5"
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule"
  ]

  tags = var.tags
}

###############################################################################
# CPU NODE POOL (Standard_D16s_v5) Spot
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "spot_cpu" {

  #checkov:skip=CKV_AZURE_168: "Ensure Azure Kubernetes Cluster (AKS) nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows between Compute and Storage resources"

  name                  = "cpu16spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = "Standard_D16s_v5"
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  node_taints = [
    "node.anyscale.com/capacity-type=SPOT:NoSchedule"
  ]

  priority        = "Spot"
  eviction_policy = "Delete"

  tags = var.tags
}

locals {
  gpu_pool_configs = {
    T4 = {
      name         = "gput4"
      vm_size      = "Standard_NC16as_T4_v3"
      product_name = "NVIDIA-T4"
      gpu_count    = "1"
    }
    A10 = {
      name         = "gpua10"
      vm_size      = "Standard_NV36ads_A10_v5"
      product_name = "NVIDIA-A10"
      gpu_count    = "1"
    }
    A100 = {
      name         = "gpua100"
      vm_size      = "Standard_NC24ads_A100_v4"
      product_name = "NVIDIA-A100"
      gpu_count    = "1"
    }
    H100 = {
      name         = "gpuh100x8"
      vm_size      = "Standard_ND96isr_H100_v5"
      product_name = "NVIDIA-H100"
      gpu_count    = "8"
    }
  }

  # keep only the types the caller asked for
  selected_gpu_pools = {
    for k, v in local.gpu_pool_configs :
    k => v if contains(var.node_group_gpu_types, k)
  }
}

###############################################################################
# GPU Node POOL (Standard_NC16as_T4_v3) OnDemand
###############################################################################

#trivy:ignore:avd-azu-0168
#trivy:ignore:avd-azu-0227
resource "azurerm_kubernetes_cluster_node_pool" "gpu_ondemand" {
  #checkov:skip=CKV_AZURE_168
  #checkov:skip=CKV_AZURE_227

  for_each = local.selected_gpu_pools

  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = each.value.vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  # ── autoscaling (shared across all pools) ───────────────────────────────────
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  upgrade_settings { max_surge = "1" }

  # ── labels & taints ────────────────────────────────────────────────────────
  node_labels = {
    "nvidia.com/gpu.product" = each.value.product_name
    "nvidia.com/gpu.count"   = each.value.gpu_count
  }

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule",
    "nvidia.com/gpu=present:NoSchedule",
    "node.anyscale.com/accelerator-type=GPU:NoSchedule",
  ]

  tags = var.tags
}

###############################################################################
# GPU Node POOL (Standard_NC16as_T4_v3) Spot
###############################################################################
#trivy:ignore:avd-azu-0168
#trivy:ignore:avd-azu-0227
resource "azurerm_kubernetes_cluster_node_pool" "gpu_spot" {
  #checkov:skip=CKV_AZURE_168
  #checkov:skip=CKV_AZURE_227

  for_each = local.selected_gpu_pools

  name                  = "${each.value.name}spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = each.value.vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  # ── autoscaling (shared across all pools) ───────────────────────────────────
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  # ── labels & taints ────────────────────────────────────────────────────────
  node_labels = {
    "nvidia.com/gpu.product" = each.value.product_name
    "nvidia.com/gpu.count"   = each.value.gpu_count
  }

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule",
    "nvidia.com/gpu=present:NoSchedule",
    "node.anyscale.com/accelerator-type=GPU:NoSchedule",
  ]

  priority        = "Spot"
  eviction_policy = "Delete"

  tags = var.tags
}

##############################################################################
# MANAGED IDENTITY FOR ANYSCALE OPERATOR
###############################################################################
resource "azurerm_user_assigned_identity" "anyscale_operator" {
  name                = "${var.aks_cluster_name}-anyscale-operator-mi"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

###############################################################################
# FEDERATED‑IDENTITY CREDENTIAL  (ServiceAccount --> User‑Assigned Identity)
###############################################################################
resource "azurerm_federated_identity_credential" "anyscale_operator_fic" {
  name                = "anyscale-operator-fic"
  resource_group_name = azurerm_resource_group.rg.name

  parent_id = azurerm_user_assigned_identity.anyscale_operator.id # user assigned identity
  issuer    = azurerm_kubernetes_cluster.aks.oidc_issuer_url      # OIDC issuer from AKS
  subject   = "system:serviceaccount:${var.anyscale_operator_namespace}:anyscale-operator"
  audience  = ["api://AzureADTokenExchange"] # fixed value for AAD tokens
}

###############################################################################
# ROLE ASSIGNMENTS (IDENTITY ←→ STORAGE ACCOUNT)
###############################################################################
resource "azurerm_role_assignment" "anyscale_blob_contrib" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.anyscale_operator.principal_id
}

###############################################################################
# HOW TO BIND KUBERNETES SERVICE ACCOUNT
###############################################################################
#
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: anyscale-operator
#   namespace: anyscale-system
#   annotations:
#     azure.workload.identity/client-id: "${azurerm_user_assigned_identity.anyscale_operator.client_id}"
#
# ================================
# apiVersion: v1
# kind: Pod
# metadata:
#   name: sample-pod
#   labels:
#     azure.workload.identity/use: "true"
# spec:
#   serviceAccountName: anyscale-operator
