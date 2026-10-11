output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "csi_client_id" {
  description = "Client ID of the identity the Key Vault add-on uses inside the cluster."
  value       = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].client_id
}

output "github_client_id" {
  description = "Client ID GitHub Actions logs in as (not a secret)."
  value       = azurerm_user_assigned_identity.github.client_id
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --admin"
}

output "grafana_name" {
  value = azurerm_dashboard_grafana.this.name
}

output "grafana_url" {
  description = "Open this in a browser and sign in with your Azure account."
  value       = azurerm_dashboard_grafana.this.endpoint
}
