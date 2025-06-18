locals {
  role_definition_name_owner = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
  owner_repo_name            = replace("${var.github_repository_owner}-${var.github_repository_name}", "windows", "w5s")
}

locals {
  gh_actions_job_workflow_ref_claim_suffix = contains(
    local.preview_gh_actions_oidc_subject_claim_customization_repos,
    data.github_repository.this.name,
  ) ? ":job_workflow_ref:Azure/avm-terraform-governance/.github/workflows/pr-check-template.yml@refs/heads/main" : ""

  preview_gh_actions_oidc_subject_claim_customization_repos = toset([
    "terraform-azure-avm-utl-interfaces",
    "terraform-azurerm-avm-res-keyvault-vault"
  ])
}
