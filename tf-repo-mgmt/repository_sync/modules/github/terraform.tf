terraform {
  # `removed { lifecycle { destroy = false } }` (see
  # github.repository.removed_managed_files.tf) requires Terraform 1.7+.
  required_version = ">= 1.7.0"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
    }
  }
}
