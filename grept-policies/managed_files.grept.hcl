locals {
  managed_files_to_skip = [
    ".github/workflows/copilot-setup-steps.yml"
  ]

  managed_files_additional_set            = env("AVM_MANAGED_FILES_ADDITIONAL")
  managed_files_directory_path            = "${env("AVM_GOVERNANCE_REPO_DIR")}/managed-files/%s"
  managed_files_directory_path_root       = format(local.managed_files_directory_path, "root")
  managed_files_directory_path_additional = local.managed_files_additional_set == null || local.managed_files_additional_set == "" ? null : format(local.managed_files_directory_path, "root")

  managed_files_root           = { for file in fileset(local.managed_files_directory_path_root, "**") : file => file(${local.managed_files_directory_path_root}/${file}) if !contains(local.managed_files_to_skip, file) }
  managed_files_additional     = local.managed_files_directory_path_additional == null ? {} : { for file in fileset(local.managed_files_directory_path_additional, "**") : file => file(${local.managed_files_directory_path_additional}/${file}) if !contains(local.managed_files_to_skip, file) }
  managed_files_final          = merge(local.managed_files_root, local.managed_files_additional)
}

rule "file_hash" "managed_files" {
  for_each = local.managed_files_final

  glob = each.key
  hash = sha1(each.value)
}

fix "local_file" "managed_files" {
  for_each = local.managed_files_final

  rule_ids = [rule.file_hash.managed_files[each.key].id]
  paths    = [each.key]
  content  = each.value
}
