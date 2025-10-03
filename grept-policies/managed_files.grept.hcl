locals {
  managed_files = toset([
    "_footer.md",
    ".devcontainer/devcontainer.json",
    ".editorconfig",
    ".github/CODEOWNERS",
    ".github/copilot-instructions.md",
    ".github/ISSUE_TEMPLATE/avm_module_issue.yml",
    ".github/ISSUE_TEMPLATE/avm_question_feedback.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/policies/eventResponder.yml",
    ".github/policies/scheduledSearches.yml",
    ".github/PULL_REQUEST_TEMPLATE.md",
    # ".github/workflows/copilot-setup-steps.yml", disabled for now until we test more thoroughly
    ".github/workflows/pr-check.yml",
    ".terraform-docs.yml",
    ".vscode/mcp.json",
    ".vscode/settings.json",
    "AGENTS.md",
    "avm.bat",
    "avm.ps1",
    "avm",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "examples/.terraform-docs.yml",
    "LICENSE",
    "Makefile",
    "modules/.terraform-docs.yml",
    "SECURITY.md",
    "SUPPORT.md",
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
