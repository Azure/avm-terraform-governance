# Order meta-arguments on every resource, data and ephemeral block:
#   head: for_each, count, provider
#   foot: lifecycle, depends_on
# Body (provider-specific args like name, type, parent_id, body, ...) stays in source order
# (sort_body_alphabetically = false). For providers we have schemas for, order_resource_attrs.mptf.hcl
# takes over and emits a required-then-optional alphabetical body order.
#
# IMPORTANT: this transform must NOT run on the same addresses that order_resource_attrs.mptf.hcl
# handles, otherwise the two reorders fight each other. `reorder_attributes` always rebuilds the
# body via `body.Clear() + emitReorderElements`, and the LAST transform to touch a block wins for
# the unlisted body ordering. With sort_body_alphabetically=false, unlisted body elements get
# re-sorted by their ORIGINAL source position — so whichever transform ran later overwrites the
# schema-driven body order coming from the earlier one. We dodge that by excluding addresses
# already covered by order_resource_attrs.mptf.hcl from this transform's for_each.
#
# Ephemeral blocks have no schema-driven body equivalent in mapotf v0.1.3 (no provider_schema
# field for ephemerals), so meta-arg ordering is the only thing we apply here.

data "resource"  "for_order" {}
data "data"      "for_order" {}
data "ephemeral" "for_order" {}

locals {
  # Addresses covered by order_resource_attrs.mptf.hcl. These get full head + body + foot ordering
  # there, so we MUST skip them here to avoid the body-clobber described above.
  meta_known_resource_addrs = merge(
    local.attrs_azurerm_resource_addrs,
    local.attrs_azapi_resource_addrs,
    local.attrs_random_resource_addrs,
  )
  meta_known_data_addrs = merge(
    local.attrs_azurerm_data_addrs,
    local.attrs_azapi_data_addrs,
    local.attrs_random_data_addrs,
  )

  meta_resource_pairs = flatten([
    for t, by_name in data.resource.for_order.result : [
      for k, v in by_name : { addr = "${t}.${k}", v = v }
    ]
  ])
  meta_resource_addrs = { for p in local.meta_resource_pairs : p.addr => p.v
    if !contains(keys(local.meta_known_resource_addrs), "resource.${p.addr}")
  }

  meta_data_pairs = flatten([
    for t, by_name in data.data.for_order.result : [
      for k, v in by_name : { addr = "${t}.${k}", v = v }
    ]
  ])
  meta_data_addrs = { for p in local.meta_data_pairs : p.addr => p.v
    if !contains(keys(local.meta_known_data_addrs), "data.${p.addr}")
  }

  meta_ephemeral_pairs = flatten([
    for t, by_name in data.ephemeral.for_order.result : [
      for k, v in by_name : { addr = "${t}.${k}", v = v }
    ]
  ])
  meta_ephemeral_addrs = { for p in local.meta_ephemeral_pairs : p.addr => p.v }
}

transform "reorder_attributes" "resource_meta" {
  for_each                 = local.meta_resource_addrs
  target_block_address     = "resource.${each.key}"
  head_attributes          = ["for_each", "count", "provider"]
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "data_meta" {
  for_each                 = local.meta_data_addrs
  target_block_address     = "data.${each.key}"
  head_attributes          = ["for_each", "count", "provider"]
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "ephemeral_meta" {
  for_each                 = local.meta_ephemeral_addrs
  target_block_address     = "ephemeral.${each.key}"
  head_attributes          = ["for_each", "count", "provider"]
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}
