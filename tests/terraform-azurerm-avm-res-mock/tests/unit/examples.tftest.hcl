mock_provider "azurerm" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  create_example_resources = true
}

run "default" {
  command = apply

  module {
    source = "./examples/default"
  }

  assert {
    condition     = output.resource_id != null
    error_message = "The default example should produce a non-null resource_id when create_example_resources is true."
  }
}

run "default_ignore" {
  command = apply

  module {
    source = "./examples/default-ignore"
  }

  assert {
    condition     = output.resource_id != null
    error_message = "The default-ignore example should produce a non-null resource_id when create_example_resources is true."
  }
}
