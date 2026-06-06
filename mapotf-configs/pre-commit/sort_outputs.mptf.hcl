data "output" "for_sort" {}

locals {
  outs         = data.output.for_sort.result
  ordered_outs = sort(keys(local.outs))
}

# AVM spec for outputs: known attrs in this fixed order; unlisted attrs are rare and stay at the end
# in source order.
transform "reorder_attributes" "output_attrs" {
  for_each                 = local.outs
  target_block_address     = "output.${each.key}"
  head_attributes          = ["description", "value", "sensitive"]
  foot_attributes          = ["depends_on"]
  sort_body_alphabetically = false
}

transform "remove_block_element" "drop_output_sensitive_false" {
  for_each             = { for n, v in local.outs : n => v if try(v.sensitive, "") == "false" }
  target_block_address = "output.${each.key}"
  paths                = ["sensitive"]
}

transform "sort_blocks_in_file" "outputs_tf" {
  file_name     = "outputs.tf"
  desired_order = [for n in local.ordered_outs : "output.${n}"]
}
