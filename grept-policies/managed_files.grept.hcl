locals {
  managed_files = {
    root = toset([
      ".devcontainer/devcontainer.json",
      ".editorconfig",
      ".gitattributes",
      ".github/CODEOWNERS",
      ".github/ISSUE_TEMPLATE/avm_module_issue.yml",
      ".github/ISSUE_TEMPLATE/avm_question_feedback.yml",
      ".github/ISSUE_TEMPLATE/config.yml",
      ".github/PULL_REQUEST_TEMPLATE.md",
      ".github/copilot-instructions.md",
      ".github/policies/eventResponder.yml",
      ".github/policies/scheduledSearches.yml",
      ".github/workflows/pr-check.yml",
      ".terraform-docs.yml",
      ".vscode/mcp.json",
      ".vscode/extensions.json",
      ".vscode/settings.json",
      "AGENTS.md",
      "CODE_OF_CONDUCT.md",
      "CONTRIBUTING.md",
      "LICENSE",
      "Makefile",
      "SECURITY.md",
      "SUPPORT.md",
      "_footer.md",
      "avm",
      "avm.bat",
      "avm.ps1",
      "examples/.terraform-docs.yml",
      "modules/.terraform-docs.yml",
      # ".github/workflows/copilot-setup-steps.yml", disabled for now until we test more thoroughly
    ])
    alz = toset([
      ".github/ISSUE_TEMPLATE/config.yml",
    ])
  }

  managed_files_ref            = coalesce(env("AVM_MANAGED_FILES_REF"), "main")
  managed_files_url_prefix     = "https://raw.githubusercontent.com/Azure/avm-terraform-governance/${local.managed_files_ref}/managed-files/%s/"
  managed_files_default_set    = coalesce(env("AVM_MANAGED_FILES_DEFAULT"), "root")
  managed_files_additional_set = coalesce(env("AVM_MANAGED_FILES_ADDITIONAL"), "")
  managed_files_root           = { for file in local.managed_files["root"] : file => "root" }
  managed_files_additional     = local.managed_files_additional_set == "" ? {} : { for file in local.managed_files[local.managed_files_additional_set] : file => local.managed_files_additional_set }
  managed_files_final          = merge(local.managed_files_root, local.managed_files_additional)
}

data "http" "managed_files" {
  for_each = local.managed_files_final

  request_headers = merge({}, local.common_http_headers)
  url             = "${format(local.managed_files_url_prefix, each.value)}${each.key}"
}

rule "file_hash" "managed_files" {
  for_each = local.managed_files_final

  glob = each.key
  hash = sha1(data.http.managed_files[each.key].response_body)
}

fix "local_file" "managed_files" {
  for_each = local.managed_files_final

  rule_ids = [rule.file_hash.managed_files[each.key].id]
  paths    = [each.key]
  content  = data.http.managed_files[each.key].response_body
}
