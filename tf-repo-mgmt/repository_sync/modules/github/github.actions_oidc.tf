# This file manages the GitHub Actions OIDC subject claim customization for specific repositories
# that are in-scope. When wanting to roll out to all repositories, set count to 1 and remove the condition.
resource "github_actions_repository_oidc_subject_claim_customization_template" "this" {
  count       = !var.repository_creation_mode_enabled ? 1 : 0
  repository  = github_repository.this.name
  use_default = false
  include_claim_keys = [
    "repository_owner_id",
    "repository_id",
    "environment",
    "job_workflow_ref",
  ]
}
