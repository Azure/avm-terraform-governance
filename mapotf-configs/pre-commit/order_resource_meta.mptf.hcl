# Order meta-arguments on every resource and data block:
#   head: for_each, count, provider
#   tail: lifecycle, depends_on
# The "middle" (provider-specific args like name, type, parent_id, body, ...) stays in source
# order. avmfix used to split middle into required-then-optional via Terraform provider schema
# introspection; mapotf v0.1.2 does not yet expose provider schemas, so we deliberately leave
# middle order alone rather than alphabetising it.
#
# Coverage note: mapotf v0.1.2 has no data source for `ephemeral` blocks, so ephemeral resources
# are NOT covered here. avmfix did cover them. Flagged upstream as a v0.1.3 candidate.

data "resource" "for_order" {}
data "data"     "for_order" {}

locals {
  meta_resource_pairs = flatten([
    for t, by_name in data.resource.for_order.result : [
      for k, v in by_name : { addr = "${t}.${k}", v = v }
    ]
  ])
  meta_resource_addrs = { for p in local.meta_resource_pairs : p.addr => p.v }

  meta_data_pairs = flatten([
    for t, by_name in data.data.for_order.result : [
      for k, v in by_name : { addr = "${t}.${k}", v = v }
    ]
  ])
  meta_data_addrs = { for p in local.meta_data_pairs : p.addr => p.v }
}

transform "reorder_attributes" "resource_meta" {
  for_each                   = local.meta_resource_addrs
  target_block_address       = "resource.${each.key}"
  head_attributes            = ["for_each", "count", "provider"]
  tail_attributes            = ["lifecycle", "depends_on"]
  sort_middle_alphabetically = false
}

transform "reorder_attributes" "data_meta" {
  for_each                   = local.meta_data_addrs
  target_block_address       = "data.${each.key}"
  head_attributes            = ["for_each", "count", "provider"]
  tail_attributes            = ["lifecycle", "depends_on"]
  sort_middle_alphabetically = false
}
