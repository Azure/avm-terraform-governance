# Removes any repository-level rulesets from a target repository that were
# not created by our Terraform automation.
#
# Background: `repository_sync/modules/github/github.rulesets.tf` is the
# single source of truth for repository-level rulesets on every AVM repo.
# Three rulesets are managed there:
#   * "Azure Verified Modules"             (target=branch)
#   * "Only allow v tags"                  (target=tag)
#   * "Must not delete/update version tags" (target=tag)
# Anything else that shows up at the repository scope was created manually
# (or by some other tool) outside our automation, and silently shadows or
# weakens the policies we ship. This module enumerates repository-scoped
# rulesets and deletes anything whose `name` is not in the managed list.
#
# Org-level / enterprise-level rulesets are deliberately NOT touched:
#   * The list endpoint is called with `includes_parents=false` so the
#     response only contains rulesets defined ON this repository.
#   * Each candidate is additionally double-checked against
#     `source_type == "Repository"` before we DELETE it.
# So the org-wide `azure-production-ruleset` (and any future org/enterprise
# rulesets) are out of scope and will never be enumerated, let alone
# deleted, by this function.
#
# Endpoints:
#   GET    /repos/{owner}/{repo}/rulesets?includes_parents=false
#   DELETE /repos/{owner}/{repo}/rulesets/{ruleset_id}
# Both require the "Administration" repo permission, which the AVM bot has
# on every repo it governs.
#
# Plan mode logs each unmanaged ruleset with `[PLAN]` and never deletes.
# Apply mode logs and then issues a `DELETE` against the ruleset (204 = ok,
# 404 = already gone in a race).
#
# Returns:
#   @{
#     IssueLog       = updated issue log
#     RemovedCount   = number of unmanaged rulesets deleted (0 in plan mode)
#     DetectedNames  = string[] of unmanaged ruleset names that were
#                      detected (regardless of plan vs apply)
#   }

function Remove-UnmanagedRulesets {
    param(
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [array]$issueLog,
        [string[]]$managedRulesetNames = @(
            "Azure Verified Modules",
            "Only allow v tags",
            "Must not delete/update version tags"
        )
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog      = $issueLog
        RemovedCount  = 0
        DetectedNames = @()
    }

    # `includes_parents=false` restricts the response to rulesets defined
    # ON the repository itself, so org/enterprise rulesets are never even
    # enumerated here. `--paginate` covers the unlikely case of >30
    # repo-level rulesets without us having to walk pages manually.
    $listEndpoint = "repos/$orgAndRepoName/rulesets?includes_parents=false&per_page=100"

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $listOutput = gh api --paginate $listEndpoint 2>$stderrFile
        $exit = $LASTEXITCODE
        $stderr = ""
        if (Test-Path $stderrFile) { $stderr = (Get-Content -Path $stderrFile -Raw) }

        if ($exit -ne 0) {
            throw "gh api $listEndpoint exited $exit : $stderr"
        }

        $rulesets = @()
        if (-not [string]::IsNullOrWhiteSpace($listOutput)) {
            try {
                # `gh api --paginate` concatenates JSON arrays for each page
                # by emitting them back-to-back; `ConvertFrom-Json` on the
                # whole blob does NOT handle that. The simplest robust
                # parse is to wrap each top-level JSON array in a single
                # outer array via a regex on the joining `][`, then merge.
                $joined = ($listOutput -join "`n").Trim()
                if ($joined.StartsWith("[")) {
                    $wrapped = "[" + ($joined -replace "\]\s*\[", ",") + "]"
                    # `$wrapped` is now a single JSON array of objects.
                    # ConvertFrom-Json returns a single object for a 1-elem
                    # array, so coerce to array with `@(...)`.
                    $rulesets = @($wrapped | ConvertFrom-Json)
                }
            } catch {
                throw "Failed to parse rulesets response for $orgAndRepoName : $_"
            }
        }

        if ($rulesets.Count -eq 0) {
            Write-Host "$modeTag $orgAndRepoName has no repository-level rulesets."
            return $result
        }

        $managedSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$managedRulesetNames,
            [System.StringComparer]::Ordinal
        )

        $unmanaged = @($rulesets | Where-Object {
            # Belt-and-braces: even with `includes_parents=false`, double
            # check the source so we never DELETE something that does not
            # belong to this repo. Skip rulesets with no name (defensive).
            $_.source_type -eq "Repository" `
                -and -not [string]::IsNullOrWhiteSpace($_.name) `
                -and -not $managedSet.Contains([string]$_.name)
        })

        if ($unmanaged.Count -eq 0) {
            Write-Host "$modeTag $orgAndRepoName has $($rulesets.Count) repository-level ruleset(s); all match the managed set."
            return $result
        }

        $result.DetectedNames = @($unmanaged | ForEach-Object { [string]$_.name })

        foreach ($rs in $unmanaged) {
            $rsName = [string]$rs.name
            $rsId   = [int]$rs.id
            Write-Host "$modeTag $orgAndRepoName has an unmanaged repository ruleset '$rsName' (id=$rsId, target=$($rs.target))." -ForegroundColor Yellow

            if ($planOnly) {
                continue
            }

            $deleteEndpoint = "repos/$orgAndRepoName/rulesets/$rsId"
            $deleteStderr = [System.IO.Path]::GetTempFileName()
            try {
                $null = gh api $deleteEndpoint --method DELETE 2>$deleteStderr
                $deleteExit = $LASTEXITCODE
                if ($deleteExit -ne 0) {
                    $deleteErr = ""
                    if (Test-Path $deleteStderr) { $deleteErr = (Get-Content -Path $deleteStderr -Raw) }

                    # A 404 here just means the ruleset disappeared between
                    # our LIST and DELETE (someone else deleted it, or our
                    # paginated list returned a stale entry). Treat as a
                    # successful no-op so we do not raise a spurious issue.
                    if ($deleteErr -match "HTTP 404") {
                        Write-Host "  Ruleset '$rsName' (id=$rsId) already gone on $orgAndRepoName (HTTP 404)."
                        continue
                    }

                    throw "gh api DELETE $deleteEndpoint exited $deleteExit : $deleteErr"
                }
                Write-Host "  Deleted unmanaged ruleset '$rsName' (id=$rsId) on $orgAndRepoName." -ForegroundColor Green
                $result.RemovedCount++
            } finally {
                Remove-Item -Path $deleteStderr -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Warning "  Failed to check/remove unmanaged rulesets for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "unmanaged-rulesets-cleanup-failed" `
            -message "Failed to check or remove unmanaged repository ruleset(s) on $orgAndRepoName." `
            -data $null `
            -issueLog $result.IssueLog
    } finally {
        Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
    }

    return $result
}
