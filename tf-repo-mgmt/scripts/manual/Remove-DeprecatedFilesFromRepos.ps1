# One-off cleanup script. Removes files listed in
# `tf-repo-mgmt/repository-config/deprecated-files.json` from AVM module
# repositories where the GitHub App is installed.
#
# Authenticates as the GitHub App via `Connect-AsApp.ps1` (provide the
# `azure-verified-modules.pem` private key alongside the client ID), enumerates
# installation repositories, and for each one:
#
# 1. Reads the repo's default-branch git tree in one API call.
# 2. Matches the tree against the candidate deprecated paths (root entries
#    apply to every repo; the per-overlay entries apply only to repos in a
#    repository group that declares the matching `managedFilesAdditional`).
# 3. If any matches are found, shallow-clones the repo into a temp directory,
#    `git rm -rf`s the matched paths, commits as the bot, pushes to the default
#    branch, then deletes the temp directory.
#
# Most repositories have none of the deprecated files and are skipped after a
# single read API call. Run with `-WhatIf` to enumerate matches without
# cloning or modifying anything.
#
# Example:
#   cd tf-repo-mgmt
#   ./scripts/manual/Remove-DeprecatedFilesFromRepos.ps1 `
#     -client_id <github-app-client-id> `
#     -private_key_path ./azure-verified-modules.pem

param(
  [Parameter(Mandatory = $true)]
  [string]$client_id,
  [string]$private_key_path = "azure-verified-modules.pem",
  [string]$orgName = "Azure",
  [string]$repoConfigFilePath = (Join-Path $PSScriptRoot "../../repository-config/config.json"),
  [string]$deprecatedFilesConfigFilePath = (Join-Path $PSScriptRoot "../../repository-config/deprecated-files.json"),
  [string[]]$validProviders = @("azure", "azurerm", "azapi"),
  [string[]]$reposToSkip = @(
    "bicep-registry-modules",
    "terraform-azure-modules",
    "ALZ-PowerShell-Module",
    "Azure-Verified-Modules",
    "Azure-Verified-Modules-Grept",
    "avmtester",
    "tflint-ruleset-avm",
    "avm-gh-app",
    "avm-container-images-cicd-agents-and-runners",
    "Azure-Verified-Modules-Workflows",
    "avm-terraform-governance"
  ),
  [string]$commitAuthorName = "azure-verified-modules[bot]",
  # Defaults to the AVM GitHub App user id (matches `github_avm_app_id` in
  # repository_sync/variables.tf). Override if running as a different app.
  [string]$commitAuthorEmail = "1049636+azure-verified-modules[bot]@users.noreply.github.com",
  [string]$commitMessage = "chore: remove deprecated files [skip ci]",
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

function Get-ModuleIdFromRepoName {
  param(
    [string]$repoName,
    [string[]]$providers
  )
  foreach ($provider in $providers) {
    $prefix = "terraform-$provider-"
    if ($repoName.StartsWith($prefix)) {
      return $repoName.Substring($prefix.Length)
    }
  }
  return $null
}

function Get-OverlayForModule {
  param(
    [string]$moduleId,
    [object]$repositoryConfig
  )
  foreach ($group in $repositoryConfig.repositoryGroups) {
    if ($group.repositories -and ($group.repositories -contains $moduleId) -and
        $group.PSObject.Properties.Name -contains "managedFilesAdditional" -and
        $group.managedFilesAdditional) {
      return $group.managedFilesAdditional
    }
  }
  return ""
}

function Get-DeprecatedPathsForRepo {
  param(
    [string]$overlay,
    [object]$deprecatedFilesConfig
  )
  $paths = @()
  if ($deprecatedFilesConfig.PSObject.Properties.Name -contains "root" -and $deprecatedFilesConfig.root) {
    $paths += @($deprecatedFilesConfig.root)
  }
  if ($overlay -ne "" -and
      $deprecatedFilesConfig.PSObject.Properties.Name -contains $overlay -and
      $deprecatedFilesConfig.$overlay) {
    $paths += @($deprecatedFilesConfig.$overlay)
  }
  return @($paths | Select-Object -Unique)
}

function Get-MatchingDeprecatedPaths {
  param(
    [string[]]$candidatePaths,
    [string[]]$repoFilePaths
  )
  $matches = @()
  foreach ($candidate in $candidatePaths) {
    $hit = $false
    if ($repoFilePaths -contains $candidate) {
      $hit = $true
    } else {
      $prefix = "$candidate/"
      foreach ($p in $repoFilePaths) {
        if ($p.StartsWith($prefix)) { $hit = $true; break }
      }
    }
    if ($hit) { $matches += $candidate }
  }
  return $matches
}

# Authenticate as the GitHub App. Sets $env:GH_TOKEN to an installation
# access token usable for both `gh api` calls and HTTPS git push.
$connectAsAppPath = Join-Path $PSScriptRoot "Connect-AsApp.ps1"
if (-not (Test-Path $connectAsAppPath)) {
  throw "Cannot find Connect-AsApp.ps1 at '$connectAsAppPath'."
}
& $connectAsAppPath -client_id $client_id -private_key_path $private_key_path

if ([string]::IsNullOrEmpty($env:GH_TOKEN)) {
  throw "Connect-AsApp.ps1 did not set GH_TOKEN. Cannot continue."
}

$modeTag = if ($WhatIf) { "[PLAN]" } else { "[APPLY]" }
Write-Host ""
if ($WhatIf) {
  Write-Host "================ PLAN MODE (-WhatIf) ================" -ForegroundColor Yellow
  Write-Host "No repositories will be cloned or modified." -ForegroundColor Yellow
  Write-Host "Each match below is prefixed with $modeTag for easy log filtering." -ForegroundColor Yellow
  Write-Host "=====================================================" -ForegroundColor Yellow
} else {
  Write-Host "================ APPLY MODE =========================" -ForegroundColor Red
  Write-Host "Matching files WILL be deleted and pushed to the default branch." -ForegroundColor Red
  Write-Host "=====================================================" -ForegroundColor Red
}
Write-Host ""

# Load configuration.
$repositoryConfig = Get-Content -Path $repoConfigFilePath -Raw | ConvertFrom-Json
$deprecatedFilesConfig = Get-Content -Path $deprecatedFilesConfigFilePath -Raw | ConvertFrom-Json

# Enumerate every repository where the GitHub App is installed (paginated).
$installedRepositories = @()
$itemsPerPage = 100
$page = 1
$incompleteResults = $true
while ($incompleteResults) {
  $response = ConvertFrom-Json (gh api "/installation/repositories?per_page=$itemsPerPage&page=$page")
  $installedRepositories += $response.repositories
  $incompleteResults = ($page * $itemsPerPage) -lt $response.total_count
  $page++
}
Write-Host "Found $($installedRepositories.Count) installed repositories."

$repositoriesProcessed = 0
$repositoriesWithMatches = 0
$repositoriesUpdated = 0
$repositoriesSkipped = 0
$repositoriesFailed = 0
$summary = @()

foreach ($repo in $installedRepositories) {
  $repoName = $repo.name

  if ($reposToSkip -contains $repoName) {
    Write-Host "Skipping $repoName (in skip list)."
    $repositoriesSkipped++
    continue
  }

  $moduleId = Get-ModuleIdFromRepoName -repoName $repoName -providers $validProviders
  if ($null -eq $moduleId) {
    Write-Host "Skipping $repoName (does not match terraform-<provider>-* naming)."
    $repositoriesSkipped++
    continue
  }

  $repositoriesProcessed++
  $overlay = Get-OverlayForModule -moduleId $moduleId -repositoryConfig $repositoryConfig
  $candidatePaths = Get-DeprecatedPathsForRepo -overlay $overlay -deprecatedFilesConfig $deprecatedFilesConfig
  if ($candidatePaths.Count -eq 0) {
    continue
  }

  $defaultBranch = $repo.default_branch
  if ([string]::IsNullOrEmpty($defaultBranch)) {
    Write-Warning "$repoName has no default_branch in installation listing; skipping."
    $repositoriesSkipped++
    continue
  }

  # One API call per repo: walk the entire tree on the default branch.
  $treeJson = gh api "repos/$orgName/$repoName/git/trees/$($defaultBranch)?recursive=1" 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($treeJson)) {
    Write-Warning "$repoName tree fetch failed; skipping."
    $repositoriesFailed++
    continue
  }
  $tree = ($treeJson | ConvertFrom-Json).tree
  $repoFilePaths = @($tree | Where-Object { $_.type -eq "blob" } | ForEach-Object { $_.path })

  $matches = Get-MatchingDeprecatedPaths -candidatePaths $candidatePaths -repoFilePaths $repoFilePaths
  if ($matches.Count -eq 0) {
    continue
  }

  $repositoriesWithMatches++
  Write-Host ""
  Write-Host "$modeTag $repoName ($moduleId, overlay='$overlay', default_branch=$defaultBranch) - $($matches.Count) match(es):" -ForegroundColor Cyan
  foreach ($m in $matches) {
    Write-Host "$modeTag   $repoName :: $m"
  }

  if ($WhatIf) {
    $summary += [pscustomobject]@{ repo = $repoName; action = "would-delete"; paths = ($matches -join ", ") }
    continue
  }

  $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-cleanup-" + [System.Guid]::NewGuid().ToString())
  $cloneUrl = "https://x-access-token:$($env:GH_TOKEN)@github.com/$orgName/$repoName.git"

  $cloneOk = $true
  try {
    Write-Host "  Cloning into $tempDir..." -ForegroundColor DarkGray
    git clone --quiet --depth 1 --branch $defaultBranch $cloneUrl $tempDir
    if ($LASTEXITCODE -ne 0) { throw "git clone exited $LASTEXITCODE" }

    Push-Location $tempDir
    try {
      foreach ($path in $matches) {
        git rm -r -f -- $path | Out-Null
        if ($LASTEXITCODE -ne 0) {
          Write-Warning "  git rm failed for '$path'; continuing with the rest."
        }
      }

      $status = git status --porcelain
      if ([string]::IsNullOrWhiteSpace($status)) {
        Write-Warning "  No staged changes after git rm; skipping commit/push."
      } else {
        git -c "user.name=$commitAuthorName" -c "user.email=$commitAuthorEmail" commit -q -m $commitMessage
        if ($LASTEXITCODE -ne 0) { throw "git commit exited $LASTEXITCODE" }
        git push --quiet origin $defaultBranch
        if ($LASTEXITCODE -ne 0) { throw "git push exited $LASTEXITCODE" }
        Write-Host "  Pushed cleanup commit to origin/$defaultBranch." -ForegroundColor Green
        $repositoriesUpdated++
        $summary += [pscustomobject]@{ repo = $repoName; action = "deleted"; paths = ($matches -join ", ") }
      }
    } finally {
      Pop-Location
    }
  } catch {
    Write-Warning "  Failed to update $repoName : $_"
    $cloneOk = $false
    $repositoriesFailed++
    $summary += [pscustomobject]@{ repo = $repoName; action = "failed"; paths = ($matches -join ", ") }
  } finally {
    if (Test-Path $tempDir) {
      try {
        # Git on Windows often marks .git/objects/pack files as read-only;
        # clear that before removing so cleanup actually succeeds.
        Get-ChildItem -Path $tempDir -Recurse -Force | ForEach-Object {
          try { $_.Attributes = "Normal" } catch { }
        }
        Remove-Item -Recurse -Force $tempDir
      } catch {
        Write-Warning "  Failed to clean up $tempDir : $_"
      }
    }
  }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Yellow
Write-Host "Repositories processed   : $repositoriesProcessed"
Write-Host "Repositories skipped     : $repositoriesSkipped"
Write-Host "Repositories with matches: $repositoriesWithMatches"
Write-Host "Repositories updated     : $repositoriesUpdated"
Write-Host "Repositories failed      : $repositoriesFailed"
if ($WhatIf) {
  Write-Host "(WhatIf mode: no repositories were modified.)" -ForegroundColor Yellow
}
if ($summary.Count -gt 0) {
  Write-Host ""
  $summary | Format-Table -AutoSize | Out-String | Write-Host
}
