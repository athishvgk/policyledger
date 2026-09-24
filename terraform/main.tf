# A local kind (Kubernetes IN Docker) cluster. This is a real Kubernetes
# control plane and node running as Docker containers on this machine --
# nothing here talks to any cloud account.
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
}

# The helm provider needs to know which cluster to talk to. Rather than
# pointing it at a kubeconfig file on disk, we wire it directly to the
# credentials kind_cluster just produced, so Terraform doesn't depend on
# anything outside its own state.
provider "helm" {
  kubernetes = {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

# Prometheus + Grafana + Alertmanager + assorted exporters, packaged as one
# Helm chart. This gives Day 4's dashboard and alert rule something to run
# against. Alertmanager is disabled: this project has nowhere to send a
# real notification (no Slack/email/PagerDuty), so a fired alert is
# inspected in Prometheus's own UI instead of routed anywhere.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = var.monitoring_namespace
  create_namespace = true

  values = [
    yamlencode({
      alertmanager = {
        enabled = false
      }
      prometheus = {
        prometheusSpec = {
          retention = "6h"
        }
      }
    })
  ]

  depends_on = [kind_cluster.this]
}
