locals {
  github_token = env("GITHUB_TOKEN")
  common_http_headers = local.github_token == "" ? {} : {
    Authorization = "Bearer ${local.github_token}"
  }
  url_prefix        = "https://raw.githubusercontent.com/Azure/terraform-azurerm-avm-template/main"
}
