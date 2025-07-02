data "github_team" "this" {
  for_each = var.github_teams
  slug  = each.value.slug
}

locals {
  repository_teams = { for k,v in var.github_teams : k => {
    id = data.github_team.this[k].id
    permission = v.repository_access_permission
   } if v.repository_access_permission != "none" }
  environment_approval_teams = { for k,v in var.github_teams : k => data.github_team.this[k].id if v.environment_approval }
}