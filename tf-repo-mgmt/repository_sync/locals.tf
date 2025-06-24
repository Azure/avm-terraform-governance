locals {
  role_definition_name_owner = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
  owner_repo_name            = replace("${var.github_repository_owner}-${var.github_repository_name}", "windows", "w5s")
}

locals {
  # These repos are in-scope for the preview of the GitHub Actions OIDC subject claim customization feature.
  # This will limit use of the credential to a managed workflow in the specified repos.
  preview_gh_actions_oidc_subject_claim_customization_repos = toset([
    "terraform-azure-avm-utl-interfaces",
    "terraform-azurerm-avm-res-keyvault-vault"
  ])

  # This is the suffix to append to the subject claim for the job_workflow_ref claim.
  # It is appended to the subject claim when the repository is in-scope for the preview
  # of the GitHub Actions OIDC subject claim customization feature.
  gh_actions_job_workflow_ref_claim_suffix = contains(
    local.preview_gh_actions_oidc_subject_claim_customization_repos,
    data.github_repository.this.name,
  ) ? ":job_workflow_ref:Azure/avm-terraform-governance/.github/workflows/managed-pr-check.yml@refs/heads/main" : ""

}

locals {
  github_avm_app_id = "1049636"
}
