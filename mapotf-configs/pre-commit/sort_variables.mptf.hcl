data "variable" "for_sort" {}

locals {
  vars           = data.variable.for_sort.result
  required_names = sort([for n, v in local.vars : n if !contains(keys(v), "default")])
  optional_names = sort([for n, v in local.vars : n if contains(keys(v), "default")])
  ordered_vars   = concat(local.required_names, local.optional_names)
}

# Re-order attributes inside every variable block: type, default, description, nullable, sensitive.
# Anything else (validation, etc.) stays as a nested element handled by mapotf's reorder_attributes
# nested-block semantics.
transform "reorder_attributes" "var_attrs" {
  for_each                 = local.vars
  target_block_address     = "variable.${each.key}"
  head_attributes          = ["type", "default", "description", "nullable", "sensitive"]
  sort_body_alphabetically = false
}

# Drop redundant nullable = true (the language default).
transform "remove_block_element" "drop_nullable_true" {
  for_each             = { for n, v in local.vars : n => v if try(v.nullable, null) == true }
  target_block_address = "variable.${each.key}"
  paths                = ["nullable"]
}

# Drop redundant sensitive = false (the language default).
transform "remove_block_element" "drop_sensitive_false" {
  for_each             = { for n, v in local.vars : n => v if try(v.sensitive, null) == false }
  target_block_address = "variable.${each.key}"
  paths                = ["sensitive"]
}

# Consolidate + order every variable block into variables.tf.
# Blocks already in variables.tf that are not variable.* are not touched here
# (move_misplaced_blocks.mptf.hcl handles that side of the contract).
transform "sort_blocks_in_file" "variables_tf" {
  file_name     = "variables.tf"
  desired_order = [for n in local.ordered_vars : "variable.${n}"]
}
