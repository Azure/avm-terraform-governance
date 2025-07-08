param (
    [string]$organizationName = "Azure",
    [string]$repositoryName = "avm-terraform-governance",
    [string]$branchName = "chore-update-repo-sync",
    [string]$workflowFileName = "tf-repo-mgmt.yml",
    [hashtable]$inputs = @{
        repositories = "avm-ptn-example-repo"
        plan_only = $false
    },
    [int]$maximumRetries = 10,
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

    $result = (& $command $arguments)
}

function Wait-ForWorkflowRunToComplete {
    param (
        [string]$organizationName,
        [string]$repositoryName,
        [hashtable]$headers
    )

    $workflowRunUrl = "https://api.github.com/repos/$organizationName/$repositoryName/actions/runs"
    Write-Host "Workflow Run URL: $workflowRunUrl"

    $workflowRun = $null
    $workflowRunStatus = ""
    $workflowRunConclusion = ""
    while($workflowRunStatus -ne "completed") {
        Start-Sleep -Seconds 10

        $workflowRun = Invoke-RestMethod -Method GET -Uri $workflowRunUrl -Headers $headers -StatusCodeVariable statusCode
        if ($statusCode -lt 300) {
            $workflowRunStatus = $workflowRun.workflow_runs[0].status
            $workflowRunConclusion = $workflowRun.workflow_runs[0].conclusion
            Write-Host "Workflow Run Status: $workflowRunStatus - Conclusion: $workflowRunConclusion"
        } else {
            Write-Host "Failed to find the workflow run. Status Code: $statusCode"
            throw "Failed to find the workflow run."
        }
    }

    if($workflowRunConclusion -ne "success") {
        throw "The workflow run did not complete successfully. Conclusion: $workflowRunConclusion"
    }
}

# Setup Variables
$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$personalAccessToken"))
$headers = @{
    "Authorization" = "Basic $token"
    "Accept" = "application/vnd.github+json"
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
    Wait-ForWorkflowRunToComplete -organizationName $organizationName -repositoryName $repositoryName -headers $headers
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