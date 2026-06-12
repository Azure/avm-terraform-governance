# Example AVM-shaped resources/data/locals for governance fixture coverage.
# All real resource/data blocks are gated by var.create_example_resources (default false) so
# that pr-check terraform plan, terraform test integration, and any other apply path do not
# provision real Azure resources by default. The unit test (tests/unit/unit.tftest.hcl) sets
# the flag to true to exercise the apply path with mock providers.

data "azapi_client_config" "this" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  resource_group_prefix = "rg-avm-azapi-mock"
  example_keys          = ["primary", "secondary"]
}

locals {
  default_tags = {
    environment = "test"
    managed_by  = "avm-terraform-governance"
  }
}

resource "azapi_resource" "example_rg" {
  for_each = toset(var.create_example_resources ? local.example_keys : [])

  location  = var.location
  name      = "${local.resource_group_prefix}-${random_string.suffix.result}-${each.value}"
  parent_id = "/subscriptions/${data.azapi_client_config.this.subscription_id}"
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  body = {
    tags = local.default_tags
  }
  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers   = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  update_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null

  lifecycle {
    ignore_changes = [
      body.tags,
    ]
  }
}

resource "azapi_resource" "example_rg_singleton" {
  count = var.create_example_resources ? 1 : 0

  location  = var.location
  name      = "${local.resource_group_prefix}-${random_string.suffix.result}-singleton"
  parent_id = "/subscriptions/${data.azapi_client_config.this.subscription_id}"
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  body = {
    tags = local.default_tags
  }
  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers   = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  update_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null

  depends_on = [
    azapi_resource.example_rg,
  ]
}
