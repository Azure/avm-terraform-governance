locals {
  codeowners_file_path       = ".github/CODEOWNERS"
  codeowners_default_line    = join(" ", [for team in var.codeowners_default_teams : "@${var.github_repository_owner}/${team}"])
  codeowners_protection_line = join(" ", [for team in var.codeowners_file_protection_teams : "@${var.github_repository_owner}/${team}"])
  codeowners_content = templatefile("${path.module}/templates/CODEOWNERS.tftpl", {
    default_owners         = local.codeowners_default_line
    file_protection_owners = local.codeowners_protection_line
  })
}

# The CODEOWNERS file is managed dynamically rather than via the managed-files
# grept policies because the content varies per repository (tier).
#
# The GitHub App used by this provider is configured as a bypass actor on the
# main branch ruleset, so the commit pushes directly to the default branch
# without requiring a pull request. The commit message includes `[skip ci]` so
# the change does not trigger CI runs in the target repository.
resource "github_repository_file" "codeowners" {
  count               = var.repository_creation_mode_enabled ? 0 : 1
  repository          = github_repository.this.name
  file                = local.codeowners_file_path
  content             = local.codeowners_content
  commit_message      = "chore: update CODEOWNERS [skip ci]"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [
      commit_author,
      commit_email,
    ]
  }
}
