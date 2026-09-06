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
}
