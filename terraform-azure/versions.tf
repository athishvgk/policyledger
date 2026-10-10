terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      # Demo-only: lets `terraform destroy` fully remove the vault instead of
      # leaving it soft-deleted (and its name reserved) for days. A real
      # vault would keep purge protection ON so a deleted secret store can
      # be recovered.
      purge_soft_delete_on_destroy = true
    }
  }
}
