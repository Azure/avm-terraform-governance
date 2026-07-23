---
name: avm-tf-azapi
description: Use this skill whenever AzAPI is involved in an Azure Verified Module (AVM) for Terraform — writing a new `azapi_resource`, migrating an existing AzureRM-based module to AzAPI, translating an ARM template or Bicep snippet to AzAPI, deciding whether a given resource qualifies for the narrow AzureRM exception (TFFR3), or debugging AzAPI behaviour (retries, locks, response_export_values, replace_triggers_refs). AVM Terraform modules MUST use AzAPI — this skill is the canonical guidance for how. Trigger on phrases like "AzAPI", "azapi_resource", "migrate from azurerm to azapi", "aztfmigrate", "convert AzureRM to AzAPI", "ARM to Terraform", "Bicep to Terraform", "response_export_values", "replace_triggers_refs", "azapi locks", "azapi retry", "TFFR3", "data plane resource exception", "why AzAPI in AVM".
---

# AzAPI — the AVM Terraform default

**AVM Terraform modules MUST use the AzAPI provider.** The AzureRM provider is permitted only under the narrow [TFFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR3.md) exception (e.g. some data-plane resources with no AzAPI equivalent). This is a 2026 change in the AVM spec and **the migration is not complete across the AVM ecosystem yet** — the official template and several flagship modules still use `azurerm_*` resources for their primary resource. Treat that as legacy; the AzAPI-first rule is the current spec direction.

Authoritative sources:
- <https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/specs/_index.md> ("Why AVM Terraform modules favor AzAPI")
- [TFFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR3.md) — Providers, Permitted Versions (and the AzureRM exception)
- [TFFR4](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR4.md) — AzAPI `response_export_values`
- [TFFR5](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR5.md) — AzAPI `replace_triggers_refs`
- [TFFR6](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR6.md) — AzAPI `resource_types` variable (the **`type` argument MUST come from `var.resource_types`** — never inline)
- [TFFR7](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR7.md) — AzAPI `retry` and `timeouts` as consumer-configurable variables
- <https://registry.terraform.io/providers/Azure/azapi/latest>
- <https://learn.microsoft.com/azure/developer/terraform/how-to-migrate-between-azurerm-and-azapi>
- <https://github.com/Azure/aztfmigrate>

## Why AzAPI (in one breath, so you can answer the inevitable pushback)

1. **Built-in retries.** First-class `retry` block with regex-based error matching. Handles eventual-consistency errors deterministically without `time_sleep` workarounds.
2. **Pre-flight validation.** ARM pre-flight checks happen at `plan` time → faster feedback, fewer half-deployed resources.
3. **Day-zero access to new Azure features.** AzAPI talks straight to the ARM REST API; you get new resource types and properties the day Azure ships them, not the day AzureRM ships an update.
4. **ARM/Bicep parity.** Same resource type identifiers (`Microsoft.KeyVault/vaults@2023-07-01`) and same property shape — trivially easy to translate documentation, samples, and Bicep modules into Terraform.
5. **Direct partnership with Azure RP engineering teams.** Bugs go straight to the underlying ARM behaviour, not through provider-translation layers.
6. **Consistency across the AVM ecosystem.** Every AVM TF module uses the same patterns for identity, diagnostics, RBAC, locks and private endpoints.

## The canonical pattern

```hcl
# terraform.tf  — see avm-tf-codestyle for full provider pinning
terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    # modtm, random, and (only if TFFR3-justified) azurerm follow
  }
}
```

```hcl
# variables.tf — TFFR6 and TFFR7 require these three variables on every AVM TF module
variable "resource_types" {
  type = object({
    search_search_services = optional(string, "Microsoft.Search/searchServices@2024-06-01-preview")
  })
  default     = {}
  nullable    = false
  description = <<DESCRIPTION
(Optional, TFFR6) AzAPI resource types used by this module. Each key is the snake_case form of the ARM resource type with `Microsoft.` dropped and the provider rendered as a single lowercase token. Override individual entries to pin a different API version.
DESCRIPTION
}

variable "retry" {
  type = object({
    error_message_regex  = optional(list(string))
    interval_seconds     = optional(number)
    max_interval_seconds = optional(number)
  })
  default     = null
  description = "(Optional, TFFR7) Retry configuration applied to every AzAPI resource managed by the module."
}

variable "timeouts" {
  type = object({
    create = optional(string)
    read   = optional(string)
    update = optional(string)
    delete = optional(string)
  })
  default     = null
  description = "(Optional, TFFR7) Default per-operation timeouts applied to every AzAPI resource. Go duration strings (`30m`, `1h`)."
}
```

```hcl
# main.tf
data "azapi_client_config" "current" {}

resource "azapi_resource" "this" {
  type      = var.resource_types.search_search_services       # TFFR6 — NEVER inline a literal type
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  name      = var.name
  location  = var.location
  tags      = var.tags

  identity {
    type         = local.identity_type
    identity_ids = local.user_assigned_identity_ids
  }

  body = {
    sku = { name = var.sku }
    properties = {
      replicaCount        = var.replica_count
      partitionCount      = var.partition_count
      hostingMode         = var.hosting_mode
      publicNetworkAccess = var.public_network_access_enabled ? "enabled" : "disabled"

      # WAF-aligned defaults — local API keys off, AAD on
      disableLocalAuth = !var.local_authentication_enabled
      authOptions      = var.local_authentication_enabled ? { aadOrApiKey = { aadAuthFailureMode = var.authentication_failure_mode } } : null

      networkRuleSet = var.allowed_ips == null ? null : {
        bypass  = "AzureServices"
        ipRules = [for ip in var.allowed_ips : { value = ip }]
      }

      encryptionWithCmk = var.customer_managed_key == null ? null : {
        enforcement = "Enabled"
      }
    }
  }

  # TFFR4 — required attribute, set to [] if nothing is needed downstream
  response_export_values = [
    "identity.principalId",
    "properties.privateEndpointConnections",
  ]

  # TFFR5 — required attribute. Use [] when no properties need a replace trigger.
  replace_triggers_refs = []

  # TFFR7 — driven by var.retry, not a hard-coded block. The module MAY default
  # `retry.error_message_regex` to known transient errors for this RP.
  dynamic "retry" {
    for_each = var.retry == null ? [] : [var.retry]
    content {
      error_message_regex  = coalesce(retry.value.error_message_regex, ["ResourceGroupNotFound", "AnotherOperationInProgress"])
      interval_seconds     = coalesce(retry.value.interval_seconds, 10)
      max_interval_seconds = coalesce(retry.value.max_interval_seconds, 60)
    }
  }

  # TFFR7 — same pattern for timeouts
  dynamic "timeouts" {
    for_each = var.timeouts == null ? [] : [var.timeouts]
    content {
      create = timeouts.value.create
      read   = timeouts.value.read
      update = timeouts.value.update
      delete = timeouts.value.delete
    }
  }
}
```

## Key attributes — what each one is for

| Attribute | Purpose |
|---|---|
| `type` | ARM resource type + explicit API version, e.g. `Microsoft.Storage/storageAccounts@2023-01-01`. **TFFR6: the literal MUST live in `var.resource_types` and the `type` argument MUST read `var.resource_types.<key>` — never an inline string literal.** |
| `parent_id` | ID of the parent. For top-level resources: `/subscriptions/{sub}/resourceGroups/{rg}`. For child resources: the parent resource's ID. |
| `name` | Resource name. Per [TFRMNFR2](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR2.md) the *Terraform resource symbol* is `this`; the ARM resource name comes from `var.name`. |
| `location` | Azure region. |
| `body` | Resource properties as an **HCL object — not a JSON string**. Maps 1:1 to ARM/Bicep. |
| `identity {}` | Managed identity block. See `avm-tf-interfaces` for the `managed_identities` variable that drives this. |
| `tags` | Top-level tags map. |
| `response_export_values` | **TFFR4** — required. List of ARM property paths to read back. Use `[]` if nothing is needed. Access with `azapi_resource.this.output.<path>`. Common: `"identity.principalId"`, `"properties.privateEndpointConnections"`. |
| `replace_triggers_refs` | **TFFR5** — list of property paths that force resource replacement when changed. Use for immutable fields the underlying RP rejects on update. |
| `locks` | Mutex list — resource IDs to lock on to prevent concurrent ARM operations. Use when two AzAPI resources touch the same parent. |
| `retry {}` | Transient-error handling. Always include a sensible `error_message_regex` for the resource's known flaky errors instead of bare `time_sleep`. |
| `timeouts {}` | Per-operation timeout. Default ARM timeouts are too short for many resources. |
| `sensitive_body` | Secrets (keys, passwords). Merged with `body` at runtime. Use `sensitive_body_version = { "properties.key1" = "1" }` so Terraform notices changes. **All sensitive values MUST be ephemeral.** |

## Adjacent AzAPI resources

- **`azapi_update_resource`** — patches properties on a resource you didn't create with AzAPI (e.g. a property the AzureRM provider doesn't expose yet).
- **`azapi_resource_action`** — invokes an ARM action (e.g. `listKeys`, `regenerateKey`). Equivalent to a POST on `/<resource-id>/<action>`.
- **`data.azapi_resource`** — read-only ARM GET.
- **`data.azapi_client_config`** — current `subscription_id`, `tenant_id`, `object_id` — the AzAPI equivalent of `azurerm_client_config`. Used in `parent_id` construction and in `main.telemetry.tf`.
- **`ephemeral "azapi_resource_action"`** — for sensitive values like access keys that should never enter state.

## The AzureRM exception (TFFR3) — the full checklist

You may use the AzureRM provider **only** for resources whose functionality is genuinely unavailable through any AzAPI resource (`azapi_resource`, `azapi_data_plane_resource`, `azapi_resource_action`, `azapi_update_resource`). In practice this is a small set of edge cases — typically data-plane operations such as Key Vault secrets/certificates, Storage blobs, and a handful of resources whose `azurerm_*` implementation calls non-ARM APIs.

**Where this exception applies the module MUST do all of the following ([TFFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR3.md)):**

1. Pin `azurerm` to `~> 4.0` in `required_providers`.
2. Use AzAPI for **every** resource that has an AzAPI equivalent. AzureRM is not a convenience alternative.
3. Document the exception in `README.md` — list each `azurerm_*` resource used, the data-plane / non-ARM API it wraps, why no AzAPI equivalent exists today, and the upstream AzAPI issue or PR tracking replacement. (Put this in `_header.md` so it lands in the auto-generated README.)
4. Replace each `azurerm_*` resource with its AzAPI equivalent **in the next module release after the AzAPI capability ships**.
5. Add the TFLint exclusion (without this, the AVM tooling blocks the provider):
   ```hcl
   rule "provider_azurerm_disallowed" {
     enabled = false
   }
   ```

The exception **MUST NOT** be used to:

- Avoid migrating an existing AzureRM resource that *does* have an AzAPI equivalent.
- Reduce author effort because the AzAPI body schema is more verbose.
- Side-step TFFR4 / TFFR5 / TFFR6 / TFFR7 — those rules apply to every AzAPI resource regardless.

### What about the standard cross-cutting interfaces?

**The cross-cutting interface resources (lock, role assignment, diagnostic setting, private endpoint) are NOT carved out by TFFR3.** All four have AzAPI equivalents (`Microsoft.Authorization/locks`, `Microsoft.Authorization/roleAssignments`, `Microsoft.Insights/diagnosticSettings`, `Microsoft.Network/privateEndpoints`) and must therefore be implemented in AzAPI in new and migrated modules. The fact that most existing AVM modules still use `azurerm_management_lock` / `azurerm_role_assignment` / `azurerm_monitor_diagnostic_setting` / `azurerm_private_endpoint` is **migration debt from before the AzAPI-first mandate, not a pattern to copy**. Cite TFFR3 if pressed.

## `replace_triggers_refs` — defaults differ per resource type

[TFFR5](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR5.md) requires the attribute to be set on every `azapi_resource`, but the **right value depends on the resource type**. Don't default to `[]` everywhere — some RPs have well-known properties whose mutation must force replacement, and missing the trigger means consumers hit mid-apply ARM errors instead of clean recreates.

| Resource family | Sensible default | Why |
|---|---|---|
| Most resources (no immutable post-create properties) | `[]` | Updates are in-place safe. |
| `Microsoft.Network/privateEndpoints` | `["properties.subnet.id"]` | Changing the subnet of a PE is rejected by ARM — must recreate. |
| `Microsoft.Search/searchServices`, capacity-sensitive PaaS | `["properties.hostingMode"]` | `hostingMode` is immutable post-create on Search; same shape for similar capacity-tier-driving properties on other services. |
| `Microsoft.Authorization/roleAssignments` | `[]`, with `lifecycle { ignore_changes = [name] }` | The GUID name is server-allocated; don't trigger replace on it, and let lifecycle ignore it for migrations from AzureRM. |

When you author a new module, list the properties the RP rejects on update (the API docs call them out, or you discover them the hard way) and put their dotted paths into `replace_triggers_refs`. The variable should still be consumer-overridable so they can extend it.

## TFNFR38 and `marketplace_partner_resource_id`

[TFNFR38](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR38.md) generally says a single AVM resource module manages a single ARM resource type. The canonical exception is **`marketplace_partner_resource_id`** on the `diagnostic_settings` interface — that single property legitimately points at any of several marketplace partner resource types (Datadog, Elastic, Logz.io, etc.), so the module is genuinely multi-type by design. If you see `marketplace_partner_resource_id`, that's the carve-out; you don't need to argue TFNFR38 around it.

Outside this case, if your module appears to need to manage two different ARM resource types as primaries, it's almost certainly two modules.

## `azapi.retry.multiplier` deprecation

Heads-up: the current AzAPI provider schema emits a deprecation warning for `retry.multiplier` (the per-attempt back-off multiplier). The replacement is the existing `interval_seconds` / `max_interval_seconds` pair, which the AVM `retry` variable schema already uses. If you see the warning in CI, it's because someone added `multiplier` to a module's `retry` variable or to the dynamic `retry` block — remove it. The `retry` variable shape in this skill already omits it.

## Migrating an existing AzureRM-based module to AzAPI

> For the full migration playbook — cardinality trap, `moved {}` patterns, end-to-end migration test recipe, `MoveResourceState` gotchas — see the **`avm-tf-migration`** skill. This section is the AzAPI-rewrite half; that skill is the state-preservation half. Don't ship a migration without working through both.

**Per-resource workflow:**

1. **Look up the ARM schema** for the resource — use the in-repo `azure-schema` CLI shipped at `.agents/skills/avm-terraform-module-development/scripts/azure-schema` if you're inside an AVM module repo, otherwise the ARM REST API docs on Microsoft Learn. Find the latest stable API version (prefer non-preview unless the GA feature you need is only in a preview version, per [SFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/functional/SFR1.md)).
2. **Map every `azurerm_*` property to its ARM equivalent.** Most AzureRM property names are snake_case translations of the ARM camelCase — `public_network_access_enabled` ↔ `properties.publicNetworkAccess`. The `azurerm` provider source on GitHub is the cheat-sheet.
3. **Rewrite the resource block.** Keep the Terraform symbol name (`this`). Switch `azurerm_search_service.this` → `azapi_resource.this`. Move properties from top-level (AzureRM) into the `body.properties` object (ARM/AzAPI).
4. **Mirror dynamic blocks.** AzureRM `dynamic "network_acls" { ... }` becomes a regular HCL expression inside `body.properties.networkRuleSet`.
5. **Move computed/output fields to `response_export_values`.** Anything downstream needed (e.g. `principal_id` from the identity block, `endpoint`) — list the ARM paths and read via `.output.<path>`.
6. **Handle in-place vs replace.** Properties the RP rejects on update go into `replace_triggers_refs`. Without this, `terraform apply` will error mid-update instead of cleanly recreating.
7. **Run `aztfmigrate`** for state migration — see below. This is a critical step: rewriting the HCL is necessary but not sufficient; Terraform state still references the old `azurerm_*` address and must be moved.
8. **Rerun the test suite.** Existing `examples/` and `tests/integration/` should pass unchanged — if a consumer's call site needs to change, that's a breaking change → bump the minor version per `avm-tf-lifecycle`.

### Using `aztfmigrate` for state migration

[`aztfmigrate`](https://github.com/Azure/aztfmigrate) is the Microsoft-supported tool for converting an existing AzureRM resource and its state to AzAPI. It rewrites both the HCL and the Terraform state file. There's also a VS Code extension that does the same interactively.

**Important caveats:**

- `aztfmigrate` operates against a **root Terraform configuration** with applied state — it does not directly migrate resources declared inside a child module. To migrate an AVM module's primary resource, run the tool against a root configuration that *calls* the module (one of the `examples/<name>/` is the natural choice), generate the AzAPI HCL there, then port the rewritten resource block back into the module's own `main.tf` and craft the `moved {}` blocks by hand.
- The direction of migration must be specified explicitly: AzureRM → AzAPI uses `-to azapi`.

**Workflow:**

```bash
# from a root configuration that uses the module (typically examples/default)
cd examples/default
terraform init
terraform apply                  # so we have applied state to migrate from

aztfmigrate plan -to azapi       # see what aztfmigrate proposes
aztfmigrate migrate -to azapi    # rewrite the HCL and move state addresses

terraform plan                   # MUST show "no changes" if the migration is clean
```

Then:

1. Copy the rewritten AzAPI HCL into the module's own `main.tf`, adapting it to use `var.resource_types`, `var.retry`, `var.timeouts`, and the standard interface variables.
2. Add `moved {}` blocks in `main.tf` so consumers' state moves cleanly on module upgrade — e.g. `moved { from = azurerm_search_service.this   to = azapi_resource.this }`. Keep these in `main.tf` for at least one minor version after the migration, then remove.
3. If the resource has `lifecycle.ignore_changes`, port that to AzAPI carefully — AzAPI's ignore semantics use JMES-like ARM paths, not Terraform attribute names.
4. Re-run the integration tests; the module's outputs may have shifted from `.attributes.<x>` to `.output.<x>` and consumers will need updated guidance in the release notes.

### Translating ARM/Bicep to AzAPI

This is straightforward because AzAPI mirrors ARM/Bicep:

```bicep
// Bicep
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: name
  location: location
  sku: { name: sku }
  properties: {
    replicaCount: replicaCount
    partitionCount: partitionCount
    publicNetworkAccess: publicNetworkAccess ? 'enabled' : 'disabled'
  }
}
```

```hcl
# AzAPI
resource "azapi_resource" "this" {
  type      = "Microsoft.Search/searchServices@2024-06-01-preview"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  name      = var.name
  location  = var.location
  body = {
    sku = { name = var.sku }
    properties = {
      replicaCount        = var.replica_count
      partitionCount      = var.partition_count
      publicNetworkAccess = var.public_network_access_enabled ? "enabled" : "disabled"
    }
  }
  response_export_values = []
}
```

You can paste an ARM JSON snippet directly into VS Code with the AzAPI extension installed and it will offer to convert it to an `azapi_resource`.

## Common pitfalls

- **Treating `body` as a JSON string.** It's an HCL object. Don't wrap it in `jsonencode()`. Reading `azapi_resource.this.output.properties.foo` is HCL access, not JSON traversal.
- **Forgetting `response_export_values`.** TFFR4 requires the attribute to be present even if empty — `response_export_values = []`. Without it your module fails AVM linting.
- **Skipping `replace_triggers_refs` for immutable properties.** Update-time ARM errors that say "this property cannot be changed after creation" need to be in `replace_triggers_refs` — TFFR5.
- **Pinning a preview API version when GA exists.** Per [SFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/functional/SFR1.md), prefer GA. Preview is only acceptable when the GA feature requires a preview API version, or when the consumer explicitly opts in (and the variable description starts with `THIS IS A VARIABLE USED FOR A PREVIEW SERVICE/FEATURE, MICROSOFT MAY NOT PROVIDE SUPPORT FOR THIS, PLEASE CHECK THE PRODUCT DOCS FOR CLARIFICATION`).
- **Using `azurerm` "because that's what the other AVM modules do".** Many existing modules predate the AzAPI mandate. Cite TFFR3 — if there's no AzAPI equivalent, document why; otherwise migrate.
- **Skipping `aztfmigrate` for state migration.** Rewriting HCL without moving state addresses will cause `terraform plan` to want to destroy and recreate everything.
- **Using `azapi` for one property and `azurerm` for another on the same resource.** State chaos. Pick one provider per resource.
