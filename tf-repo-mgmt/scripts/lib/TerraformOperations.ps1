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
