data "output" "for_sort" {}

locals {
  outs = data.output.for_sort.result

  # Each output's target file: stay in its current file if that file already
  # matches `*outputs*.tf`; otherwise route to `outputs.tf`. This preserves
  # multi-file output layouts while consolidating strays.
  outs_with_tf = {
    for n, v in local.outs : n => {
      v = v
      target_file = (
        length(regexall("outputs.*\\.tf$", try(v.mptf.range.file_name, ""))) > 0
        ? v.mptf.range.file_name
        : "outputs.tf"
      )
    }
  }

  out_target_files = distinct([for n, vf in local.outs_with_tf : vf.target_file])

  # Per-target-file ordered list (pure alphabetical).
  ordered_outs_by_file = {
    for f in local.out_target_files : f => sort([for n, vf in local.outs_with_tf : n if vf.target_file == f])
  }
}

# Sort every output's body alphabetically. No fixed head/foot list: all known output attrs
# (`description`, `sensitive`, `ephemeral`, `value`, `depends_on`, `precondition`) sort by name.
transform "reorder_attributes" "output_attrs" {
  for_each                 = local.outs
  target_block_address     = "output.${each.key}"
  sort_body_alphabetically = true
}

# Drop redundant sensitive = false (the language default).
transform "remove_block_element" "drop_output_sensitive_false" {
  for_each             = { for n, v in local.outs : n => v if try(v.sensitive, null) == false }
  target_block_address = "output.${each.key}"
  paths                = ["sensitive"]
}

# Drop redundant ephemeral = false (the language default).
transform "remove_block_element" "drop_output_ephemeral_false" {
  for_each             = { for n, v in local.outs : n => v if try(v.ephemeral, null) == false }
  target_block_address = "output.${each.key}"
  paths                = ["ephemeral"]
}

# Per-file sort. One transform per file that currently holds at least one output
# (canonical `*outputs*.tf` files preserve their split; strays land in `outputs.tf`).
transform "sort_blocks_in_file" "outs_per_file" {
  for_each      = local.ordered_outs_by_file
  file_name     = each.key
  desired_order = [for n in each.value : "output.${n}"]
}
