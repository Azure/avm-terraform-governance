variable "create_example_resources" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether to create the example AVM-shaped resources/data sources in this mock module.

Defaults to false so that any apply path (terraform plan in pr-check, terraform test integration
against real Azure) does not provision real resources. Set to true in the unit test (which uses
mock_provider blocks) to exercise the full apply path against mocked providers.
DESCRIPTION
  nullable    = false
}
