locals {
  repository_teams = { for k, v in var.github_teams : k => {
    id         = try(github_team.this[k].id, data.github_team.this[k].id)
    permission = v.repository_access_permission
  } if v.repository_access_permission != "none" }
}

resource "github_team_repository" "this" {
  for_each   = local.repository_teams
  team_id    = each.value.id
  repository = github_repository.this.name
  permission = each.value.permission
}
