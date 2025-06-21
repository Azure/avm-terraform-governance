mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  location = "eastus"
}

run "plan" {
  command = plan

  assert {
    condition     = can(modtm_telemetry.telemetry)
    error_message = "Telemetry resource should be created when enable_telemetry is true (default)."
  }
}
