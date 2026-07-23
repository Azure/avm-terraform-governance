---
name: avm-tf-migration
description: Use this skill whenever an AVM Terraform module is being migrated from AzureRM to AzAPI, whether for the primary resource, a cross-cutting interface resource (lock, role assignment, diagnostic setting, private endpoint), or when extracting satellite resources into TFRMNFR1 submodules during the same change. Covers the cardinality trap that destroys state across the cross-provider hop (module-call `for_each` vs internal `for_each`), the canonical `moved {}` patterns for in-place and submodule-extraction moves, the end-to-end migration test recipe (deploy with published AzureRM → swap to local → 0 destroys → re-plan idempotent → teardown), `MoveResourceState` and `terraform state mv` mechanics, the Terraform 1.8+ requirement, and per-resource gotchas like `lifecycle { ignore_changes = [name] }` on role assignments to preserve server-allocated GUIDs. Trigger on phrases like "migrate this module to AzAPI", "azurerm to azapi", "extract into submodule", "moved block", "MoveResourceState", "destroy/create on upgrade", "state preservation", "consumers will see replace", "cardinality trap", "module for_each migration", "TFRMNFR1 submodule extraction", "split satellite into submodule", "0 destroys", "migration test recipe", "aztfmigrate state".
---

# AVM Terraform: AzureRM → AzAPI migration playbook

This skill is what you reach for when an existing AVM Terraform module needs to change provider — almost always AzureRM → AzAPI per [TFFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR3.md), often combined with extracting satellite resources into a [TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md) submodule.

It exists because the AVM-published migration guidance covers the "rewrite the HCL" half and leaves the "and don't break every consumer's state" half mostly to folklore. Cross-provider migrations are not garden-variety Terraform refactors: the provider and the resource type both change, so `moved {}` blocks have load-bearing semantics, and the slightest cardinality mismatch silently flips the upgrade into a destroy/recreate.

## The non-negotiable principle

**State preservation is non-negotiable during AzureRM → AzAPI migration.** Every cross-provider change MUST be verified with an end-to-end migration test (see §3) showing **zero destroys** on the upgrade plan. A migration that recreates the consumer's Search service, Key Vault, or App Service is a critical-severity outage, not a release note. If the test can't show 0 destroys, the migration is not ready to ship.

This sits alongside AzAPI-first as a top-line rule, not a nice-to-have.

## 1. The cardinality trap (read this first if you're extracting submodules)

The single most common way migrations break: a previously root-level `azurerm_X.this` resource is extracted into a TFRMNFR1 submodule at the same time as the provider hop. Authors instinctively reach for `for_each` on the module call:

```hcl
# ❌ THIS DESTROYS STATE ACROSS THE PROVIDER HOP
module "subnet" {
  source   = "./modules/subnet"
  for_each = var.subnets
  # ...
}

moved {
  from = azurerm_subnet.this[each.key]
  to   = module.subnet[each.key].azapi_resource.this
}
```

Terraform **cannot re-key state across a cross-provider hop when `for_each` is on the module call**. The `moved {}` block parses but the planner treats the old `azurerm_subnet.this[<key>]` entries and the new `module.subnet["<key>"].azapi_resource.this` entries as unrelated — every consumer sees destroy/recreate.

**The correct shape:** parent calls the submodule **once** with a map input; submodule owns the `for_each` **internally** on the resource:

```hcl
# ✅ parent module
module "subnets" {
  source  = "./modules/subnet"
  subnets = var.subnets  # the whole map, not per-key
  # ...
}

moved {
  from = azurerm_subnet.this
  to   = module.subnets.azapi_resource.this
}
```

```hcl
# ✅ submodule (./modules/subnet/main.tf)
variable "subnets" {
  type = map(object({ /* ... */ }))
}

resource "azapi_resource" "this" {
  for_each = var.subnets
  type     = var.resource_types.network_virtual_networks_subnets
  # ...
}
```

Now Terraform's per-key state re-keying carries across the cross-provider hop automatically because the shape (`for_each` on the resource) matches between old and new addresses.

### TFRMNFR1 "no for_each on submodule primary resource" — apparent conflict, resolved

[TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md) says the **submodule's primary resource SHOULD NOT use `count` or `for_each`**, and the cardinality trap above forces you to put `for_each` on the resource. These are not actually in conflict — the spec's intent is satisfied at the **composition level** (the parent's call to the submodule is `count`/`for_each`-free), and the workaround is the only viable shape for cross-provider state preservation.

This is now established precedent across multiple merged migrations. Cite these in PRs if the AVM reviewer pushes back:

- [`terraform-azurerm-avm-res-web-serverfarm` PR #121](https://github.com/Azure/terraform-azurerm-avm-res-web-serverfarm/pull/121) — App Service Plan multiple-instance migration.
- [`terraform-azurerm-avm-res-network-natgateway` PR #192](https://github.com/Azure/terraform-azurerm-avm-res-network-natgateway/pull/192) — NAT Gateway subnet-association extraction.
- [`terraform-azurerm-avm-res-eventgrid-domain` PR #18](https://github.com/Azure/terraform-azurerm-avm-res-eventgrid-domain/pull/18) — Event Grid Domain topic extraction.

## 2. The `moved {}` patterns you actually need

### 2a. Same module, same address, provider changes (in-place primary)

```hcl
# Before: azurerm_search_service.this
# After:  azapi_resource.this
moved {
  from = azurerm_search_service.this
  to   = azapi_resource.this
}
```

This works because Terraform's cross-provider `moved` machinery uses [`MoveResourceState`](https://developer.hashicorp.com/terraform/plugin/framework/resources/state-move) — the target provider (AzAPI) declares the source types it can absorb. Keep the `moved {}` block in the module for at least one minor release after the migration so lagging consumers still get the address translation, then remove.

### 2b. Submodule extraction, single instance

```hcl
# Before: azurerm_management_lock.this[0]   (count = var.lock == null ? 0 : 1)
# After:  module.lock.azapi_resource.this   (single instance inside submodule)
moved {
  from = azurerm_management_lock.this[0]
  to   = module.lock.azapi_resource.this
}
```

### 2c. Submodule extraction, collection (the trap case)

```hcl
# Before: azurerm_subnet.this  (for_each = var.subnets)
# After:  module.subnets.azapi_resource.this  (for_each = var.subnets, INTERNAL to submodule)
moved {
  from = azurerm_subnet.this
  to   = module.subnets.azapi_resource.this
}
```

Note: **no `[each.key]`** on either side. The whole resource collection moves under the submodule wrapper; per-key state carries across automatically when the `for_each` shape matches.

### 2d. Per-key explicit moves (when shapes don't align)

If the submodule expects a different key shape (e.g. you're consolidating two old collections under one new key), each key needs its own `moved {}`. This is rare and expensive — prefer to keep keys stable and write a single collection-level move.

## 3. The end-to-end migration test recipe

This is the single highest-value artefact of a migration PR. Run it locally before opening the PR; paste the resulting plan output into the PR description.

```bash
# 1. Deploy with the currently published (AzureRM) version of the module.
cd examples/default
cat <<'EOF' > terraform.tfvars
# minimal inputs to exercise the resource(s) being migrated
EOF
terraform init   # uses Azure/avm-res-X-X/azurerm @ current published version
terraform apply -auto-approve

# 2. Swap the module source to the local working tree containing the AzAPI rewrite.
# In main.tf change:
#   source  = "Azure/avm-res-search-searchservice/azurerm"
#   version = "~> 0.2"
# to:
#   source = "../.."
sed -i.bak 's|source.*=.*"Azure/avm-res-search-searchservice/azurerm"|source = "../.."|' main.tf
# (also delete the `version = "~> 0.2"` line)

terraform init -upgrade

# 3. THE TEST. Plan MUST show 0 to destroy / 0 to replace.
terraform plan -out=tfplan
terraform show -json tfplan | jq '[.resource_changes[] | select(.change.actions[] | . == "delete" or . == "replace")] | length'
# Expected: 0. If non-zero, your moved {} blocks are wrong or the cardinality trap struck.

# 4. Apply and re-plan. Re-plan MUST be idempotent (No changes.).
terraform apply tfplan
terraform plan -detailed-exitcode
# Exit code 0 = clean; 2 = drift detected. Anything but 0 means hidden differences in body shape.

# 5. Tear down.
terraform destroy -auto-approve
```

A migration PR description without this output is incomplete. Reviewers should reject "trust me, I tested it" without the plan summary attached.

### Common failure modes and what they mean

| Symptom in step 3 | Likely cause |
|---|---|
| Resource will be destroyed and recreated | Cardinality trap (§1) or `moved {}` block address doesn't match old state exactly |
| Resource will be updated in-place (with body diff) | AzAPI `body` shape doesn't match what AzureRM produced — usually nullable property differences |
| Resource will be created (no destroy) | Old address wasn't in state at apply time — the `moved {}` block silently no-ops |
| Provider configuration is required for resource being destroyed | You removed `azurerm` from `required_providers` too early — keep it until after one release with the `moved` blocks shipped |

## 4. MoveResourceState gotchas

The cross-provider `moved {}` machinery is `MoveResourceState`, added to the Terraform plugin framework and to `terraform` itself in **1.8.0**. The AVM template currently pins `required_version = ">= 1.9, < 2.0"`, so this is normally fine, but two things to flag:

- **Submodule moves use `module.<name>.<address>` addressing**, not just `<address>`. The address on the `to` side is the address as seen from the parent module.
- **Per-key state carries across `for_each` automatically when the shape aligns** (see §1). When it doesn't align, the move silently no-ops — Terraform doesn't error, the planner just doesn't connect the old and new addresses, and you get destroy/create.
- **`lifecycle { ignore_changes = [name] }` on role assignments.** AzAPI `Microsoft.Authorization/roleAssignments` typically uses a server-allocated GUID for `name`. When migrating from `azurerm_role_assignment` (which also has a UUID `name` that Terraform computed), preserving the old GUID is what keeps the role assignment from being recreated. Pattern:

  ```hcl
  resource "azapi_resource" "this" {
    type      = var.resource_types.authorization_role_assignments
    parent_id = var.scope
    name      = each.value.principal_id_uuid_v5_or_imported_guid
    body      = { properties = { /* ... */ } }

    lifecycle {
      ignore_changes = [name]   # AzAPI imports preserve the old GUID; don't fight it
    }
  }
  ```

## 5. When `aztfmigrate` is the right tool — and when it isn't

[`aztfmigrate`](https://github.com/Azure/aztfmigrate) (run with `-to azapi`) is great for **simple in-place primary-resource migrations** at the root configuration level. See `avm-tf-azapi` for the standard workflow.

It is **not** the right tool when:

- You're extracting satellites into submodules at the same time as the provider hop. The tool doesn't know about your TFRMNFR1 refactor.
- You need to apply consistent AVM patterns (`var.resource_types`, `var.retry`, `var.timeouts`, discrete outputs per TFFR2) — `aztfmigrate` produces provider-faithful HCL, not AVM-idiomatic HCL. Always hand-edit after.
- Your module has cross-cutting interface resources (lock, role_assignment, diag, PE) that also need migrating in the same release. Do those manually with explicit `moved {}` blocks per §2.

The rule of thumb: use `aztfmigrate` to generate the first-draft AzAPI HCL when there's no submodule extraction; rely on the §3 end-to-end test (not `aztfmigrate`'s self-report) to prove correctness.

## 6. Where to put the migration `moved {}` blocks

- **Top of `main.tf`**, before the resource declarations they apply to. Group them under a `# Cross-provider migration — keep for at least one minor release after vX.Y` comment.
- For submodule extraction: the `moved {}` block lives in the **parent module's** `main.tf`, not the submodule. The address on the `from` side is the old root-level address; the address on the `to` side is `module.<submodule>.<new_address>`.
- Don't put `moved {}` blocks in `examples/<name>/main.tf` — examples are torn down each test cycle, they have no state to preserve.

## 7. Release notes contract

A migration release MUST include in the changelog / GitHub release notes:

1. **The migration**: which resource(s), from which provider/type to which AzAPI type.
2. **The end-to-end test result**: "0 destroys / 0 replaces verified on the `examples/default` configuration; see PR description for plan output."
3. **The consumer upgrade steps**: typically just `terraform init -upgrade && terraform plan` and verify 0 destroys before applying. If `terraform plan` shows replacements, the consumer should NOT apply and should open an issue.
4. **The `moved {}` retention window**: "These `moved {}` blocks will be removed in v0.X+2. Upgrade through this release within that window."
5. **The version bump**: per [SNFR12](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR12.md) 0.x.y pre-GA, a cross-provider migration warrants a minor bump (`0.4.0` → `0.5.0`), not a major, and definitely not a patch.

## Authoritative sources

- [TFFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR3.md) — the AzAPI-only mandate (with exception checklist)
- [TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md) — submodule rules (and the for_each spec language)
- [SNFR12](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR12.md) — 0.x.y pre-GA versioning
- <https://developer.hashicorp.com/terraform/language/modules/develop/refactoring> — `moved {}` mechanics
- <https://developer.hashicorp.com/terraform/plugin/framework/resources/state-move> — `MoveResourceState` plugin framework API
- [`aztfmigrate`](https://github.com/Azure/aztfmigrate) — `-to azapi` workflow (and its limitations)
- Merged migration precedent: serverfarm PR #121, natgateway PR #192, eventgrid-domain PR #18
