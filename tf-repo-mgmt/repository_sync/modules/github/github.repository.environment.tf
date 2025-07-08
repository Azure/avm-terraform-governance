resource "github_repository_environment" "this" {
  count               = var.repository_creation_mode_enabled ? 0 : 1
  environment         = var.github_repository_environment_name
  repository          = github_repository.this.name
  can_admins_bypass   = true
  prevent_self_review = false
  reviewers {
    teams = values(local.environment_approval_teams)
  }
}

resource "github_actions_environment_secret" "tenant_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  environment     = github_repository_environment.this.environment
  secret_name     = "ARM_TENANT_ID"
  plaintext_value = var.arm_tenant_id
}

resource "github_actions_environment_secret" "subscription_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  environment     = github_repository_environment.this.environment
  secret_name     = "ARM_SUBSCRIPTION_ID"
  plaintext_value = var.arm_subscription_id
}

resource "github_actions_environment_secret" "client_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  environment     = github_repository_environment.this.environment
  secret_name     = "ARM_CLIENT_ID"
  plaintext_value = var.arm_client_id
}

# This environment is used for jobs that do not require authentication.
# Due to the OIDC subject claim refs mandating that environment is included,
# all jobs must be run in an environment whether they need authentication or not.
resource "github_repository_environment" "dummy_no_approval" {
  environment = var.github_repository_no_approval_environment_name
  repository  = github_repository.this.name
}
