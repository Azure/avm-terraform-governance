data "github_organization" "this" {
  name         = var.github_repository_owner
  summary_only = true
}
