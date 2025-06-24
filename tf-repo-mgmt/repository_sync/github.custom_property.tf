resource "github_repository_custom_property" "string" {
  count = contains(
    local.preview_gh_actions_oidc_subject_claim_customization_repos,
    data.github_repository.this.name,
  ) ? 1 : 0
  repository     = github_repository.example.name
  property_name  = "rulesets-prod-opt-in"
  property_type  = "single_select"
  property_value = ["false"]
}
