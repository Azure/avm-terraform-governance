locals {
  deprecated_files = toset([
    "locals.telemetry.tf",
    "locals.version.tf.json"
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
