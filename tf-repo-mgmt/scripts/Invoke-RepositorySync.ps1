# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# ARM_USE_AZUREAD
# ARM_USE_OIDC
# ARM_TENANT_ID
# ARM_SUBSCRIPTION_ID
# ARM_CLIENT_ID
# Must run gh auth login -h "GitHub.com" before running this script

param(
    [string]$stateStorageAccountName,
    [string]$stateResourceGroupName,
    [string]$stateContainerName,
    [string]$targetSubscriptionId,
    [string]$identityResourceGroupName,
    [bool]$planOnly = $false,
    [bool]$firstRun = $false,
    [string]$repoId,
    [string]$repoUrl,
    [string]$repoType,
    [string]$repoSubType,
    [string]$repoOwnerTeam,
    [string]$repoContributorTeam,
    [bool]$repoIsProtected,
    [string]$outputDirectory = "."
)

Write-Host "Running repo sync script"

function Add-IssueToLog {
    param(
        [string]$orgAndRepoName,
        [string]$type,
        [string]$message,
        [object]$data,
        [array]$issueLog,
        [string]$issueLogFile="issue.log"
    )

    $issueLogItem = @{
        orgAndRepoName = $orgAndRepoName
        type = $type
        message = $message
        data = $data
    }

    $issueLog += $issueLogItem

    $issueLogItemJson = ConvertTo-Json $issueLogItem -Depth 100
    Add-Content -Path $issueLogFile -Value $issueLogItemJson

    return $issueLog
}

$env:ARM_USE_AZUREAD = "true"

$issueLog = @()

$secretNames = @("ARM_TENANT_ID", "ARM_SUBSCRIPTION_ID", "ARM_CLIENT_ID")


Write-Host "Checking $($repoId)"
if(Test-Path "imports.tf") {
    Remove-Item "imports.tf" -Force
}

if(Test-Path ".terraform") {
    Remove-Item ".terraform" -Recurse -Force
}

$repoUrl = $repoUrl
$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

$existingRepo = $(gh api "repos/$orgAndRepoName" 2> $null) | ConvertFrom-Json

if ($existingRepo.status -eq 404) {
    Write-Warning "Skipping: $orgAndRepoName has not been created yet."
    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-missing" -message "Repo $orgAndRepoName does not exist." -issueLog $issueLog
} else {
    Write-Host "<--->" -ForegroundColor Green
    Write-Host "$([Environment]::NewLine)Updating: $orgAndRepoName.$([Environment]::NewLine)" -ForegroundColor Green
    Write-Host "<--->" -ForegroundColor Green

    $existingEnvironment = $(gh api "repos/$orgAndRepoName/environments/test" 2> $null) | ConvertFrom-Json

    if (($existingEnvironment.status -ne 404) -and ($repoType -eq "avm") -and $firstRun) {
        Write-Host "First Run: Taking ownership of test environment for $orgAndRepoName"
        $import = @"
import {
to = github_repository_environment.this[0]
id = "$($repoName):test"
}

"@

        Add-Content -Path "imports.tf" -Value $import

        foreach($secretName in $secretNames) {
            $existingSecret = $(gh api "repos/$orgAndRepoName/environments/test/secrets/$secretName" 2> $null) | ConvertFrom-Json
            if($existingSecret.status -ne 404) {

                if(!$planOnly) {
                    Write-Host "Deleting secret: $secretName"
                    gh api -X DELETE "repos/$orgAndRepoName/environments/test/secrets/$secretName"
                } else {
                    Write-Host "Planning to delete secret: $secretName"
                }
            }
        }
    }

    $ownerTeamName = ""
    if($null -ne $repoOwnerTeam) {
        $ownerTeamName = $repoOwnerTeam.Replace("@Azure/", "")
        $existingOwnerTeam = $(gh api "orgs/$orgName/teams/$($ownerTeamName)" 2> $null) | ConvertFrom-Json
        if($existingOwnerTeam.status -eq 404) {
            Write-Warning "Owner team does not exist: $($ownerTeamName)"
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "owner-team-missing" -message "Team $ownerTeamName does not exist." -data $ownerTeamName -issueLog $issueLog
            $ownerTeamName = ""
        }
    }

    $contributorTeamName = ""
    if($null -ne $repoContributorTeam) {
        $contributorTeamName = $repoContributorTeam.Replace("@Azure/", "")
        $existingContributorTeam = $(gh api "orgs/$orgName/teams/$($contributorTeamName)" 2> $null) | ConvertFrom-Json
        if($existingContributorTeam.status -eq 404) {
            Write-Warning "Contributor team does not exist: $($contributorTeamName)"
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "contributor-team-missing" -message "Team $contributorTeamName does not exist." -data $contributorTeamName -issueLog $issueLog
            $contributorTeamName = ""
        }
    }

    terraform init `
        -backend-config="resource_group_name=$stateResourceGroupName" `
        -backend-config="storage_account_name=$stateStorageAccountName" `
        -backend-config="container_name=$stateContainerName" `
        -backend-config="key=$($repoId).tfstate"

    terraform plan `
        -out="$($repoId).tfplan" `
        -var="github_repository_owner=$orgName" `
        -var="github_repository_name=$repoName" `
        -var="github_owner_team_name=$($ownerTeamName)" `
        -var="github_contributor_team_name=$($contributorTeamName)" `
        -var="manage_github_environment=$(($repoType -eq "avm").ToString().ToLower())" `
        -var="target_subscription_id"=$($targetSubscriptionId) `
        -var="identity_resource_group_name=$($identityResourceGroupName)" `
        -var="is_protected_repo=$(($repoIsProtected).ToString().ToLower())"

    $plan = $(terraform show -json "$($repoId).tfplan") | ConvertFrom-Json

    $hasDestroy = $false
    foreach($resource in $plan.resource_changes) {
        if($resource.change.actions -contains "delete") {
            Write-Warning "Planning to destroy: $($resource.address)"
            $hasDestroy = $true
        }
    }

    if($hasDestroy) {
        Write-Warning "Skipping: $orgAndRepoName as it has at least one destroy actions."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-includes-destroy" -message "Plan includes destroy for $orgAndRepoName." -data $plan -issueLog $issueLog
    }

    if(!$planOnly -and $plan.errored) {
        Write-Warning "Skipping: Plan failed for $orgAndRepoName."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Plan failed for $orgAndRepoName." -data $plan -issueLog $issueLog
    }

    if(!$hasDestroy -and !$planOnly -and !$plan.errored) {
        terraform apply "$($repoId).tfplan"
    }
}

if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}
