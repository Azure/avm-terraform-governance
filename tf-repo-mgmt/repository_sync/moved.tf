moved {
  from = github_repository.this
  to = module.github.github_repository.this
}

moved {
  from = github_repository_environment.this
  to = module.github.github_repository_environment.this[0]
}

moved {
  from = github_actions_environment_secret.tenant_id[0]
  to = module.github.github_actions_environment_secret.tenant_id[0]
}

moved {
  from = github_actions_environment_secret.subscription_id[0]
  to = module.github.github_actions_environment_secret.subscription_id[0]
}

moved {
  from = github_actions_environment_secret.client_id[0]
  to = module.github.github_actions_environment_secret.client_id[0]
}

moved {
  from = azapi_resource.identity
  to = module.azure[0].azapi_resource.identity
}

moved {
  from = azapi_resource.identity_federated_credentials
  to = module.azure[0].azapi_resource.identity_federated_credentials
}

moved {
  from = azapi_resource.identity_role_assignment
  to = module.azure[0].azapi_resource.identity_role_assignment
}

moved {
  from = azuread_group_member.example
  to = module.azure[0].azuread_group_member.example
}

moved {
  from = github_issue_label.this
  to = module.github.github_issue_label.this
}
