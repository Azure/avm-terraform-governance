# Terraform lifecycle operations: workspace cleanup, init, import-bootstrap,
# plan, and apply (with retry).

# Removes per-run artifacts from the Terraform module directory so each repo
# starts from a known-clean state. Skipped when the caller passes
# `-skipCleanup` to the sync script (useful for local debugging).
function Clear-TerraformWorkspace {
    param([string]$terraformModulePath)

    if (Test-Path "$terraformModulePath/.terraform") {
        Remove-Item "$terraformModulePath/.terraform" -Recurse -Force
    }
    if (Test-Path "$terraformModulePath/terraform.tfvars.json") {
        Remove-Item "$terraformModulePath/terraform.tfvars.json" -Force
    }
    if (Test-Path "$terraformModulePath/terraform.tfstate") {
        Remove-Item "$terraformModulePath/terraform.tfstate" -Force
    }
    if (Test-Path "$terraformModulePath/.terraform.lock.hcl") {
        Remove-Item "$terraformModulePath/.terraform.lock.hcl" -Force
    }
    if (Test-Path "$terraformModulePath/imports.tf") {
        Remove-Item "$terraformModulePath/imports.tf" -Force
    }
}

# Runs `terraform init`. In repository-creation mode this is a local-backend
# bootstrap (writes `backend_override.tf` first); otherwise it points at the
# remote AzureRM backend using the supplied state-storage parameters.
function Invoke-TerraformInit {
    param(
        [string]$terraformModulePath,
        [bool]$repositoryCreationModeEnabled,
        [string]$repoId,
        [string]$orgAndRepoName,
        [string]$stateResourceGroupName,
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [array]$issueLog
    )

    if ($repositoryCreationModeEnabled) {
        Set-Content -Path "$terraformModulePath/backend_override.tf" -Value @"
terraform {
    backend "local" {}
}
"@

        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = @( "init")
                    OutputLog = "init.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -printOutput
    } else {
        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = @(
                        "init",
                        "-backend-config=`"resource_group_name=$stateResourceGroupName`"",
                        "-backend-config=`"storage_account_name=$stateStorageAccountName`"",
                        "-backend-config=`"container_name=$stateContainerName`"",
                        "-backend-config=`"key=$($repoId).tfstate`""
                    )
                    OutputLog = "init.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -printOutput
    }

    if (!$result.success) {
        Write-Warning "Terraform init failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "init-failed" -message "Terraform init failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    return $issueLog
}

# Bootstrap imports for managed-file paths that are not yet in state.
#
# `github_repository_file.managed` is configured with `overwrite_on_create =
# false`, so the first apply against a repo that already contains one of the
# managed files would skip it and leave Terraform unaware of the existing
# content. This function checks each candidate path individually: any path
# that is missing from state AND exists on the target repo's default branch
# (per the pre-fetched `$repoTree`) gets an `import` block written to
# `imports.tf` before plan. This handles both first-time syncs and
# incremental cases where the managed-file set grows (e.g. when CODEOWNERS
# is migrated from the previous standalone resource via the module's
# `removed` block).
#
# `-pathsRecentlyDeleted` is the list of paths just removed by the
# deprecated-files cleanup; they are subtracted from the tree's blob list so
# we never try to import a file we have already deleted in this run.
function New-ImportBootstrap {
    param(
        [string]$terraformModulePath,
        [hashtable]$managedFiles,
        [string]$repoName,
        [string]$orgAndRepoName,
        [hashtable]$repoTree,
        [string[]]$pathsRecentlyDeleted = @()
    )

    $importsFilePath = "$terraformModulePath/imports.tf"
    if (Test-Path $importsFilePath) {
        Remove-Item $importsFilePath -Force
    }

    $codeownersPath = ".github/CODEOWNERS"
    $candidateImportPaths = @(@($managedFiles.Keys) + $codeownersPath | Select-Object -Unique)

    $stateListLog = "state-list.log"
    $stateList = Invoke-TerraformWithRetry `
        -commands @(
            @{
                Arguments = @("state", "list")
                OutputLog = $stateListLog
            }
        ) `
        -workingDirectory $terraformModulePath `
        -retryOn @()

    $stateAddresses = @()
    if ($stateList -and $stateList.success) {
        $stateLogPath = Join-Path $terraformModulePath $stateListLog
        if (Test-Path $stateLogPath) {
            $stateAddresses = @(Get-Content -Path $stateLogPath | ForEach-Object { $_.Trim() })
        }
    }

    $pathsNotInState = @()
    foreach ($candidate in $candidateImportPaths) {
        $stateAddress = "module.github.github_repository_file.managed[`"$candidate`"]"
        if ($stateAddresses -notcontains $stateAddress) {
            $pathsNotInState += $candidate
        }
    }

    if ($pathsNotInState.Count -eq 0) {
        Write-Host "All managed-file paths already in state for $orgAndRepoName; skipping import bootstrap."
        return
    }

    Write-Host "$($pathsNotInState.Count) managed-file path(s) missing from state for $orgAndRepoName; checking the target repo for pre-existing copies."

    if (!$repoTree -or !$repoTree.Success) {
        Write-Warning "No repo tree available for $orgAndRepoName; continuing without import blocks."
        return
    }

    $defaultBranch = $repoTree.DefaultBranch
    $existingFiles = @($repoTree.BlobPaths | Where-Object { $pathsRecentlyDeleted -notcontains $_ })
    $importsToWrite = @($pathsNotInState | Where-Object { $existingFiles -contains $_ })

    if ($importsToWrite.Count -eq 0) {
        Write-Host "No pre-existing copies of the missing managed-file paths found in $orgAndRepoName; no imports needed."
        return
    }

    $importBlocks = New-Object System.Collections.Generic.List[string]
    $importBlocks.Add("# Auto-generated by Invoke-RepositorySync.ps1 for paths missing from state.")
    $importBlocks.Add("# Brings existing target-repo files into state so subsequent plans only diff")
    $importBlocks.Add("# content that actually differs from the managed source. Safe to delete - it")
    $importBlocks.Add("# is regenerated on every run and only contains entries for files that exist.")
    foreach ($path in $importsToWrite) {
        # `github_repository_file` import ID format is
        # `<repository>:<file path>:<branch>` (three colon-separated parts).
        # The repo name and file path must be separated by `:`, not `/`,
        # despite the file itself living under `<repository>/<path>` in git.
        $importBlocks.Add("")
        $importBlocks.Add("import {")
        $importBlocks.Add("  id = `"$($repoName):$($path):$($defaultBranch)`"")
        $importBlocks.Add("  to = module.github.github_repository_file.managed[`"$($path)`"]")
        $importBlocks.Add("}")
    }
    Set-Content -Path $importsFilePath -Value ($importBlocks -join [Environment]::NewLine)
    Write-Host "Wrote $($importsToWrite.Count) import block(s) to $importsFilePath"
}

# Runs `terraform plan`, parses the resulting plan JSON, applies the
# can-this-be-destroyed gate, and (if safe) runs `terraform apply` with a
# one-shot replan/apply retry on first failure.
function Invoke-TerraformPlanAndApply {
    param(
        [string]$terraformModulePath,
        [string]$repoId,
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [string[]]$resourceTypesThatCannotBeDestroyed,
        [array]$issueLog
    )

    $result = Invoke-TerraformWithRetry `
        -commands @(
            @{
                Arguments = @("plan", "-out=`"$($repoId).tfplan`"")
                OutputLog = "plan.log"
            }
        ) `
        -workingDirectory $terraformModulePath `
        -printOutput

    if (!$result.success) {
        Write-Warning "Terraform plan failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Terraform plan failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    $plan = $(terraform -chdir="$terraformModulePath" show -json "$($repoId).tfplan") | ConvertFrom-Json

    if (!$plan -or !$plan.resource_changes) {
        Write-Warning "Failed to parse Terraform plan for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-parse-failed" -message "Failed to parse Terraform plan for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    $hasDestroy = $false
    foreach ($resource in $plan.resource_changes) {
        if ($resource.change.actions -contains "delete") {
            if ($resourceTypesThatCannotBeDestroyed -contains $resource.type) {
                Write-Warning "Planning to destroy: $($resource.address). Resource type: $($resource.type) cannot be destroyed, so skipping the apply."
                $hasDestroy = $true
            } else {
                Write-Host "Planning to destroy: $($resource.address). Resource type: $($resource.type) can be destroyed, so allowing the apply to continue."
            }
        }
    }

    if ($hasDestroy) {
        Write-Warning "Skipping: $orgAndRepoName as it has at least one destroy actions."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-includes-destroy" -message "Plan includes destroy for $orgAndRepoName." -data $plan -issueLog $issueLog
    }

    if (!$planOnly -and $plan.errored) {
        Write-Warning "Skipping: Plan failed for $orgAndRepoName."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Plan failed for $orgAndRepoName." -data $plan -issueLog $issueLog
    }

    if (!$hasDestroy -and !$planOnly -and !$plan.errored) {

        Write-Host "Applying plan for $orgAndRepoName"
        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = @("apply", "$($repoId).tfplan")
                    OutputLog = "apply.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -printOutput `
            -maxRetries 0

        if (!$result.success) {
            Write-Warning "Terraform apply first attempt failed for $orgAndRepoName. Entering plan apply retry loop..."
            $result = Invoke-TerraformWithRetry `
                -commands @(
                    @{
                        Arguments = @("plan", "-out=`"$($repoId).tfplan`"")
                        OutputLog = "plan.log"
                    },
                    @{
                        Arguments = @("apply", "$($repoId).tfplan")
                        OutputLog = "apply.log"
                    }
                ) `
                -workingDirectory $terraformModulePath `
                -printOutput
        }

        if (!$result.success) {
            Write-Warning "Terraform apply failed for $orgAndRepoName. Exiting."
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "apply-failed" -message "Terraform apply failed for $orgAndRepoName." -data $null -issueLog $issueLog
            exit 1
        } else {
            Write-Host "Terraform apply succeeded for $orgAndRepoName"
        }
    }

    return $issueLog
}
