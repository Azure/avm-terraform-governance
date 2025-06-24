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

variable "github_core_team_name" {
  type        = string
  description = "Name of the GitHub core team."
  default     = "avm-core-team-technical-terraform"
}

variable "github_owner_team_name" {
  type        = string
  description = "Name of the GitHub owner team."
}

variable "github_contributor_team_name" {
  type        = string
  description = "Name of the GitHub owner team."
}

variable "location" {
  type        = string
  description = "Location of the resources."
  default     = "eastus2"
}

variable "manage_github_environment" {
  type        = bool
  description = "Whether to manage the environment."
  default     = false
}

variable "github_labels_source_path" {
  type        = string
  description = "Source csv for labels."
  default     = "./temp/labels.csv"
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
  default     = false
}
