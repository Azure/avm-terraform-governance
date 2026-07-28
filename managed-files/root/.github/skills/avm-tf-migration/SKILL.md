---
name: avm-tf-migration
description: Use this skill whenever an AVM Terraform module is being migrated from AzureRM to AzAPI, whether for the primary resource, a cross-cutting interface resource (lock, role assignment, diagnostic setting, private endpoint), or when extracting satellite resources into TFRMNFR1 submodules. Covers the cardinality trap (why a reusable `moved {}` block cannot re-home a collection into a `for_each`'d submodule call, and why pushing `for_each` inside the submodule is a TFRMNFR1 violation rather than a fix), the TFRMNFR1-compliant migration strategies (migrate the provider flat first with a same-level wildcard `moved {}`; migrate a resource in place inside an already-`for_each`'d submodule; accept a breaking change for module-managed interface resources; treat collection extraction as inherently state-breaking), the canonical `moved {}` patterns, the end-to-end migration test recipe (deploy with published AzureRM → swap to local → 0 destroys → re-plan idempotent → teardown), `MoveResourceState` and `terraform state mv` mechanics, the Terraform 1.8+ requirement, and per-resource gotchas like `lifecycle { ignore_changes = [name] }` on role assignments to preserve server-allocated GUIDs. Trigger on phrases like "migrate this module to AzAPI", "azurerm to azapi", "extract into submodule", "moved block", "MoveResourceState", "destroy/create on upgrade", "state preservation", "consumers will see replace", "cardinality trap", "module for_each migration", "TFRMNFR1 submodule extraction", "split satellite into submodule", "0 destroys", "migration test recipe", "aztfmigrate state".
---

# AVM Terraform: AzureRM → AzAPI migration playbook

This skill is what you reach for when an existing AVM Terraform module needs to change provider — almost always AzureRM → AzAPI per [TFFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/functional/TFFR3.md), often combined with extracting satellite resources into a [TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md) submodule.

It exists because the AVM-published migration guidance covers the "rewrite the HCL" half and leaves the "and don't break every consumer's state" half mostly to folklore. Cross-provider migrations are not garden-variety Terraform refactors: the provider and the resource type both change, so `moved {}` blocks have load-bearing semantics, and the slightest cardinality mismatch silently flips the upgrade into a destroy/recreate.

## The non-negotiable principle

**State preservation is non-negotiable during AzureRM → AzAPI migration.** Every cross-provider change MUST be verified with an end-to-end migration test (see §3) showing **zero destroys** on the upgrade plan. A migration that recreates the consumer's Search service, Key Vault, or App Service is a critical-severity outage, not a release note. If the test can't show 0 destroys, the migration is not ready to ship.

This sits alongside AzAPI-first as a top-line rule, not a nice-to-have.

## 1. The cardinality trap (read this first if you're extracting submodules)

The single most common way migrations break: authors try to **extract a root-level collection into a [TFRMNFR1](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/resource/non-functional/TFRMNFR1.md) submodule at the same time as the provider hop**, and expect a reusable `moved {}` block to preserve state. It can't — and the shape that *would* make a reusable `moved {}` work is the one shape the spec forbids.

TFRMNFR1 is unambiguous about cardinality: the **parent** puts `count`/`for_each` on the submodule *call*, and the submodule's primary `azapi_resource` manages **exactly one instance** (it **MUST NOT** declare `count` or `for_each`). So the compliant call is:

```hcl
# ✅ TFRMNFR1-compliant cardinality: for_each on the module CALL, single instance inside
module "subnet" {
  source   = "./modules/subnet"
  for_each = var.subnets
  # ...
}
```

But you **cannot** write a single reusable `moved {}` block that re-homes a root-level `for_each` resource into that `for_each`'d module call:

```hcl
# ❌ There is no general (wildcard) moved {} block for this shape
moved {
  from = azurerm_subnet.this               # keys are the consumer's
  to   = module.subnet.azapi_resource.this
}
```

Terraform requires an **explicit instance key** on a `moved` target that sits inside a `for_each`'d module call (`module.subnet["snet-web"].azapi_resource.this`), and those keys belong to the consumer — unknowable when you author the module. The wildcard form above never compiles to a per-key mapping, so every consumer sees destroy/recreate. (Terraform [refactoring docs](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring): "you must specify a specific instance key … to match with the new location of the resource configuration".)

**Do not "solve" this by pushing the `for_each` inside the submodule.** The shape where the parent calls the submodule *once* with a whole map and the submodule's `azapi_resource` carries `for_each` internally *does* let a wildcard `moved {}` re-key state — but it is exactly what **TFRMNFR1 forbids**: submodules **MUST** manage a single instance so they remain independently consumable. AVM maintainers have confirmed this on review. State preservation is not a licence to break TFRMNFR1.

### The compliant migration strategies

Because "provider hop + collection extraction into a compliant submodule" cannot be done in one state-preserving step, split the concerns:

1. **Migrate the provider first, keep the resource flat (preferred).** In one release, swap `azurerm_X.this` → `azapi_resource.this` (or a named `azapi_resource.X` for a collection) **at the root of the module**, with a same-level wildcard `moved {}`. Both addresses live at the same module depth, so the wildcard re-keys cleanly across the provider hop — even when both sides are `for_each`'d:

   ```hcl
   # ✅ Same module level, for_each on both sides — wildcard moved works
   moved {
     from = azurerm_public_ip.this   # for_each = var.public_ips
     to   = azapi_resource.public_ip # for_each = var.public_ips
   }
   ```

2. **Migrate a resource that already lives in a submodule, in place.** When the submodule already exists (the parent already `for_each`'s it) and you're only changing the provider of the resource *inside* it, put the `moved {}` **inside the submodule** so each instance re-homes itself at its own module level:

   ```hcl
   # ./modules/subnet/main.tf — evaluated once per submodule instance
   moved {
     from = azurerm_subnet.this
     to   = azapi_resource.this
   }
   ```

   This is the pattern `terraform-azurerm-avm-res-network-virtualnetwork` uses in `modules/subnet`, and it is fully TFRMNFR1-compliant (the submodule is still single-instance).

3. **Accept a breaking change for module-managed interface resources.** Locks, diagnostic settings and role assignments are managed *by* the module, not by the consumer, so recreating them is low impact. Where a state-preserving `moved {}` isn't available, migrate them without one and flag the recreate in the release notes.

4. **Extracting a consumer-data collection into a *new* compliant submodule is inherently state-breaking.** If you must both extract *and* preserve state, the only options are a documented per-key `terraform state mv` recipe for consumers, or doing the extraction as a separate breaking release from the provider migration. Prefer designing subresources as submodules from day one so no extraction is ever needed.

Cite these merged migrations if a reviewer wants precedent — note they all migrated the provider **flat**, without a same-release submodule extraction:

- [`terraform-azurerm-avm-res-web-serverfarm` PR #121](https://github.com/Azure/terraform-azurerm-avm-res-web-serverfarm/pull/121) — App Service Plan; root-level `moved {}` for the plan, lock and role assignment.
- [`terraform-azurerm-avm-res-network-natgateway` PR #192](https://github.com/Azure/terraform-azurerm-avm-res-network-natgateway/pull/192) — NAT Gateway; a `for_each` `public_ip` collection re-keyed by a same-level wildcard `moved {}`.
- [`terraform-azurerm-avm-res-eventgrid-domain` PR #18](https://github.com/Azure/terraform-azurerm-avm-res-eventgrid-domain/pull/18) — Event Grid Domain support interfaces migrated as a breaking change (no `moved {}`).

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

### 2c. Same-level collection, provider changes (in-place, `for_each` on both sides)

```hcl
# Before: azurerm_public_ip.this  (for_each = var.public_ips)  — at module root
# After:  azapi_resource.public_ip (for_each = var.public_ips) — still at module root
moved {
  from = azurerm_public_ip.this
  to   = azapi_resource.public_ip
}
```

Note: **no `[each.key]`** on either side, and **both addresses are at the same module depth**. The wildcard form re-keys every instance across the provider hop because Terraform can pair the old and new addresses one-to-one. This is the shape `terraform-azurerm-avm-res-network-natgateway` used for its `public_ip` collection.

### 2d. Collection *extraction* into a submodule — not a `moved {}` case

Moving a root-level `for_each` collection **into** a `for_each`'d submodule call cannot be expressed with a reusable `moved {}` block (see §1: the target keys inside a `for_each`'d module call are the consumer's and can't be wildcarded). Don't attempt it, and don't work around it by putting `for_each` inside the submodule (TFRMNFR1 violation). Options: migrate the provider **flat** first and extract in a later breaking release, or ship the extraction as a breaking change with a per-key `terraform state mv` recipe for consumers. If the resource already lives in a submodule, migrate it in place with a `moved {}` **inside** that submodule (§1, strategy 2).

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
| Resource will be destroyed and recreated | Cardinality trap (§1 — a `moved {}` targeting a resource inside a `for_each`'d module call), or the `moved {}` block address doesn't match old state exactly |
| Resource will be updated in-place (with body diff) | AzAPI `body` shape doesn't match what AzureRM produced — usually nullable property differences |
| Resource will be created (no destroy) | Old address wasn't in state at apply time — the `moved {}` block silently no-ops |
| Provider configuration is required for resource being destroyed | You removed `azurerm` from `required_providers` too early — keep it until after one release with the `moved` blocks shipped |

## 4. MoveResourceState gotchas

The cross-provider `moved {}` machinery is `MoveResourceState`, added to the Terraform plugin framework and to `terraform` itself in **1.8.0**. The AVM template currently pins `required_version = ">= 1.9, < 2.0"`, so this is normally fine, but two things to flag:

- **Submodule moves use `module.<name>.<address>` addressing**, not just `<address>`. The address on the `to` side is the address as seen from the parent module. A wildcard `moved {}` only works when the module on the `to` side is **not** `for_each`/`count`-indexed; for a resource migrating *within* an already-`for_each`'d submodule, put the `moved {}` inside the submodule so each instance re-homes at its own level (§1, strategy 2).
- **Same-level wildcard `moved {}` re-keys `for_each` collections automatically** when both addresses sit at the same module depth (§2c). When the shapes don't align — or the target is inside a `for_each`'d module call — the move silently no-ops: Terraform doesn't error, the planner just doesn't connect the old and new addresses, and you get destroy/create.
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
