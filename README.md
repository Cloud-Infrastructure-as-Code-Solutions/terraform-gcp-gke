# terraform-gcp-gke

Provisions a GKE cluster and an arbitrary set of node pools (keyed by name in
`var.node_pools`), private by default with Workload Identity and Shielded
Nodes enabled.

## Naming

Every named resource (`google_container_cluster`, `google_container_node_pool`)
derives its name from `var.resource_names` and `var.description` rather than
taking a name directly:

```
<resource_names[key]>-<description>-<NN>
```

`NN` is a zero-padded sequence number. The cluster is a singleton and is
always `-01`. Node pools are numbered in the sorted order of their
`var.node_pools` keys — see the caveat in `locals.tf` about what that means
for `terraform apply` when the set of pool keys changes shape.

```hcl
module "gke" {
  source = "git::https://github.com/brieschick34/terraform-gcp-gke.git?ref=v1.0.0"

  project_id = var.project_id
  location   = var.zone

  resource_names = {
    gke_cluster  = "gke"
    gke_nodepool = "gkenp"
  }
  description = "sandbox"

  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.private.id
  master_cidr           = var.master_cidr
  authorized_networks   = var.authorized_networks
  node_service_account  = google_service_account.node.email

  node_pools = {
    system = {
      machine_type = "e2-medium"
      node_count   = 1
    }
  }
}
```

See `variables.tf` for the full input reference and `outputs.tf` for what the
module exposes.
