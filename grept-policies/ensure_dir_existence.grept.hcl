locals {
  must_exist_dirs = toset([
    "examples",
    "tests",
  ])
}

rule "dir_exist" "dir_must_exist" {
  for_each = local.must_exist_dirs

  dir = each.value
}

fix "local_file" "dir_keep" {
  for_each = local.must_exist_dirs

  rule_ids = [rule.dir_exist.dir_must_exist[each.key].id]
  paths    = ["${each.value}/.gitkeep"]
  content  = ""
}
