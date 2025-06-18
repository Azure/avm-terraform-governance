# Porch Configurations

This directory contains configuration files for various Porch workflows used in testing Azure Verified Modules.
They ensure consistency between local tests and CI tests.

## Authoring Tips

### Output errors to stderr

When writing checks, redirect any output to `stderr` instead of `stdout`.
This is important because the Porch displays `stdout` by default for failed steps.

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
