resource "github_repository_custom_property" "prod_opt_in" {
  count          = var.bypass_ruleset_for_approval_enabled ? 1 : 0
  repository     = github_repository.this.name
  property_name  = "rulesets-prod-opt-in"
  property_type  = "single_select"
  property_value = ["false"]
}

resource "github_repository_custom_property" "default_opt_in" {
  count          = var.bypass_ruleset_for_approval_enabled ? 1 : 0
  repository     = github_repository.this.name
  property_name  = "rulesets-default-opt-in"
  property_type  = "single_select"
  property_value = ["false"]
}

resource "github_repository_custom_property" "global_opt_out" {
  count          = var.bypass_ruleset_for_approval_enabled ? 1 : 0
  repository     = github_repository.this.name
  property_name  = "global-rulesets-opt-out"
  property_type  = "single_select"
  property_value = ["true"]
}
