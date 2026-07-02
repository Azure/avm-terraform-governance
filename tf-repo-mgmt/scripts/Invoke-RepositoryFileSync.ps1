# Requires Environment Variables for GitHub Actions
# GH_TOKEN  (an app/installation token with write access to the target repos)
#
# No `gh auth login` is required: Sync-RepoFiles runs `gh auth setup-git`
# itself, and the gh CLI / git credential helper authenticate from GH_TOKEN.
#
# Syncs the generic managed files (the contents of `managed-files/`) and
# removes deprecated files from each target repository. This is the
# file-management half of repository governance and is deliberately kept
# separate from Invoke-RepositoryConfigSync.ps1, which owns the Terraform /
# GitHub-API configuration (teams, rulesets, branch protection, CODEOWNERS).
# It performs no Terraform or Azure operations and needs no Azure identity.

param(
    [bool]$planOnly = $false,
    [string]$repoId = "avm-ptn-example-repo",
    [string]$repoUrl = "https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo",
    [string]$outputDirectory = ".",
    [string]$repoConfigFilePath = "./repository-config/config.json",
    [string]$deprecatedFilesConfigFilePath = "./repository-config/deprecated-files.json",
    [string]$managedFilesBaseDir = "../managed-files"
)

Write-Host "Running repository file sync script"

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
. (Join-Path $libDir "GitHubPullRequest.ps1")

$issueLog = @()

$repositoryConfig = Get-Content -Path $repoConfigFilePath -Raw | ConvertFrom-Json
$settings = Resolve-RepositorySettings -repositoryConfig $repositoryConfig -repoId $repoId
$managedFiles = Build-ManagedFilesMap `
    -baseDir $managedFilesBaseDir `
    -overlay $settings.ManagedFilesAdditional `
    -excluded $settings.ExcludedManagedFiles `
    -repoId $repoId

# Load deprecated-file paths once. Each path is matched against the target
# repo's default-branch tree; matching paths are removed in the same PR that
# carries the managed-file updates.
$deprecatedPaths = @()
if(Test-Path $deprecatedFilesConfigFilePath) {
    $deprecatedPaths = @(Get-Content -Path $deprecatedFilesConfigFilePath -Raw | ConvertFrom-Json)
    Write-Host "Loaded $($deprecatedPaths.Count) deprecated path(s) from $deprecatedFilesConfigFilePath."
}

$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

Write-Host "$([Environment]::NewLine)<--->" -ForegroundColor Green
Write-Host "$([Environment]::NewLine)Syncing files for: $orgAndRepoName.$([Environment]::NewLine)" -ForegroundColor Green
Write-Host "<--->$([Environment]::NewLine)" -ForegroundColor Green

# Fetch the default-branch tree once. The managed-files sync uses the cached
# blob SHAs to detect which files need creating/updating and which deprecated
# paths are actually present, all without making any additional GitHub REST
# calls per file. Nothing to diff if there are no managed files and no
# deprecated paths configured.
$repoTree = $null
$needRepoTree = ($deprecatedPaths.Count -gt 0) -or ($managedFiles.Keys.Count -gt 0)
if($needRepoTree) {
    $repoTree = Get-RepositoryDefaultBranchTree -orgAndRepoName $orgAndRepoName
}

if($repoTree -and $repoTree.Success) {
    # CODEOWNERS is intentionally NOT synced here - it is owned by
    # Invoke-RepositoryConfigSync.ps1 because its team references depend on the
    # repository access Terraform grants. Passing `$null` content keeps it out
    # of the desired-file set.
    $syncResult = Sync-RepoFiles `
        -orgAndRepoName $orgAndRepoName `
        -deprecatedPaths $deprecatedPaths `
        -managedFiles $managedFiles `
        -codeownersContent $null `
        -repoTree $repoTree `
        -planOnly $planOnly `
        -issueLog $issueLog
    $issueLog = $syncResult.IssueLog
} elseif($needRepoTree) {
    Write-Host "Skipping file sync for $orgAndRepoName because the default-branch tree could not be fetched." -ForegroundColor Yellow
}

if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}
