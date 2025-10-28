variable "azure_subscription_id" {
  description = "(Required) Azure subscription ID"
  type        = string
  default     = "854c9ddb-fe9e-4aea-8d58-99ed88282881"
}

variable "azure_location" {
  description = "(Optional) Azure region for all resources."
  type        = string
  default     = "West US"
}

variable "tags" {
  description = "(Optional) Tags applied to all taggable resources."
  type        = map(string)
  default = {
    SkipASB_Audit  = "true"
    SkipAKSCluster = "1"
  }
}

variable "aks_cluster_name" {
  description = "(Optional) Name of the AKS cluster (and related resources)."
  type        = string
  default     = "anyscale-demo"
}

variable "anyscale_operator_namespace" {
  description = "(Optional) Kubernetes namespace for the Anyscale operator."
  type        = string
  default     = "anyscale-operator"
}
