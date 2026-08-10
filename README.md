# Azure Verified Modules Terraform Governance

This repository manages the GitHub configuration and shared repository files for Azure Verified Modules Terraform repositories.

The Terraform authoring toolchain, pinned tool and policy assets, and reusable module workflow are maintained in [Azure/azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools) and delivered through the `Avm.Authoring` PowerShell module.

The governance assets that remain here are:

- `managed-files`: files synchronized into AVM Terraform repositories.
- `tf-repo-mgmt`: repository, identity, environment, ruleset, and team configuration.
- `.github/actions/avm-repos`: repository discovery used by fleet workflows.
