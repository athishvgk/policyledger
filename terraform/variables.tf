variable "cluster_name" {
  description = "Name of the local kind cluster."
  type        = string
  default     = "policyledger"
}

variable "monitoring_namespace" {
  description = "Namespace kube-prometheus-stack is installed into."
  type        = string
  default     = "monitoring"
}
