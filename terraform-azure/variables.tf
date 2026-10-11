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
  description = "VM size for the single AKS node (must be x86, 2+ vCPU, 4+ GB). Checked available in eastus2 for this subscription; re-check with az vm list-skus before using another region."
  type        = string
  default     = "Standard_D2as_v7"
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

variable "grafana_major_version" {
  description = "Grafana major version for Azure Managed Grafana."
  type        = string
  default     = "12"
}

variable "grafana_sku" {
  description = "Managed Grafana tier. Standard is about $0.034/hour in eastus2 plus $6 per user per month; Essential has no hourly charge but fewer features."
  type        = string
  default     = "Standard"
}
