# Managed files for AVM repositories.
#
# Files under `managed-files/root/` are synced to every repository. When
# `var.managed_files_additional` is non-empty (e.g. `alz` for Azure Landing
# Zones modules), the files under `managed-files/<set>/` are merged on top of
# the root set, with the overlay winning on conflict.
#
# The canonical list of deprecated files lives in
# `tf-repo-mgmt/repository-config/deprecated-files.json` so the same source of
# truth drives both this Terraform configuration and the PowerShell import
# pre-step in `Invoke-RepositorySync.ps1`.
locals {
  managed_files_repo_root_dir       = abspath("${path.module}/../../../..")
  managed_files_root_dir            = "${local.managed_files_repo_root_dir}/managed-files/root"
  managed_files_additional_dir      = var.managed_files_additional == "" ? "" : "${local.managed_files_repo_root_dir}/managed-files/${var.managed_files_additional}"
  managed_files_deprecated_raw      = jsondecode(file("${local.managed_files_repo_root_dir}/tf-repo-mgmt/repository-config/deprecated-files.json"))
  managed_files_deprecated_root_set = toset(local.managed_files_deprecated_raw.root)
  managed_files_deprecated_additional_set = var.managed_files_additional == "" ? toset([]) : toset(
    lookup(local.managed_files_deprecated_raw, var.managed_files_additional, [])
  )
  managed_files_deprecated_all = setunion(
    local.managed_files_deprecated_root_set,
    local.managed_files_deprecated_additional_set,
  )

  managed_files_root_map = {
    for f in fileset(local.managed_files_root_dir, "**") :
    f => "${local.managed_files_root_dir}/${f}"
    if !contains(local.managed_files_deprecated_all, f)
  }

  managed_files_additional_map = local.managed_files_additional_dir == "" ? {} : {
    for f in fileset(local.managed_files_additional_dir, "**") :
    f => "${local.managed_files_additional_dir}/${f}"
    if !contains(local.managed_files_deprecated_all, f)
  }

  managed_files_final = merge(local.managed_files_root_map, local.managed_files_additional_map)
}

# Syncs each managed file to the target repository. `overwrite_on_create`
# ensures the initial apply against an existing repository adopts whatever is
# already there. `[skip ci]` keeps the commit from triggering downstream
# workflows in the target repository.
resource "github_repository_file" "managed" {
  for_each = var.repository_creation_mode_enabled ? {} : local.managed_files_final

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

# Removes deprecated files from target repositories. Instances are imported
# into state by `Invoke-RepositorySync.ps1` before each `terraform apply`;
# imports for files that no longer exist on the remote fail silently, so this
# block is naturally a no-op once cleanup has run against a given repository.
removed {
  from = github_repository_file.deprecated_files

  lifecycle {
    destroy = true
  }
}
