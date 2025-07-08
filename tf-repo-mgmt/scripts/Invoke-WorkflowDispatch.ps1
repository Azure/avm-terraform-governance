param (
    [string]$organizationName = "Azure",
    [string]$repositoryName = "avm-terraform-governance",
    [string]$branchName = "main",
    [string]$workflowFileName = "tf-repo-mgmt.yml",
    [hashtable]$inputs = @{
        repositories = "avm-ptn-example-repo"
        plan_only = $false
    },
    [int]$maximumRetries = 1,
    [int]$retryCount = 0,
    [int]$retryDelay = 10000
)

function Invoke-Workflow {
    param (
        [string]$organizationName,
        [string]$repositoryName,
        [string]$branchName = "main",
        [string]$workflowName,
        [hashtable]$inputs
    )

    $command = "gh"

    $arguments = @(
        "workflow",
        "run",
        $workflowName,
        "--repo", "$organizationName/$repositoryName",
        "--ref", $branchName
    )

    foreach ($key in $inputs.Keys) {
        $value = $inputs[$key]
        if ($value -is [bool]) {
            $value = $value.ToString().ToLower()
        }
        $arguments += "--raw-field"
        $arguments += "$key=$value"
    }

    & $command $arguments
    Start-Sleep -Seconds 5
}

function Wait-ForWorkflowRunToComplete {
    param (
        [string]$organizationName,
        [string]$repositoryName,
        [string]$branchName = "main",
        [string]$workflowName
    )

    $user = (gh api user | ConvertFrom-Json).login

    $command = "gh"

    $arguments = @(
        "run",
        "ls",
        "--workflow", $workflowName,
        "--event", "workflow_dispatch",
        "--repo", "$organizationName/$repositoryName",
        "--branch", $branchName,
        "--json", "databaseId",
        "--limit", "1",
        "--user", $user
    )

    $workflowRun = (& $command $arguments) | ConvertFrom-Json
    $workflowRunId = $workflowRun.databaseId

    Write-Host "Workflow Run ID: $workflowRunId"

    gh run watch $workflowRunId --repo "$organizationName/$repositoryName"

    $result = gh run view $workflowRunId --json conclusion,status | ConvertFrom-Json

    if($result.conclusion -ne "success") {
        throw "The workflow run did not complete successfully. Conclusion: $($result.conclusion), Status: $($result.status)"
    }
}

# Run the Module in a retry loop
$success = $false

do {
    $retryCount++
    try {
        # Trigger the apply workflow
        Write-Host "Triggering the $workflowAction workflow"
        Invoke-Workflow `
            -organizationName $organizationName `
            -repositoryName $repositoryName `
            -branchName $branchName `
            -workflowName $workflowFileName `
            -inputs $inputs
        Write-Host "$workflowAction workflow triggered successfully"

        # Wait for the apply workflow to complete
        Write-Host "Waiting for the $workflowAction workflow to complete"
        Wait-ForWorkflowRunToComplete `
            -organizationName $organizationName `
            -repositoryName $repositoryName `
            -branchName $branchName `
            -workflowName $workflowFileName
        Write-Host "$workflowAction workflow completed successfully"

        $success = $true
    } catch {
        Write-Host $_
        Write-Host "Failed to trigger the workflow successfully, trying again..."
    }
} while ($success -eq $false -and $retryCount -lt $maximumRetries)

if ($success -eq $false) {
    throw "Failed to trigger the workflow after $maximumRetries attempts."
}
