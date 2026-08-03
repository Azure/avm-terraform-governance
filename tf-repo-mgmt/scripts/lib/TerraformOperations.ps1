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

# Returns $true or $false for blob existence, or $null when the check itself
# failed, so the caller can tell "not there" apart from "could not tell".
function Test-TerraformStateBlob {
    param(
        [string]$storageAccountName,
        [string]$containerName,
        [string]$blobName
    )

    $output = az storage blob exists `
        --account-name $storageAccountName `
        --container-name $containerName `
        --name $blobName `
        --auth-mode login `
        --query exists -o tsv 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not check whether state blob '$blobName' exists. $($output | Out-String)"
        return $null
    }

    return (($output | Out-String).Trim() -eq "true")
}

# Migrates a repository's state from the legacy module-scoped blob key to the
# repository-scoped one. The legacy key dropped the provider segment from the
# repository name, so every repository publishing the same module shared a single
# state blob and rewrote the others' resources on each run. The copy is only made
# when the legacy state actually describes this repository, so a repository that
# never owned that state starts empty rather than adopting another's resources.
function Copy-TerraformStateToRepositoryKey {
    param(
        [string]$legacyBlobName,
        [string]$repositoryBlobName,
        [string]$repoName,
        [string]$storageAccountName,
        [string]$containerName
    )

    if (!$storageAccountName -or !$containerName) {
        Write-Warning "No state storage details were supplied, so the state key migration was skipped."
        return $true
    }

    if ($legacyBlobName -eq $repositoryBlobName) {
        return $true
    }

    $repositoryBlobExists = Test-TerraformStateBlob -storageAccountName $storageAccountName -containerName $containerName -blobName $repositoryBlobName
    if ($null -eq $repositoryBlobExists) {
        return $false
    }

    if ($repositoryBlobExists) {
        return $true
    }

    $legacyBlobExists = Test-TerraformStateBlob -storageAccountName $storageAccountName -containerName $containerName -blobName $legacyBlobName
    if ($null -eq $legacyBlobExists) {
        return $false
    }

    if (!$legacyBlobExists) {
        Write-Host "No existing state for '$repoName'. Starting from an empty state."
        return $true
    }

    $legacyStateFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).tfstate"

    try {
        $downloadOutput = az storage blob download `
            --account-name $storageAccountName `
            --container-name $containerName `
            --name $legacyBlobName `
            --file $legacyStateFile `
            --auth-mode login `
            --no-progress 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not download legacy state blob '$legacyBlobName'. $($downloadOutput | Out-String)"
            return $false
        }

        $legacyState = Get-Content -Path $legacyStateFile -Raw | ConvertFrom-Json

        $legacyRepository = $legacyState.resources |
            Where-Object { $_.mode -eq "managed" -and $_.type -eq "github_repository" } |
            Select-Object -First 1

        $legacyRepositoryName = $null
        if ($legacyRepository -and $legacyRepository.instances.Count -gt 0) {
            $legacyRepositoryName = $legacyRepository.instances[0].attributes.name
        }

        if ($legacyRepositoryName -ne $repoName) {
            Write-Warning "Legacy state blob '$legacyBlobName' describes '$legacyRepositoryName', not '$repoName'. Starting '$repoName' from an empty state so it does not adopt another repository's resources."
            return $true
        }

        Write-Host "Migrating state for '$repoName' from '$legacyBlobName' to '$repositoryBlobName'."

        $uploadOutput = az storage blob upload `
            --account-name $storageAccountName `
            --container-name $containerName `
            --name $repositoryBlobName `
            --file $legacyStateFile `
            --auth-mode login `
            --no-progress 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not write state blob '$repositoryBlobName'. $($uploadOutput | Out-String)"
            return $false
        }

        Write-Host "Migrated state for '$repoName' to '$repositoryBlobName'."
        return $true
    }
    catch {
        Write-Warning "State key migration for '$repoName' failed. $($_.Exception.Message)"
        return $false
    }
    finally {
        if (Test-Path $legacyStateFile) {
            Remove-Item $legacyStateFile -Force
        }
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
        [string]$repoName,
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
        $stateBlobName = "$($repoName).tfstate"

        $migrated = Copy-TerraformStateToRepositoryKey `
            -legacyBlobName "$($repoId).tfstate" `
            -repositoryBlobName $stateBlobName `
            -repoName $repoName `
            -storageAccountName $stateStorageAccountName `
            -containerName $stateContainerName

        if (!$migrated) {
            Write-Warning "Terraform state key migration failed for $orgAndRepoName. Exiting."
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "state-migration-failed" -message "Terraform state key migration failed for $orgAndRepoName." -data $null -issueLog $issueLog
            exit 1
        }

        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = @(
                        "init",
                        "-backend-config=`"resource_group_name=$stateResourceGroupName`"",
                        "-backend-config=`"storage_account_name=$stateStorageAccountName`"",
                        "-backend-config=`"container_name=$stateContainerName`"",
                        "-backend-config=`"key=$stateBlobName`""
                    )
                    OutputLog = "init.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -stateStorageAccountName $stateStorageAccountName `
            -stateContainerName $stateContainerName `
            -stateBlobName $stateBlobName `
            -printOutput
    }

    if (!$result.success) {
        Write-Warning "Terraform init failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "init-failed" -message "Terraform init failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    return $issueLog
}

# Runs `terraform plan`, parses the resulting plan JSON, applies the
# can-this-be-destroyed gate, and (if safe) runs `terraform apply` with a
# one-shot replan/apply retry on first failure.
function Invoke-TerraformPlanAndApply {
    param(
        [string]$terraformModulePath,
        [string]$repoName,
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [string[]]$resourceTypesThatCannotBeDestroyed,
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [array]$issueLog
    )

    $stateBlobName = "$($repoName).tfstate"
    $planFileName = "$($repoName).tfplan"

    $result = Invoke-TerraformWithRetry `
        -commands @(
            @{
                Arguments = @("plan", "-out=`"$planFileName`"")
                OutputLog = "plan.log"
            }
        ) `
        -workingDirectory $terraformModulePath `
        -stateStorageAccountName $stateStorageAccountName `
        -stateContainerName $stateContainerName `
        -stateBlobName $stateBlobName `
        -printOutput

    if (!$result.success) {
        Write-Warning "Terraform plan failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Terraform plan failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    $plan = $(terraform -chdir="$terraformModulePath" show -json "$planFileName") | ConvertFrom-Json

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
                    Arguments = @("apply", "$planFileName")
                    OutputLog = "apply.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -stateStorageAccountName $stateStorageAccountName `
            -stateContainerName $stateContainerName `
            -stateBlobName $stateBlobName `
            -printOutput `
            -maxRetries 0

        if (!$result.success) {
            Write-Warning "Terraform apply first attempt failed for $orgAndRepoName. Entering plan apply retry loop..."
            $result = Invoke-TerraformWithRetry `
                -commands @(
                    @{
                        Arguments = @("plan", "-out=`"$planFileName`"")
                        OutputLog = "plan.log"
                    },
                    @{
                        Arguments = @("apply", "$planFileName")
                        OutputLog = "apply.log"
                    }
                ) `
                -workingDirectory $terraformModulePath `
                -stateStorageAccountName $stateStorageAccountName `
                -stateContainerName $stateContainerName `
                -stateBlobName $stateBlobName `
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
