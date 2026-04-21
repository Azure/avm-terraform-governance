locals {
  environment_approval_team_ids = [for k, v in var.github_teams : data.github_team.this[k].id if v.environment_approval]

  # Approval-gated environments. Map key -> environment name.
  approval_environments = var.repository_creation_mode_enabled ? {} : {
    pr_check      = var.github_repository_pr_check_environment_name
    examples_test = var.github_repository_examples_test_environment_name
  }
}

# Approval-gated environments (PR check and example tests).
# Both share the same reviewer teams and the same Azure identity (federated
# credentials are created per-environment in the azure module so the OIDC
# subject claim matches).
resource "github_repository_environment" "approval" {
  for_each = local.approval_environments

  environment         = each.value
  repository          = github_repository.this.name
  can_admins_bypass   = true
  prevent_self_review = false
  reviewers {
    teams = local.environment_approval_team_ids
  }
}

# This environment is used for jobs that do not require approval (or auth).
# Due to the OIDC subject claim refs mandating that environment is included,
# all jobs must be run in an environment whether they need authentication or not.
resource "github_repository_environment" "no_approval" {
  environment = var.github_repository_no_approval_environment_name
  repository  = github_repository.this.name
}

# Shared Azure auth values are stored at repository scope so they can be
# consumed by any environment (and any new environment added in future)
# without duplicating per-environment secrets.
resource "github_actions_secret" "arm_tenant_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  secret_name     = "ARM_TENANT_ID"
  plaintext_value = var.arm_tenant_id
}

resource "github_actions_secret" "arm_client_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  secret_name     = "ARM_CLIENT_ID"
  plaintext_value = var.arm_client_id
}

resource "github_actions_secret" "test_subscription_ids" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  secret_name     = "TEST_SUBSCRIPTION_IDS"
  plaintext_value = jsonencode(var.test_subscription_ids)
}
