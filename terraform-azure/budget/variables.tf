variable "subscription_id" {
  description = "Azure subscription to put the budget on: export TF_VAR_subscription_id=$(az account show --query id -o tsv)"
  type        = string
}

variable "alert_email" {
  description = "Where budget alerts are sent. Pass at run time so it stays out of git: export TF_VAR_alert_email=you@example.com"
  type        = string
}

variable "amount" {
  description = "Monthly budget in USD."
  type        = number
  default     = 20
}
