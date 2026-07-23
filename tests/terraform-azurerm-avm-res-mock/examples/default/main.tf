provider "azurerm" {
  features {}
}

module "test" {
  source = "../../"

  location                 = "westus3"
  create_example_resources = var.create_example_resources
}
