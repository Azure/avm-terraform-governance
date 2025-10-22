resource "github_repository_environment" "copilot" {
  count       = var.repository_creation_mode_enabled ? 0 : 1
  environment = var.github_repository_copilot_environment_name
  repository  = github_repository.this.name
}

resource "github_actions_environment_secret" "copilot_tenant_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  environment     = github_repository_environment.copilot[0].environment
  secret_name     = "ARM_TENANT_ID"
  plaintext_value = var.arm_tenant_id
}

resource "github_actions_environment_secret" "copilot_client_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  environment     = github_repository_environment.copilot[0].environment
  secret_name     = "ARM_CLIENT_ID"
  plaintext_value = var.arm_client_id
}

resource "github_actions_environment_secret" "copilot_subscription_id" {
  count           = var.repository_creation_mode_enabled ? 0 : 1
  repository      = github_repository.this.name
  environment     = github_repository_environment.this[0].environment
  secret_name     = "ARM_SUBSCRIPTION_ID"
  plaintext_value = var.test_subscription_ids[0].id
}
