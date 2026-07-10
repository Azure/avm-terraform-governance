mock_provider "azapi" {}
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

run "second_example" {
  command = apply

  module {
    source = "./examples/second_example"
  }

  assert {
    condition     = output.resource_id != null
    error_message = "The second_example example should produce a non-null resource_id when create_example_resources is true."
  }
}

run "ignored_example" {
  command = apply

  module {
    source = "./examples/ignored_example"
  }

  assert {
    condition     = output.resource_id != null
    error_message = "The ignored_example example should produce a non-null resource_id when create_example_resources is true."
  }
}
