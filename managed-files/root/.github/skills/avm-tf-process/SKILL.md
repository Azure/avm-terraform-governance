---
name: avm-tf-process
description: Use this skill whenever a contributor is going through the AVM contribution process for a Terraform module — from proposal to repo bootstrap to first publish to ongoing PRs. Covers the proposal issue (https://aka.ms/AVM/ModuleProposal), getting added to the `avm-module-owners-terraform` GitHub team via Core Identity, cloning the `terraform-azurerm-avm-template` template repository to bootstrap a new module repo, the CODEOWNERS file, branch protection (TFNFR3), the standard AVM GitHub labels (Set-AvmGitHubLabels.ps1), PR approval logic for single vs multiple module owners, and publishing the first version to the Terraform Registry. Trigger on phrases like "propose a new AVM module", "create AVM module repo", "set up CODEOWNERS for AVM", "AVM branch protection", "PR approval rules", "publish to Terraform Registry", "AVM template repo", "avm-module-owners-terraform", "AVM labels".
---

# AVM Terraform contribution process

End-to-end: from "I want to build an AVM module for X" to a published `0.1.0` on the Terraform Registry, then ongoing PR flow.

Authoritative sources:
- <https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/contributing/process.md>
- <https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/contributing/terraform/_index.md>
- <https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/specs/terraform/resource.md> (Contribution/Support section)
- [SNFR8](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR8.md) — Module Owner(s) GitHub
- [SNFR9](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR9.md) — AVM & PG Teams GitHub Repo Permissions
- [SNFR10](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR10.md) — MIT Licensing
- [SNFR23](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR23.md) — GitHub Repo Labels
- [TFNFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR3.md) — Branch Protection

## Step 1 — Propose the module

Open a [module proposal issue](https://aka.ms/AVM/ModuleProposal) on `Azure/Azure-Verified-Modules`. Include the items listed in `avm-tf-lifecycle` (name, class, language=Terraform, description, owner if known).

The AVM core team triages. If accepted, the module name is added to the Terraform [module index](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/indexes/_index.md) and labelled `Status: Owners Identified 🤘` → `Status: Ready For Repository Creation 📝` → `Status: Repository Created 📄` as the process proceeds.

**Today, the module owner MUST be a Microsoft FTE** ([SNFR8](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR8.md)). Community contributors can submit PRs to existing modules from forks, but owning a module requires a Microsoft email address.

## Step 2 — Get added to the owners team

Access to AVM Terraform repositories is managed by the single [`avm-module-owners-terraform`](https://github.com/orgs/Azure/teams/avm-module-owners-terraform) GitHub team. **Request access via the `Azure Verified Module Owners Terraform` entitlement in Core Identity** (Microsoft internal). This is different from Bicep, which uses a per-module GitHub team.

## Step 3 — Bootstrap the module repo

The AVM core team will create the repo under the `Azure` org from the [`terraform-azurerm-avm-template`](https://github.com/Azure/terraform-azurerm-avm-template) template. You should not create it yourself.

When the empty repo lands, you'll see the template's TODO list:

1. Set up a GitHub repo environment called `test` (for integration tests).
2. Configure environment protection so a deployment to `test` requires approval.
3. Create a user-assigned managed identity in your test Azure subscription.
4. Grant the managed identity the minimum required role on your test subscription.
5. Configure federated identity credentials on the managed identity → the GitHub `test` environment (NOT a service principal secret — see `avm-tf-testing`).
6. Search the codebase for `TODO` comments and resolve them.

The template ships with:

- `terraform.tf` (provider pinning — see `avm-tf-codestyle`)
- `main.tf` (placeholder for the primary resource — replace with your AzAPI implementation)
- `main.telemetry.tf` (`modtm` wiring, do not edit — see `avm-tf-telemetry`)
- `variables.tf` / `outputs.tf` / `locals.tf`
- `_header.md` / `_footer.md` (README is auto-generated from these — see `avm-tf-documentation`)
- `examples/default/` (the first example, which doubles as a smoke test)
- `.github/` (workflows, CODEOWNERS template, issue templates)
- `.agents/skills/avm-terraform-module-development/` — Microsoft's per-repo dev-loop skill (read this for `./avm` script usage)
- `Makefile` and `./avm` script (the local automation entry point)

## Step 4 — Make the AVM team a repo admin

Per [SNFR9](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR9.md), the module owner **MUST** make these two GitHub teams admins on the repo:

- `@Azure/avm-core-team-technical-terraform` — AVM core team
- `@Azure/terraform-avm` — Terraform PG team

Do this via the repo's `Settings → Collaborators and teams → Add teams`. The bots that drive PR review and labelling depend on these team memberships.

## Step 5 — Wire up CODEOWNERS

Edit `.github/CODEOWNERS`. The exact entry depends on the module — typical pattern is to make the module's GitHub team or the owner's individual handle the codeowner for the whole repo:

```
*       @your-microsoft-handle @second-owner-microsoft-handle
```

If there are multiple owners listed, the PR approval rules below apply.

## Step 6 — Branch protection ([TFNFR3](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/terraform/shared/non-functional/TFNFR3.md))

Set on the default branch (`main`). All of the following **MUST** be enabled:

1. Require a Pull Request before merging.
2. Require approval of the most recent reviewable push.
3. Dismiss stale pull request approvals when new commits are pushed.
4. Require linear history.
5. Prevent force pushes.
6. Do not allow deletions.
7. Require CODEOWNERS review.
8. Do not allow bypassing the above settings — **enforced to administrators** too.

If you bootstrapped from the template, the bundled `.github/policies/branchprotection.yml` enforces most of this automatically.

## Step 7 — Standard GitHub labels ([SNFR23](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR23.md))

AVM uses a canonical label set across all module repos (Type/Status/Needs/Class/Language). Apply them with the [`Set-AvmGitHubLabels.ps1`](https://azure.github.io/Azure-Verified-Modules/scripts/Set-AvmGitHubLabels.ps1) script:

```powershell
Set-AvmGitHubLabels.ps1 -RepositoryName "Azure/terraform-azurerm-avm-res-your-module" -CreateCsvLabelExports $false -NoUserPrompts $true
```

You need GitHub CLI installed and authenticated, and repo admin permissions. The label set is pulled from the AVM-hosted CSV at `https://azure.github.io/Azure-Verified-Modules/governance/avm-standard-github-labels.csv` and includes everything the AVM bots and issue templates expect (e.g. `Needs: Triage 🔍`, `Status: Module Available 🟢`, `Language: Terraform 🌐`, `Class: Resource Module 📦`).

## Step 8 — License

`LICENSE` **MUST** be MIT ([SNFR10](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR10.md)). The template ships with the correct file — don't replace it.

## Step 9 — Build, test, publish

Use the `./avm` script (Linux/macOS) or `.\avm.ps1` (Windows) — see `avm-tf-testing` for the full local dev loop. The minimum before opening a PR:

```bash
PORCH_NO_TUI=1 ./avm pre-commit     # fmt, lint, docs, file-layout checks
PORCH_NO_TUI=1 ./avm tf-test-unit   # provider-mocked unit tests
PORCH_NO_TUI=1 ./avm pr-check       # the same checks CI will run
```

When the first PR merges, the release-please / semantic-release workflow cuts the tag (`v0.1.0`), which triggers publication to the Terraform Registry under `Azure/avm-res-<rp>-<type>/azurerm`.

## Ongoing PR approval logic

Per [contributing/process](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/contributing/process.md), who needs to approve a PR depends on (a) who submitted it and (b) how many owners the module has:

| | PR by a module owner | PR by anyone else |
|---|---|---|
| **Single-owner module** | AVM core team (or, for Terraform only, the owner of another AVM module) approves | The module owner approves |
| **Multi-owner module** | Another owner (not the submitter) approves | One of the owners approves |

For Terraform, owners of *other* AVM modules can act as cross-reviewers for single-owner modules — this is a Terraform-specific concession that doesn't exist for Bicep.

Bots auto-assign the expected reviewers based on these rules; you don't need to assign manually.

## Common pitfalls

- **Creating the repo yourself before approval.** Don't — wait for the AVM core team. The repo's name, visibility, and team configuration depend on AVM tooling.
- **Adding individual users to repo permissions** ([SNFR20](https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/refs/heads/main/docs/content/specs-defs/includes/shared/shared/non-functional/SNFR20.md)). All repo permissions go through GitHub teams. Add yourself to `avm-module-owners-terraform` via Core Identity; don't grant yourself direct repo access.
- **Skipping the label script.** The AVM bots rely on the canonical labels — missing labels break triage automation.
- **Forgetting that branch protection applies to admins.** TFNFR3 explicitly requires "enforced to administrators". A common mistake is leaving the admin-bypass checkbox enabled.
- **Publishing as `1.0.0`.** Forbidden — see `avm-tf-lifecycle`. The release-please config in the template defaults to `0.x.y`; don't override it.
