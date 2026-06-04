# Order the meta-arguments on every module call. Inputs (the "middle") keep source order
# because mapotf cannot yet introspect the source module's variables.tf to do
# required-before-optional ordering.

data "module" "for_order" {}
data "moved"  "for_order" {}

transform "reorder_attributes" "module_meta" {
  for_each                   = data.module.for_order.result
  target_block_address       = "module.${each.key}"
  head_attributes            = ["for_each", "count", "source", "version", "providers"]
  tail_attributes            = ["depends_on"]
  sort_middle_alphabetically = false
}

transform "reorder_attributes" "moved_attrs" {
  for_each                   = data.moved.for_order.result
  target_block_address       = "moved.${each.key}"
  head_attributes            = ["from", "to"]
  sort_middle_alphabetically = false
}
