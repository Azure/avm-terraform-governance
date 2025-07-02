resource "github_team_repository" "avm_core" {
  for_each   = local.repository_teams
  team_id    = each.value.id
  repository = github_repository.this.name
  permission = each.value.permission
}
