# Porch Configurations

This directory contains configuration files for various Porch workflows used in testing Azure Verified Modules.
They ensure consistency between local tests and CI tests.

## Authoring Tips

### Output errors to stderr

When writing checks, redirect any output to `stderr` instead of `stdout`.
This is important because Porch only displays `stderr` for failed steps.
`stdout` is captured but hidden unless Porch is run with `--stdout`, which CI only does when re-run with debug logging enabled.

E.g.

```yaml
type: shell
name: Check for required directory, fail if not present
command_line: |
  if [ ! -d "./some/dir" ]; then
    echo "This ./some/dir does not exist and is required" 1>&2
    exit 1
  fi
```

### Conditional skip

If you want to not fail the workflow, but skip following steps conditionally, use the the `skip_on_exit_codes` field.

```yaml
type: shell
name: Check for required directory, skip if not present
command_line: |
  if [ ! -d "./some/dir" ]; then
    echo "This ./some/dir does not exist and is required" 1>&2
    exit 99
  fi
skip_on_exit_codes:
  - 99
```

### Flow control

To control whether or not a step runs, use the `runs_on_condition` field.
This is useful for cleaning up resources or performing actions based on the success or failure of previous steps.

```yaml
- type: shell
  name: this step fails
  command_line: |
    exit 1

- type: shell
  name: this step runs only if the previous step succeeded
  command_line: |
    echo "This step runs only if the previous step succeeded"

- type: shell
  name: this step runs only if the previous step failed
  command_line: |
    echo "This step runs only if the previously executed (not skipped) step failed"
  runs_on_condition: failure

- type: shell
  name: this step always runs
  command_line: |
    echo "This step always runs"
  runs_on_condition: always
```

###  Grouping steps

You can use type `serial` or `parallel` to group steps together.
The root level commands are always run in series.

```yaml
- type: serial
  name: Group of steps that run serially
  commands:
    - type: shell
      name: First step in serial group
      command_line: |
        echo "This is the first step in a serial group"
    - type: shell
      name: Second step in serial group
      command_line: |
        echo "This is the second step in a serial group"

- type: parallel
  name: Group of steps that run in parallel
  commands:
    - type: shell
      name: Will be run concurrently
      command_line: |
        echo "This is the first step in a parallel group"

    - type: shell
      name: Will be run concurrently as well!
      command_line: |
        echo "This is the second step in a parallel group"
```

## Per-example hooks and `.env` auto-sourcing

The per-example `foreachdirectory` blocks in [`test-examples.porch.yaml`](./test-examples.porch.yaml) and the `well architected` block in [`pr-check.porch.yaml`](./pr-check.porch.yaml) provide optional per-example hook scripts that run inside each example's working directory:

- `pre.sh` / `pre.ps1` — run before the terraform steps.
- `post.sh` / `post.ps1` — run after the terraform steps (always, including on failure).

Each step in a Porch run executes in its own subprocess, so environment variables `export`ed from `pre.sh` / `pre.ps1` do not propagate to the subsequent `terraform init` / `terraform plan` / `terraform apply` / `terraform destroy` steps.

To bridge this, every terraform step in those blocks auto-sources a file named `.env` from the example's working directory if one exists:

```bash
set -a; [ -f .env ] && . ./.env; set +a
terraform <command>
```

`set -a` causes assignments in `.env` to be auto-exported, so the `terraform` process (and any subprocess it spawns, e.g. `gh` via `local-exec`) inherits them as real environment variables for that step only. File presence is the opt-in — examples without a `.env` are unaffected.

### Usage

If your example needs an env var that should not be set on the host (for example, a token that would interfere with local `gh` authentication), have your `pre.sh` write a `.env` file in the example directory and your `post.sh` remove it:

```bash
# pre.sh
cat > .env <<EOF
GITHUB_TOKEN=${AVM_E2E_GITHUB_TOKEN}
EOF
```

```bash
# post.sh
rm -f .env
```

Add `.env` to your module's `.gitignore` so it is never committed.

> If pwsh-typed terraform steps are added to these configs in the future, use the analogous PowerShell preamble:
>
> ```powershell
> if (Test-Path .env) {
>   Get-Content .env | ForEach-Object {
>     if ($_ -match '^([^=]+)=(.*)$') {
>       [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2])
>     }
>   }
> }
> ```

## Example test retries

End to end tests deploy real Azure infrastructure and fail intermittently on region and SKU capacity rather than on module defects. [`test-examples.porch.yaml`](./test-examples.porch.yaml) retries those failures automatically, up to twice per example.

Porch has no retry primitive, so attempts are unrolled as ordinary steps chained by exit code: `0` success, `90` retryable failure, `1` anything else.

### How the steps flow into each other

Two Porch behaviours make this work:

- `success_exit_codes` sets a step's **status**, not its **exit code**. An apply can exit `90`, count as a success so the run is not failed, and still expose `90` to the next gate.
- A **skipped** step does not advance Porch's "previous result", so gates compare against the last step that actually ran.

| Step | Runs when | Success codes |
| ---- | --------- | ------------- |
| `Terraform Apply` | previous succeeded | `0`, `90` |
| `Terraform Destroy and Retry (1)` | previous exit `90` | `0`, `90` |
| `Terraform Destroy and Retry (2, final)` | previous exit `90` | `0` |
| `Terraform Plan Idempotency Check` | previous succeeded | `0` |

Paths, where `~` means skipped:

| Outcome | Apply | Retry 1 | Retry 2 | Idempotency | Example |
| ------- | ----- | ------- | ------- | ----------- | ------- |
| Clean run | `0` | `~` | `~` | runs | passes |
| One flaky failure | `90` | `0` | `~` | runs | passes |
| Two flaky failures | `90` | `90` | `0` | runs | passes |
| Retries exhausted | `90` | `90` | `90` fails | `~` | fails |
| Real defect | `1` fails | `~` | `~` | `~` | fails |

Retry 2 does not fire on a clean run because Retry 1 was skipped and never advanced the previous result. Exhausting the retries fails because the final step omits `90` from its success codes. `Terraform Destroy` runs last with `runs_on_condition: always`, so cleanup happens on every path.

All three attempt steps share one script via a YAML anchor; the retries set `AVM_E2E_RETRY=1` to switch it from "apply the saved plan" to "destroy, then redeploy".

### Retries destroy first

Capacity errors are region specific, so the region must change — but not underneath a populated state.

`-replace=random_integer.region_index` is the obvious fix and is **wrong**. Names come from `module.naming`, which takes no region input, so the resource group is replaced under the *same name* while name-only dependents such as subnets are planned as unchanged. Azure cascade-deletes them and the apply fails with `Root object was present, but now absent` and `Subnet ... was not found`.

Each retry therefore runs:

```shell
terraform destroy -auto-approve
terraform apply -auto-approve
```

Destroy drops `random_integer.region_index` from state, so the next plan re-rolls the region by itself and the apply rebuilds the whole graph from scratch. Reusing `tfplan` is not an option either: a partial apply advances the state serial, so it fails with `Saved plan is stale`. If the destroy fails, the retry aborts with `1` rather than deploying over partial state.

### Tuning the error list

Patterns live in the `retryable` variable in the shared script, matched case insensitively against combined terraform output. Keep them anchored to capacity and quota wording. Broad codes are excluded deliberately: `OperationNotAllowed` covers both quota exhaustion and "cannot delete resource while nested resources exist", and only the former should retry.

### Output handling

Classifying failures means capturing terraform's output. The `run()` helper does this for both the destroy and the apply:

- Porch shows only `stderr` for failed steps, so the script re-emits captured output there before exiting non-zero. Without it a non-retryable failure reports an exit code and nothing else.
- Porch's progress ticker reads `stdout`, so terraform is piped through `tee` rather than buffered to a file.
- `$?` after a pipeline belongs to `tee`, so terraform's real exit code is stashed in a temp file.

### What is not retried

The idempotency check (retrying would hide non-idempotent modules), plan failures, and anything not matching the list.

### Changing the number of attempts

Copy a `Terraform Destroy and Retry (N)` step. Every step except the last uses `success_exit_codes: [0, 90]`; the last omits `90`, which is what makes exhausting the retries fail. When adding one, the previously final step must gain `[0, 90]`.

### Testing the retry path

[`retry-flaky`](../tests/terraform-azurerm-avm-res-mock/examples/retry-flaky) fails its first apply with a matching message, then succeeds. It runs in `governance - test`, so a regression in the chain fails CI. No other mock example produces capacity errors, so without it the retry steps would only ever skip.

