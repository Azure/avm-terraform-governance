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

variable "github_repository_environment_names" {
  type        = set(string)
  description = "Names of the GitHub environments to create federated identity credentials for. The OIDC subject claim includes the environment name, so one credential is created per environment."
}

variable "location" {
  type        = string
  description = "Location of the resources."
}

variable "is_protected_repo" {
  type        = bool
  description = "Whether the repository is protected and requires pull request approval."
}

variable "github_job_workflow_ref" {
  type        = string
  description = "GitHub Actions job workflow ref."
}

variable "github_organization_id" {
  type        = string
  description = "ID of the GitHub organization."
}

variable "github_repository_id" {
  type        = string
  description = "ID of the GitHub repository."
}
