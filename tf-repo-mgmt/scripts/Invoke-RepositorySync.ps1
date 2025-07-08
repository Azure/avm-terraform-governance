# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# ARM_USE_AZUREAD
# ARM_USE_OIDC
# ARM_TENANT_ID
# ARM_SUBSCRIPTION_ID
# ARM_CLIENT_ID
# Must run gh auth login -h "GitHub.com" before running this script

param(
    [switch]$repositoryCreationModeEnabled,
    [string]$stateStorageAccountName,
    [string]$stateResourceGroupName,
    [string]$stateContainerName,
    [string]$targetSubscriptionId,
    [string]$identityResourceGroupName,
    [bool]$planOnly = $false,
    [string]$repoId,
    [string]$repoUrl,
    [string]$repoType,
    [string]$repoSubType,
    [string]$outputDirectory = ".",
    [string]$repoConfigFilePath = "./repository-config/config.json",
    [string]$metaDataFilePath = "./repository-meta-data/meta-data.csv",
    [string]$terraformModulePath = "./repository_sync",
    [string[]]$resourceTypesThatCannotBeDestroyed = @(
        "github_repository"
    )
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

$repositoryMetaDate = Get-Content -Path $metaDataFilePath -Raw | ConvertFrom-Csv

$moduleName = $repositoryMetaDate | Where-Object { $_.moduleId -eq $repoId } | Select-Object -ExpandProperty moduleDisplayName

$repositoryConfig = Get-Content -Path $repoConfigFilePath -Raw | ConvertFrom-Json
$repositoryGroups = $repositoryConfig.repositoryGroups | Where-Object { $_.repositories -contains $repoId }

$isProtected = ($repositoryGroups | Where-Object { $_.protected -eq $true }).Length -gt 0
$repositoryGroupNames = @($repositoryGroups | ForEach-Object { $_.name })
$repositoryGroupNames += "all"

$teams = @()

foreach($repositoryGroupName in $repositoryGroupNames) {
    $teamMappings = $repositoryConfig.teamMappings | Where-Object { $_.repositoryGroups -contains $repositoryGroupName }
    if($teamMappings.Count -gt 0) {
        $teams += $teamMappings
    }
}

Write-Host "$([Environment]::NewLine)Checking $($repoId)"
if(Test-Path "$terraformModulePath/.terraform") {
    Remove-Item "$terraformModulePath/.terraform" -Recurse -Force
}

if(Test-Path "$terraformModulePath/terraform.tfvars.json") {
    Remove-Item"$terraformModulePath/terraform.tfvars.json" -Force
}

$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

Write-Host "$([Environment]::NewLine)<--->" -ForegroundColor Green
Write-Host "$([Environment]::NewLine)Updating: $orgAndRepoName.$([Environment]::NewLine)" -ForegroundColor Green
Write-Host "<--->$([Environment]::NewLine)" -ForegroundColor Green

$githubTeams = @{}

foreach($team in $teams) {
    $skipCheck = $false
    if($repositoryCreationModeEnabled -and $team.createdWithRepository) {
        Write-Host "Skipping team: $($team.name) as it is created with repository."
        $skipCheck = $true
    }
    $teamName = $team.name.Replace("{{repoId}}", $repoId)
    $teamDescription = $team.description.Replace("{{repoId}}", $repoId)
    $teamExists = $false

    if($skipCheck) {
        $teamExists = $true
    } else {
        $existingTeam = $(gh api "orgs/$orgName/teams/$($teamName)" 2> $null) | ConvertFrom-Json
        $teamExists = $existingTeam.status -ne 404
    }

    if(!$teamExists) {
        Write-Warning "Team does not exist: $($teamName)"
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-missing" -message "Team $teamName does not exist." -data $teamName -issueLog $issueLog
    } else {
        Write-Host "Team exists: $($teamName)"
        $githubTeams[$teamName] = @{
            slug        = $teamName
            description = $teamDescription
            repository_access_permission = $team.repositoryPermission
            environment_approval = $team.environmentApproval
            created_with_repository = $team.createdWithRepository
            members_are_team_maintainers = $team.membersAreTeamMaintainers
        }
    }
}

$terraformVariables = @{
    repository_creation_mode_enabled = $repositoryCreationModeEnabled
    github_repository_owner = $orgName
    github_repository_name = $repoName
    module_id = $repoId
    module_name = $moduleName
    target_subscription_id = $targetSubscriptionId
    identity_resource_group_name = $identityResourceGroupName
    is_protected_repo = $isProtected
    github_teams = $githubTeams
}

$terraformVariables | ConvertTo-Json -Depth 100 | Out-File "$terraformModulePath/terraform.tfvars.json"

if($repositoryCreationModeEnabled) {
    Set-Content -Path "$terraformModulePath/backend_override.tf" -Value @"
terraform {
    backend "local" {}
}
"@

    terraform `
        -chdir="$terraformModulePath" `
        init
} else {
    terraform `
        -chdir="$terraformModulePath" `
        init `
        -backend-config="resource_group_name=$stateResourceGroupName" `
        -backend-config="storage_account_name=$stateStorageAccountName" `
        -backend-config="container_name=$stateContainerName" `
        -backend-config="key=$($repoId).tfstate"
}

terraform `
    -chdir="$terraformModulePath" `
    plan `
    -out="$($repoId).tfplan"

$plan = $(terraform -chdir="$terraformModulePath" show -json "$($repoId).tfplan") | ConvertFrom-Json

$hasDestroy = $false
foreach($resource in $plan.resource_changes) {
    if($resource.change.actions -contains "delete") {
        if($resourceTypesThatCannotBeDestroyed -contains $resource.type) {
            Write-Warning "Planning to destroy: $($resource.address). Resource type: $($resource.type) cannot be destroyed, so skipping the apply."
            $hasDestroy = $true
        } else {
            Write-Host "Planning to destroy: $($resource.address). Resource type: $($resource.type) can be destroyed, so allowing the apply to continue."
        }
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
    terraform `
        -chdir="$terraformModulePath" `
        apply "$($repoId).tfplan"
}


if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}
