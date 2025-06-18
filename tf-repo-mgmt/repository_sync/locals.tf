locals {
  role_definition_name_owner = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
  owner_repo_name            = replace("${var.github_repository_owner}-${var.github_repository_name}", "windows", "w5s")
}

locals {
  preview_gh_actions_oidc_subject_claim_customization_repos = toset([
    "terraform-azure-avm-utl-interfaces",
    "terraform-azurerm-avm-res-keyvault-vault"
  ])
}
