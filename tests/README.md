# How to test changes

All of the workflows that we use have substitution variables that can be set to change the references.

## List of environment variables

| Variable Name | Description | Default Value |
| ------------- | ----------- | ------------- |
| CONFTEST_APRL_URL | The URL to the APRL Conftest policies. | `git::https://github.com/Azure/policy-library-avm.git//policy/Azure-Proactive-Resiliency-Library-v2` |
| CONFTEST_AVMSEC_URL | The URL to the AVMSEC Conftest policies. | `git::https://github.com/Azure/policy-library-avm.git//policy/avmsec` |
| CONFTEST_EXCEPTIONS_URL | The URL to the global Conftest exceptions file. | `https://raw.githubusercontent.com/Azure/policy-library-avm/main/policy/avmsec/avm_exceptions.rego.bak` |
| CONTAINER_IMAGE | The container image to use in the `avm` script in the template repo. | `ghcr.io/azure/avm-terraform-governance:avm-latest` |
| CONTAINER_PULL_POLICY | The pull policy for the container image. | `always` |
| GREPT_URL | The URL to the Grept policies. | `git::https://github.com/Azure/avm-terraform-governance.git//grept-policies` |
| MAKEFILE_REF | The git ref to use for the remote Makefile. | `main` |
| MPTF_URL | The URL to the Map of TF configs. | `git::https://github.com/Azure/avm-terraform-governance.git//mapotf-configs` |
| PORCH_BASE_URL | The base go-getter URL for the porch configs. | `git::https://github.com/Azure/avm-terraform-governance//porch-configs` |
| PORCH_REF | The git ref to use for the porch configs. | `main` |
| TFLINT_CONFIG_URL | The URL to the TFLint config files. | `https://raw.githubusercontent.com/Azure/avm-terraform-governance/main/tflint-configs` |

## Mock modules

There are two mock modules that are used in the tests:

- `mock-module-azurerm`: A mock module that simulates AzureRM resources.
- `mock-module-azapi`: A mock module that simulates AzAPI resources.

## Test harness

There is a test workflow that will run the governance framework against the mock modules. You can run this workflow manually or as part of a pull request.

The workflow will:

- Build the container image and store as an artifact.
- Use the above container to run all future steps.
- Override the default URLs for all the policies and configs to use the specific commit of branch you are testing.
- Execute the following:
  - `avm pre-commit`: Runs the pre-commit hooks (and git commit if needed).
  - `avm pr-check`: Runs the tests against the mock modules.

This allows you to ensure that any policy changes you make will not break the existing tests and that the governance framework works as expected.
