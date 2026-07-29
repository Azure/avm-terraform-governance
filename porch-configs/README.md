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

End to end example tests deploy real Azure infrastructure, so they fail intermittently on region and SKU capacity rather than on module defects: `SkuNotAvailable`, zonal allocation failures, quota exhaustion, or `sku_selector` finding no deployable size in the randomly chosen region. [`test-examples.porch.yaml`](./test-examples.porch.yaml) retries those failures automatically, up to twice per example.

Porch has no retry primitive, so the attempts are unrolled as ordinary steps and chained together with exit codes:

| Exit code | Meaning |
| --------- | ------- |
| `0` | Success. The remaining retry steps skip themselves. |
| `90` | Failed, and the output matched the retryable error list. |
| `1` | Failed for any other reason. Fail immediately. |

### How the steps flow into each other

Three ordinary steps behave like a retry loop because of two Porch behaviours:

- **`success_exit_codes` sets a step's _status_, but never rewrites its _exit code_.** An apply can exit `90`, be reported as a **success** so the run is not failed, and still expose `90` to the next step's gate. This is what separates "retryable failure" from "the example failed".
- **A skipped step does not advance Porch's "previous result".** Gates keep comparing against the last step that *actually ran*, so a chain of skips all still see the same exit code.

The steps are configured like this:

| Step | Runs when | Counts as success |
| ---- | --------- | ----------------- |
| `Terraform Apply` | previous step succeeded (default) | `0`, `90` |
| `Terraform Destroy and Retry (1)` | previous exit code is `90` | `0`, `90` |
| `Terraform Destroy and Retry (2, final)` | previous exit code is `90` | `0` only |
| `Terraform Plan Idempotency Check` | previous step succeeded (default) | `0` only |

Which produces these paths, where `~` means skipped:

| Outcome | Apply | Retry 1 | Retry 2 | Idempotency | Example |
| ------- | ----- | ------- | ------- | ----------- | ------- |
| Clean run | `0` | `~` | `~` | runs | passes |
| One flaky failure | `90` | `0` | `~` | runs | passes |
| Two flaky failures | `90` | `90` | `0` | runs | passes |
| Retries exhausted | `90` | `90` | `90` **fails** | `~` | fails |
| Real defect | `1` **fails** | `~` | `~` | `~` | fails |

Three things fall out of that table:

- **Retry 2 does not fire on a clean run.** Retry 1 was skipped, so it never advanced the previous result — Retry 2's gate still sees the apply's `0`, not a `90`.
- **A real defect never retries.** Exit `1` is not `90`, so both retry steps skip and the example fails on the first attempt, exactly as before this feature existed.
- **Exhausting the retries fails the run.** The final step omits `90` from `success_exit_codes`, so its status is *error*; the idempotency check runs on success and therefore skips.

`Terraform Destroy` sits at the end with `runs_on_condition: always`, so cleanup happens down every one of those paths.

All three attempt steps share one script via a YAML anchor. The retry steps set `AVM_E2E_RETRY=1`, which switches the script from "apply the saved plan" to "destroy, then redeploy from scratch".

### Retries destroy first

Capacity errors are region and SKU specific, so a retry that redeploys into the same region fails identically. The region has to change, but it must not change *underneath a populated state*.

Re-planning in place with `-replace=random_integer.region_index` looks like the obvious fix and is wrong. Example resource names come from `module.naming`, which takes no region input, so the names do not change when the region does. The resource group is therefore replaced under the *same name*, while dependents that reference only `.name` — subnets, for example — are planned as unchanged. Azure cascade-deletes those along with the resource group, and the apply fails with `Provider produced inconsistent result after apply ... Root object was present, but now absent` and `Subnet ... was not found`.

So each retry destroys before redeploying:

```shell
terraform destroy -auto-approve
terraform apply -auto-approve
```

Destroying removes `random_integer.region_index` from state, so the following plan re-rolls the region on its own and no `-replace` is needed. The apply then creates the whole graph from scratch, which is consistent by construction.

The retry apply deliberately does not reuse `tfplan`. A failed apply is usually a partial apply, which advances the state serial and makes the saved plan stale — `terraform apply tfplan` would fail with `Saved plan is stale` regardless of the underlying capacity problem.

If `terraform destroy` itself fails the retry aborts with exit `1` rather than deploying on top of partial state.

### Tuning the error list

The patterns live in the `retryable` variable in the shared script and are matched case insensitively against the combined terraform output. Keep them anchored to capacity and quota wording.

Broad Azure error codes are deliberately excluded. `OperationNotAllowed`, for example, covers both quota exhaustion and "cannot delete resource while nested resources exist", and only the former should ever be retried.

### How the terraform output is handled

Classifying the failure means the step has to capture its own output, which interacts with two Porch behaviours:

- Porch only displays `stderr` for failed steps, so the step re-emits the captured output to `stderr` before exiting non-zero. Without this a genuine, non-retryable failure would report only an exit code and no diagnostics.
- Porch's progress ticker reads `stdout`, so terraform is piped through `tee` rather than redirected to a file. Buffering the whole apply to a file would leave long-running deployments with no live output.

Because `$?` after a pipeline is `tee`'s status, terraform's real exit code is stashed in a temporary file inside the pipeline and read back afterwards. The `run()` helper wraps both concerns so the destroy and the apply are handled identically.

### What is not retried

- **The idempotency check.** Retrying it would hide genuinely non-idempotent modules.
- **Plan failures.** Only the apply and retry steps classify their output.
- **Anything not matching the list.** It fails on the first attempt, as before.

### Changing the number of attempts

The attempt count is fixed by how many retry steps are unrolled. To add one, copy a `Terraform Destroy and Retry (N)` step. Note that `success_exit_codes` differs by position:

- Every step **except the last** uses `success_exit_codes: [0, 90]`. Exit 90 must count as a success, otherwise a failed early attempt marks the whole example as failed even when a later attempt passes.
- The **last** step omits `90`, which is what makes exhausting the retries fail the run.

So when adding a step, the previously final one must gain `success_exit_codes: [0, 90]`.

### Testing the retry path

The mock module example [`retry-flaky`](../tests/terraform-azurerm-avm-res-mock/examples/retry-flaky) fails its first apply with a message matching the retryable list, then succeeds on the next attempt. It runs in the `governance - test` workflow, so a regression in the retry chain fails CI. The other mock examples never produce capacity errors, so without it the retry steps would only ever be skipped.

