data "azurerm_client_config" "current" {}

# ACR and Key Vault names are global across all of Azure, so a short random
# suffix keeps them from colliding with anyone else's.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result
  tags = {
    project = "policyledger"
    purpose = "demo"
    destroy = "same-day"
  }
}

# Everything below lives in one resource group, so `terraform destroy` (or
# deleting this one group) removes the whole demo.
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = local.tags
}

# ---- container registry ------------------------------------------------
# The Azure equivalent of GHCR: where the finished, scanned image is stored
# and where the cluster pulls it from. Admin user is off: access is only
# through Azure role assignments, never a shared password.
resource "azurerm_container_registry" "this" {
  name                = "acr${var.name}${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

# ---- Kubernetes cluster ------------------------------------------------
# The Azure equivalent of the local kind cluster: a real, Azure-managed
# Kubernetes control plane plus one worker node.
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  dns_prefix          = var.name
  sku_tier            = "Free" # no uptime SLA; fine for a demo
  tags                = local.tags

  # Kubernetes RBAC is already the default; stated explicitly so the intent
  # is on the page and the config scanner can see it.
  role_based_access_control_enabled = true

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  # Required block in azurerm v5. "Manual" is the classic mode: we pick the
  # node count and size ourselves instead of letting AKS auto-provision.
  node_provisioning_profile {
    mode = "Manual"
  }

  # Cilium enforces the NetworkPolicy in k8s/08-networkpolicy.yaml.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
  }

  # Add-on that lets pods read secrets straight from Key Vault (see
  # k8s-azure/secret-sync.yaml). Rotation is off to keep the demo simple.
  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }
}

# Lets the cluster's nodes pull images from our registry (and nothing else).
resource "azurerm_role_assignment" "aks_pulls_from_acr" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

# ---- Key Vault ---------------------------------------------------------
# Encrypted secret storage with an access log, replacing the base64
# Kubernetes Secret the kind version relies on.
resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.name}-${local.suffix}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # demo-only, see versions.tf
  tags                       = local.tags
}

# Whoever runs terraform needs permission to write secrets into the vault.
resource "azurerm_role_assignment" "terraform_writes_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# A random database password is generated here and stored only in the vault
# and in Terraform state. It is never written to a file or to git.
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.terraform_writes_secrets]
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "database-url"
  value        = "postgresql+psycopg2://policyledger:${random_password.db.result}@postgres:5432/policyledger"
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.terraform_writes_secrets]
}

# The add-on's own identity is the only thing allowed to read those secrets
# from inside the cluster.
resource "azurerm_role_assignment" "csi_reads_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}

# ---- GitHub Actions login (OIDC) ---------------------------------------
# GitHub proves who it is with a short-lived signed token instead of a
# stored Azure password. This identity trusts tokens from exactly one repo
# and one branch, and holds only the two roles the deploy needs.
resource "azurerm_user_assigned_identity" "github" {
  name                = "id-${var.name}-github"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.github.id
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repository}:ref:refs/heads/main"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "github_pushes_to_acr" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github.principal_id
}

resource "azurerm_role_assignment" "github_gets_cluster_credentials" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = azurerm_user_assigned_identity.github.principal_id
}
