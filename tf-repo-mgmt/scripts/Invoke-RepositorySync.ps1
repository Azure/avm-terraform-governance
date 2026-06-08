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
. (Join-Path $libDir "DeprecatedFiles.ps1")
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

# Fetch the default-branch tree once per repo. The deprecated-files cleanup
# and the managed-files import bootstrap both need to know what files exist
# on the default branch; sharing the result halves the GitHub REST traffic
# and removes a class of race conditions where the default branch could
# change between the two reads.
$repoTree = $null
$needRepoTree = (!$repositoryCreationModeEnabled) -and (($deprecatedPaths.Count -gt 0) -or ($managedFiles.Keys.Count -gt 0))
if($needRepoTree) {
    $repoTree = Get-RepositoryDefaultBranchTree -orgAndRepoName $orgAndRepoName
}

# Remove deprecated files from the target repository before any Terraform
# runs. In plan mode the matches are logged with a `[PLAN]` prefix and no
# commit is made; in apply mode a single `[skip ci]` commit is pushed.
# Paths actually deleted come back as `DeletedPaths` so the import bootstrap
# can exclude them from the cached tree (the tree was fetched before the
# delete and so still lists them).
$deletedDeprecatedPaths = @()
if(!$repositoryCreationModeEnabled -and $deprecatedPaths.Count -gt 0) {
    $cleanupResult = Remove-DeprecatedRepoFiles `
        -orgAndRepoName $orgAndRepoName `
        -deprecatedPaths $deprecatedPaths `
        -repoTree $repoTree `
        -planOnly $planOnly `
        -issueLog $issueLog
    $issueLog = $cleanupResult.IssueLog
    $deletedDeprecatedPaths = $cleanupResult.DeletedPaths
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
    managed_files = $managedFiles
}

$terraformVariables | ConvertTo-Json -Depth 100 | Out-File "$terraformModulePath/terraform.tfvars.json"

$issueLog = Invoke-TerraformInit `
    -terraformModulePath $terraformModulePath `
    -repositoryCreationModeEnabled $repositoryCreationModeEnabled.IsPresent `
    -repoId $repoId `
    -orgAndRepoName $orgAndRepoName `
    -stateResourceGroupName $stateResourceGroupName `
    -stateStorageAccountName $stateStorageAccountName `
    -stateContainerName $stateContainerName `
    -issueLog $issueLog

if(!$repositoryCreationModeEnabled) {
    New-ImportBootstrap `
        -terraformModulePath $terraformModulePath `
        -managedFiles $managedFiles `
        -repoName $repoName `
        -orgAndRepoName $orgAndRepoName `
        -repoTree $repoTree `
        -pathsRecentlyDeleted $deletedDeprecatedPaths
}

$issueLog = Invoke-TerraformPlanAndApply `
    -terraformModulePath $terraformModulePath `
    -repoId $repoId `
    -orgAndRepoName $orgAndRepoName `
    -planOnly $planOnly `
    -resourceTypesThatCannotBeDestroyed $resourceTypesThatCannotBeDestroyed `
    -issueLog $issueLog

if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}

