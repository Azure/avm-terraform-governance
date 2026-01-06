locals {
  deprecated_files = {
    root = toset([
      ".github/actions/version-check/action.yml",
      ".github/policies/avmrequiredfiles.yml",
      ".github/workflows/e2e.yml",
      ".github/workflows/grept_cronjob.yml",
      ".github/workflows/linting.yml",
      ".github/workflows/version-check.yml",
      "locals.telemetry.tf",
      "locals.version.tf.json",
    ])
    alz = toset([
      ".github/ISSUE_TEMPLATE/avm_module_issue.yml",
    ])
  }

  deprecated_files_additional_set = env("AVM_MANAGED_FILES_ADDITIONAL")
  deprecated_files_final          = setunion(local.deprecated_files["root"], local.deprecated_files_additional_set == null || local.deprecated_files_additional_set == "" ? toset([]) : local.deprecated_files[local.deprecated_files_additional_set])
}

rule "must_be_true" "deprecated_file" {
  for_each  = local.deprecated_files_final
  condition = !fileexists(each.value)
  depends_on = [ local_file.managed_files ]
}

fix "rm_local_file" "deprecated_file" {
  for_each = local.deprecated_files_final
  rule_ids = [rule.must_be_true.deprecated_file[each.key].id]
  paths    = [each.value]
}
