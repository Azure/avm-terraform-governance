# How to test changes

All of the workflows that we use have substitution variables that can be set to change the references.

## List of environment variables

| Variable Name | Description | Default Value |
| ------------- | ----------- | ------------- |
| CONFTEST_APRL_URL | The URL to the APRL Conftest policies. | `git::https://github.com/Azure/policy-library-avm.git//policy/Azure-Proactive-Resiliency-Library-v2` |
| CONFTEST_AVMSEC_URL | The URL to the AVMSEC Conftest policies. | `git::https://github.com/Azure/policy-library-avm.git//policy/avmsec` |
| CONFTEST_EXCEPTIONS_URL | The URL to the global Conftest exceptions file. | `https://raw.githubusercontent.com/Azure/policy-library-avm/main/policy/avmsec/avm_exceptions.rego.bak` |
| GREPT_URL | The URL to the Grept policies. | `git::https://github.com/Azure/avm-terraform-governance.git//grept-policies` |
| MPTF_URL | The URL to the Map of TF configs. | `git::https://github.com/Azure/avm-terraform-governance.git//mapotf-configs` |
| PORCH_BASE_URL | The base go-getter URL for the porch configs. | `git::https://github.com/Azure/avm-terraform-governance//porch-configs` |
| PORCH_REF | The git ref to use for the porch configs. | `main` |
| TFLINT_CONFIG_URL | The URL to the TFLint config files. | `https://raw.githubusercontent.com/Azure/avm-terraform-governance/main/tflint-configs` |
