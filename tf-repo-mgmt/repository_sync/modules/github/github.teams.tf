data "github_team" "this" {
  for_each = var.github_teams
  slug     = each.value.slug
}
