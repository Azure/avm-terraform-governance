# Managed files for AVM repositories.
#
# The map of source-backed files to sync is built by `Invoke-RepositorySync.ps1`
# and passed in via `var.managed_files`. The PowerShell driver walks
# `managed-files/root/` (plus the per-group overlay selected by
# `managedFilesAdditional`, with the overlay winning on conflict) and removes
# anything listed in the matching repository group's `excludedManagedFiles`.
# The CODEOWNERS file is then folded in by the module itself with content
# rendered from the per-repo CODEOWNERS template, so a single
# `github_repository_file.managed` resource governs every synced file.
#
# Keeping the source-file map build outside Terraform avoids
# `path.module`-relative directory traversal and makes overlay/exclusion
# behaviour testable from a single place.

locals {
  codeowners_file_path       = ".github/CODEOWNERS"
  codeowners_default_line    = join(" ", [for team in var.codeowners_default_teams : "@${var.github_repository_owner}/${team}"])
  codeowners_protection_line = join(" ", [for team in var.codeowners_file_protection_teams : "@${var.github_repository_owner}/${team}"])
  codeowners_content = templatefile("${path.module}/templates/CODEOWNERS.tftpl", {
    default_owners         = local.codeowners_default_line
    file_protection_owners = local.codeowners_protection_line
  })

  # Combined set of files to sync: every file from `var.managed_files` plus
  # the templated CODEOWNERS. Each value describes how to obtain the
  # content (from disk via `source`, or pre-computed in HCL via `content`).
  managed_file_set = merge(
    { for path, source in var.managed_files : path => { source = source, content = null } },
    { (local.codeowners_file_path) = { source = null, content = local.codeowners_content } },
  )
}

# Drop the previous standalone CODEOWNERS resource from state without
# destroying the file in the target repo. The `import` block written by
# Invoke-RepositorySync.ps1 on the same plan then re-adopts the existing
# `.github/CODEOWNERS` under `github_repository_file.managed`, so no commit
# is made unless the CODEOWNERS content actually changes.
removed {
  from = github_repository_file.codeowners
  lifecycle {
    destroy = false
  }
}

# Syncs each managed file to the target repository.
#
# `overwrite_on_create = false` keeps the first apply against a repo that
# already contains a managed file as a no-op for that file. The PowerShell
# driver (Invoke-RepositorySync.ps1) writes an `imports.tf` file with
# `import` blocks for every pre-existing target-repo file on the first sync
# run so subsequent plans only diff content that actually differs from the
# managed source. `[skip ci]` keeps the commit from triggering downstream
# workflows in the target repository.
resource "github_repository_file" "managed" {
  for_each = var.repository_creation_mode_enabled ? {} : local.managed_file_set

  repository          = github_repository.this.name
  file                = each.key
  content             = each.value.content != null ? each.value.content : file(each.value.source)
  commit_message      = "chore: sync managed file ${each.key} [skip ci]"
  overwrite_on_create = false

  lifecycle {
    ignore_changes = [
      commit_author,
      commit_email,
    ]
  }
}

