output "client_id" {
  value = azapi_resource.identity.output.properties.clientId
}

output "tenant_id" {
  value = data.azapi_client_config.current.tenant_id
}
