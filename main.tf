###############################################################################
# GKE cluster with an arbitrary set of node pools.
#
# Pool topology is data, not copy-pasted resource blocks — the difference
# between an app pool and a system pool is a map entry rather than a second
# 80-line resource. Names are derived from var.resource_names/var.description
# rather than passed in directly; see locals.tf.
###############################################################################

###############################################################################
# Node identity
#
# Created only when var.node_service_account is null. GKE otherwise defaults
# nodes to the Compute Engine default SA, which holds project-wide Editor --
# this is the module's own guard against that, not something every caller
# should have to remember to wire up separately.
###############################################################################

resource "google_service_account" "node" {
  count = var.node_service_account == null ? 1 : 0

  account_id   = local.node_sa_id
  display_name = "GKE node service account (${var.description})"
  description  = "Minimal-privilege identity for GKE nodes. Not for workloads."
}

resource "google_project_iam_member" "node" {
  for_each = var.node_service_account == null ? toset(var.node_service_account_roles) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node[0].email}"
}

resource "google_container_cluster" "this" {
  name     = local.cluster_name
  location = var.location

  deletion_protection = var.deletion_protection

  network    = var.network
  subnetwork = var.subnetwork

  # The default pool cannot be fully customised in place, so it is created and
  # immediately replaced by the pools declared below.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    # Nodes get no external IPs.
    enable_private_nodes = true

    enable_private_endpoint = var.enable_private_endpoint

    master_ipv4_cidr_block = var.master_cidr
  }

  master_authorized_networks_config {
    # Do not implicitly trust Google-owned public IPs.
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  enable_shielded_nodes = true

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  network_policy {
    enabled  = var.enable_network_policy
    provider = var.enable_network_policy ? "CALICO" : "PROVIDER_UNSPECIFIED"
  }

  release_channel {
    channel = var.release_channel
  }

  logging_config {
    enable_components = var.logging_components
  }

  monitoring_config {
    enable_components = var.monitoring_components

    managed_prometheus {
      enabled = false
    }
  }

  cost_management_config {
    enabled = false
  }

  addons_config {
    # Required: installs the NEG controller that turns a Service's
    # cloud.google.com/neg annotation into a standalone zonal NEG, which is
    # what the external load balancer binds to.
    http_load_balancing {
      disabled = false
    }

    network_policy_config {
      disabled = !var.enable_network_policy
    }

    horizontal_pod_autoscaling {
      disabled = true
    }

    gcp_filestore_csi_driver_config {
      enabled = false
    }

    gcs_fuse_csi_driver_config {
      enabled = false
    }
  }

  maintenance_policy {
    recurring_window {
      start_time = "2025-01-01T08:00:00Z"
      end_time   = "2025-01-01T14:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  resource_labels = var.resource_labels

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

resource "google_container_node_pool" "this" {
  for_each = var.node_pools

  name     = local.node_pool_names[each.key]
  cluster  = google_container_cluster.this.name
  location = var.location

  # Static size unless autoscaling is set, in which case node_count becomes
  # the initial size and the autoscaler owns scaling from there. Terraform
  # treats an explicit null the same as omitting the argument.
  node_count         = each.value.autoscaling == null ? each.value.node_count : null
  initial_node_count = each.value.autoscaling == null ? null : each.value.node_count

  dynamic "autoscaling" {
    for_each = each.value.autoscaling == null ? [] : [each.value.autoscaling]
    content {
      min_node_count = autoscaling.value.min_node_count
      max_node_count = autoscaling.value.max_node_count
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # max_surge = 0 by default: on a single-node pool, surging would briefly
  # provision and bill for a second node on every upgrade. Accepting a short
  # outage is the right trade where there is no availability target — and on a
  # pool sharing a ReadWriteOnce PVC, a surge node cannot attach it anyway.
  upgrade_settings {
    max_surge       = each.value.max_surge
    max_unavailable = each.value.max_unavailable
    strategy        = "SURGE"
  }

  node_config {
    machine_type = each.value.machine_type
    spot         = each.value.spot

    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    image_type   = each.value.image_type

    service_account = local.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    tags   = each.value.tags
    labels = merge(var.resource_labels, each.value.labels)

    # Reserves a pool. A NoSchedule taint means only pods that explicitly
    # tolerate it land here, which is how the system pool keeps CI runners from
    # competing with application workloads for memory.
    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Forces workloads to use Workload Identity rather than reading the node's
    # service account token off the metadata server.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    # Taints and labels are read back in a different order than written.
    ignore_changes = [node_config[0].labels]
  }

  # Nodes booting on a freshly-created SA before its IAM grants land fail
  # closed on their first logging/monitoring write. Only real when this
  # module created the SA itself -- an empty for_each on
  # google_project_iam_member.node makes this a no-op dependency otherwise.
  depends_on = [google_project_iam_member.node]
}
