# State-only cleanup for the previous Terraform-managed file sync.
#
# Until this PR, every managed file under `managed-files/<...>` (plus a
# rendered `.github/CODEOWNERS`) was projected into a per-file
# `github_repository_file.managed[path]` resource. The PowerShell driver
# imported pre-existing files into state on first sync, and Terraform owned
# every subsequent content update.
#
# That design was replaced by `Sync-RepoFiles` in
# `tf-repo-mgmt/scripts/lib/RepoFilesSync.ps1`, which clones the target repo
# once per sync run, applies removals/adds/updates against the cached git
# tree, and opens-then-merges a single bot PR. Doing the file mutations
# outside of Terraform sidesteps the "one commit per file" amplification of
# `github_repository_file` and lets us add (not just remove) files in the
# same flow.
#
# The `removed` blocks below drop the stale state entries WITHOUT touching
# the actual files in the target repo. They can be deleted in a future
# cleanup PR once every state file has been pruned by at least one apply.
# `lifecycle { destroy = false }` requires Terraform 1.7+ (already pinned
# via `required_version`).

removed {
  from = github_repository_file.managed
  lifecycle {
    destroy = false
  }
}

removed {
  from = github_repository_file.codeowners
  lifecycle {
    destroy = false
  }
}
