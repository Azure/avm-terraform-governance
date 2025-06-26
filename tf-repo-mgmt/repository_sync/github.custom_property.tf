resource "github_repository_custom_property" "prod_opt_in" {
  count = contains(
    local.preview_ruleset_bypass_for_app_repos,
    data.github_repository.this.name,
  ) ? 1 : 0
  repository     = data.github_repository.this.name
  property_name  = "rulesets-prod-opt-in"
  property_type  = "single_select"
  property_value = ["false"]
}

resource "github_repository_custom_property" "default_opt_in" {
  count = contains(
    local.preview_ruleset_bypass_for_app_repos,
    data.github_repository.this.name,
  ) ? 1 : 0
  repository     = data.github_repository.this.name
  property_name  = "rulesets-default-opt-in"
  property_type  = "single_select"
  property_value = ["false"]
}

resource "github_repository_custom_property" "global_opt_out" {
  count = contains(
    local.preview_ruleset_bypass_for_app_repos,
    data.github_repository.this.name,
  ) ? 1 : 0
  repository     = data.github_repository.this.name
  property_name  = "global-rulesets-opt-out"
  property_type  = "single_select"
  property_value = ["true"]
}
