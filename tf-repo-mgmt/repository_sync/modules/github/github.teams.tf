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
  github_teams_with_maintainers = { for k, v in local.github_team_to_read : k => v if v.members_are_team_maintainers }
  team_maintainers = { for final_members in flatten([for k, v in local.github_teams_with_maintainers : [for member in data.github_team.this[k].members : {
    composite_key = "${k}-${member}"
    username      = member
  }]]) : final_members.composite_key => final_members.username }
  final_team_maintainers = merge(local.team_maintainers, { for k, v in var.module_owner_github_handles : k => v if v != "" })

  final_maintainer_mapped_to_teams = { for final_mapped_members in  flatten([ for k, v in local.github_team_to_create : [
    for k_member, v_member in local.final_team_maintainers : {
      composite_key = "${k}-${k_member}"
      team_id = github_team.this[k].id
      username  = v_member
    }
  ] ]) : final_mapped_members.composite_key => {
    team_id  = final_mapped_members.team_id
    username = final_mapped_members.username
  } }
}

resource "github_team_membership" "maintainers" {
  for_each = local.final_maintainer_mapped_to_teams
  team_id  = each.value.team_id
  username = each.value.username
  role     = "maintainer"
}
