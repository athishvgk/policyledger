# ---- metrics: Azure Monitor managed Prometheus + Managed Grafana ---------
# The Azure equivalent of the kube-prometheus-stack the kind cluster runs.
# The pieces are the same (something scrapes /metrics, something stores the
# numbers, something draws graphs); Azure just hosts the storage and the
# graphing for us instead of running them as pods.
#
#   AKS add-on (monitor_metrics)  ->  scrapes pods, ships samples
#   data collection rule          ->  says "send them to that workspace"
#   Monitor workspace             ->  the Prometheus-compatible database
#   Managed Grafana               ->  dashboards that query the workspace
#   alert rule group              ->  the PodRestarting alert (see below)

# The database. Billed per sample ingested (about $0.16 per 10 million).
resource "azurerm_monitor_workspace" "this" {
  name                = "amw-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# The front door the add-on sends samples to, and the rule that routes
# whatever arrives there into the workspace above.
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = "dce-${var.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = "dcr-${var.name}"
  resource_group_name         = azurerm_resource_group.this.name
  location                    = azurerm_resource_group.this.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  tags                        = local.tags

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.this.id
      name               = "workspace"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["workspace"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }
}

# Attaches the rule (and the endpoint) to the cluster.
resource "azurerm_monitor_data_collection_rule_association" "rule" {
  name                    = "dcra-${var.name}"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
}

resource "azurerm_monitor_data_collection_rule_association" "endpoint" {
  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_kubernetes_cluster.this.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
}

# ---- Grafana -------------------------------------------------------------
resource "azurerm_dashboard_grafana" "this" {
  name                  = "amg-${var.name}-${local.suffix}"
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  grafana_major_version = var.grafana_major_version
  sku                   = var.grafana_sku
  tags                  = local.tags

  # Logins go through Entra ID, so there is no Grafana admin password.
  # The API-key feature is left off (its default).
  api_key_enabled                   = false
  deterministic_outbound_ip_enabled = false

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }
}

# Grafana reads the workspace as its own identity, so that identity needs
# read access to it.
resource "azurerm_role_assignment" "grafana_reads_workspace" {
  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

# Whoever runs terraform gets to log in to Grafana and edit dashboards.
resource "azurerm_role_assignment" "me_admin_grafana" {
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---- alert ---------------------------------------------------------------
# Same rule as k8s/10-prometheus-rule.yaml. There is deliberately no
# action group: nothing here pages or emails anyone, so a firing alert is
# only visible in the Azure portal (Monitor -> Alerts). Wiring an action
# group to email is the obvious next step and is not done.
resource "azurerm_monitor_alert_prometheus_rule_group" "policyledger" {
  name                = "policyledger-alerts"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  cluster_name        = azurerm_kubernetes_cluster.this.name
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.this.id]
  tags                = local.tags

  rule {
    alert      = "PodRestarting"
    expression = "increase(kube_pod_container_status_restarts_total{namespace=\"policyledger\"}[15m]) > 0"
    for        = "PT1M"
    severity   = 3

    labels = {
      severity = "warning"
    }

    annotations = {
      summary = "A policyledger container restarted in the last 15 minutes"
    }

    alert_resolution {
      auto_resolved   = true
      time_to_resolve = "PT10M"
    }
  }
}
