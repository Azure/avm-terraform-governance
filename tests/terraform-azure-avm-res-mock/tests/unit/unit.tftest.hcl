mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  create_example_resources = true
  location                 = "eastus"
}

run "apply" {
  command = apply

  assert {
    condition     = can(modtm_telemetry.telemetry)
    error_message = "Telemetry resource should be created when enable_telemetry is true (default)."
  }

  assert {
    condition     = length(azapi_resource.example_rg) == 2
    error_message = "Two example resource groups should be created when create_example_resources is true."
  }

  assert {
    condition     = length(azapi_resource.example_rg_singleton) == 1
    error_message = "One singleton example resource group should be created when create_example_resources is true."
  }
}
