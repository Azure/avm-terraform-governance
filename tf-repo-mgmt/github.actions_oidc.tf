resource "github_actions_repository_oidc_subject_claim_customization_template" "this" {
  count       = contains(local.preview_gh_actions_oidc_subject_claim_customization_repos, data.github_repository.this.name) ? 1 : 0
  repository  = data.github_repository.this.name
  use_default = false
  include_claim_keys = [
    "environment",
    "job_workflow_ref",
    "repository",
  ]
}
