Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/RepositoryConfig.ps1")

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$MessagePattern
    )

    $thrown = $false
    try {
        & $Action
    } catch {
        $thrown = $true
        if ($_.Exception.Message -notlike $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got '$($_.Exception.Message)'."
        }
    }

    if (-not $thrown) {
        throw "Expected an error matching '$MessagePattern'."
    }
}

$defaultRef = "Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main"
$groupRef = "Azure/example/.github/workflows/terraform-module.yml@refs/heads/release"
$teamMappings = @(
    [pscustomobject]@{
        name = "test-contributors"
        repositoryGroups = @("all")
    },
    [pscustomobject]@{
        name = "test-readers"
        repositoryGroups = @("all")
    }
)

$rootConfig = [pscustomobject]@{
    repositoryGroups = @()
    teamMappings = $teamMappings
    workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
        jobWorkflowRef = $defaultRef
    }
}
$rootSettings = Resolve-RepositorySettings -repositoryConfig $rootConfig -repoId "unlisted-repository"
Assert-Equal $defaultRef $rootSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "Root OIDC subject default was not applied."

$overrideConfig = [pscustomobject]@{
    repositoryGroups = @(
        [pscustomobject]@{
            name = "override"
            managedFilesOrder = 10
            repositories = @("overridden-repository")
            workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
                jobWorkflowRef = $groupRef
            }
        }
    )
    teamMappings = $teamMappings
    workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
        jobWorkflowRef = $defaultRef
    }
}
$overrideSettings = Resolve-RepositorySettings -repositoryConfig $overrideConfig -repoId "overridden-repository"
Assert-Equal $groupRef $overrideSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "Repository-group OIDC subject override did not win."

$actualConfigPath = Join-Path $PSScriptRoot ".." "repository-config" "config.json"
$actualConfig = Get-Content -Path $actualConfigPath -Raw | ConvertFrom-Json
$configuredRepositories = @(
    $actualConfig.repositoryGroups |
        ForEach-Object { $_.repositories } |
        Select-Object -Unique
)
$configuredRepositories += "unlisted-repository"
foreach ($repository in $configuredRepositories) {
    $actualSettings = Resolve-RepositorySettings -repositoryConfig $actualConfig -repoId $repository
    Assert-Equal $defaultRef $actualSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "The checked-in OIDC subject is incorrect for '$repository'."
}

Assert-Throws -MessagePattern "Repository config root sets unsupported*" -Action {
    $invalidKeyConfig = [pscustomobject]@{
        repositoryGroups = @()
        teamMappings = $teamMappings
        workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
            unsupported = "value"
        }
    }
    Resolve-RepositorySettings -repositoryConfig $invalidKeyConfig -repoId "repository"
}

Assert-Throws -MessagePattern "workloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef must use the form*" -Action {
    $invalidRefConfig = [pscustomobject]@{
        repositoryGroups = @()
        teamMappings = $teamMappings
        workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
            jobWorkflowRef = "Azure/example/.github/workflows/terraform-module.yml@main"
        }
    }
    Resolve-RepositorySettings -repositoryConfig $invalidRefConfig -repoId "repository"
}

Assert-Throws -MessagePattern "workloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef must use the form*" -Action {
    $invalidWorkflowConfig = [pscustomobject]@{
        repositoryGroups = @()
        teamMappings = $teamMappings
        workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
            jobWorkflowRef = "not-a-workflow@refs/heads/main"
        }
    }
    Resolve-RepositorySettings -repositoryConfig $invalidWorkflowConfig -repoId "repository"
}

$shaRef = "Azure/example/.github/workflows/terraform-module.yaml@0123456789abcdef0123456789abcdef01234567"
$shaConfig = [pscustomobject]@{
    repositoryGroups = @()
    teamMappings = $teamMappings
    workloadIdentityFederationSubjectClaimOverrides = [pscustomobject]@{
        jobWorkflowRef = $shaRef
    }
}
$shaSettings = Resolve-RepositorySettings -repositoryConfig $shaConfig -repoId "repository"
Assert-Equal $shaRef $shaSettings.WorkloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"] "A valid workflow SHA ref was rejected."

Write-Host "Repository configuration tests passed."
