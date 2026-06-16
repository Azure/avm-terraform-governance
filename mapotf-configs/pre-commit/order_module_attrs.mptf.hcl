# Order every module call.
#
#   head : meta-arguments — source, version and providers first (in authored
#          order), then count, then for_each.
#   body : required inputs (alpha) → optional inputs (alpha) — discovered via
#          `data "module_source"` which loads the target module with
#          `terraform-config-inspect`. Local sources (`./`, `../`, absolute paths)
#          and registry/git/http sources are both supported by mapotf >= v0.1.4.
#          Each group is wrapped in `sort()` because mapotf v0.1.4 returns
#          `required_variables` / `optional_variables` in source-declaration
#          order, not alphabetical.
#   foot : depends_on
#
# Modules whose `source` cannot be inspected (e.g. computed from a variable) are
# silently skipped — `data "module_source"` returns empty `required_variables` /
# `optional_variables`, leaving the meta-arg ordering still applied.

data "module" "for_order" {}
data "moved" "for_order" {}

data "module_source" "for_order" {
  for_each = data.module.for_order.result
  source   = each.value.source
  version  = try(each.value.version, "")
}

transform "reorder_attributes" "module_full" {
  # try() wrapper handles the zero-iteration case: when a tf-dir has no
  # `module {}` blocks, `data.module_source.for_order` is not registered at all
  # (mapotf v0.1.4 quirk — namespace only registers when for_each fires at
  # least once). `try(..., {})` makes the transform a no-op in that case.
  for_each                 = try(data.module_source.for_order, {})
  target_block_address     = "module.${each.key}"
  head_attributes          = ["source", "version", "providers", "count", "for_each"]
  body_attributes          = concat(sort(each.value.required_variables), sort(each.value.optional_variables))
  foot_attributes          = ["depends_on"]
  sort_body_alphabetically = false
}

transform "reorder_attributes" "moved_attrs" {
  for_each                 = data.moved.for_order.result
  target_block_address     = "moved.${each.key}"
  head_attributes          = ["from", "to"]
  sort_body_alphabetically = false
}
