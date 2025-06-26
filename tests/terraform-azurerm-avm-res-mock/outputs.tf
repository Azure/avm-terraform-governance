output "resource_id" {
  description = "The ID of the resource created by the module."
  value       = null
}

output "azurerm_use" {
  description = "This output is used to ensure that the azurerm provider is used in the module."
  value       = data.azurerm_client_config.this.subscription_id
}
