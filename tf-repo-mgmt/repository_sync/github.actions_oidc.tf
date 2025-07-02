# This file manages the GitHub Actions OIDC subject claim customization for specific repositories
# that are in-scope. When wanting to roll out to all repositories, set count to 1 and remove the condition.
resource "github_actions_repository_oidc_subject_claim_customization_template" "this" {
  count       = contains(local.preview_gh_actions_oidc_subject_claim_customization_repos, github_repository.this.name) ? 1 : 0
  repository  = github_repository.this.name
  use_default = false
  include_claim_keys = [
    "repository",
    "environment",
    "job_workflow_ref",
  ]
}
