# Azure Verified Modules Terraform Governance

> [!IMPORTANT]
> This repository has been deprecated and archived. It is retained only for
> historical reference and is no longer maintained.

## Replacements

- **Terraform authoring tooling:** The legacy AVM tooling and container images
  have been replaced by
  [`Avm.Authoring`](https://www.powershellgallery.com/packages/Avm.Authoring).
  Its source is maintained in
  [Azure/azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools/tree/main/src/Avm.Authoring).
- **Managed files:** Relocated to
  [Azure/azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools/tree/main/repository-management/managed-files).
- **Repository creation:** Relocated to
  [Azure/azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools/tree/main/repository-management/repository-creation).
- **Repository sync:** Relocated to
  [Azure/azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools/tree/main/repository-management/repository-sync).
- **Offline sync:** Relocated to
  [Azure/Azure-Verified-Modules](https://github.com/Azure/Azure-Verified-Modules/tree/main/utilities/terraform/offline-sync).

The legacy container, Porch, Make, Mapotf/TFLint configuration, workflow, and
test-fixture assets were deprecated in favor of `Avm.Authoring`. Repository Data
Sync and Terraform module-index CSV generation were retired without replacement.
