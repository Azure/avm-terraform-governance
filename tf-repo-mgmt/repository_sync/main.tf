module "azure" {
  source = "./modules/azure"
  count  = var.repository_creation_mode_enabled ? 0 : 1

  target_subscription_id             = var.target_subscription_id
  management_group_id                = var.management_group_id
  github_repository_owner            = var.github_repository_owner
  github_repository_name             = var.github_repository_name
  github_repository_environment_name = var.github_repository_environment_name
  identity_resource_group_name       = var.identity_resource_group_name
  location                           = var.location
  github_job_workflow_ref_suffix     = local.github_job_workflow_ref_suffix
  is_protected_repo                  = var.is_protected_repo
}

module "github" {
  source = "./modules/github"

  repository_creation_mode_enabled               = var.repository_creation_mode_enabled
  github_repository_owner                        = var.github_repository_owner
  github_repository_name                         = var.github_repository_name
  github_repository_environment_name             = var.github_repository_environment_name
  github_repository_no_approval_environment_name = var.github_repository_no_approval_environment_name
  github_repository_copilot_environment_name     = var.github_repository_copilot_environment_name
  is_protected_repo                              = var.is_protected_repo
  bypass_ruleset_for_approval_enabled            = true
  github_teams                                   = var.github_teams
  github_avm_app_id                              = var.github_avm_app_id
  labels                                         = local.labels
  arm_client_id                                  = var.repository_creation_mode_enabled ? "" : module.azure[0].client_id
  arm_subscription_id                            = var.repository_creation_mode_enabled ? "" : var.target_subscription_id
  arm_tenant_id                                  = var.repository_creation_mode_enabled ? "" : module.azure[0].tenant_id
  module_id                                      = var.module_id
  module_name                                    = var.module_name
  custom_subject_claims_enabled                  = local.feature_flags.preview_github_actions_oidc_subject_claim_customization
}

import {
  id = var.github_repository_name
  to = module.github.github_repository.this
}
