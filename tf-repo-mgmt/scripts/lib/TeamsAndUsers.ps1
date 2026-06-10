# Reconciliation of GitHub teams and direct collaborators against the
# configured team mapping for the repository.

# Verifies every team referenced by the repo's config actually exists in the
# org, and returns a map keyed by team slug that the github Terraform module
# consumes via `var.github_teams`.
#
# Returns @{ GithubTeams = $hashtable; IssueLog = $array }.
function Resolve-GitHubTeams {
    param(
        [string]$orgName,
        [string]$orgAndRepoName,
        [array]$teams,
        [array]$issueLog
    )

    $githubTeams = @{}

    foreach ($team in $teams) {
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

        if (!$existingTeam.success) {
            Write-Warning "Failed to check if team exists: $($teamName)."
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-check-failed" -message "Failed to check if team $teamName exists." -data $null -issueLog $issueLog
            exit 1
        }

        $teamExists = $existingTeam.output.slug -and $existingTeam.output.slug -eq $teamName

        if (!$teamExists) {
            Write-Warning "Team does not exist: $($teamName)"
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-missing" -message "Team $teamName does not exist." -data $teamName -issueLog $issueLog
        } else {
            Write-Host "Team exists: $($teamName)"
            $githubTeams[$teamName] = @{
                slug                         = $teamName
                description                  = $teamDescription
                repository_access_permission = $team.repositoryPermission
                environment_approval         = $team.environmentApproval
                members_are_team_maintainers = $team.membersAreTeamMaintainers
            }
        }
    }

    return @{
        GithubTeams = $githubTeams
        IssueLog    = $issueLog
    }
}

# Removes direct (non-team) collaborators from the repo. Module owners that
# are JIT-elevated are skipped unless `-forceUserRemoval` is true.
function Remove-DirectCollaborators {
    param(
        [string]$orgAndRepoName,
        [object]$moduleMetaData,
        [bool]$planOnly,
        [bool]$forceUserRemoval,
        [array]$issueLog
    )

    $allowedUsers = @()
    if ($moduleMetaData) {
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

    if (!$repoUsers.success) {
        Write-Warning "Failed to get repository users for: $orgAndRepoName. Skipping."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-users-fetch-failed" -message "Failed to fetch repository users for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    Write-Host "Found $($repoUsers.output.Count) users in repository: $orgAndRepoName"
    foreach ($user in $repoUsers.output) {
        $userLogin = $user.login

        if ($allowedUsers -contains $userLogin -and $user.role_name -eq "admin") {
            Write-Warning "User has direct access to $orgAndRepoName, but is an owner or AVM core team member and has admin access. They are likely JIT elevated, so skipping the error: $($userLogin)"
            if ($forceUserRemoval) {
                Write-Warning "Force user removal is enabled, removing access now: $($userLogin) - role: $($user.role_name)"
                $issueLog = Invoke-CollaboratorRemoval -orgAndRepoName $orgAndRepoName -userLogin $userLogin -planOnly $planOnly -issueLog $issueLog
            }
        } else {
            Write-Warning "User has direct access to $orgAndRepoName, but AVM repos cannot have direct user access outside of JIT, removing access now: $($userLogin) - role: $($user.role_name)"
            $issueLog = Invoke-CollaboratorRemoval -orgAndRepoName $orgAndRepoName -userLogin $userLogin -planOnly $planOnly -issueLog $issueLog
        }
    }

    return $issueLog
}

# Helper for `Remove-DirectCollaborators` so both code paths share the same
# planOnly handling.
function Invoke-CollaboratorRemoval {
    param(
        [string]$orgAndRepoName,
        [string]$userLogin,
        [bool]$planOnly,
        [array]$issueLog
    )

    if ($planOnly) {
        Write-Host "Would run command: gh api 'repos/$orgAndRepoName/collaborators/$($userLogin)' -X DELETE"
        return $issueLog
    }

    $result = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/collaborators/$($userLogin)", "-X", "DELETE")
                OutputLog = "remove-user.json"
            }
        ) `
        -printOutputOnError

    if (!$result.success) {
        Write-Warning "Failed to remove user: $($userLogin) from repository: $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "user-removal-failed" -message "Failed to remove user $($userLogin) from repository $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    return $issueLog
}

# Removes any team that has access to the repo but is not in the configured
# `$githubTeams` map. Teams in `$extraTeamsToIgnore` (e.g. `security`) are
# left in place.
function Remove-UnmanagedRepositoryTeams {
    param(
        [string]$orgName,
        [string]$orgAndRepoName,
        [hashtable]$githubTeams,
        [string[]]$extraTeamsToIgnore,
        [bool]$planOnly,
        [array]$issueLog
    )

    $repoTeams = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/teams", "--paginate")
                OutputLog = "repo-teams.json"
            }
        ) `
        -returnOutputParsedFromJson

    if (!$repoTeams.success) {
        Write-Warning "Failed to get repository teams for: $orgAndRepoName. Skipping."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "repo-teams-fetch-failed" -message "Failed to fetch repository teams for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    Write-Host "Found $($repoTeams.output.Count) teams in repository: $orgAndRepoName"
    foreach ($team in $repoTeams.output) {
        $teamName = $team.name
        if ($extraTeamsToIgnore -contains $teamName) {
            Write-Host "Skipping team: $($teamName) as it is in the ignore list."
            continue
        }
        if (!$githubTeams.ContainsKey($teamName)) {
            Write-Warning "Team exists in repository but not in config, will be removed: $($teamName)"
            $teamSlug = $team.slug
            if ($planOnly) {
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

                if (!$result.success) {
                    Write-Warning "Failed to remove team: $($teamName) from repository: $orgAndRepoName. Exiting."
                    $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "team-removal-failed" -message "Failed to remove team $($teamName) from repository $orgAndRepoName." -data $null -issueLog $issueLog
                    exit 1
                }
            }
        }
    }

    return $issueLog
}
