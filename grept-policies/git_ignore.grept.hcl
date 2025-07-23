locals {
  ignored_items = toset([
    ".DS_Store",
    ".terraform.lock.hcl",
    ".terraformrc",
    "*.md.tmp",
    "*.mptfbackup",
    "*.tfstate.*",
    "*.tfstate",
    "*.tfvars.json",
    "*.tfvars",
    "**/.terraform/*",
    "*tfplan*",
    "avm.tflint_example.hcl",
    "avm.tflint_example.merged.hcl",
    "avm.tflint_module.hcl",
    "avm.tflint_module.merged.hcl",
    "avm.tflint.hcl",
    "avm.tflint.merged.hcl",
    "avmmakefile",
    "crash.*.log",
    "crash.log",
    "examples/*/policy",
    "README-generated.md",
    "terraform.rc",
    ".avm",
    ".vscode/mcp.json",
  ])
}

data "git_ignore" "current_ignored_items" {}

rule "must_be_true" "essential_ignored_items" {
  condition = length(compliment(local.ignored_items, data.git_ignore.current_ignored_items.records)) == 0
}

fix "git_ignore" "ensure_ignore" {
  rule_ids = [rule.must_be_true.essential_ignored_items.id]
  exist    = local.ignored_items
}
