locals {
  must_exist_files = tomap({
    "main.tf" : "",
    "terraform.tf" : ""
    "_header.md" : "",
  })
}

rule "must_be_true" "must_exist_files" {
  for_each      = local.must_exist_files
  condition     = fileexists(each.key)
  error_message = "File ${each.key} must exist"
}

fix "local_file" "must_exist_files" {
  for_each = local.must_exist_files

  rule_ids = [rule.must_be_true.must_exist_files[each.key].id]
  paths    = [each.key]
  content  = each.value
}
