output "azurerm_use" {
  description = "This output is used to ensure that the azurerm provider is used in the module."
  value       = data.azurerm_client_config.this.subscription_id
}

output "resource_id" {
  description = "The ID of the resource created by the module."
  value       = try(values(azurerm_resource_group.this)[0].id, null)
}

output "resource_ids" {
  description = "The IDs of the example resources created by the module, keyed by example_keys."
  value       = { for k, rg in azurerm_resource_group.this : k => rg.id }
}

output "subscription_id" {
  description = "The ID of the subscription the module is deployed to."
  sensitive   = true
  value       = data.azurerm_client_config.this.subscription_id
}
