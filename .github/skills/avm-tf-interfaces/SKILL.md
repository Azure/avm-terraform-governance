---
name: avm-tf-interfaces
description: Use this skill whenever an Azure Verified Module (AVM) for Terraform needs to expose, implement, or accept one of the standard cross-cutting interfaces — diagnostic settings, role assignments, locks, tags, managed identities, private endpoints, customer-managed keys, or alerts. These interfaces have EXACT variable names mandated by RMFR4 and consistent schemas across every AVM module so consumers learn them once. Covers the canonical variable shapes (with `optional()` defaults), the implementation pattern in main.*.tf, the resource-naming prefixes (e.g. `pep-` for private endpoints per SNFR25), and what dependencies the module MUST NOT deploy. Trigger on phrases like "diagnostic_settings", "role_assignments", "private_endpoints", "managed_identities", "customer_managed_key", "lock variable", "AVM interface", "RMFR4", "RMFR5", "standard interface", "cross-cutting interface", "add RBAC to my module", "add private endpoint to AVM module".
---

# AVM standard cross-cutting interfaces (Terraform)

> **Scope of this skill.** This is the **consumer-facing** interface guidance — variable names, schemas, and how the parent module wires them into the primary resource. For **submodule-internal** interface concerns (the rename trick when a submodule needs a non-standard `private_endpoints`-shaped collection, the map vs scalar `output "resource_id"` shape for collection submodules under RMFR7, the per-element `parent_id` derivation when consumers set per-PE `resource_group_name`), see the **`avm-tf-submodules`** skill. For migrating an interface resource from `azurerm_*` to AzAPI without consumer destroys (the `lifecycle { ignore_changes = [name] }` trick on role assignments, the `moved {}` block patterns), see **`avm-tf-migration`**.

Resource modules **MUST** expose these interfaces with these **exact variable names** ([RMFR4](https://azure.github.io/Azure-Verified-Modules/spec/RMFR4)) **for each interface the primary resource actually supports**. They are how consumers configure locks, RBAC, diagnostics, identity, private connectivity, and customer-managed keys consistently across every AVM module they use. Learn the variable once → use it everywhere.

| Optional Feature / Extension Resource | Terraform variable | Severity (if supported by primary resource) |
|---|---|---|
| Diagnostic Settings | `diagnostic_settings` | MUST |
| Role Assignments | `role_assignments` | MUST |
| Resource Locks | `lock` | MUST |
| Tags | `tags` | MUST |
| Managed Identities (System / User Assigned) | `managed_identities` | MUST |
| Private Endpoints | `private_endpoints` | MUST |
| Customer Managed Keys | `customer_managed_key` | MUST |
| Azure Monitor Alerts | `alerts` | SHOULD |

> RMFR4's MUSTs are **conditional on the primary resource actually supporting the feature.** A Resource Group has no private endpoint surface; some PaaS services don't expose CMK; an Azure Front Door doesn't take resource locks the same way a Storage Account does. If the primary resource doesn't support a feature, **omit the variable entirely** rather than expose a no-op one — the AVM tooling will accept that.
>
> **Implementation provider.** Per [TFFR3](https://azure.github.io/Azure-Verified-Modules/spec/TFFR3) the *implementation* of these interface resources (the lock, role assignment, diagnostic setting, private endpoint resources themselves) MUST be AzAPI — `Microsoft.Authorization/locks`, `Microsoft.Authorization/roleAssignments`, `Microsoft.Insights/diagnosticSettings`, `Microsoft.Network/privateEndpoints` — not `azurerm_*`. Many existing AVM modules still use `azurerm_*` for these; that's pre-mandate migration debt, not a pattern to copy for new modules.

Authoritative sources:
- [RMFR4](https://azure.github.io/Azure-Verified-Modules/spec/RMFR4) — Consistent Feature & Extension Resources Value Add
- [RMFR5](https://azure.github.io/Azure-Verified-Modules/spec/RMFR5) — Consistent Feature & Extension Resources Interfaces/Schemas
- [SNFR25](https://azure.github.io/Azure-Verified-Modules/spec/SNFR25) — Resource Naming
- The canonical schemas live in [`Azure/avm-utl-interfaces`](https://registry.terraform.io/modules/Azure/avm-utl-interfaces/azure/latest) on the Terraform Registry. Resource modules today usually inline the schema (copying from there); pattern modules increasingly consume it.

## The non-negotiable rule

**A resource module MUST NOT deploy the dependencies of these interfaces.** For example:

- `diagnostic_settings` does NOT deploy the Log Analytics Workspace or Storage Account or Event Hub — those are referenced by ID from the consumer.
- `role_assignments` does NOT deploy the principal (the principal must exist).
- `private_endpoints` does NOT deploy the VNet, subnet, or Private DNS Zone — those are referenced by ID.
- `customer_managed_key` does NOT deploy the Key Vault or the Key — those are referenced by ID.

This is what makes AVM modules composable. Any "convenience" that deploys a dependency couples the module to a topology that won't match every consumer's environment.

## Canonical variable schemas

These are the schemas every AVM resource module exposes. Copy them verbatim — divergence from the schema breaks the consumer's "learn once, use everywhere" experience.

### `lock`

```hcl
variable "lock" {
  type = object({
    kind = string
    name = optional(string, null)
  })
  default     = null
  description = <<DESCRIPTION
Controls the Resource Lock configuration for this resource. The following properties can be specified:

- `kind` - (Required) The type of lock. Possible values are `\"CanNotDelete\"` and `\"ReadOnly\"`.
- `name` - (Optional) The name of the lock. If not specified, a name will be generated based on the `kind` value. Changing this forces the creation of a new resource.
DESCRIPTION
  validation {
    condition     = var.lock == null || try(contains(["CanNotDelete", "ReadOnly"], var.lock.kind), false)
    error_message = "Lock kind must be either CanNotDelete or ReadOnly."
  }
}
```

Implementation (in `main.tf`):

```hcl
resource "azurerm_management_lock" "this" {
  count      = var.lock != null ? 1 : 0
  lock_level = var.lock.kind
  name       = coalesce(var.lock.name, "lock-${var.name}")
  scope      = azapi_resource.this.id
  notes      = var.lock.kind == "CanNotDelete" ? "Cannot delete the resource or its child resources." : "Cannot delete or modify the resource or its child resources."
}
```

### `tags`

```hcl
variable "tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the resource."
}
```

Tags pass through directly to the primary resource's `tags` attribute.

### `role_assignments`

```hcl
variable "role_assignments" {
  type = map(object({
    role_definition_id_or_name             = string
    principal_id                           = string
    description                            = optional(string, null)
    skip_service_principal_aad_check       = optional(bool, false)
    condition                              = optional(string, null)
    condition_version                      = optional(string, null)
    delegated_managed_identity_resource_id = optional(string, null)
    principal_type                         = optional(string, null)
  }))
  default     = {}
  nullable    = false
  description = <<DESCRIPTION
A map of role assignments to create on the resource. The map key is deliberate user-defined string so consumers can use `terraform plan` deterministically. Each entry supports `role_definition_id_or_name` (either a fully-qualified role definition ID or the role's display name), `principal_id`, and the remaining optional AAD fields.
DESCRIPTION
}
```

Implementation uses the role-definition-name-vs-ID heuristic with `strcontains(lower(each.value.role_definition_id_or_name), "/providers/microsoft.authorization/roledefinitions/")` — copy from any existing AVM module (e.g. `keyvault-vault/main.tf`) verbatim.

### `diagnostic_settings`

```hcl
variable "diagnostic_settings" {
  type = map(object({
    name                                     = optional(string, null)
    log_categories                           = optional(set(string), [])
    log_groups                               = optional(set(string), ["allLogs"])
    metric_categories                        = optional(set(string), ["AllMetrics"])
    log_analytics_destination_type           = optional(string, "Dedicated")
    workspace_resource_id                    = optional(string, null)
    storage_account_resource_id              = optional(string, null)
    event_hub_authorization_rule_resource_id = optional(string, null)
    event_hub_name                           = optional(string, null)
    marketplace_partner_resource_id          = optional(string, null)
  }))
  default     = {}
  nullable    = false
  description = "A map of diagnostic settings to create on this resource. Defaults to `name = \"diag-<resource-name>\"`."
}
```

Implementation: one `azurerm_monitor_diagnostic_setting "this"` per `for_each`, with dynamic `enabled_log` blocks for `log_categories`, dynamic `enabled_log` blocks for `log_groups`, and dynamic `metric` blocks for `metric_categories`. Default name **MUST** prefix with `diag-` per SNFR25.

### `managed_identities`

```hcl
variable "managed_identities" {
  type = object({
    system_assigned            = optional(bool, false)
    user_assigned_resource_ids = optional(set(string), [])
  })
  default     = {}
  nullable    = false
  description = "Controls the Managed Identity configuration on this resource."
}
```

Resolves to one of `SystemAssigned`, `UserAssigned`, `SystemAssigned, UserAssigned`, or absent. Implementation pattern:

```hcl
locals {
  identity_type = (
    var.managed_identities.system_assigned && length(var.managed_identities.user_assigned_resource_ids) > 0 ? "SystemAssigned, UserAssigned" :
    var.managed_identities.system_assigned ? "SystemAssigned" :
    length(var.managed_identities.user_assigned_resource_ids) > 0 ? "UserAssigned" :
    null
  )
}

# inside azapi_resource.this
identity {
  type         = local.identity_type
  identity_ids = var.managed_identities.user_assigned_resource_ids
}
```

If no identity is configured, omit the `identity` block entirely (the AzAPI provider accepts `null` here).

### `private_endpoints`

```hcl
variable "private_endpoints" {
  type = map(object({
    name                                  = optional(string, null)
    role_assignments = optional(map(object({
      role_definition_id_or_name             = string
      principal_id                           = string
      description                            = optional(string, null)
      skip_service_principal_aad_check       = optional(bool, false)
      condition                              = optional(string, null)
      condition_version                      = optional(string, null)
      delegated_managed_identity_resource_id = optional(string, null)
      principal_type                         = optional(string, null)
    })), {})  # mirrors top-level role_assignments shape
    lock                                  = optional(object({ kind = string, name = optional(string, null) }), null)
    tags                                  = optional(map(string), null)
    subnet_resource_id                    = string
    private_dns_zone_group_name           = optional(string, "default")
    private_dns_zone_resource_ids         = optional(set(string), [])
    application_security_group_associations = optional(map(string), {})
    private_service_connection_name       = optional(string, null)
    network_interface_name                = optional(string, null)
    location                              = optional(string, null)
    resource_group_name                   = optional(string, null)
    ip_configurations = optional(map(object({
      name               = string
      private_ip_address = string
    })), {})
  }))
  default     = {}
  nullable    = false
  description = "A map of private endpoints to create on this resource."
}

variable "private_endpoints_manage_dns_zone_group" {
  type        = bool
  default     = true
  description = "Whether to manage Private DNS Zone Groups. Set to false to use the `this_unmanaged_dns_zone_groups` resource branch (for AzAPI-driven setups where the DNS zone group is managed elsewhere)."
}
```

Implementation: split into two `azurerm_private_endpoint` resources — `this` (with `private_dns_zone_group`) and `this_unmanaged_dns_zone_groups` (without) — driven by `private_endpoints_manage_dns_zone_group`. **Default name MUST be `pep-<primary-resource-name>`** per SNFR25.

### `customer_managed_key`

```hcl
variable "customer_managed_key" {
  type = object({
    key_vault_resource_id              = string
    key_name                           = string
    key_version                        = optional(string, null)
    user_assigned_identity = optional(object({
      resource_id = string
    }), null)
  })
  default     = null
  description = "Configuration for Customer Managed Keys (CMK) for encryption at rest. The Key Vault, key, and (if used) user-assigned identity MUST already exist."
}
```

Wire into `body.properties.encryption*` or the resource-type-specific equivalent.

### `alerts` (SHOULD)

Schema varies by resource (the spec doesn't yet fix one), but if your resource supports Azure Monitor alerts you SHOULD expose an `alerts` map variable that creates `azurerm_monitor_metric_alert` / `azurerm_monitor_scheduled_query_rules_alert_v2` instances.

## File layout convention

Split each interface into its own `main.<interface>.tf` to keep `main.tf` focused on the primary resource:

```
main.tf                       # primary resource (azapi_resource.this) + lock + role_assignments + diagnostic_settings (small interfaces)
main.private_endpoint.tf      # private endpoints
main.telemetry.tf             # modtm telemetry (do not edit; see avm-tf-telemetry)
main.customer_managed_key.tf  # CMK wiring (if non-trivial)
locals.tf                     # identity_type, role_definition_resource_substring, etc.
```

This matches the layout in flagship AVM repos like `terraform-azurerm-avm-res-keyvault-vault`.

## Why these interfaces are interfaces, not resources

The variable schemas are normative — RMFR5 ("Consistent Feature & Extension Resources Interfaces/Schemas") requires every module that exposes one of these features to use the same shape. A consumer that knows how to add a private endpoint to a Key Vault AVM module knows how to add one to a Storage Account AVM module, and to a Search Service AVM module, with zero re-learning. **Do not invent your own shape** "to be more ergonomic for my resource" — that defeats the whole point.

When the underlying primary resource supports a feature the standard interface doesn't model perfectly (e.g. a CMK with extra configuration knobs), add resource-specific variables alongside — don't deform the standard interface.

## `avm-utl-interfaces`

The [`Azure/avm-utl-interfaces`](https://registry.terraform.io/modules/Azure/avm-utl-interfaces/azure/latest) utility module on the Terraform Registry publishes the canonical interface schemas. Today, **resource modules typically inline the schemas** (copying from the utility module). **Pattern modules** are more likely to consume the utility module directly because they often need to thread interface shapes through to multiple child resource modules. Either approach satisfies RMFR4/RMFR5 as long as the variable names and shapes match exactly.

## Common pitfalls

- **Deploying the Log Analytics Workspace inside the module "for convenience".** Forbidden — the consumer supplies it.
- **Renaming variables.** `diagnosticSettings`, `diagnosticsSettings`, `diag_settings` are all wrong — it's `diagnostic_settings`. Same for `role_assignments` (not `roleAssignments`, not `rbac`).
- **Defaulting a private endpoint name to something that isn't `pep-`-prefixed.** SNFR25 mandates the prefix.
- **Adding a default lock.** Locks are opt-in; the variable default is `null` (no lock created).
- **Defaulting `private_endpoints_manage_dns_zone_group = false`.** Default is `true` — modules opt consumers into the DNS-zone-group experience by default.
- **Forgetting the `nullable = false` on map variables like `role_assignments`, `diagnostic_settings`, `private_endpoints`.** `null` and `{}` should behave the same; `nullable = false` removes the foot-gun.
- **Implementing managed identity as two separate variables (`system_assigned_identity` + `user_assigned_identity_ids`).** It's one variable, `managed_identities`, with an object shape.
