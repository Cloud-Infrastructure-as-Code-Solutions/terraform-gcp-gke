output "name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "id" {
  description = "Fully qualified cluster id."
  value       = google_container_cluster.this.id
}

output "location" {
  description = "Cluster location (zone for a zonal cluster)."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Control plane endpoint."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "ca_certificate" {
  description = "Base64 cluster CA, for configuring the kubernetes/helm providers."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "node_pools" {
  description = "Created node pool names, keyed by logical pool name."
  value       = { for k, v in google_container_node_pool.this : k => v.name }
}

output "node_pool_labels" {
  description = "Node labels per pool, for building nodeSelector values."
  value       = { for k, v in var.node_pools : k => v.labels }
}
