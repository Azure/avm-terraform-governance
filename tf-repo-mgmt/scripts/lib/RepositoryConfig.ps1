# Resolves the per-repository view of `repository-config/config.json`:
# team mappings, code-owners teams, topics, managed-files overlay/exclusions.
#
# Returns a hashtable so the orchestrator can pull fields by name rather than
# unpacking 8 positional return values.

function Resolve-RepositorySettings {
    param(
        [object]$repositoryConfig,
        [string]$repoId
    )

    $repositoryGroups = $repositoryConfig.repositoryGroups | Where-Object { $_.repositories -contains $repoId }

    $repositoryGroupNames = @($repositoryGroups | ForEach-Object { $_.name })
    $repositoryGroupNames += "all"

    $teams = @()
    foreach ($repositoryGroupName in $repositoryGroupNames) {
        $teamMappings = @($repositoryConfig.teamMappings | Where-Object { $_.repositoryGroups -contains $repositoryGroupName })
        if ($teamMappings.Count -gt 0) {
            $teams += $teamMappings
        }
    }

    # Collect the CODEOWNERS default teams from every repository group that
    # contains this repo. These teams become required reviewers for all files
    # in the repo (e.g. tier 1 modules require review from the engineering
    # owners team).
    $codeOwnersDefaultTeams = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains "codeOwnersTeams" -and $repositoryGroup.codeOwnersTeams) {
            $codeOwnersDefaultTeams += $repositoryGroup.codeOwnersTeams
        }
    }
    $codeOwnersDefaultTeams = @($codeOwnersDefaultTeams | Select-Object -Unique)

    # The teams that protect the CODEOWNERS file itself are global and apply
    # to every repository regardless of tier.
    $codeOwnersFileProtectionTeams = @()
    if ($repositoryConfig.PSObject.Properties.Name -contains "codeOwners" -and $repositoryConfig.codeOwners -and $repositoryConfig.codeOwners.fileProtectionTeams) {
        $codeOwnersFileProtectionTeams = @($repositoryConfig.codeOwners.fileProtectionTeams)
    }

    # Collect repository topics: start from the global default topics and add
    # any topics defined on each matching repository group (e.g.
    # `avm-tier-1`). The result is the authoritative topic list for the
    # repository, so any topic set on the repo that is not in this list will
    # be removed by Terraform.
    $repositoryTopics = @()
    if ($repositoryConfig.PSObject.Properties.Name -contains "topics" -and $repositoryConfig.topics -and $repositoryConfig.topics.default) {
        $repositoryTopics += $repositoryConfig.topics.default
    }
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains "topics" -and $repositoryGroup.topics) {
            $repositoryTopics += $repositoryGroup.topics
        }
    }
    $repositoryTopics = @($repositoryTopics | Select-Object -Unique)

    # Collect and order the managed-files overlay sets declared on any matching
    # repository group (e.g. `alz` for the azure-landing-zones group). Lower
    # orders are applied first, so a higher-order overlay wins for duplicate
    # paths. This ordering is mirrored in Avm.Authoring's
    # Sync-AvmManagedFile.ps1 and the two implementations must not diverge.
    $overlayEntries = @()
    $declarationIndex = 0
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'managedFilesAdditional' -and $repositoryGroup.managedFilesAdditional) {
            $order = 0
            if ($repositoryGroup.PSObject.Properties.Name -contains 'managedFilesOrder' -and $null -ne $repositoryGroup.managedFilesOrder) {
                $order = [int] $repositoryGroup.managedFilesOrder
            }
            foreach ($overlay in @($repositoryGroup.managedFilesAdditional)) {
                $overlayEntries += [pscustomobject]@{
                    Overlay = $overlay
                    Order   = $order
                    Index   = $declarationIndex
                }
            }
        }
        $declarationIndex++
    }

    $managedFilesAdditional = @(
        $overlayEntries |
            Sort-Object -Property Order, Index |
            Select-Object -ExpandProperty Overlay |
            Select-Object -Unique
    )

    # Collect the set of managed files to exclude from the final map for
    # this repository. Excluded files are pulled in from every matching
    # repository group's `excludedManagedFiles` field and de-duplicated. Use
    # this to suppress files that exist in `managed-files/root/` (or in the
    # overlay) but should not be deployed to repositories in this group
    # (e.g. ALZ repos don't ship the generic AVM module issue templates).
    $excludedManagedFiles = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains "excludedManagedFiles" -and $repositoryGroup.excludedManagedFiles) {
            $excludedManagedFiles += @($repositoryGroup.excludedManagedFiles)
        }
    }
    $excludedManagedFiles = @($excludedManagedFiles | Select-Object -Unique)

    # Workload identity federation subject-claim overrides. Root values apply
    # to every repository, and repository groups can override individual keys.
    #
    # Merged per key across every group containing the repo, using the same
    # (managedFilesOrder, declaration index) precedence as managed-files
    # overlays: higher order wins.
    $supportedClaimOverrides = @{
        jobWorkflowRef = "github_job_workflow_ref"
    }

    $claimOverrideEntries = @()
    if ($repositoryConfig.PSObject.Properties.Name -contains "workloadIdentityFederationSubjectClaimOverrides" -and $repositoryConfig.workloadIdentityFederationSubjectClaimOverrides) {
        foreach ($claimOverride in $repositoryConfig.workloadIdentityFederationSubjectClaimOverrides.PSObject.Properties) {
            if (-not $supportedClaimOverrides.ContainsKey($claimOverride.Name)) {
                throw "Repository config root sets unsupported workloadIdentityFederationSubjectClaimOverrides key '$($claimOverride.Name)'. Supported keys: $($supportedClaimOverrides.Keys -join ', ')."
            }
            $claimOverrideEntries += [pscustomobject]@{
                Claim = $claimOverride.Name
                Value = $claimOverride.Value
                Order = [int]::MinValue
                Index = -1
            }
        }
    }

    $claimDeclarationIndex = 0
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains "workloadIdentityFederationSubjectClaimOverrides" -and $repositoryGroup.workloadIdentityFederationSubjectClaimOverrides) {
            $order = 0
            if ($repositoryGroup.PSObject.Properties.Name -contains "managedFilesOrder" -and $null -ne $repositoryGroup.managedFilesOrder) {
                $order = [int]$repositoryGroup.managedFilesOrder
            }
            foreach ($claimOverride in $repositoryGroup.workloadIdentityFederationSubjectClaimOverrides.PSObject.Properties) {
                if (-not $supportedClaimOverrides.ContainsKey($claimOverride.Name)) {
                    throw "Repository group '$($repositoryGroup.name)' sets unsupported workloadIdentityFederationSubjectClaimOverrides key '$($claimOverride.Name)'. Supported keys: $($supportedClaimOverrides.Keys -join ', ')."
                }
                $claimOverrideEntries += [pscustomobject]@{
                    Claim = $claimOverride.Name
                    Value = $claimOverride.Value
                    Order = $order
                    Index = $claimDeclarationIndex
                }
            }
        }
        $claimDeclarationIndex++
    }

    $workloadIdentityFederationSubjectClaimOverrides = @{}
    foreach ($claimOverrideEntry in ($claimOverrideEntries | Sort-Object -Property Order, Index)) {
        $workloadIdentityFederationSubjectClaimOverrides[$claimOverrideEntry.Claim] = $claimOverrideEntry.Value
    }

    # A job_workflow_ref claim always carries a fully-qualified git ref
    # (refs/heads/..., refs/tags/...) or a full commit SHA, even though `uses:`
    # is normally written as `@main`. Fail here rather than at OIDC exchange.
    if ($workloadIdentityFederationSubjectClaimOverrides.ContainsKey("jobWorkflowRef")) {
        $jobWorkflowRefOverride = $workloadIdentityFederationSubjectClaimOverrides["jobWorkflowRef"]
        $jobWorkflowRefPattern = "^[^/\s@]+/[^/\s@]+/\.github/workflows/[^/\s@]+\.ya?ml@(?:refs/[^\s]+|[0-9a-fA-F]{40})$"
        if ($jobWorkflowRefOverride -notmatch $jobWorkflowRefPattern) {
            throw "workloadIdentityFederationSubjectClaimOverrides.jobWorkflowRef must use the form 'owner/repository/.github/workflows/workflow.yml@refs/heads/branch' (a tag ref or full commit SHA is also supported), but was '$jobWorkflowRefOverride'."
        }
    }

    return @{
        RepositoryGroups                                = $repositoryGroups
        RepositoryGroupNames                            = $repositoryGroupNames
        Teams                                           = $teams
        CodeOwnersDefaultTeams                          = $codeOwnersDefaultTeams
        CodeOwnersFileProtectionTeams                   = $codeOwnersFileProtectionTeams
        Topics                                          = $repositoryTopics
        ManagedFilesAdditional                          = $managedFilesAdditional
        ExcludedManagedFiles                            = $excludedManagedFiles
        WorkloadIdentityFederationSubjectClaimOverrides = $workloadIdentityFederationSubjectClaimOverrides
    }
}
