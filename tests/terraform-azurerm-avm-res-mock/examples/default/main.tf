provider "azurerm" {
  features {}
}

module "test" {
  source   = "../../"
  location = "westus3"
}
