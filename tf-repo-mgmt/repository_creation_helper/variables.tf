variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
  default     = "Azure"
}

variable "module_owner_github_handles" {
  type        = map(string)
  description = "GitHub handles of the module owners."
}

variable "module_id" {
  type        = string
  description = "ID of the AVM (e.g. avm-ptn-alz-managment)"
}

variable "github_owner_team_name_postfix" {
  type        = string
  description = "Name of the GitHub owner team."
  default     = "module-owners-tf"
}

variable "github_contributor_team_name_postfix" {
  type        = string
  description = "Name of the GitHub owner team."
  default     = "module-contributors-tf"
}

variable "maintainer_teams" {
  type        = map(string)
  description = "Map of teams that should have maintainers added to the repository."
  default = {
    avm_core      = "avm-core-team-technical-terraform"
    terraform_avm = "terraform-avm"
  }
}
