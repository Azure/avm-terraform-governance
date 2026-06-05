# Managed files for AVM repositories.
#
# The map of files to sync is built by `Invoke-RepositorySync.ps1` and passed
# in via `var.managed_files`. The PowerShell driver walks `managed-files/root/`
# (plus the per-group overlay selected by `managedFilesAdditional`, with the
# overlay winning on conflict) and removes anything listed in the matching
# repository group's `excludedManagedFiles`. Keeping the map build outside
# Terraform avoids `path.module`-relative directory traversal and makes
# overlay/exclusion behaviour testable from a single place.

# Syncs each managed file to the target repository. `overwrite_on_create`
# ensures the initial apply against an existing repository adopts whatever is
# already there. `[skip ci]` keeps the commit from triggering downstream
# workflows in the target repository.
resource "github_repository_file" "managed" {
  for_each = var.repository_creation_mode_enabled ? {} : var.managed_files

  repository          = github_repository.this.name
  file                = each.key
  content             = file(each.value)
  commit_message      = "chore: sync managed file ${each.key} [skip ci]"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [
      commit_author,
      commit_email,
    ]
  }
}
