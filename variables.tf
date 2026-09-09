variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "enable_project_services" {
  description = <<-EOT
    Enable this module's required GCP APIs (container, iam, logging,
    monitoring -- see locals.tf) before creating anything. Defaults to true
    so the module is self-sufficient on its own.

    Set to false only if something else in the same apply already enables
    all four -- unlikely for most stacks, since none of them are typically
    owned by whatever creates the VPC/subnet this cluster runs in.
  EOT
  type        = bool
  default     = true
}

variable "resource_names" {
  description = <<-EOT
    Naming-prefix codes keyed by resource type, used to derive every resource
    name this module creates. Required keys: "gke_cluster", "gke_nodepool".
    Optional key: "gke_node_sa" (defaults to "sa" if omitted), used only when
    var.node_service_account is null and this module creates its own node
    service account.

    A derived name has the shape "<resource_names[key]>-<description>-<NN>",
    where NN is a zero-padded sequence number (01, 02, ...). The cluster is a
    singleton and is always "-01"; node pools are numbered in the sorted order
    of their var.node_pools keys. The node service account is also a
    singleton, but its account_id drops the "-<NN>" suffix and truncates to
    30 characters -- see locals.tf.

    Example:
      resource_names = {
        gke_cluster  = "gke"
        gke_nodepool = "gkenp"
        gke_node_sa  = "sa"
      }
  EOT
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["gke_cluster", "gke_nodepool"] : contains(keys(var.resource_names), k)])
    error_message = "resource_names must include \"gke_cluster\" and \"gke_nodepool\" keys."
  }
}

variable "description" {
  description = "Descriptor segment interpolated into every derived resource name (e.g. an environment or workload identifier)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.description))
    error_message = "description must be lowercase alphanumeric with hyphens, and must not start or end with a hyphen."
  }
}

variable "location" {
  description = <<-EOT
    Zone for a ZONAL cluster (one control plane), or a region for a regional
    one (three). Pass a zone unless you are deliberately paying for HA.
  EOT
  type        = string
}

variable "network" {
  description = "VPC self link or id."
  type        = string
}

variable "subnetwork" {
  description = "Subnet self link or id. Must carry the two secondary ranges below."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pod IPs."
  type        = string
  default     = "pods"
}

variable "services_range_name" {
  description = "Secondary range name for ClusterIP services."
  type        = string
  default     = "services"
}

variable "master_cidr" {
  description = "/28 for the control plane's Google-managed peered VPC."
  type        = string
}

variable "authorized_networks" {
  description = <<-EOT
    CIDRs allowed to reach the public control plane endpoint. IPv4 only.

    Note this does NOT govern in-cluster traffic: pods reach the API server over
    the internal endpoint regardless, which is what lets an in-cluster CI runner
    deploy without any entry here.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}

variable "enable_private_endpoint" {
  description = "true removes the public control plane endpoint entirely; kubectl then requires a tunnel."
  type        = bool
  default     = false
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
}

variable "enable_network_policy" {
  description = "Calico NetworkPolicy enforcement. Costs ~150-250 MB of node memory."
  type        = bool
  default     = true
}

variable "logging_components" {
  description = <<-EOT
    Cloud Logging components. SYSTEM_COMPONENTS only by default — adding
    WORKLOADS ingests every container log and is billed per GB, which is the
    most common surprise on a low-cost cluster.
  EOT
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS"]
}

variable "monitoring_components" {
  description = "Cloud Monitoring components."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS"]
}

variable "node_service_account" {
  description = <<-EOT
    Email of an EXISTING service account to attach to nodes.

    Leave null (the default) to have this module create its own
    minimal-privilege node service account and grant it
    var.node_service_account_roles. Set this only to share one service
    account across multiple clusters, or to reuse an org-managed identity --
    in either case this module grants no IAM roles, since it isn't the
    account's owner.
  EOT
  type        = string
  default     = null
}

variable "node_service_account_roles" {
  description = <<-EOT
    IAM roles granted to the node service account this module creates.
    Ignored when var.node_service_account is set (this module never manages
    IAM on an account it did not create).

    Defaults to what kubelet actually needs -- GKE otherwise falls back to
    the Compute Engine default SA, which holds project-wide Editor. No
    artifactregistry.reader by default: if your images come from a registry
    that isn't Artifact Registry (e.g. GHCR via an imagePullSecret), the node
    identity has no business being in the image-pull path at all. Add it
    here if you do use Artifact Registry.
  EOT
  type        = list(string)
  default = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ]
}

variable "deletion_protection" {
  description = "Blocks terraform destroy of the cluster."
  type        = bool
  default     = false
}

variable "resource_labels" {
  description = "Labels applied to the cluster and node pools."
  type        = map(string)
  default     = {}
}

variable "node_pools" {
  description = <<-EOT
    Node pools, keyed by name.

    taints let you reserve a pool: a pool with a NoSchedule taint only accepts
    pods that tolerate it, and labels give the matching nodeSelector.

    node_count is per pool and is a static size. Keep any pool whose workloads
    share a ReadWriteOnce PVC at exactly 1 — GKE only permits RWO multi-attach
    across pods on the SAME node, so a second node strands pods on attach
    errors.

    autoscaling, when set, replaces the static node_count with a cluster
    autoscaler range and node_count instead becomes the pool's
    initial_node_count (typically 0). This is how machine-type fallback works:
    define several pools with identical labels/taints and one candidate
    machine_type each, all with autoscaling { min=0, max=1 }. The autoscaler
    only scales up a pool when it has unschedulable pods to place, and stops
    looking once one pool succeeds — so pools sharing labels/taints normally
    resolve to exactly one node total, preserving the RWO single-node
    constraint. This does NOT hold if a candidate machine_type is too small to
    fit the full pod set: leftover unschedulable pods can then trigger a
    SECOND pool to scale up, producing a second node the PVC cannot attach to.
    Only include machine types proven to fit the whole workload.
  EOT
  type = map(object({
    machine_type    = string
    node_count      = number
    spot            = optional(bool, true)
    disk_size_gb    = optional(number, 50)
    disk_type       = optional(string, "pd-standard")
    image_type      = optional(string, "COS_CONTAINERD")
    labels          = optional(map(string), {})
    tags            = optional(list(string), [])
    max_surge       = optional(number, 0)
    max_unavailable = optional(number, 1)
    autoscaling = optional(object({
      min_node_count = number
      max_node_count = number
    }))
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}
