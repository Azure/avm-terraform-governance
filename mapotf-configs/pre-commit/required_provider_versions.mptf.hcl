data "terraform" this {

}

locals {
  azapi_provider_version_valid  = try(!semvercheck(data.terraform.this.required_providers.azapi.version, "2.3.999"), false) && try(semvercheck(data.terraform.this.required_providers.azapi.version, "2.999.999"), false)
  random_provider_version_valid = try(!semvercheck(data.terraform.this.required_providers.random.version, "2.999.999"), true) && try(semvercheck(data.terraform.this.required_providers.random.version, "3.999.999"), true)
}

transform "update_in_place" azapi_provider_version {
  for_each             = local.avm_headers_for_azapi_enabled && !local.azapi_provider_version_valid ? toset([1]) : toset([])
  target_block_address = "terraform"
  asraw {
    required_providers {
      azapi = {
        source  = "Azure/azapi"
        version = "~> 2.4"
      }
    }
  }
}

transform "update_in_place" random_provider_version {
  for_each             = !local.random_provider_version_valid ? toset([1]) : toset([])
  target_block_address = "terraform"
  asraw {
    required_providers {
      random = {
        source  = "hashicorp/random"
        version = "~> 3.0"
      }
    }
  }
  depends_on = [
    transform.update_in_place.azapi_provider_version
  ]
}