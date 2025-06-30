locals {
  preview_ruleset_bypass_for_app_repos = toset([
    "terraform-azure-avm-utl-interfaces",
    "terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet",
    "terraform-azurerm-avm-ptn-alz-connectivity-virtual-wan",
    "terraform-azurerm-avm-ptn-alz-management",
    "terraform-azurerm-avm-ptn-alz",
    "terraform-azurerm-avm-ptn-hubnetworking",
    "terraform-azurerm-avm-ptn-virtualwan",
    "terraform-azurerm-avm-res-keyvault-vault",
  ])
}
