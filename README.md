# Azure Verified Modules Governance Repo

This project centralizes the governance of Azure Verified Modules, ensuring compliance with best practices and organizational policies.

It is currently a work in progress, the following assets live here:

- **Dockerfile**: Standard container image for AVM Terraform based on Azure Linux 3.0.
- **tflint config**: Configuration for TFLint to enforce coding standards and best practices.
- **managed files**: Repository files (workflows, CODEOWNERS, dependabot config, etc.) synced into each AVM Terraform repository by the central governance Terraform run (`tf-repo-mgmt/repository_sync`).
- **porch configs**: standard process orchestration templates to ensure consistent testing and validation of Terraform modules.
- **managed github workflows**: GitHub Actions workflows to automate the testing and validation of Terraform modules.
- **makefile**: A centralized Makefile to streamline the development process across all AVM repositories.

## Testing the tests

See the [Testing](./tests/README.md) documentation for details on how we test the governance framework.
