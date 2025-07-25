variable "repository_creation_mode_enabled" {
  type        = bool
  description = "Whether we are running in repository creation mode."
}

variable "arm_subscription_id" {
  type        = string
  description = "Id of the subscription to run tests in."
}

variable "arm_client_id" {
  type        = string
  description = "Client ID of the service principal to use for ARM operations."
}

variable "arm_tenant_id" {
  type        = string
  description = "Tenant of the service principal to use for ARM operations."
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
}

variable "github_repository_name" {
  type        = string
  description = "Name of the GitHub repository."
}

variable "module_id" {
  type        = string
  description = "ID of the AVM (e.g. avm-ptn-alz-managment)"
}

variable "module_name" {
  type        = string
  description = "Description of the AVM (e.g. Azure Landing Zones Management Resources)"
}

variable "github_repository_environment_name" {
  type        = string
  description = "Name of the environment used to store secrets for the test environment."
}

variable "github_repository_no_approval_environment_name" {
  type        = string
  description = "Name of the environment used as a dummy no approval environment."
}

variable "github_teams" {
  type = map(object({
    slug                         = string
    description                  = optional(string, "")
    repository_access_permission = optional(string, "none")
    environment_approval         = optional(bool, false)
    created_with_repository      = optional(bool, false)
    members_are_team_maintainers = optional(bool, false)
  }))
  description = <<DESCRIPTION
Map of GitHub teams to be created or managed.

- `slug`: The slug of the team.
- `repository_access_level`: The access level for the team on the repository, can be `push` or `maintain` (default is "none").
- `environment_approval`: Whether the team is an approver for the environment (default is false)
DESCRIPTION
}

variable "labels" {
  type = map(object({
    name        = string
    color       = string
    description = string
  }))
  description = "Source csv for labels."
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
}

variable "bypass_ruleset_for_approval_enabled" {
  type        = bool
  description = "Whether to bypass the ruleset for approval for the GitHub App."
}

variable "github_avm_app_id" {
  type        = string
  description = "The GitHub App ID for the AVM."
}

variable "custom_subject_claims_enabled" {
  type        = bool
  description = "Whether custom subject claims are enabled for the GitHub Actions OIDC integration."
}

variable "module_owner_github_handles" {
  type        = map(string)
  description = "Map of module owner GitHub handles."
}
