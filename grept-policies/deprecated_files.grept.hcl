locals {
  deprecated_files = toset([
    ".github/policies/avmrequiredfiles.yml",
    ".github/workflows/e2e.yml",
    ".github/workflows/grept_cronjob.yml",
    ".github/workflows/linting.yml",
    ".github/workflows/version-check.yml",
    "locals.telemetry.tf",
    "locals.version.tf.json",
  ])
}

rule "must_be_true" "deprecated_file" {
  for_each  = local.deprecated_files
  condition = !fileexists(each.value)
}

fix "rm_local_file" "deprecated_file" {
  for_each = local.deprecated_files
  rule_ids = [rule.must_be_true.deprecated_file[each.key].id]
  paths    = [each.value]
}
