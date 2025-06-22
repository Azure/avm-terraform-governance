# How to test changes

All of the workflows that we use have substitution variables that can be set to change the references.

## List of environment variables

| Variable Name | Description | Default Value |
| ------------- | ----------- | ------------- |
| AVM_EXAMPLE | By default all examples are run with `test-examples`, set this to limit to a specific example. | undefined |
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

- `terraform-azure-avm-res-mock`: A mock module that simulates AzAPI resources.
- `terraform-azurerm-avm-res-mock`: A mock module that simulates AzureRM resources.

## Test harness

There is a [test workflow](https://github.com/Azure/avm-terraform-governance/actions/workflows/governance-test.yml)
[[yaml]](https://github.com/Azure/avm-terraform-governance/blob/main/.github/workflows/governance-test.yml) that
will run the governance framework against the mock modules. You can run this workflow manually
or as part of a pull request.

The workflow has two jobs, the second of which uses a matrix to run against both mock modules.

### Job 1 - Build image

This job is responsible for building the container image that will be used in the second job.
It stores the image as an artifact so that it can be downloaded in the second job, without having to push it to a registry.

This job also runs a trivy scan on the image to ensure that it is secure and does not contain any vulnerabilities. This step is set to continue on error, so that the workflow can continue even if the scan fails.

> [!IMPORTANT]
> Please review the build to ensure that there are no vulnerabilities that have been added by packages or dependencies that have been added to the image. If there are vulnerabilities, please address them before merging your changes.


### Job 2 - Run tests

This job is responsible for running the governance framework against the mock modules. It uses the container image built in the first job and runs the tests against both mock modules.

It overrides the default URLs for all the policies and configs to use the specific commit of branch you are testing.

It executes the following steps:

1. `avm pre-commit`: Runs the pre-commit hooks (and git commit if needed).
1. `avm pr-check`: Runs the tests against the mock modules.
1. `avm test-examples`: Deploys the examples.
1. `avm tf-test-unit`: Runs the Terraform unit tests.

This allows you to ensure that any policy changes you make will not break the existing tests and that the governance framework works as expected.

## Updating the container image

If you need to update the container image, you should make sure that:

1. The changes to the Dockerfile are in the `main` branch of the `avm-terraform-governance` repository, before updating and policies or configs that depend on it.
1. A release is created in the `avm-terraform-governance` repository with the updated image tag and this has succeeded and pushed the image to the container registry.

After this is done you can merge in the changes to the policies or configs that depend on the updated image.
