# AVM Standard Interfaces

AVM defines a small, fixed set of **interfaces** that resource modules expose where the underlying Azure resource supports them. They standardise variable names, types, and behaviour across every module so consumers learn one shape and reuse it everywhere.

All interfaces are implemented in the canonical utility module **`Azure/avm-utl-interfaces/azure`** (version `~> 0.6`). Resource modules should compose that utility module rather than redefining variable shapes by hand. For the authoritative interface text, fetch each interface page via `https://azure.github.io/Azure-Verified-Modules/llms.txt`.

## Interfaces

### Diagnostic settings

Exposes `diagnostic_settings` (map of objects) so consumers can route resource logs and metrics to Log Analytics, Storage, Event Hub, or partner solutions. Apply on every resource that produces diagnostic logs or metrics.

**Modules MUST use the v2 schema.** The v2 shape models `logs` and `metrics` as sets of objects with `category` / `category_group`, `enabled`, and optional `retention_policy`, instead of the legacy flat sets of category strings. Do not specify allowed values for category names — the module must stay evergreen as resource providers add new categories.

Wire it through the utility module via its `diagnostic_settings_v2` input and consume the `diagnostic_settings_azapi_v2` output — the legacy `diagnostic_settings` input/output on the utility module is the old shape and **must not** be used in new code.

### Role assignments

Exposes `role_assignments` (map of objects) so consumers can attach Azure RBAC role assignments scoped to the resource. The key becomes a stable map key for plan-time stability; the object specifies `role_definition_id_or_name`, `principal_id`, `description`, etc.

### Locks

Exposes a `lock` (single object: `kind` = `None | CanNotDelete | ReadOnly`, `name` optional). Apply to top-level resources that support management locks.

### Managed identities

Exposes `managed_identities` (object with `system_assigned` bool and `user_assigned_resource_ids` set of strings). Apply on every resource that supports managed identity.

### Private endpoints

Exposes `private_endpoints` (map of objects) so consumers can deploy private endpoints into a target subnet, register them in private DNS zones, and configure custom IP addressing. Apply on every resource that supports Private Link.

### Customer-managed keys

Exposes `customer_managed_key` (single object: `key_vault_resource_id`, `key_name`, optional `key_version`, optional `user_assigned_identity` reference). Apply on every resource that supports CMK encryption.

### Tags

Exposes `tags` (map of strings). Required on every resource that supports tags. The pattern-module equivalent typically forwards a shared `tags` input to every composed module.

### AzAPI resource types

Exposes `resource_types` (object) so consumers can pin the API version used for each AzAPI resource the module owns. Keys are deterministic: lowercase the provider namespace without `Microsoft.` and append each resource-type path segment with underscores. Declare one `optional(string, "<resource-type>@<api-version>")` field per resource and nested child-shaped objects for submodules. Defaults **MUST** use stable API versions unless the resource only ships preview.

Parent modules **MUST** cascade the relevant subset of `resource_types` to each submodule (see TFFR6 and TFRMNFR1). Submodules **MUST** declare their own `resource_types` variable using the same pattern.

### AzAPI retry

Exposes `retry` (single object: `error_message_regex`, `interval_seconds`, `max_interval_seconds`, all optional). MUST be applied to every `azapi_resource` (and equivalent AzAPI resources) declared by the module and cascaded unchanged into every submodule. `retry` is an attribute on `azapi_resource`, so it is assigned directly.

### AzAPI timeouts

Exposes `timeouts` (single object: `create`, `read`, `update`, `delete`, all optional Go duration strings). MUST be applied to every `azapi_resource` (and equivalent AzAPI resources) declared by the module and cascaded unchanged into every submodule. `timeouts` is a **block** on `azapi_resource` (not an attribute), so a `dynamic "timeouts"` block is required to honour the variable's `null` default.

### AzAPI ignored body changes

Exposes `ignore_body_changes` (object) with one `optional(list(string), [])` field per owned AzAPI resource and a nested child-shaped object per submodule. Apply the matching field to each resource and collapse an empty list to `null`. Paths use body-relative dot notation and do not support list indices.

For the full `resource_types`, `retry`, `timeouts`, and `ignore_body_changes` schemas and wiring, read [AzAPI.md](./AzAPI.md#resource-types).

## Implementation pattern

1. Take a dependency on `Azure/avm-utl-interfaces/azure` in `terraform.tf`.
2. Call the utility module in `main.tf` to translate the standard inputs into the AzAPI body shape. Note the diagnostic-settings input field is `diagnostic_settings_v2` (the legacy `diagnostic_settings` field on the utility module is the old shape):

   ```hcl
   module "avm_interfaces" {
     source  = "Azure/avm-utl-interfaces/azure"
     version = "~> 0.6"

     diagnostic_settings_v2 = var.diagnostic_settings
     managed_identities     = var.managed_identities
     # …
   }
   ```

3. Reference the utility module's outputs in the relevant `azapi_resource` blocks. For diagnostic settings iterate `module.avm_interfaces.diagnostic_settings_azapi_v2`:

   ```hcl
   resource "azapi_resource" "diagnostic_settings" {
     for_each = module.avm_interfaces.diagnostic_settings_azapi_v2

     type      = var.resource_types.insights_diagnostic_settings
     name      = each.value.name
     parent_id = azapi_resource.this.id
     body      = each.value.body

     ignore_body_changes    = length(var.ignore_body_changes.insights_diagnostic_settings) > 0 ? var.ignore_body_changes.insights_diagnostic_settings : null
     replace_triggers_refs  = []
     response_export_values = []
     retry                  = var.retry

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

4. Implement supporting satellite and extension resources (private endpoints, diagnostic settings, role assignments, locks) as distinct, descriptively named resources. Use submodules wherever TFRMNFR1 applies, and never collapse a separate resource into the primary resource's `body`.

## When NOT to expose an interface

If the underlying Azure resource does not support a capability (e.g. no private endpoints, no managed identity, no diagnostic settings), do **not** expose the corresponding variable. Adding a no-op variable creates a misleading contract.
