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

function Add-IssueToLog {
    param(
        [string]$orgAndRepoName,
        [string]$type,
        [string]$message,
        [object]$data,
        [array]$issueLog,
        [ValidateSet("warning", "error")]
        [string]$severity = "error",
        [string]$issueLogFile="issue.log"
    )

    $issueLogItem = @{
        orgAndRepoName = $orgAndRepoName
        type = $type
        severity = $severity
        message = $message
        data = $data
    }

    $issueLog += $issueLogItem

    $issueLogItemJson = ConvertTo-Json $issueLogItem -Depth 100
    Add-Content -Path $issueLogFile -Value $issueLogItemJson

    return $issueLog
}

function Invoke-TerraformWithRetry {
  param(
    [hashtable[]]$commands,
    [string]$workingDirectory,
    [string]$outputLog = "output.log",
    [string]$errorLog = "error.log",
    [int]$maxRetries = 50,
    [int]$retryDelayIncremental = 10,
    [string[]]$retryOn = @("429 Too Many Requests", "Client.Timeout exceeded while awaiting headers", "Error: Failed to install provider", "Error: Failed to query available provider packages", "403 API rate limit"),
    [switch]$printOutput,
    [switch]$printOutputOnError,
    [switch]$returnOutputParsedFromJson
  )

  foreach($command in $commands) {
    $command.Arguments = @("-chdir=$workingDirectory") + $command.Arguments
  }

  return Invoke-CommandWithRetry `
    -parentCommand "terraform" `
    -commands $commands `
    -outputLog $outputLog `
    -errorLog $errorLog `
    -maxRetries $maxRetries `
    -retryDelayIncremental $retryDelayIncremental `
    -retryOn $retryOn `
    -printOutput:$printOutput.IsPresent `
    -printOutputOnError:$printOutputOnError.IsPresent `
    -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
}

function Invoke-GitHubCliWithRetry {
  param(
    [hashtable[]]$commands,
    [string]$outputLog = "output.log",
    [string]$errorLog = "error.log",
    [int]$maxRetries = 50,
    [int]$retryDelayIncremental = 10,
    [string[]]$retryOn = @("API rate limit exceeded"),
    [switch]$printOutput,
    [switch]$printOutputOnError,
    [switch]$returnOutputParsedFromJson
  )

  return Invoke-CommandWithRetry `
    -parentCommand "gh" `
    -commands $commands `
    -outputLog $outputLog `
    -errorLog $errorLog `
    -maxRetries $maxRetries `
    -retryDelayIncremental $retryDelayIncremental `
    -retryOn $retryOn `
    -printOutput:$printOutput.IsPresent `
    -printOutputOnError:$printOutputOnError.IsPresent `
    -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
}

function Invoke-CommandWithRetry {
  param(
    $parentCommand,
    [hashtable[]]$commands,
    [string]$outputLog = "output.log",
    [string]$errorLog = "error.log",
    [int]$maxRetries = 10,
    [int]$retryDelayIncremental = 10,
    [string[]]$retryOn = @("API rate limit exceeded"),
    [switch]$printOutput,
    [switch]$printOutputOnError,
    [switch]$returnOutputParsedFromJson
  )

  $retryCount = 0
  $shouldRetry = $true

  $returnOutputs = @()

  while ($shouldRetry -and $retryCount -le $maxRetries) {
    $shouldRetry = $false

    foreach ($command in $commands) {
      $arguments = $command.Arguments

      $localLogPath = $outputLog
      if($command.OutputLog) {
        $localLogPath = $command.OutputLog
      }

      Write-Host "Running $parentCommand with arguments: $($arguments -join ' ')"
      $process = Start-Process `
        -FilePath $parentCommand `
        -ArgumentList $arguments `
        -RedirectStandardOutput $localLogPath `
        -RedirectStandardError $errorLog `
        -PassThru `
        -NoNewWindow `
        -Wait

      if ($process.ExitCode -ne 0) {
        Write-Host "$parentCommand failed with exit code $($process.ExitCode)."

        if($retryOn -contains "*") {
          $shouldRetry = $true
        } else {
          $errorOutput = Get-Content -Path $errorLog
          foreach($line in $errorOutput) {
            foreach($retryError in $retryOn) {
              if ($line -like "*$retryError*") {
                Write-Host "Retrying $parentCommand due to error: $line"
                $shouldRetry = $true
              }
            }
          }
        }

        if ($shouldRetry) {
          Write-Host "Retrying $parentCommand due to error:"
          Get-Content -Path $errorLog | Write-Host
          $retryCount++
          break
        } else {
          Write-Host "$parentCommand failed with exit code $($process.ExitCode). Check the logs for details."
          if($printOutputOnError) {
            Write-Host "Output Log:"
            Get-Content -Path $localLogPath | Write-Host
          }
          Write-Host "Error Log:"
          Get-Content -Path $errorLog | Write-Host
          $returnOutputs += @{
            success = $false
          }
          return $returnOutputs
        }
      } else {
        if($printOutput) {
          Write-Host "Output Log:"
          Get-Content -Path $localLogPath | Write-Host
        }
        if($returnOutputParsedFromJson) {
          $outputContent = Get-Content -Path $localLogPath -Raw
          $parsedOutput = $outputContent | ConvertFrom-Json
          $returnOutputs += @{
            success = $true
            output = $parsedOutput
          }
        } else {
            $returnOutputs += @{
                success = $true
            }
        }
      }
    }
    if ($shouldRetry) {
        if ($retryCount -gt $maxRetries) {
            Write-Host "Max retries reached. Exiting."
            $returnOutputs = @( @{
                success = $false
            })
            return $returnOutputs
        }
        Write-Host "Retrying $parentCommand commands (attempt $retryCount of $maxRetries)..."
        $retryDelay = $retryDelayIncremental * $retryCount
        Write-Host "Waiting for $retryDelay seconds before retrying..."
        Start-Sleep -Seconds $retryDelay
    }
  }

  return $returnOutputs
}

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
$repositoryGroups = $repositoryConfig.repositoryGroups | Where-Object { $_.repositories -contains $repoId }

$repositoryGroupNames = @($repositoryGroups | ForEach-Object { $_.name })
$repositoryGroupNames += "all"

$teams = @()

foreach($repositoryGroupName in $repositoryGroupNames) {
    $teamMappings = $repositoryConfig.teamMappings | Where-Object { $_.repositoryGroups -contains $repositoryGroupName }
    if($teamMappings.Count -gt 0) {
        $teams += $teamMappings
    }
}

# Collect the CODEOWNERS default teams from every repository group that contains
# this repo. These teams become required reviewers for all files in the repo
# (e.g. tier 1 modules require review from the engineering owners team).
$codeOwnersDefaultTeams = @()
foreach($repositoryGroup in $repositoryGroups) {
    if($repositoryGroup.PSObject.Properties.Name -contains "codeOwnersTeams" -and $repositoryGroup.codeOwnersTeams) {
        $codeOwnersDefaultTeams += $repositoryGroup.codeOwnersTeams
    }
}
$codeOwnersDefaultTeams = @($codeOwnersDefaultTeams | Select-Object -Unique)

# The teams that protect the CODEOWNERS file itself are global and apply to
# every repository regardless of tier.
$codeOwnersFileProtectionTeams = @()
if($repositoryConfig.PSObject.Properties.Name -contains "codeOwners" -and $repositoryConfig.codeOwners -and $repositoryConfig.codeOwners.fileProtectionTeams) {
    $codeOwnersFileProtectionTeams = @($repositoryConfig.codeOwners.fileProtectionTeams)
}

# Collect repository topics: start from the global default topics and add any
# topics defined on each matching repository group (e.g. `avm-tier-1`).
# The result is the authoritative topic list for the repository, so any topic
# set on the repo that is not in this list will be removed by Terraform.
$repositoryTopics = @()
if($repositoryConfig.PSObject.Properties.Name -contains "topics" -and $repositoryConfig.topics -and $repositoryConfig.topics.default) {
    $repositoryTopics += $repositoryConfig.topics.default
}
foreach($repositoryGroup in $repositoryGroups) {
    if($repositoryGroup.PSObject.Properties.Name -contains "topics" -and $repositoryGroup.topics) {
        $repositoryTopics += $repositoryGroup.topics
    }
}
$repositoryTopics = @($repositoryTopics | Select-Object -Unique)

# Collect the managed-files overlay set declared on any matching repository
# group (e.g. `alz` for the azure-landing-zones group). At most one distinct
# value is allowed; conflicting overlays across groups for the same repo are a
# configuration error.
$managedFilesAdditionalValues = @()
foreach($repositoryGroup in $repositoryGroups) {
    if($repositoryGroup.PSObject.Properties.Name -contains "managedFilesAdditional" -and $repositoryGroup.managedFilesAdditional) {
        $managedFilesAdditionalValues += $repositoryGroup.managedFilesAdditional
    }
}
$managedFilesAdditionalValues = @($managedFilesAdditionalValues | Select-Object -Unique)
if($managedFilesAdditionalValues.Count -gt 1) {
    Write-Error "Repository '$repoId' belongs to multiple repository groups that declare conflicting 'managedFilesAdditional' overlay sets: $($managedFilesAdditionalValues -join ', '). At most one is allowed."
    exit 1
}
$managedFilesAdditional = if($managedFilesAdditionalValues.Count -eq 1) { $managedFilesAdditionalValues[0] } else { "" }

# Collect the set of managed files to exclude from the final map for this
# repository. Excluded files are pulled in from every matching repository
# group's `excludedManagedFiles` field and de-duplicated. Use this to suppress
# files that exist in `managed-files/root/` (or in the overlay) but should not
# be deployed to repositories in this group (e.g. ALZ repos don't ship the
# generic AVM module issue templates).
$excludedManagedFiles = @()
foreach($repositoryGroup in $repositoryGroups) {
    if($repositoryGroup.PSObject.Properties.Name -contains "excludedManagedFiles" -and $repositoryGroup.excludedManagedFiles) {
        $excludedManagedFiles += @($repositoryGroup.excludedManagedFiles)
    }
}
$excludedManagedFiles = @($excludedManagedFiles | Select-Object -Unique)

# Build the managed-files map (target path -> absolute source path) that will
# be passed to the github Terraform module. Walking the filesystem here keeps
# Terraform free of `path.module`-relative directory traversal and lets us
# apply overlay merging + exclusions in one place.
$managedFilesRootDir = Join-Path $managedFilesBaseDir "root"
$managedFilesOverlayDir = ""
if($managedFilesAdditional -ne "") {
    $managedFilesOverlayDir = Join-Path $managedFilesBaseDir $managedFilesAdditional
}

function Add-ManagedFilesFromDir {
    param(
        [string]$baseDir,
        [hashtable]$map
    )
    if([string]::IsNullOrEmpty($baseDir)) { return }
    if(-not (Test-Path -Path $baseDir -PathType Container)) {
        Write-Warning "Managed files directory does not exist: $baseDir"
        return
    }
    $baseDirAbsolute = (Resolve-Path -Path $baseDir).Path
    $prefixLength = $baseDirAbsolute.Length + 1
    # `-Force` is required because PowerShell treats dot-prefixed entries as
    # hidden on Linux/macOS (the runner OS for sync), and without it
    # `Get-ChildItem -Recurse` silently skips `.github/`, `.devcontainer/`,
    # `.vscode/`, `.editorconfig`, `.gitattributes`, `.terraform-docs.yml`,
    # etc. Windows does not flag dotfiles as hidden, so the bug is invisible
    # locally.
    Get-ChildItem -Path $baseDirAbsolute -Recurse -File -Force | ForEach-Object {
        $relativePath = $_.FullName.Substring($prefixLength) -replace '\\', '/'
        $absoluteSource = $_.FullName -replace '\\', '/'
        $map[$relativePath] = $absoluteSource
    }
}

$managedFiles = @{}
Add-ManagedFilesFromDir -baseDir $managedFilesRootDir -map $managedFiles
if($managedFilesOverlayDir -ne "") {
    Add-ManagedFilesFromDir -baseDir $managedFilesOverlayDir -map $managedFiles
}

foreach($excluded in $excludedManagedFiles) {
    if($managedFiles.ContainsKey($excluded)) {
        $managedFiles.Remove($excluded) | Out-Null
        Write-Host "Excluded managed file from sync: $excluded"
    }
}

Write-Host "Resolved $($managedFiles.Count) managed file(s) for repository '$repoId' (overlay='$managedFilesAdditional', exclusions=$($excludedManagedFiles.Count))."

Write-Host "$([Environment]::NewLine)Checking $($repoId)"

if(!$skipCleanup) {
    if(Test-Path "$terraformModulePath/.terraform") {
        Remove-Item "$terraformModulePath/.terraform" -Recurse -Force
    }

    if(Test-Path "$terraformModulePath/terraform.tfvars.json") {
        Remove-Item "$terraformModulePath/terraform.tfvars.json" -Force
    }

    if(Test-Path "$terraformModulePath/terraform.tfstate") {
        Remove-Item "$terraformModulePath/terraform.tfstate" -Force
    }

    if(Test-Path "$terraformModulePath/.terraform.lock.hcl") {
        Remove-Item "$terraformModulePath/.terraform.lock.hcl" -Force
    }

    if(Test-Path "$terraformModulePath/imports.tf") {
        Remove-Item "$terraformModulePath/imports.tf" -Force
    }
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
    $teamExists = $false
    $teamName = $team.name

    $existingTeam = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "orgs/$orgName/teams/$($teamName)")
                OutputLog = "team-exists.json"
            }
        ) `
        -returnOutputParsedFromJson

    if(!$existingTeam.success) {
        Write-Warning "Failed to check if team exists: $($teamName)."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-check-failed" -message "Failed to check if team $teamName exists." -data $null -issueLog $issueLog
        exit 1
    }

    $teamExists = $existingTeam.output.slug -and $existingTeam.output.slug -eq $teamName

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
            members_are_team_maintainers = $team.membersAreTeamMaintainers
        }
    }
}

if(!$repositoryCreationModeEnabled) {
    Write-Host "Checking repository: $orgAndRepoName for existing teams and users."

    $allowedUsers = @()

    if($moduleMetaData) {
        $allowedUsers = @(
            $moduleMetaData.primaryOwnerGitHubHandle,
            $moduleMetaData.secondaryOwnerGitHubHandle
        )
    }

    Write-Host "Checking repository: $orgAndRepoName for existing users."
    $repoUsers = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/collaborators?affiliation=direct")
                OutputLog = "repo-users.json"
            }
        ) `
        -returnOutputParsedFromJson

    if(!$repoUsers.success) {
        Write-Warning "Failed to get repository users for: $orgAndRepoName. Skipping."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-users-fetch-failed" -message "Failed to fetch repository users for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    Write-Host "Found $($repoUsers.output.Count) users in repository: $orgAndRepoName"
    foreach($user in $repoUsers.output) {
        $userLogin = $user.login

        if($allowedUsers -contains $userLogin -and $user.role_name -eq "admin") {
            Write-Warning "User has direct access to $orgAndRepoName, but is an owner or AVM core team member and has admin access. They are likely JIT elevated, so skipping the error: $($userLogin)"
            if($forceUserRemoval) {
                Write-Warning "Force user removal is enabled, removing access now: $($userLogin) - role: $($user.role_name)"
                if($planOnly) {
                    Write-Host "Would run command: gh api 'repos/$orgAndRepoName/collaborators/$($userLogin)' -X DELETE"
                } else {
                    $result = Invoke-GitHubCliWithRetry `
                        -commands @(
                            @{
                                Arguments = @("api", "repos/$orgAndRepoName/collaborators/$($userLogin)", "-X", "DELETE")
                                OutputLog = "remove-user.json"
                            }
                        ) `
                        -printOutputOnError

                    if(!$result.success) {
                        Write-Warning "Failed to remove user: $($userLogin) from repository: $orgAndRepoName. Exiting."
                        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "user-removal-failed" -message "Failed to remove user $($userLogin) from repository $orgAndRepoName." -data $null -issueLog $issueLog
                        exit 1
                    }
                }
            }
        } else {
            Write-Warning "User has direct access to $orgAndRepoName, but AVM repos cannot have direct user access outside of JIT, removing access now: $($userLogin) - role: $($user.role_name)"
            if($planOnly) {
                Write-Host "Would run command: gh api 'repos/$orgAndRepoName/collaborators/$($userLogin)' -X DELETE"
            } else {
                $result = Invoke-GitHubCliWithRetry `
                    -commands @(
                        @{
                            Arguments = @("api", "repos/$orgAndRepoName/collaborators/$($userLogin)", "-X", "DELETE")
                            OutputLog = "remove-user.json"
                        }
                    ) `
                    -printOutputOnError

                if(!$result.success) {
                    Write-Warning "Failed to remove user: $($userLogin) from repository: $orgAndRepoName. Exiting."
                    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "user-removal-failed" -message "Failed to remove user $($userLogin) from repository $orgAndRepoName." -data $null -issueLog $issueLog
                    exit 1
                }
            }
        }
    }

    $repoTeams = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/teams", "--paginate")
                OutputLog = "repo-teams.json"
            }
        ) `
        -returnOutputParsedFromJson

    if(!$repoTeams.success) {
        Write-Warning "Failed to get repository teams for: $orgAndRepoName. Skipping."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-teams-fetch-failed" -message "Failed to fetch repository teams for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    Write-Host "Found $($repoTeams.output.Count) teams in repository: $orgAndRepoName"
    foreach($team in $repoTeams.output) {
        $teamName = $team.name
        if($extraTeamsToIgnore -contains $teamName) {
            Write-Host "Skipping team: $($teamName) as it is in the ignore list."
            continue
        }
        if(!$githubTeams.ContainsKey($teamName)) {
            Write-Warning "Team exists in repository but not in config, will be removed: $($teamName)"
            $teamSlug = $team.slug
            if($planOnly) {
                Write-Host "Would run command: gh api 'orgs/$orgName/teams/$($teamSlug)/repos/$orgAndRepoName' -X DELETE"
            } else {
                $result = Invoke-GitHubCliWithRetry `
                    -commands @(
                        @{
                            Arguments = @("api", "orgs/$orgName/teams/$($teamSlug)/repos/$orgAndRepoName", "-X", "DELETE")
                            OutputLog = "remove-team.json"
                        }
                    ) `
                    -printOutputOnError

                if(!$result.success) {
                    Write-Warning "Failed to remove team: $($teamName) from repository: $orgAndRepoName. Exiting."
                    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-removal-failed" -message "Failed to remove team $($teamName) from repository $orgAndRepoName." -data $null -issueLog $issueLog
                    exit 1
                }
            }
        }
    }
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
    codeowners_default_teams = $codeOwnersDefaultTeams
    codeowners_file_protection_teams = $codeOwnersFileProtectionTeams
    topics = $repositoryTopics
    managed_files = $managedFiles
}

$terraformVariables | ConvertTo-Json -Depth 100 | Out-File "$terraformModulePath/terraform.tfvars.json"

if($repositoryCreationModeEnabled) {
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

    if(!$result.success) {
        Write-Warning "Terraform init failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "init-failed" -message "Terraform init failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

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

    if(!$result.success) {
        Write-Warning "Terraform init failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "init-failed" -message "Terraform init failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }
}

# Bootstrap imports for managed-file paths that are not yet in state.
#
# `github_repository_file.managed` is configured with `overwrite_on_create =
# false`, so the first apply against a repo that already contains one of the
# managed files would skip it and leave Terraform unaware of the existing
# content. To avoid this we check each candidate path individually: any path
# that is missing from state AND exists on the target repo's default branch
# gets an `import` block written to `imports.tf` before plan. This handles
# both first-time syncs and incremental cases where the managed-file set
# grows (e.g. when CODEOWNERS is migrated from the previous standalone
# resource via the module's `removed` block).
$importsFilePath = "$terraformModulePath/imports.tf"
if(Test-Path $importsFilePath) {
    Remove-Item $importsFilePath -Force
}

if(!$repositoryCreationModeEnabled) {
    $codeownersPath = ".github/CODEOWNERS"
    $candidateImportPaths = @(@($managedFiles.Keys) + $codeownersPath | Select-Object -Unique)

    $stateListLog = "state-list.log"
    $stateList = Invoke-TerraformWithRetry `
        -commands @(
            @{
                Arguments = @("state", "list")
                OutputLog = $stateListLog
            }
        ) `
        -workingDirectory $terraformModulePath `
        -retryOn @()

    $stateAddresses = @()
    if($stateList -and $stateList.success) {
        $stateLogPath = Join-Path $terraformModulePath $stateListLog
        if(Test-Path $stateLogPath) {
            $stateAddresses = @(Get-Content -Path $stateLogPath | ForEach-Object { $_.Trim() })
        }
    }

    $pathsNotInState = @()
    foreach($candidate in $candidateImportPaths) {
        $stateAddress = "module.github.github_repository_file.managed[`"$candidate`"]"
        if($stateAddresses -notcontains $stateAddress) {
            $pathsNotInState += $candidate
        }
    }

    if($pathsNotInState.Count -eq 0) {
        Write-Host "All managed-file paths already in state for $orgAndRepoName; skipping import bootstrap."
    } else {
        Write-Host "$($pathsNotInState.Count) managed-file path(s) missing from state for $orgAndRepoName; checking the target repo for pre-existing copies."

        $repoInfo = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Arguments = @("api", "repos/$orgAndRepoName")
                    OutputLog = "repo-info.json"
                }
            ) `
            -returnOutputParsedFromJson

        if(!$repoInfo -or !$repoInfo.success -or !$repoInfo.output.default_branch) {
            Write-Warning "Failed to fetch repo info for $orgAndRepoName (success=$($repoInfo.success), default_branch='$($repoInfo.output.default_branch)'); continuing without import blocks."
        } else {
            $defaultBranch = $repoInfo.output.default_branch
            $treeResult = Invoke-GitHubCliWithRetry `
                -commands @(
                    @{
                        Arguments = @("api", "repos/$orgAndRepoName/git/trees/$($defaultBranch)?recursive=1")
                        OutputLog = "repo-tree.json"
                    }
                ) `
                -returnOutputParsedFromJson

            if(!$treeResult -or !$treeResult.success -or !$treeResult.output.tree) {
                Write-Warning "Failed to fetch git tree for $orgAndRepoName (success=$($treeResult.success), tree_count=$($treeResult.output.tree.Count)); continuing without import blocks."
            } else {
                $existingFiles = @($treeResult.output.tree | Where-Object { $_.type -eq "blob" } | ForEach-Object { $_.path })
                $importsToWrite = @($pathsNotInState | Where-Object { $existingFiles -contains $_ })

                if($importsToWrite.Count -eq 0) {
                    Write-Host "No pre-existing copies of the missing managed-file paths found in $orgAndRepoName; no imports needed."
                } else {
                    $importBlocks = New-Object System.Collections.Generic.List[string]
                    $importBlocks.Add("# Auto-generated by Invoke-RepositorySync.ps1 for paths missing from state.")
                    $importBlocks.Add("# Brings existing target-repo files into state so subsequent plans only diff")
                    $importBlocks.Add("# content that actually differs from the managed source. Safe to delete - it")
                    $importBlocks.Add("# is regenerated on every run and only contains entries for files that exist.")
                    foreach($path in $importsToWrite) {
                        # `github_repository_file` import ID format is
                        # `<repository>:<file path>:<branch>` (three colon-
                        # separated parts). The repo name and file path must
                        # be separated by `:`, not `/`, despite the file
                        # itself living under `<repository>/<path>` in git.
                        $importBlocks.Add("")
                        $importBlocks.Add("import {")
                        $importBlocks.Add("  id = `"$($repoName):$($path):$($defaultBranch)`"")
                        $importBlocks.Add("  to = module.github.github_repository_file.managed[`"$($path)`"]")
                        $importBlocks.Add("}")
                    }
                    Set-Content -Path $importsFilePath -Value ($importBlocks -join [Environment]::NewLine)
                    Write-Host "Wrote $($importsToWrite.Count) import block(s) to $importsFilePath"
                }
            }
        }
    }
}

$result = Invoke-TerraformWithRetry `
-commands @(
    @{
        Arguments = @("plan", "-out=`"$($repoId).tfplan`"")
        OutputLog = "plan.log"
    }
) `
-workingDirectory $terraformModulePath `
-printOutput

if(!$result.success) {
    Write-Warning "Terraform plan failed for $orgAndRepoName. Exiting."
    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Terraform plan failed for $orgAndRepoName." -data $null -issueLog $issueLog
    exit 1
}

$plan = $(terraform -chdir="$terraformModulePath" show -json "$($repoId).tfplan") | ConvertFrom-Json

if(!$plan -or !$plan.resource_changes) {
    Write-Warning "Failed to parse Terraform plan for $orgAndRepoName. Exiting."
    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-parse-failed" -message "Failed to parse Terraform plan for $orgAndRepoName." -data $null -issueLog $issueLog
    exit 1
}

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

    if(!$result.success) {
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

    if(!$result.success) {
        Write-Warning "Terraform apply failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "apply-failed" -message "Terraform apply failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    } else {
        Write-Host "Terraform apply succeeded for $orgAndRepoName"
    }
}


if($issueLog.Count -eq 0) {
    Write-Host "No issues found for $repoId"
} else {
    Write-Host "Issues found for $repoId"
    $issueLogJson = ConvertTo-Json $issueLog -Depth 100
    $issueLogJson | Out-File "$outputDirectory/issue.log.json"
}
