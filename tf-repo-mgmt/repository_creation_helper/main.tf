locals {
  avm_core_team_members = { for final_members in flatten([for value in data.github_team.avm_core : [for member in value.members : {
    composite_key = "${value.slug}-${member}"
    username      = member
  }]]) : final_members.composite_key => final_members.username }
  team_maintainers = merge(local.avm_core_team_members, { for k, v in var.module_owner_github_handles : k => v if v != "" })
}

resource "github_team" "owners" {
  name                      = "${var.module_id}-${var.github_owner_team_name_postfix}"
  description               = "Owners of the ${var.module_id} Azure Verified Module."
  privacy                   = "closed"
  create_default_maintainer = true
}

resource "github_team" "contributors" {
  name                      = "${var.module_id}-${var.github_contributor_team_name_postfix}"
  description               = "Contributors of the ${var.module_id} Azure Verified Module."
  privacy                   = "closed"
  create_default_maintainer = true
}

resource "github_team_membership" "owners_maintainer" {
  for_each = local.team_maintainers
  team_id  = github_team.owners.id
  username = each.value
  role     = "maintainer"
}

resource "github_team_membership" "contributors_maintainer" {
  for_each = local.team_maintainers
  team_id  = github_team.contributors.id
  username = each.value
  role     = "maintainer"
}

data "github_team" "avm_core" {
  for_each = var.maintainer_teams
  slug     = each.value
}
