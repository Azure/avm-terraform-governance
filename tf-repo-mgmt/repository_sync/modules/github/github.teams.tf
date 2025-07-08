locals {
  github_team_to_create = { for k, v in var.github_teams : k => v if v.created_with_repository && var.repository_creation_mode_enabled }
  github_team_to_read   = { for k, v in var.github_teams : k => v if !v.created_with_repository || (!var.repository_creation_mode_enabled && v.created_with_repository) }
}

resource "github_team" "this" {
  for_each                  = local.github_team_to_create
  name                      = each.value.slug
  description               = each.value.description
  privacy                   = "closed"
  create_default_maintainer = true
}

data "github_team" "this" {
  for_each = local.github_team_to_read
  slug     = each.value.slug
}

locals {
  repository_teams = { for k, v in var.github_teams : k => {
    id         = try(github_team.this[k].id, data.github_team.this[k].id)
    permission = v.repository_access_permission
  } if v.repository_access_permission != "none" }
  environment_approval_teams = { for k, v in var.github_teams : k => try(github_team.this[k].id, data.github_team.this[k].id) if v.environment_approval }
}

resource "github_team_repository" "this" {
  for_each   = local.repository_teams
  team_id    = each.value.id
  repository = github_repository.this.name
  permission = each.value.permission
}
