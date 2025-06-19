terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    azapi = {
      source  = "hasicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}
