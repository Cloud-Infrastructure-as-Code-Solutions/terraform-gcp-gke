###############################################################################
# Derived resource names.
#
# Node pool indices come from the sorted order of var.node_pools' keys, not
# from anything stored per-key. Adding or removing a pool can therefore shift
# the "-NN" suffix — and hence the name, which is ForceNew — of every pool
# that sorts after the change, recreating them even though their config did
# not change. Acceptable for the deliberately generic, index-based naming
# this module standardizes on; expect a bigger apply than usual when the set
# of node pool keys changes shape.
###############################################################################

locals {
  cluster_name = "${var.resource_names["gke_cluster"]}-${var.description}-01"

  node_pool_keys  = sort(keys(var.node_pools))
  node_pool_index = { for idx, key in local.node_pool_keys : key => format("%02d", idx + 1) }

  node_pool_names = {
    for key in local.node_pool_keys :
    key => "${var.resource_names["gke_nodepool"]}-${var.description}-${local.node_pool_index[key]}"
  }

  # google_service_account.account_id is capped at 30 characters by the GCP
  # API -- tighter than every other name this module derives, and the only
  # one where "<code>-<description>-<NN>" reliably overflows once
  # var.description carries a real naming convention's full token chain.
  # Dropping the "-NN" suffix (the SA is always a singleton, so it adds
  # nothing) and truncating is the least-surprising way to stay under that
  # cap; collision isn't a concern since this module creates at most one.
  node_sa_id = substr(
    "${try(var.resource_names["gke_node_sa"], "sa")}-${var.description}",
    0, 30,
  )

  node_service_account = coalesce(var.node_service_account, try(google_service_account.node[0].email, null))
}
