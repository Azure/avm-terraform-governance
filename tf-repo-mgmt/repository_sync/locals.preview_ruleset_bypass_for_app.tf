locals {
  preview_ruleset_bypass_for_app_repos = toset([
    "terraform-azure-avm-utl-interfaces",
    "terraform-azurerm-avm-res-keyvault-vault"
  ])
}
