variable "target_subscription_id" {
  type        = string
  description = "Id of the subscription to run tests in."
}

variable "management_group_id" {
  type        = string
  description = "Id of the management group to create the role assignment in."
}

variable "identity_resource_group_name" {
  type        = string
  description = "Name of the resource group to create the identities in."
}

variable "github_repository_owner" {
  type        = string
  description = "Owner of the GitHub repositories."
}

variable "github_repository_name" {
  type        = string
  description = "Name of the GitHub repository."
}

variable "github_repository_environment_name" {
  type        = string
  description = "Name of the environment used to store secrets for the test environment."
}

variable "location" {
  type        = string
  description = "Location of the resources."
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
}

variable "github_job_workflow_ref_suffix" {
  type        = string
  description = "Suffix to append to the GitHub Actions job workflow ref claim."
}
