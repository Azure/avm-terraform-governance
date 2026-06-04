# avmfix moves blocks out of variables.tf / outputs.tf if they aren't of the canonical type.
# Mirror that behaviour by addressing every non-variable block whose source file is variables.tf
# (or vice versa for outputs.tf) and moving it into main.tf.

data "resource" "for_move" {}
data "data"     "for_move" {}
data "module"   "for_move" {}
data "output"   "for_move" {}
data "variable" "for_move" {}
data "moved"    "for_move" {}

locals {
  # Address every root block keyed by its full address, with its mptf metadata available.
  resource_addrs = flatten([
    for t, by_name in data.resource.for_move.result : [
      for k, v in by_name : { addr = "resource.${t}.${k}", v = v }
    ]
  ])
  data_addrs = flatten([
    for t, by_name in data.data.for_move.result : [
      for k, v in by_name : { addr = "data.${t}.${k}", v = v }
    ]
  ])
  module_addrs   = [for k, v in data.module.for_move.result   : { addr = "module.${k}",   v = v }]
  output_addrs   = [for k, v in data.output.for_move.result   : { addr = "output.${k}",   v = v }]
  variable_addrs = [for k, v in data.variable.for_move.result : { addr = "variable.${k}", v = v }]
  moved_addrs    = [for k, v in data.moved.for_move.result    : { addr = "moved.${k}",    v = v }]

  all_addrs = concat(
    local.resource_addrs,
    local.data_addrs,
    local.module_addrs,
    local.output_addrs,
    local.variable_addrs,
    local.moved_addrs,
  )

  # Non-variable blocks living in variables.tf → main.tf
  non_var_in_variables_tf = {
    for x in local.all_addrs : x.addr => x.v
    if try(x.v.mptf.range.file_name, "") == "variables.tf" && !startswith(x.addr, "variable.")
  }

  # Non-output blocks living in outputs.tf → main.tf
  non_output_in_outputs_tf = {
    for x in local.all_addrs : x.addr => x.v
    if try(x.v.mptf.range.file_name, "") == "outputs.tf" && !startswith(x.addr, "output.")
  }
}

transform "move_block" "out_of_variables_tf" {
  for_each             = local.non_var_in_variables_tf
  target_block_address = each.key
  file_name            = "main.tf"
}

transform "move_block" "out_of_outputs_tf" {
  for_each             = local.non_output_in_outputs_tf
  target_block_address = each.key
  file_name            = "main.tf"
}
