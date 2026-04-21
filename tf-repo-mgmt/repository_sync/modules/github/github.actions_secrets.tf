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
