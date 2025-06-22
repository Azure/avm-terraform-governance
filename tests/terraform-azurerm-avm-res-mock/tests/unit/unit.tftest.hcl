mock_provider "azurerm" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  location = "eastus"
}

run "apply" {
  command = apply

  assert {
    condition     = can(modtm_telemetry.telemetry)
    error_message = "Telemetry resource should be created when enable_telemetry is true (default)."
  }
}
