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
        $teamMappings = $repositoryConfig.teamMappings | Where-Object { $_.repositoryGroups -contains $repositoryGroupName }
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

    # Collect the managed-files overlay set declared on any matching
    # repository group (e.g. `alz` for the azure-landing-zones group). At
    # most one distinct value is allowed; conflicting overlays across groups
    # for the same repo are a configuration error.
    $managedFilesAdditionalValues = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains "managedFilesAdditional" -and $repositoryGroup.managedFilesAdditional) {
            $managedFilesAdditionalValues += $repositoryGroup.managedFilesAdditional
        }
    }
    $managedFilesAdditionalValues = @($managedFilesAdditionalValues | Select-Object -Unique)
    if ($managedFilesAdditionalValues.Count -gt 1) {
        Write-Error "Repository '$repoId' belongs to multiple repository groups that declare conflicting 'managedFilesAdditional' overlay sets: $($managedFilesAdditionalValues -join ', '). At most one is allowed."
        exit 1
    }
    $managedFilesAdditional = if ($managedFilesAdditionalValues.Count -eq 1) { $managedFilesAdditionalValues[0] } else { "" }

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

    return @{
        RepositoryGroups              = $repositoryGroups
        RepositoryGroupNames          = $repositoryGroupNames
        Teams                         = $teams
        CodeOwnersDefaultTeams        = $codeOwnersDefaultTeams
        CodeOwnersFileProtectionTeams = $codeOwnersFileProtectionTeams
        Topics                        = $repositoryTopics
        ManagedFilesAdditional        = $managedFilesAdditional
        ExcludedManagedFiles          = $excludedManagedFiles
    }
}
