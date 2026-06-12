# Schema-driven body ordering for resource and data blocks.
#
# Uses mapotf v0.1.3's `data "provider_schema"` to fetch sorted required/optional attribute name
# lists per resource/data type, then drives `reorder_attributes.body_attributes` so every body is
# emitted as `required (alphabetical) → optional (alphabetical) → anything-else`.
#
# Note: mapotf runs `terraform init` + `terraform providers schema` under the hood to populate
# `data "provider_schema"`, so this transform implies a one-time provider download per run.
#
# azapi special handling: a handful of attributes are technically optional in the provider schema
# but are far more important than `body` and friends (`name`, `parent_id`, `location`, ...). They
# are promoted into the required-list slot here so they appear at the top of the body.
#
# Naming: all locals/data identifiers are namespaced with `attrs_` to avoid colliding with the
# `meta_` prefix used in order_resource_meta.mptf.hcl. mapotf identifiers share a global
# namespace across every .mptf.hcl file loaded from the same dir.
#
# Coverage: only providers we know AVM modules use heavily are wired up here (azurerm, azapi,
# random). Resources / data sources from other providers (tls, kubernetes, helm, ...) still get
# head/foot meta-arg ordering via order_resource_meta.mptf.hcl, but their bodies stay in source
# order. Extend this file when new providers become common.

data "provider_schema" "azurerm" {
  provider_source  = "hashicorp/azurerm"
  provider_version = "~> 4.0"
}

data "provider_schema" "azapi" {
  provider_source  = "Azure/azapi"
  provider_version = "~> 2.4"
}

data "provider_schema" "random" {
  provider_source  = "hashicorp/random"
  provider_version = "~> 3.0"
}

data "resource" "for_attrs" {}
data "data"     "for_attrs" {}

locals {
  # Promoted azapi attributes — technically optional in the schema, but treated as required-tier
  # for ordering. They describe WHAT the resource is, not HOW it behaves.
  attrs_azapi_promoted = ["action", "location", "method", "name", "parent_id", "query_parameters", "resource_id"]

  # ---- Resource address → type maps, split by provider source ----

  attrs_azurerm_resource_addrs = merge([
    for t, by_name in data.resource.for_attrs.result : {
      for n, _ in by_name : "resource.${t}.${n}" => t
    } if startswith(t, "azurerm_")
  ]...)

  attrs_azapi_resource_addrs = merge([
    for t, by_name in data.resource.for_attrs.result : {
      for n, _ in by_name : "resource.${t}.${n}" => t
    } if startswith(t, "azapi_")
  ]...)

  attrs_random_resource_addrs = merge([
    for t, by_name in data.resource.for_attrs.result : {
      for n, _ in by_name : "resource.${t}.${n}" => t
    } if startswith(t, "random_")
  ]...)

  # ---- Data source address → type maps, split by provider source ----

  attrs_azurerm_data_addrs = merge([
    for t, by_name in data.data.for_attrs.result : {
      for n, _ in by_name : "data.${t}.${n}" => t
    } if startswith(t, "azurerm_")
  ]...)

  attrs_azapi_data_addrs = merge([
    for t, by_name in data.data.for_attrs.result : {
      for n, _ in by_name : "data.${t}.${n}" => t
    } if startswith(t, "azapi_")
  ]...)

  attrs_random_data_addrs = merge([
    for t, by_name in data.data.for_attrs.result : {
      for n, _ in by_name : "data.${t}.${n}" => t
    } if startswith(t, "random_")
  ]...)

  # ---- azapi per-type body_attributes (required + promoted, then optional minus promoted) ----

  attrs_azapi_resource_body_by_type = {
    for t in keys(try(data.provider_schema.azapi.resources_required_attributes, {})) : t => concat(
      sort(distinct(concat(
        try(data.provider_schema.azapi.resources_required_attributes[t], []),
        [for a in local.attrs_azapi_promoted : a if contains(try(data.provider_schema.azapi.resources_optional_attributes[t], []), a)]
      ))),
      sort([
        for a in try(data.provider_schema.azapi.resources_optional_attributes[t], []) :
        a if !contains(local.attrs_azapi_promoted, a)
      ])
    )
  }

  attrs_azapi_data_body_by_type = {
    for t in keys(try(data.provider_schema.azapi.data_sources_required_attributes, {})) : t => concat(
      sort(distinct(concat(
        try(data.provider_schema.azapi.data_sources_required_attributes[t], []),
        [for a in local.attrs_azapi_promoted : a if contains(try(data.provider_schema.azapi.data_sources_optional_attributes[t], []), a)]
      ))),
      sort([
        for a in try(data.provider_schema.azapi.data_sources_optional_attributes[t], []) :
        a if !contains(local.attrs_azapi_promoted, a)
      ])
    )
  }
}

# ---- Resource body ordering ----

transform "reorder_attributes" "azurerm_resource_body" {
  for_each             = local.attrs_azurerm_resource_addrs
  target_block_address = each.key
  head_attributes      = ["for_each", "count", "provider"]
  body_attributes = concat(
    try(data.provider_schema.azurerm.resources_required_attributes[each.value], []),
    try(data.provider_schema.azurerm.resources_optional_attributes[each.value], []),
  )
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "azapi_resource_body" {
  for_each                 = local.attrs_azapi_resource_addrs
  target_block_address     = each.key
  head_attributes          = ["for_each", "count", "provider"]
  body_attributes          = try(local.attrs_azapi_resource_body_by_type[each.value], [])
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "random_resource_body" {
  for_each             = local.attrs_random_resource_addrs
  target_block_address = each.key
  head_attributes      = ["for_each", "count", "provider"]
  body_attributes = concat(
    try(data.provider_schema.random.resources_required_attributes[each.value], []),
    try(data.provider_schema.random.resources_optional_attributes[each.value], []),
  )
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

# ---- Data source body ordering ----

transform "reorder_attributes" "azurerm_data_body" {
  for_each             = local.attrs_azurerm_data_addrs
  target_block_address = each.key
  head_attributes      = ["for_each", "count", "provider"]
  body_attributes = concat(
    try(data.provider_schema.azurerm.data_sources_required_attributes[each.value], []),
    try(data.provider_schema.azurerm.data_sources_optional_attributes[each.value], []),
  )
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "azapi_data_body" {
  for_each                 = local.attrs_azapi_data_addrs
  target_block_address     = each.key
  head_attributes          = ["for_each", "count", "provider"]
  body_attributes          = try(local.attrs_azapi_data_body_by_type[each.value], [])
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "random_data_body" {
  for_each             = local.attrs_random_data_addrs
  target_block_address = each.key
  head_attributes      = ["for_each", "count", "provider"]
  body_attributes = concat(
    try(data.provider_schema.random.data_sources_required_attributes[each.value], []),
    try(data.provider_schema.random.data_sources_optional_attributes[each.value], []),
  )
  foot_attributes          = ["lifecycle", "depends_on"]
  sort_body_alphabetically = false
}
