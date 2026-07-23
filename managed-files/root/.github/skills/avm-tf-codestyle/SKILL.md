---
name: avm-tf-codestyle
description: Use this skill whenever a contributor needs to write or review the structural plumbing of an Azure Verified Module (AVM) in Terraform — file layout, provider pinning in `terraform.tf`, variable and output ordering, snake_case naming, variable validation, sensitive flags, formatting (`terraform fmt`), linting (`tflint`), and the `avmfix` auto-fixer. Covers what each canonical file (main.tf, main.*.tf, variables.tf, outputs.tf, locals.tf, terraform.tf) is for, the required provider version constraints, and the conventions the AVM CI will enforce (TFNFR4 for snake_case, TFNFR5/7/8 for variable hygiene). Trigger on phrases like "AVM file layout", "terraform.tf", "required_providers AVM", "AzAPI version pin", "snake_case", "variable validation", "tflint", "terrafmt", "avmfix", "module style", "where does this code go", "main.privateendpoint.tf".
---

# AVM Terraform code style & file layout

A well-formed AVM Terraform module looks the same as every other well-formed AVM Terraform module. CI enforces most of this; this skill makes the conventions explicit so you don't have to discover them via failed checks.

Authoritative sources:
- [TFNFR4](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR4.md) — Lower snake_casing
- [TFNFR5, TFNFR7, TFNFR8](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/_index.md) — Variable hygiene (descriptions, validation, sensitive)
- [TFNFR11, TFNFR12](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/_index.md) — Output hygiene
- [TFNFR17](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR17.md) — Code style
- [TFNFR21](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR21.md) — terraform.tf provider constraints
- [TFNFR23](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR23.md) — `_header.md` / `_footer.md` (see `avm-tf-documentation`)
- [TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md) — Subresources as submodules
- [TFRMNFR2](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR2.md) — Primary resource named `this`

## Canonical file layout

```
<repo-root>/
├── terraform.tf                        # required_version + required_providers ONLY
├── main.tf                             # primary resource (azapi_resource.this) + small interfaces (lock, RA, diag)
├── main.<interface>.tf                 # one file per non-trivial interface (private_endpoint, CMK, ...)
├── main.telemetry.tf                   # modtm wiring; DO NOT EDIT (see avm-tf-telemetry)
├── variables.tf                        # all input variables
├── outputs.tf                          # all outputs
├── locals.tf                           # all local values
├── _header.md                          # README content above the auto-generated section
├── _footer.md                          # README content below — includes Data Collection notice
├── README.md                           # AUTO-GENERATED — never edit by hand
├── LICENSE                             # MIT
├── Makefile / avm / avm.ps1 / avm.bat  # local dev loop entry points
├── .terraform-docs.yml                 # terraform-docs config
├── examples/
│   ├── .terraform-docs.yml
│   ├── default/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── _header.md
│   │   └── _footer.md
│   └── <feature>/                      # e.g. private-endpoint/, diagnostic-settings/
├── tests/
│   ├── unit/                           # provider-mocked tests
│   └── integration/                    # real-Azure tests (federated identity in CI)
├── modules/                            # subresource submodules (TFRMNFR1) — one folder per submodule
│   └── <name>/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── _header.md
│       └── _footer.md
├── .agents/skills/                     # Microsoft-shipped in-repo skill — do not modify
├── .github/                            # workflows, CODEOWNERS, issue templates, branch protection policy
└── .editorconfig / .gitattributes / .gitignore
```

### Why files split this way

- **`terraform.tf` only contains `terraform {}`.** Keeps version constraints discoverable and stops them drifting between files.
- **`main.<interface>.tf` per non-trivial interface.** Reviewers can see at a glance what a module exposes. Lock and role assignments are usually small enough to stay in `main.tf`; private endpoints and CMK get their own files.
- **`main.telemetry.tf` ships from the template untouched.** If you edit it you'll fail `./avm pre-commit`.
- **`locals.tf` is one file, not scattered through `main.*.tf`.** Easier to audit cross-resource derivations.

## `terraform.tf` — provider pinning

```hcl
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }

    # azurerm is permitted ONLY where AzAPI has no equivalent (TFFR3).
    # Remove this block entirely if the module is pure-AzAPI.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
```

Rules ([TFNFR21](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR21.md)):

- **`required_version`** uses a hard upper bound — `>= 1.9, < 2.0`. Don't leave it open-ended.
- **Every `required_providers` entry MUST pin to a major version** with `~>` or an explicit `< x.0` ceiling. Floating across majors breaks consumers.
- **`source` lowercase: `Azure/azapi`, `azure/modtm`, `hashicorp/azurerm`, `hashicorp/random`.** Case matters to the Registry.
- **`azapi` and `modtm` are present in every module.** `random` is present in every module-from-template. `azurerm` is present only where TFFR3 justifies it.

## `main.tf` — the primary resource

```hcl
resource "azapi_resource" "this" {
  type      = "Microsoft.Search/searchServices@2024-06-01-preview"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  name      = var.name
  location  = var.location
  tags      = var.tags
  body      = { ... }
  response_export_values = [ ... ]   # TFFR4 — required attribute, can be []
}
```

The primary resource is **always named `this`** ([TFRMNFR2](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR2.md)). Same for the standard-interface resources: `azurerm_management_lock.this`, `azurerm_monitor_diagnostic_setting.this` (with `for_each` if it's a map interface). For child resources within the same module that aren't iterables: still `this`. For iterables: a sensible name (e.g. `azurerm_private_endpoint.this`, `azurerm_private_endpoint.this_unmanaged_dns_zone_groups`).

## `variables.tf`

Required inputs first, then optional inputs grouped by interface, in this order:

```hcl
# Required
variable "location" { ... }
variable "name" { ... }
variable "resource_group_name" { ... }

# Resource-specific optional inputs (alphabetised within the group)
variable "sku_name" { ... }
variable "public_network_access_enabled" { ... }

# Standard interfaces (alphabetised)
variable "customer_managed_key" { ... }
variable "diagnostic_settings" { ... }
variable "lock" { ... }
variable "managed_identities" { ... }
variable "private_endpoints" { ... }
variable "role_assignments" { ... }
variable "tags" { ... }

# Telemetry — ALWAYS last
variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Controls whether or not telemetry is enabled for the module. See https://aka.ms/avm/telemetry."
  nullable    = false
}
```

### Variable hygiene rules

- **Every variable MUST have a `description`** ([TFNFR7](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR7.md)). The first line of the description goes into the generated README — write it as a self-contained sentence.
- **Variables with a finite set of valid values MUST have a `validation` block** ([TFNFR8](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR8.md)). Use `contains([...], var.foo)` for enums, regex for string formats, length checks for collections.
- **Sensitive inputs MUST set `sensitive = true`.** And prefer `ephemeral = true` on the AzAPI `sensitive_body` plumbing so the value never lands in state.
- **Object-typed variables MUST use `optional()` for every non-required field** with the same default that the documentation describes. Don't make consumers pass `null` for fields they don't care about.
- **Set `nullable = false` on map variables that default to `{}`** (e.g. `role_assignments`, `diagnostic_settings`, `private_endpoints`). `null` and `{}` should behave identically; `nullable = false` enforces this.
- **`(Optional)` / `(Required)` prefix in descriptions.** AVM convention — makes the auto-generated README readable.
- **Multi-line descriptions use a heredoc (`<<DESCRIPTION ... DESCRIPTION`).** Lets you document each field of an object variable.

### Example: a well-formed optional variable

```hcl
variable "public_network_access_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "(Optional) Whether the resource is accessible from the public internet. Defaults to `true`. Set to `false` and pair with `private_endpoints` to make the resource only reachable from peered networks."
}

variable "sku" {
  type        = string
  default     = "standard"
  nullable    = false
  description = "(Optional) The SKU tier for the Search service. Defaults to `standard`."
  validation {
    condition     = contains(["free", "basic", "standard", "standard2", "standard3", "storage_optimized_l1", "storage_optimized_l2"], lower(var.sku))
    error_message = "sku must be one of: free, basic, standard, standard2, standard3, storage_optimized_l1, storage_optimized_l2."
  }
}
```

## `outputs.tf`

Outputs MUST ([TFFR2](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR2.md), [TFNFR11/12](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/_index.md)):

- Be alphabetised.
- Have a `description` each.
- Use `sensitive = true` for secrets.
- Expose **discrete computed attributes** the consumer is likely to need (`resource_id`, `name`, `principal_id` if managed identity is configured, `private_endpoints` keyed by the input map keys, plus the handful of useful computed properties from `azapi_resource.this.output.properties.*`).
- Be `.output.<path>` for AzAPI resources (not `.attributes.<path>`).

**TFFR2: do NOT expose the entire resource object** (`output "resource" { value = azapi_resource.this.output }`) — the AzAPI response shape changes with API version, can include sensitive material, and acts as an unstable interface to the consumer. Older AVM modules expose this output; new modules and migrations MUST replace it with discrete `output "foo" { value = azapi_resource.this.output.properties.foo }` style outputs (the AzAPI version of an [anti-corruption layer](https://learn.microsoft.com/azure/architecture/patterns/anti-corruption-layer)). Don't re-output inputs (other than `name`, by convention).

```hcl
output "name" {
  description = "The name of the resource."
  value       = azapi_resource.this.name
}

output "private_endpoints" {
  description = "A map of the private endpoints created on this resource, keyed by the keys in `var.private_endpoints`."
  value       = azapi_resource.private_endpoint
}

output "resource_id" {
  description = "The Azure resource ID of the resource."
  value       = azapi_resource.this.id
}

output "system_assigned_mi_principal_id" {
  description = "The Principal ID of the system-assigned managed identity, if enabled."
  value       = try(azapi_resource.this.output.identity.principalId, null)
}

# Discrete computed attribute — example
output "search_service_endpoint" {
  description = "The fully-qualified endpoint of the search service."
  value       = try("https://${azapi_resource.this.name}.search.windows.net", null)
}
```

## `locals.tf`

For derivations that are used in more than one place, or that are gnarly enough to warrant a name. Common locals:

```hcl
locals {
  # Substring used to detect whether role_definition_id_or_name is an ID or a name.
  role_definition_resource_substring = "/providers/Microsoft.Authorization/roleDefinitions"

  # Resolves managed_identities into the ARM `identity.type` string, or null if no identity.
  identity_type = (
    var.managed_identities.system_assigned && length(var.managed_identities.user_assigned_resource_ids) > 0 ? "SystemAssigned, UserAssigned" :
    var.managed_identities.system_assigned ? "SystemAssigned" :
    length(var.managed_identities.user_assigned_resource_ids) > 0 ? "UserAssigned" :
    null
  )
}
```

## Required AzAPI plumbing variables — TFFR6 + TFFR7

Every AVM TF module MUST declare three module-level variables that consumers can override and that flow into every `azapi_resource` block:

- **`resource_types`** ([TFFR6](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR6.md)) — object whose keys are the snake_case ARM types the module uses (with `Microsoft.` dropped and provider as a single lowercase token: `Microsoft.Search/searchServices` → `search_search_services`, `Microsoft.KeyVault/vaults/secrets` → `keyvault_vaults_secrets`). Each value is the full `type@apiVersion` string. The module's `azapi_resource` blocks then read `type = var.resource_types.<key>`, never inline string literals. Submodules accept and use a sub-object of the same shape.
- **`retry`** ([TFFR7](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR7.md)) — object with optional `error_message_regex`, `interval_seconds`, `max_interval_seconds`. `default = null`. The module MAY supply defaults for known transient errors via `coalesce()` in the `dynamic "retry"` block.
- **`timeouts`** ([TFFR7](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR7.md)) — object with optional `create`/`read`/`update`/`delete` (Go duration strings). `default = null`.

All three MUST cascade to every submodule the parent instantiates.

## snake_case everywhere ([TFNFR4](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR4.md))

- Variable names: `public_network_access_enabled`, NOT `publicNetworkAccessEnabled`.
- Output names: `resource_id`, NOT `resourceId`.
- Local names: `role_definition_resource_substring`, NOT `roleDefinitionResourceSubstring`.
- Terraform resource symbols: `azapi_resource.this`, NOT `azapi_resource.This`.
- File names: `main.private_endpoint.tf`, NOT `main.privateEndpoint.tf`.

The ARM property names *inside* `body` stay in their native ARM camelCase — that's not Terraform code, that's ARM payload, and AzAPI passes it through verbatim. So `body.properties.publicNetworkAccess` is correct (it's an ARM key), but `var.public_network_access_enabled` (the Terraform variable that feeds it) is snake_case.

## Subresources as submodules ([TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md))

If a child resource of the primary resource has independent lifecycle and meaningful inputs/outputs — and *isn't* worth its own published AVM module — put it under `modules/<name>/`. Examples in `keyvault-vault`: `modules/key/`, `modules/secret/`, `modules/certificate/`. Each submodule follows the same file layout as the parent (main.tf, variables.tf, outputs.tf, _header.md, _footer.md).

## Formatting & linting tools

The `./avm pre-commit` script runs these in order. You can run them individually too:

| Tool | What it does | Failure mode |
|---|---|---|
| `terraform fmt -recursive` | Whitespace + alignment. | Pre-commit fails with a diff. |
| `tflint --recursive` | Lints HCL — required providers, unused declarations, deprecated syntax. | Pre-commit fails with the rule violation. |
| `avmfix` | AVM-specific fixer — fixes file-layout / variable-ordering / naming issues. | Pre-commit fails or auto-fixes. |
| `terraform-docs` | Regenerates `README.md` from `_header.md` + module + `_footer.md`. | `./avm pre-commit` fails if `README.md` is out of date. |
| `terraform validate` | HCL semantic validation. | Pre-commit fails. |

If you're authoring outside an AVM repo (e.g. drafting a new module before the repo exists), install the tools globally:

```bash
brew install terraform tflint terraform-docs           # macOS
choco install terraform tflint terraform-docs          # Windows
# avmfix: install from https://github.com/Azure/tfmod-scaffold (Go binary)
```

## Common pitfalls

- **Splitting `terraform.tf` across multiple files.** Put `terraform {}` in exactly one file named `terraform.tf`.
- **Pinning AzAPI to `>= 2.0`.** Always pin to a major: `~> 2.4` (today). Floating across `3.0` will break consumers when it ships.
- **Naming the primary resource `azapi_resource.search` (or similar resource-specific name).** TFRMNFR2 mandates `this`.
- **Forgetting `nullable = false` on a map variable that defaults to `{}`.** Consumers will eventually pass `null` and the module will crash on a `for_each`.
- **Editing `README.md` directly.** It's auto-generated. Edit `_header.md` / `_footer.md`. See `avm-tf-documentation`.
- **Using camelCase for Terraform identifiers.** TFNFR4 violation, fails CI.
- **Using `var.tags` defaults to `{}` instead of `null`.** Convention is `default = null` so consumers can distinguish "intentionally no tags" from "use defaults". Pass `coalesce(var.tags, {})` only at the point of use if you need a non-null value.
- **Skipping `validation` blocks on enum-typed string variables.** TFNFR8 violation and a horrible consumer experience — `terraform plan` should reject bad inputs, not `terraform apply`.
