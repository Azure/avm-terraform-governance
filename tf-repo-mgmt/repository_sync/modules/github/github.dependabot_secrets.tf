# Mirror of the repository-scope Actions secrets defined in
# `github.actions_secrets.tf` as Dependabot secrets. Dependabot does not
# share the Actions secret namespace, so any value Dependabot needs (e.g.
# for authenticating to private registries via `dependabot.yml`) must be
# duplicated here. Values are sourced from the same variables to keep
# Actions and Dependabot in lockstep.
resource "github_dependabot_secret" "arm_tenant_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  secret_name     = "ARM_TENANT_ID"
  plaintext_value = var.arm_tenant_id
}

resource "github_dependabot_secret" "arm_client_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  secret_name     = "ARM_CLIENT_ID"
  plaintext_value = var.arm_client_id
}

resource "github_dependabot_secret" "test_subscription_ids" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  secret_name     = "TEST_SUBSCRIPTION_IDS"
  plaintext_value = jsonencode(var.test_subscription_ids)
}
