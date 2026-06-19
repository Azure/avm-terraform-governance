---
name: avm-tf-testing
description: Use this skill whenever an Azure Verified Module (AVM) for Terraform needs testing — writing or updating an `examples/<name>/` configuration, a `tests/unit/` provider-mocked test, a `tests/integration/` real-Azure test, running the local `./avm` dev loop (`./avm pre-commit`, `./avm pr-check`, `./avm tf-test-unit`, `./avm tf-test-integration`, `./avm test-examples`), wiring up the `test` GitHub environment with OIDC federated identity to a user-assigned managed identity (no secrets), or debugging a CI failure. Covers the AVM testing model where each `examples/` directory IS itself a unit-ish test, the split between provider-mocked unit tests and real-Azure integration tests, and the federated-identity CI pattern. Trigger on phrases like "AVM tests", "terraform test", "tests/unit", "tests/integration", "examples directory test", "mock_provider", "federated identity AVM", "OIDC AVM CI", "./avm pre-commit", "tf-test-unit", "test-examples", "AVM CI failure", "terratest", "e2e test AVM".
---

# AVM Terraform testing

The AVM testing model has three concentric layers, all driven by the `./avm` script (the canonical local entry point that the AVM CI also uses):

```
examples/<name>/                  → "does the module apply cleanly with this configuration?"  → applied for real
tests/unit/                       → "does the logic behave correctly?"  → provider-mocked, no Azure
tests/integration/                → "does it interact correctly with Azure?"  → applied for real
```

Authoritative sources:
- <https://azure.github.io/Azure-Verified-Modules/contributing/terraform/testing/>
- Microsoft's in-repo skill at `.agents/skills/avm-terraform-module-development/references/terraform-test.md` and `example-test.md` (read these when you're inside a module repo — they're the most up-to-date reference)
- `Makefile` and `./avm` script in any AVM TF repo

## Layer 1 — `examples/`

**Every directory under `examples/` is itself a Terraform configuration that gets applied for real during CI.** They serve two purposes simultaneously: they teach consumers how to call the module, AND they act as end-to-end smoke tests.

```
examples/
├── .terraform-docs.yml
├── default/                      # MUST exist — the minimal "it works" example
│   ├── main.tf
│   ├── variables.tf
│   ├── _header.md
│   ├── _footer.md
│   └── README.md                 # auto-generated, do not edit
├── private-endpoint/             # one example per major feature
├── diagnostic-settings/
├── customer-managed-key/
└── ignore_example_for_e2e/       # opt-out for examples too expensive to apply in CI
    └── .e2eignore                # marker file
```

Each example's `main.tf` calls the module under test from `../..`:

```hcl
terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
  }
}

provider "azapi" {}

# Resources the example needs (resource group, log analytics workspace if showing diagnostics, etc.)
# — exactly the kinds of things the module under test does NOT deploy itself (see avm-tf-interfaces).

resource "azapi_resource" "rg" {
  type      = "Microsoft.Resources/resourceGroups@2021-04-01"
  name      = "rg-avm-search-example-${random_string.this.result}"
  location  = "westeurope"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  body      = {}
}

module "this" {
  source = "../.."

  name                = "srch${random_string.this.result}"
  location            = azapi_resource.rg.location
  resource_group_name = azapi_resource.rg.name

  # Drive the feature you're demonstrating, e.g. for the private-endpoint example:
  private_endpoints = {
    pe1 = {
      subnet_resource_id            = module.vnet.subnets["pe"].resource_id
      private_dns_zone_resource_ids = [module.dns.resource_id]
    }
  }
}
```

### Required examples

- `examples/default/` — minimal configuration, MUST exist. This is what the README's "Quick Start" links to.
- One example per major interface the module supports — `examples/diagnostic-settings/`, `examples/private-endpoint/`, `examples/customer-managed-key/`, etc.
- Examples that are deliberately too expensive to run in CI (e.g. examples that deploy long-cycle resources) include an `.e2eignore` marker file.

### Running an example locally

```bash
PORCH_NO_TUI=1 AVM_EXAMPLE="default" ./avm test-examples
# or, for manual init/plan/apply/destroy:
cd examples/default
terraform init
terraform plan
terraform apply
terraform plan        # MUST show "no changes" — idempotency check
terraform destroy
```

Manual mode is documented in Microsoft's in-repo `example-test.md` reference — useful when you're testing on Windows, distributing across subscriptions, or want to keep deployed resources for manual validation.

## Layer 2 — `tests/unit/`

Unit tests use [Terraform's native test framework](https://developer.hashicorp.com/terraform/language/tests) (the `terraform test` command, `.tftest.hcl` files) with **provider mocking** — they never call Azure.

```hcl
# tests/unit/lock.tftest.hcl
mock_provider "azapi" {}
mock_provider "azurerm" {}

variables {
  location            = "westeurope"
  name                = "srch-test"
  resource_group_name = "rg-test"
}

run "no_lock_creates_no_lock_resource" {
  command = apply

  assert {
    condition     = length(azapi_resource.lock) == 0
    error_message = "Lock resource should not be created when var.lock is null."
  }
}

run "cannotdelete_lock_creates_lock_resource" {
  command = apply

  variables {
    lock = { kind = "CanNotDelete" }
  }

  assert {
    condition     = length(azapi_resource.lock) == 1
    error_message = "Lock resource should be created when var.lock is set."
  }
  assert {
    condition     = azapi_resource.lock[0].body.properties.level == "CanNotDelete"
    error_message = "Lock level should match var.lock.kind."
  }
}

run "invalid_lock_kind_fails_validation" {
  command = apply

  variables {
    lock = { kind = "Frozen" }
  }

  expect_failures = [var.lock]
}
```

> **`command = apply`, not `plan`.** AVM unit tests use `command = apply` against mocked providers because that exercises the full graph (including post-apply computed values and `for_each`/conditional resources). `command = plan` skips too much. See Microsoft's in-repo `.agents/skills/avm-terraform-module-development/references/terraform-test.md` for the current canonical reference.

**Add a unit test when** your change introduces new logic, a new variable, a new validation, or a new output that can be validated without deploying real infrastructure. Skip unit tests for trivial pass-through changes — the bar is "is there logic worth proving with a mocked plan?".

Run:

```bash
PORCH_NO_TUI=1 ./avm tf-test-unit
```

### `terraform test` invocation gotchas (when you run it directly, not via `./avm`)

`terraform test` is **directory-aware** in a way that catches people out:

- **Without `-test-directory`, `terraform test` looks in the *root* of the module for `*.tftest.hcl` files and reports `0 tests` if it doesn't find any there.** AVM modules put tests under `tests/unit/` and `tests/integration/`, so you MUST pass the directory explicitly:
  ```bash
  terraform init  -test-directory=tests/unit
  terraform test  -test-directory=tests/unit
  # and separately
  terraform init  -test-directory=tests/integration
  terraform test  -test-directory=tests/integration
  ```
- **`terraform init -test-directory=...` is a separate init step from your normal `terraform init`.** Test runs need their own provider lock under the test directory. Skipping the dedicated init is the most common cause of "Required plugins are not installed" errors from `terraform test`.
- **`mock_provider "azapi" {}` is global to the test run.** That means unit tests still work when the module under test composes submodules — the mock applies to every `azapi_resource` everywhere in the graph, including those declared inside `modules/<name>/`. You don't need a per-submodule mock declaration.
- **`./avm tf-test-unit` / `./avm tf-test-integration` handle all of the above for you** — they pass the right `-test-directory` and run the init step. Only worry about the raw `terraform test` flags when you're debugging outside the script.

For full syntax + patterns read Microsoft's in-repo `.agents/skills/avm-terraform-module-development/references/terraform-test.md` — it's the canonical reference and is kept current with the AVM testing framework.

## Layer 3 — `tests/integration/`

Integration tests use the same `terraform test` framework but **without** `mock_provider` — they actually call Azure. Use them when you need to validate ARM-side behaviour that mocking can't cover (e.g. that the resource genuinely came up healthy, that a downstream feature actually works against the real RP).

```hcl
# tests/integration/create_default.tftest.hcl
provider "azapi" {}
provider "azurerm" {
  features {}
}

variables {
  random_suffix = "" # filled in by run blocks
}

run "default_module_apply" {
  command = apply

  variables {
    random_suffix = "abcd1234"
  }

  assert {
    condition     = module.this.resource_id != ""
    error_message = "resource_id output should be populated."
  }
}
```

Run:

```bash
PORCH_NO_TUI=1 ./avm tf-test-integration
```

Integration tests require an authenticated Azure session — locally via `az login`, in CI via the federated-identity setup below.

## CI: the `test` GitHub environment + OIDC federated identity

AVM modules **MUST NOT use service principal secrets** for CI. Use OIDC federated identity from GitHub Actions to a user-assigned managed identity (UAMI) in your test subscription.

**Setup (per repo, per the template's TODO list):**

1. **Create a GitHub environment called `test`** in the repo's settings.
2. **Configure environment protection rules** so deployments to `test` require manual approval (recommended; prevents drive-by PRs from spending Azure money).
3. **Create a user-assigned managed identity** in your test subscription:
   ```bash
   az identity create --name id-avm-<module-name> --resource-group rg-avm-test --location westeurope
   ```
4. **Grant the minimum required role** on the test subscription / resource group:
   ```bash
   az role assignment create \
     --assignee <uami-principal-id> \
     --role Contributor \
     --scope /subscriptions/<test-sub-id>
   ```
   (Contributor is the typical default; some modules need additional roles like `User Access Administrator` if they test `role_assignments`.)
5. **Configure federated identity credentials** on the UAMI, scoped to the GitHub `test` environment:
   ```bash
   az identity federated-credential create \
     --name github-test-env \
     --identity-name id-avm-<module-name> \
     --resource-group rg-avm-test \
     --issuer https://token.actions.githubusercontent.com \
     --subject "repo:Azure/terraform-azurerm-avm-res-<module>:environment:test" \
     --audiences api://AzureADTokenExchange
   ```
6. **Store the UAMI's `client_id`, the subscription `id`, and the `tenant_id` as secrets on the `test` GitHub environment** (the AVM template's `pr-check.yml` reads them as `secrets.*`, scoped to the environment — even though the values aren't strictly sensitive, the template treats them as secrets and you should match that pattern so the upstream workflows work unmodified):
   - `secrets.ARM_CLIENT_ID`, `secrets.ARM_SUBSCRIPTION_ID`, `secrets.ARM_TENANT_ID`
   - `ARM_USE_OIDC=true` (env var in the workflow, not a secret)

The bundled `.github/workflows/pr-check.yml` and `.github/workflows/terraform-test.yml` in any AVM TF repo show exactly how this is wired up — copy from there.

## The `./avm` script — the local dev loop entry point

The canonical local commands (use `PORCH_NO_TUI=1` to disable the interactive TUI so output is readable in non-TTY contexts):

| Command | What it does |
|---|---|
| `./avm pre-commit` | Run `terraform fmt`, `tflint`, `avmfix`, `terraform-docs`, file-layout checks. **MUST pass before every commit.** |
| `./avm pr-check` | Run the same checks CI will run, including documentation drift. **MUST pass before pushing a PR branch.** |
| `./avm tf-test-unit` | Run all `tests/unit/` tests. |
| `./avm tf-test-integration` | Run all `tests/integration/` tests. |
| `./avm test-examples` | Apply every `examples/<name>/` configuration (skipping `.e2eignore` ones). |
| `AVM_EXAMPLE="default" ./avm test-examples` | Apply only one example. |
| `./avm docs` | Regenerate `README.md` from `_header.md` + module sources + `_footer.md`. |

Windows equivalents: `.\avm.ps1 pre-commit`, etc.

## When to add tests

| Change | Unit test? | Integration test? | Example? |
|---|---|---|---|
| New optional variable that just maps to an ARM property | Yes (validation) | No | Add to relevant example if it's a feature consumers will reach for |
| New standard interface (e.g. adding `private_endpoints`) | Yes (logic) | Yes (real PE behaviour) | Yes, new example dir |
| Bug fix in a `for_each` expression | Yes (case that failed) | Only if the bug was ARM-side | No |
| Provider version bump | No | Yes (rerun integration suite) | No |
| README / `_header.md` change | No | No | No (but `./avm pr-check` validates docs) |
| New validation block | Yes (`expect_failures`) | No | No |

## Common pitfalls

- **Forgetting that `examples/` get applied in CI.** A broken example fails CI even if your module logic is fine. If an example needs an expensive resource you don't want to spin up on every PR, mark it `.e2eignore` and add a separate `tests/integration/` case.
- **Service principal secrets in CI.** Forbidden — use OIDC. If you see `secrets.AZURE_CLIENT_SECRET` anywhere in `.github/workflows/`, it's wrong.
- **Skipping `./avm pre-commit` because "fmt is fine".** `avmfix` and the doc-generation step catch things `terraform fmt` doesn't.
- **Writing integration tests that don't clean up.** `terraform test` does `apply` then `destroy` per `run` block automatically; if you skip a `destroy` (with `command = apply` and no follow-up `destroy` run), the resources stay. Watch for orphaned resources in your test subscription.
- **Mocking the wrong provider.** `mock_provider "azapi" {}` mocks AzAPI; you also need `mock_provider "azurerm" {}` if your module uses `azurerm_*` for interface resources. Mock everything you use, otherwise `terraform test` will try to genuinely initialise the unmocked provider.
- **Federated-credential subject mismatch.** The `subject` in step 5 above must EXACTLY match what GitHub Actions sends — typo'd repo names or env names cause silent auth failures with `AADSTS70021`.
