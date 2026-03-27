output "organization_id" {
  description = "The GitHub organization ID."
  value       = data.github_organization.this.id
}

output "repository_id" {
  description = "The GitHub repository ID."
  value       = github_repository.this.repo_id
}