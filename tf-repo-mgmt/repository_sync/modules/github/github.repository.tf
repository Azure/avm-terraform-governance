locals {
  module_type                   = split("-", var.module_id)[1]
  module_type_name              = local.module_type == "res" ? "Resource" : (local.module_type == "ptn" ? "Pattern" : "Utility")
  github_repository_description = "Terraform Azure Verified ${local.module_type_name} Module for ${var.module_name}"
}

resource "github_repository" "this" {
  name               = var.github_repository_name
  description        = local.github_repository_description
  archive_on_destroy = true
  auto_init          = false

  visibility   = "public"
  homepage_url = "https://registry.terraform.io/modules/Azure/${var.module_id}"

  template {
    owner                = "Azure"
    repository           = "terraform-azurerm-avm-template"
    include_all_branches = false
  }

  has_issues             = true
  has_discussions        = false
  has_projects           = false
  has_wiki               = false
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  allow_auto_merge       = true
  delete_branch_on_merge = true
  allow_update_branch    = true
  vulnerability_alerts   = false

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
