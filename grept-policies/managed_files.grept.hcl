# Until we update the template repository, we need a way to keep core files updated.
locals {
  managed_files = toset([
    "avm",
    "avm.bat",
    "avm.ps1",
    "Makefile",
    ".devcontainer/devcontainer.json",
    ".github/workflows/pr-check.yml",
  ])

  managed_files_ref        = coalesce(env("AVM_MANAGED_FILES_REF"), "main")
  managed_files_url_prefix = "https://raw.githubusercontent.com/Azure/avm-terraform-governance/${local.managed_files_ref}/managed-files/root/"
}

data "http" "managed_files" {
  for_each = local.managed_files

  request_headers = merge({}, local.common_http_headers)
  url             = "${local.managed_files_url_prefix}${each.value}"
}

rule "file_hash" "managed_files" {
  for_each = local.managed_files

  glob = each.value
  hash = sha1(data.http.managed_files[each.value].response_body)
}

fix "local_file" "managed_files" {
  for_each = local.managed_files

  rule_ids = [rule.file_hash.managed_files[each.value].id]
  paths    = [each.value]
  content  = data.http.managed_files[each.value].response_body
}
