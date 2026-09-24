output "cluster_name" {
  value = kind_cluster.this.name
}

output "kubeconfig_path" {
  description = "kind also merges this cluster into ~/.kube/config as context kind-<cluster_name>."
  value       = kind_cluster.this.kubeconfig_path
}
