variable "subscription_id" {
  description = "Azure subscription to deploy into. Pass it at run time so it never lands in git: export TF_VAR_subscription_id=$(az account show --query id -o tsv)"
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus2"
}

variable "name" {
  description = "Short base name used in every resource name."
  type        = string
  default     = "policyledger"
}

variable "node_vm_size" {
  description = "VM size for the single AKS node. Check availability and quota in your region before applying (az vm list-skus / az vm list-usage)."
  type        = string
  default     = "Standard_B2s"
}

variable "node_count" {
  description = "Number of AKS nodes. One keeps the bill small; the Deployment's 2 replicas still run, just on the same node."
  type        = number
  default     = 1
}

variable "github_repository" {
  description = "owner/repo allowed to log in to Azure from GitHub Actions (OIDC)."
  type        = string
  default     = "athishvgk/policyledger"
}
