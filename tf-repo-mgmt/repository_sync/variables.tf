variable "repository_creation_mode_enabled" {
  type        = bool
  description = "Whether we are running in repository creation mode."
  default     = false
}

variable "target_subscription_id" {
  type        = string
  description = "Id of the subscription to run tests in."
}

variable "identity_resource_group_name" {
  type        = string
  description = "Name of the resource group to create the identities in."
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
  default     = "Azure"
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
  default     = "test"
}

variable "github_repository_no_approval_environment_name" {
  type        = string
  description = "Name of the environment used as a dummy no approval environment."
  default     = "empty-no-approval"
}

variable "github_teams" {
  type = map(object({
    slug                         = string
    description                  = optional(string, "")
    repository_access_permission = optional(string, "none")
    environment_approval         = optional(bool, false)
  }))
  description = <<DESCRIPTION
Map of GitHub teams to be created or managed.

- `slug`: The slug of the team.
- `repository_access_level`: The access level for the team on the repository, can be `push` or `maintain` (default is "none").
- `environment_approval`: Whether the team is an approver for the environment (default is false)
DESCRIPTION
}

variable "location" {
  type        = string
  description = "Location of the resources."
  default     = "eastus2"
}

variable "github_labels_source_path" {
  type        = string
  description = "Source csv for labels."
  default     = "../temp/labels.csv"
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
  default     = false
}

variable "github_job_workflow_ref_suffix" {
  type        = string
  description = "GitHub job workflow ref to use for the federated identity credentials."
  default     = ":job_workflow_ref:Azure/avm-terraform-governance/.github/workflows/managed-pr-check.yml@refs/heads/main"
}

variable "feature_flags" {
  type        = map(set(string))
  description = "The feature flags to enable for the job."
  default = {
    preview_github_actions_oidc_subject_claim_customization = [
      "terraform-azure-avm-utl-interfaces",
      "terraform-azurerm-avm-res-keyvault-vault",
    ]
  }
}

variable "github_avm_app_id" {
  type        = string
  description = "The GitHub App ID for the AVM."
  default     = "1049636"
}
