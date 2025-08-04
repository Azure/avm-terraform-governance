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
    [string]$targetSubscriptionId = "",
    [string]$identityResourceGroupName = "",
    [bool]$planOnly = $false,
    [string]$repoId = "avm-ptn-example-repo",
    [string]$repoUrl = "https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo",
    [string]$moduleDisplayName = "Example Repository",
    [string]$outputDirectory = ".",
    [string]$repoConfigFilePath = "./repository-config/config.json",
    [string]$metaDataFilePath = "./repository-meta-data/meta-data.csv",
    [string]$terraformModulePath = "./repository_sync",
    [string[]]$resourceTypesThatCannotBeDestroyed = @(
        "github_repository"
    ),
    [switch]$skipCleanup,
    [string[]]$extraTeamsToIgnore = @(
        "security",
        "azurecla-write"
    ),
    [switch]$forceUserRemoval
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

function Invoke-TerraformWithRetry {
  param(
    [hashtable[]]$commands,
    [string]$workingDirectory,
    [string]$outputLog = "output.log",
    [string]$errorLog = "error.log",
    [int]$maxRetries = 10,
    [int]$retryDelayIncremental = 10,
    [string[]]$retryOn = @("429 Too Many Requests", "Client.Timeout exceeded while awaiting headers"),
    [switch]$printOutput,
    [switch]$printOutputOnError
  )

  $retryCount = 0
  $shouldRetry = $true

  while ($shouldRetry -and $retryCount -le $maxRetries) {
    $shouldRetry = $false

    foreach ($command in $commands) {
      $commandName = $command.Command
      $arguments = $command.Arguments

      $localLogPath = $outputLog
      if($command.OutputLog) {
        $localLogPath = $command.OutputLog
      }

      $commandArguments = @("-chdir=$workingDirectory", $commandName) + $arguments

      Write-Host "Running Terraform $commandName with arguments: $($commandArguments -join ' ')"
      $process = Start-Process `
        -FilePath "terraform" `
        -ArgumentList $commandArguments `
        -RedirectStandardOutput $localLogPath `
        -RedirectStandardError $errorLog `
        -PassThru `
        -NoNewWindow `
        -Wait

      if ($process.ExitCode -ne 0) {
        Write-Host "Terraform $commandName failed with exit code $($process.ExitCode)."

        if($retryOn -contains "*") {
          $shouldRetry = $true
        } else {
          $errorOutput = Get-Content -Path $errorLog
          foreach($line in $errorOutput) {
            foreach($retryError in $retryOn) {
              if ($line -like "*$retryError*") {
                Write-Host "Retrying Terraform $commandName due to error: $line"
                $shouldRetry = $true
              }
            }
          }
        }

        if ($shouldRetry) {
          Write-Host "Retrying Terraform $commandName due to error:"
          Get-Content -Path $errorLog | Write-Host
          $retryCount++
          break
        } else {
          Write-Host "Terraform $commandName failed with exit code $($process.ExitCode). Check the logs for details."
          if($printOutputOnError) {
            Write-Host "Output Log:"
            Get-Content -Path $localLogPath | Write-Host
          }
          Write-Host "Error Log:"
          Get-Content -Path $errorLog | Write-Host
          return $false
        }
      } else {
        if($printOutput) {
          Write-Host "Output Log:"
          Get-Content -Path $localLogPath | Write-Host
        }
      }
    }
    if ($shouldRetry) {
      Write-Host "Retrying Terraform commands (attempt $retryCount of $maxRetries)..."
      $retryDelay = $retryDelayIncremental * $retryCount
      Write-Host "Waiting for $retryDelay seconds before retrying..."
      Start-Sleep -Seconds $retryDelay
    }
  }
  return $true
}

function Invoke-GitHubCliWithRetry {
  param(
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
      $commandName = $command.Command
      $arguments = $command.Arguments

      $localLogPath = $outputLog
      if($command.OutputLog) {
        $localLogPath = $command.OutputLog
      }

      $commandArguments = @($commandName) + $arguments

      Write-Host "Running GitHub $commandName with arguments: $($commandArguments -join ' ')"
      $process = Start-Process `
        -FilePath "gh" `
        -ArgumentList $commandArguments `
        -RedirectStandardOutput $localLogPath `
        -RedirectStandardError $errorLog `
        -PassThru `
        -NoNewWindow `
        -Wait

      if ($process.ExitCode -ne 0) {
        Write-Host "GitHub $commandName failed with exit code $($process.ExitCode)."

        if($retryOn -contains "*") {
          $shouldRetry = $true
        } else {
          $errorOutput = Get-Content -Path $errorLog
          foreach($line in $errorOutput) {
            foreach($retryError in $retryOn) {
              if ($line -like "*$retryError*") {
                Write-Host "Retrying GitHub $commandName due to error: $line"
                $shouldRetry = $true
              }
            }
          }
        }

        if ($shouldRetry) {
          Write-Host "Retrying GitHub $commandName due to error:"
          Get-Content -Path $errorLog | Write-Host
          $retryCount++
          break
        } else {
          Write-Host "GitHub $commandName failed with exit code $($process.ExitCode). Check the logs for details."
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
      Write-Host "Retrying GitHub commands (attempt $retryCount of $maxRetries)..."
      $retryDelay = $retryDelayIncremental * $retryCount
      Write-Host "Waiting for $retryDelay seconds before retrying..."
      Start-Sleep -Seconds $retryDelay
    }
  }
  return $returnOutputs
}

$env:ARM_USE_AZUREAD = "true"

$issueLog = @()

$moduleName = $moduleDisplayName

$moduleMetaData = $null

if(!$repositoryCreationModeEnabled){
    $repositoryMetaData = Get-Content -Path $metaDataFilePath -Raw | ConvertFrom-Csv
    $moduleMetaData = $repositoryMetaData | Where-Object { $_.moduleId -eq $repoId }
    if(!$moduleMetaData) {
        Write-Warning "Module metadata missing for: $($repoId)"
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "module-metadata-missing" -message "Module metadata for $repoId does not exist." -data $repoId -issueLog $issueLog
        $moduleName = $repoId
    } else {
        $moduleName = $moduleMetaData.moduleDisplayName
    }
}

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
                Command = "api"
                Arguments = @("orgs/$orgName/teams/$($teamName)")
                OutputLog = "team-exists.json"
            }
        ) `
        -returnOutputParsedFromJson

    $teamExists = $existingTeam.success -and $existingTeam.output.status -ne 404

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

    $teamsWithMaintainers = $githubTeams.GetEnumerator() | Where-Object { $_.Value.members_are_team_maintainers -eq $true }

    foreach($teamWithMaintainers in $teamsWithMaintainers) {
        Write-Host "Checking team: $($teamWithMaintainers.Value.slug) for maintainers."
        $teamMembers = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Command = "api"
                    Arguments = @("orgs/$orgName/teams/$($teamWithMaintainers.Value.slug)/members")
                    OutputLog = "team-members.json"
                }
            ) `
            -returnOutputParsedFromJson

        if(!$teamMembers.success) {
            Write-Warning "Failed to get team members for: $($teamWithMaintainers.Value.slug). Skipping."
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-members-fetch-failed" -message "Failed to fetch team members for $($teamWithMaintainers.Value.slug)." -data $null -issueLog $issueLog
            exit 1
        }

        foreach($member in $teamMembers.output) {
            $allowedUsers += $member.login
        }
    }

    Write-Host "Checking repository: $orgAndRepoName for existing users."
    $repoUsers = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Command = "api"
                Arguments = @("repos/$orgAndRepoName/collaborators?affiliation=direct")
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
                    Invoke-GitHubCliWithRetry `
                        -commands @(
                            @{
                                Command = "api"
                                Arguments = @("repos/$orgAndRepoName/collaborators/$($userLogin)", "-X", "DELETE")
                                OutputLog = "remove-user.json"
                            }
                        ) `
                        -printOutput
                }
            }
        } else {
            Write-Warning "User has direct access to $orgAndRepoName, but AVM repos cannot have direct user access outside of JIT, removing access now: $($userLogin) - role: $($user.role_name)"
            if($planOnly) {
                Write-Host "Would run command: gh api 'repos/$orgAndRepoName/collaborators/$($userLogin)' -X DELETE"
            } else {
                Invoke-GitHubCliWithRetry `
                    -commands @(
                        @{
                            Command = "api"
                            Arguments = @("repos/$orgAndRepoName/collaborators/$($userLogin)", "-X", "DELETE")
                            OutputLog = "remove-user.json"
                        }
                    ) `
                    -printOutput
            }
        }
    }

    $repoTeams = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Command = "api"
                Arguments = @("repos/$orgAndRepoName/teams", "--paginate")
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
                Invoke-GitHubCliWithRetry `
                    -commands @(
                        @{
                            Command = "api"
                            Arguments = @("orgs/$orgName/teams/$($teamSlug)/repos/$orgAndRepoName", "-X", "DELETE")
                            OutputLog = "remove-team.json"
                        }
                    ) `
                    -printOutput
            }
        }
    }
}

$terraformVariables = @{
    repository_creation_mode_enabled = $repositoryCreationModeEnabled.IsPresent
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

$success = $false

if($repositoryCreationModeEnabled) {
    Set-Content -Path "$terraformModulePath/backend_override.tf" -Value @"
terraform {
    backend "local" {}
}
"@

    $success = Invoke-TerraformWithRetry `
    -commands @(
      @{
        Command = "init"
        Arguments = @()
        OutputLog = "init.log"
      }
    ) `
    -workingDirectory $terraformModulePath `
    -printOutput

} else {
    $success = Invoke-TerraformWithRetry `
    -commands @(
      @{
        Command = "init"
        Arguments = @(
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

if(!$success) {
    Write-Warning "Terraform init failed for $orgAndRepoName. Exiting."
    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "init-failed" -message "Terraform init failed for $orgAndRepoName." -data $null -issueLog $issueLog
    exit 1
}

$success = Invoke-TerraformWithRetry `
-commands @(
    @{
        Command = "plan"
        Arguments = @("-out=`"$($repoId).tfplan`"")
        OutputLog = "plan.log"
    }
) `
-workingDirectory $terraformModulePath `
-printOutput

if(!$success) {
    Write-Warning "Terraform plan failed for $orgAndRepoName. Exiting."
    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Terraform plan failed for $orgAndRepoName." -data $null -issueLog $issueLog
    exit 1
}

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

    Write-Host "Applying plan for $orgAndRepoName"
    $success = Invoke-TerraformWithRetry `
        -commands @(
            @{
                Command = "apply"
                Arguments = @("$($repoId).tfplan")
                OutputLog = "apply.log"
            }
        ) `
        -workingDirectory $terraformModulePath `
        -printOutput

    if(!$success) {
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
