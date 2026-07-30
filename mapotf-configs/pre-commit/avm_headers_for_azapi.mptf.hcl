locals {
  # This local is also consumed by required_provider_versions.mptf.hcl to gate the
  # azapi provider version floor, so it is intentionally retained even though the
  # headers are no longer injected.
  avm_headers_for_azapi_enabled = true

  # Controls removal of the AVM-injected azapi telemetry headers. Set to false to
  # temporarily disable the removal transform without deleting the rule.
  remove_avm_headers_for_azapi_enabled = true
}

data "variable" enable_telemetry {
  name = "enable_telemetry"
}

locals {
  var_dot_enable_telemetry_exists = try(data.variable.enable_telemetry.result["enable_telemetry"] != null, false)
}

transform "new_block" new_enable_telemetry_variable {
  for_each       = local.avm_headers_for_azapi_enabled && !local.var_dot_enable_telemetry_exists ? toset([1]) : toset([])
  new_block_type = "variable"
  labels         = ["enable_telemetry"]
  filename       = "variables.tf"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
    nullable    = false
  }
}

transform "update_in_place" enable_telemetry_variable {
  for_each             = local.avm_headers_for_azapi_enabled && local.var_dot_enable_telemetry_exists ? toset([1]) : toset([])
  target_block_address = "variable.enable_telemetry"
  asraw {
    type        = bool
    default     = true
    description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
    nullable    = false
  }
  depends_on = [
    transform.new_block.new_enable_telemetry_variable
  ]
}

locals {
  azapi_resource_with_full_headers_types = toset([
    "azapi_data_plane_resource",
    "azapi_resource",
  ])
}

data "resource" "azapi_resources_with_full_headers" {
  for_each      = local.azapi_resource_with_full_headers_types
  resource_type = each.key
}

data "resource" "azapi_update_resource" {
  resource_type = "azapi_update_resource"
}

locals {
  all_azapi_resources_with_full_headers = flatten([
    for resource in data.resource.azapi_resources_with_full_headers : [
      for result_set in resource.result : flatten([
        for r in result_set : r
      ])
    ]
  ])
  all_azapi_resources_with_full_headers_map = {
    for r in local.all_azapi_resources_with_full_headers : r.mptf.block_address => r
  }
  azapi_update_resources_map = {
    for _, r in try(data.resource.azapi_update_resource.result["azapi_update_resource"], {}) :
    r.mptf.block_address => r
  }
}

locals {
  # The canonical AVM-injected header expressions. The removal transform only
  # strips a *_headers attribute when its rendered value exactly matches one of
  # these, which guarantees that user-authored headers are never removed.
  first_version_of_azapi_user_headers = "{ \"User-Agent\" : local.avm_azapi_header }"
  current_version_of_azapi_headers    = "var.enable_telemetry ? { \"User-Agent\" : local.avm_azapi_header } : null"

  # For each azapi resource, the list of *_headers attributes that were AVM
  # injected and should therefore be removed.
  full_headers_removals = {
    for addr, r in local.all_azapi_resources_with_full_headers_map :
    addr => [
      for attr, value in {
        create_headers = try(r.create_headers, "")
        delete_headers = try(r.delete_headers, "")
        read_headers   = try(r.read_headers, "")
        update_headers = try(r.update_headers, "")
      } : attr
      if value == local.current_version_of_azapi_headers || value == local.first_version_of_azapi_user_headers
    ]
  }
  azapi_update_resource_removals = {
    for addr, r in local.azapi_update_resources_map :
    addr => [
      for attr, value in {
        read_headers   = try(r.read_headers, "")
        update_headers = try(r.update_headers, "")
      } : attr
      if value == local.current_version_of_azapi_headers || value == local.first_version_of_azapi_user_headers
    ]
  }
}

transform "remove_block_element" full_headers {
  for_each = local.remove_avm_headers_for_azapi_enabled ? {
    for addr, attrs in local.full_headers_removals : addr => attrs if length(attrs) > 0
  } : {}
  target_block_address = each.key
  paths                = each.value
}

transform "remove_block_element" azapi_update_resource_headers {
  for_each = local.remove_avm_headers_for_azapi_enabled ? {
    for addr, attrs in local.azapi_update_resource_removals : addr => attrs if length(attrs) > 0
  } : {}
  target_block_address = each.key
  paths                = each.value
}
