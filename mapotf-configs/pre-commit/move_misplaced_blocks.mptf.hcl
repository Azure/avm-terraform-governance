# Move stray non-canonical blocks out of variables.tf / outputs.tf so each file contains only
# its canonical block kind. Any non-canonical block whose source file is variables.tf (or vice
# versa for outputs.tf) is relocated to main.tf.
#
# IMPORTANT: variable / output blocks are excluded from BOTH directions. They are relocated to
# their canonical file by sort_blocks_in_file in sort_variables.mptf.hcl / sort_outputs.mptf.hcl.
# Those transforms use per-file `for_each` keyed by `mptf.range.file_name` to preserve canonical
# multi-file layouts (e.g. `variables.diagnostics.tf`, `variables.share.tf`) while still
# consolidating strays from non-canonical files into the default `variables.tf` / `outputs.tf`.
# Allowing move_block to also relocate variables/outputs would cause a transform-interaction
# issue with sort_blocks_in_file and leave duplicated unstructured token sequences behind.

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

  # Non-canonical blocks (i.e. not variable or output) living in variables.tf → main.tf.
  # Output blocks are excluded; sort_outputs.outputs_tf relocates them directly to outputs.tf.
  non_canonical_in_variables_tf = {
    for x in local.all_addrs : x.addr => x.v
    if try(x.v.mptf.range.file_name, "") == "variables.tf"
       && !startswith(x.addr, "variable.")
       && !startswith(x.addr, "output.")
  }

  # Non-canonical blocks (i.e. not output or variable) living in outputs.tf → main.tf.
  # Variable blocks are excluded; sort_variables.variables_tf relocates them directly to variables.tf.
  non_canonical_in_outputs_tf = {
    for x in local.all_addrs : x.addr => x.v
    if try(x.v.mptf.range.file_name, "") == "outputs.tf"
       && !startswith(x.addr, "output.")
       && !startswith(x.addr, "variable.")
  }
}

transform "move_block" "out_of_variables_tf" {
  for_each             = local.non_canonical_in_variables_tf
  target_block_address = each.key
  file_name            = "main.tf"
}

transform "move_block" "out_of_outputs_tf" {
  for_each             = local.non_canonical_in_outputs_tf
  target_block_address = each.key
  file_name            = "main.tf"
}
