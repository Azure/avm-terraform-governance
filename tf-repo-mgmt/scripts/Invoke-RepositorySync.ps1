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
    [string]$stateStorageAccountName = "",
    [string]$stateResourceGroupName = "",
    [string]$stateContainerName = "",
    [string]$identityResourceGroupName = "",
    [bool]$planOnly = $false,
    [string]$repoId = "avm-ptn-example-repo",
    [string]$repoUrl = "https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo",
    [string]$outputDirectory = ".",
    [string]$repoConfigFilePath = "./repository-config/config.json",
    [string]$deprecatedFilesConfigFilePath = "./repository-config/deprecated-files.json",
    [string]$managedFilesBaseDir = "../managed-files",
    [object]$repoMetaData = $null,
    [string]$terraformModulePath = "./repository_sync",
    [string[]]$resourceTypesThatCannotBeDestroyed = @(
        "github_repository"
    ),
    [switch]$skipCleanup,
    [string[]]$extraTeamsToIgnore = @(
        "security",
        "azurecla-write"
    ),
    [switch]$forceUserRemoval,
    [string]$managementGroupId = "",
    [array]$testSubscriptionIds = @()
)

Write-Host "Running repo sync script"

# Dot-source the cmdlet libs. `$PSScriptRoot` makes this resolution
# independent of the caller's working directory (the workflow runs from
# `tf-repo-mgmt/` but local debug runs can be from anywhere).
$libDir = Join-Path $PSScriptRoot "lib"
. (Join-Path $libDir "Logging.ps1")
. (Join-Path $libDir "RetryHelpers.ps1")
. (Join-Path $libDir "ManagedFiles.ps1")
. (Join-Path $libDir "RepositoryConfig.ps1")
. (Join-Path $libDir "RepoTree.ps1")
. (Join-Path $libDir "RepoFilesSync.ps1")
. (Join-Path $libDir "BranchProtection.ps1")
. (Join-Path $libDir "TeamsAndUsers.ps1")
. (Join-Path $libDir "TerraformOperations.ps1")

$env:ARM_USE_AZUREAD = "true"

$issueLog = @()

$moduleName = $repoId

$moduleMetaData = $null

if(!$repositoryCreationModeEnabled){
    $moduleMetaData = $repoMetaData
    if($moduleMetaData) {
        $moduleName = $moduleMetaData.moduleDisplayName
    }
} elseif($repoMetaData) {
    $moduleMetaData = $repoMetaData
    if($moduleMetaData.moduleDisplayName) {
        $moduleName = $moduleMetaData.moduleDisplayName
    }
}

$repositoryConfig = Get-Content -Path $repoConfigFilePath -Raw | ConvertFrom-Json
$settings = Resolve-RepositorySettings -repositoryConfig $repositoryConfig -repoId $repoId
$managedFiles = Build-ManagedFilesMap `
    -baseDir $managedFilesBaseDir `
    -overlay $settings.ManagedFilesAdditional `
    -excluded $settings.ExcludedManagedFiles `
    -repoId $repoId

# Load deprecated-file paths once. Each path is matched against the target
# repo's default-branch tree later; matching paths are removed before any
# Terraform runs so that the import bootstrap and plan operate against the
# already-cleaned repo.
$deprecatedPaths = @()
if(!$repositoryCreationModeEnabled -and (Test-Path $deprecatedFilesConfigFilePath)) {
    $deprecatedPaths = @(Get-Content -Path $deprecatedFilesConfigFilePath -Raw | ConvertFrom-Json)
    Write-Host "Loaded $($deprecatedPaths.Count) deprecated path(s) from $deprecatedFilesConfigFilePath."
}

Write-Host "$([Environment]::NewLine)Checking $($repoId)"

if(!$skipCleanup) {
    Clear-TerraformWorkspace -terraformModulePath $terraformModulePath
}

$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

Write-Host "$([Environment]::NewLine)<--->" -ForegroundColor Green
Write-Host "$([Environment]::NewLine)Updating: $orgAndRepoName.$([Environment]::NewLine)" -ForegroundColor Green
Write-Host "<--->$([Environment]::NewLine)" -ForegroundColor Green

# Fetch the default-branch tree once per repo. The repo-file sync uses the
# cached blob SHAs to detect which managed files need creating/updating and
# which deprecated paths are actually present, all without making any
# additional GitHub REST calls per file.
$repoTree = $null
$needRepoTree = (!$repositoryCreationModeEnabled) -and (($deprecatedPaths.Count -gt 0) -or ($managedFiles.Keys.Count -gt 0))
if($needRepoTree) {
    $repoTree = Get-RepositoryDefaultBranchTree -orgAndRepoName $orgAndRepoName
}

# Remove any legacy classic branch-protection rule from the target repo
# before anything else - every AVM repo must be governed exclusively by
# the rulesets defined in modules/github/github.rulesets.tf.
if(!$repositoryCreationModeEnabled -and $repoTree -and $repoTree.Success) {
    $branchProtectionResult = Remove-LegacyBranchProtection `
        -orgAndRepoName $orgAndRepoName `
        -defaultBranch $repoTree.DefaultBranch `
        -planOnly $planOnly `
        -issueLog $issueLog
    $issueLog = $branchProtectionResult.IssueLog
}

$resolveTeamsResult = Resolve-GitHubTeams `
    -orgName $orgName `
    -orgAndRepoName $orgAndRepoName `
    -teams $settings.Teams `
    -issueLog $issueLog
$githubTeams = $resolveTeamsResult.GithubTeams
$issueLog = $resolveTeamsResult.IssueLog

if(!$repositoryCreationModeEnabled) {
    Write-Host "Checking repository: $orgAndRepoName for existing teams and users."
    $issueLog = Remove-DirectCollaborators `
        -orgAndRepoName $orgAndRepoName `
        -moduleMetaData $moduleMetaData `
        -planOnly $planOnly `
        -forceUserRemoval $forceUserRemoval.IsPresent `
        -issueLog $issueLog

    $issueLog = Remove-UnmanagedRepositoryTeams `
        -orgName $orgName `
        -orgAndRepoName $orgAndRepoName `
        -githubTeams $githubTeams `
        -extraTeamsToIgnore $extraTeamsToIgnore `
        -planOnly $planOnly `
        -issueLog $issueLog
}

Write-Host "Using test subscription IDs:"
Write-Host $($testSubscriptionIds | ConvertTo-Json)

$terraformVariables = @{
    repository_creation_mode_enabled = $repositoryCreationModeEnabled.IsPresent
    github_repository_owner = $orgName
    github_repository_name = $repoName
    module_id = $repoId
    module_name = $moduleName
    management_group_id = $managementGroupId
    test_subscription_ids = $testSubscriptionIds
    identity_resource_group_name = $identityResourceGroupName
    is_protected_repo = $true
    github_teams = $githubTeams
    codeowners_default_teams = $settings.CodeOwnersDefaultTeams
    codeowners_file_protection_teams = $settings.CodeOwnersFileProtectionTeams
    topics = $settings.Topics
}

$terraformVariables | ConvertTo-Json -Depth 100 | Out-File "$terraformModulePath/terraform.tfvars.json"

$preTerraformIssueCount = $issueLog.Count

$issueLog = Invoke-TerraformInit `
    -terraformModulePath $terraformModulePath `
    -repositoryCreationModeEnabled $repositoryCreationModeEnabled.IsPresent `
    -repoId $repoId `
    -orgAndRepoName $orgAndRepoName `
    -stateResourceGroupName $stateResourceGroupName `
    -stateStorageAccountName $stateStorageAccountName `
    -stateContainerName $stateContainerName `
    -issueLog $issueLog

$issueLog = Invoke-TerraformPlanAndApply `
    -terraformModulePath $terraformModulePath `
    -repoId $repoId `
    -orgAndRepoName $orgAndRepoName `
    -planOnly $planOnly `
    -resourceTypesThatCannotBeDestroyed $resourceTypesThatCannotBeDestroyed `
    -issueLog $issueLog

# Sync managed files via a single clone -> branch -> PR -> merge flow.
# Runs AFTER terraform so that a broken terraform run does not produce a
# merged commit on the target repo for nothing, and so that any teams,
# rulesets, or bypass actors that terraform needs to create exist before
# the bot pushes a CODEOWNERS file that references them. Skipped entirely
# if terraform reported new issues for this repo.
if(!$repositoryCreationModeEnabled -and $repoTree -and $repoTree.Success) {
    if($issueLog.Count -gt $preTerraformIssueCount) {
        Write-Host "Skipping managed-file sync for $orgAndRepoName because terraform reported issues for this run." -ForegroundColor Yellow
    } else {
        $codeownersContent = Get-RenderedCodeownersContent `
            -ownerSlug $orgName `
            -defaultTeams $settings.CodeOwnersDefaultTeams `
            -fileProtectionTeams $settings.CodeOwnersFileProtectionTeams

        $syncResult = Sync-RepoFiles `
            -orgAndRepoName $orgAndRepoName `
            -deprecatedPaths $deprecatedPaths `
            -managedFiles $managedFiles `
            -codeownersContent $codeownersContent `
            -repoTree $repoTree `
            -planOnly $planOnly `
            -issueLog $issueLog
        $issueLog = $syncResult.IssueLog
    }
}

if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}

