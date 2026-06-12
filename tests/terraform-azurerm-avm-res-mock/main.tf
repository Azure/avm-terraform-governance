data "azurerm_client_config" "this" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  resource_group_prefix = "rg-avm-azurerm-mock"
  example_keys          = ["primary", "secondary"]
}

locals {
  default_tags = {
    environment = "test"
    managed_by  = "avm-terraform-governance"
  }
}

resource "azurerm_resource_group" "this" {
  for_each = toset(var.create_example_resources ? local.example_keys : [])

  location = var.location
  name     = "${local.resource_group_prefix}-${random_string.suffix.result}-${each.value}"
  tags     = local.default_tags

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

resource "azurerm_management_lock" "rg_lock" {
  count = var.create_example_resources ? 1 : 0

  lock_level = "CanNotDelete"
  name       = "${local.resource_group_prefix}-${random_string.suffix.result}-lock"
  scope      = azurerm_resource_group.this["primary"].id
  notes      = "Locked by avm-terraform-governance mock module fixture."

  depends_on = [
    azurerm_resource_group.this,
  ]
}
