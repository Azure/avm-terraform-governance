# Removes the legacy classic branch-protection rule (the older
# `repos/{owner}/{repo}/branches/{branch}/protection` REST resource) from a
# target repository if one is present.
#
# Background: every AVM repository is supposed to be governed exclusively by
# the rulesets defined in `repository_sync/modules/github/github.rulesets.tf`.
# A handful of repos still carry an older "Branch protection rule" that
# predates the ruleset migration; those rules silently shadow the rulesets
# (e.g. by enforcing required reviews that the rulesets already enforce, or
# by allowing bypasses the rulesets disallow) and need to be removed.
#
# Plan mode logs the detected rule with `[PLAN]` and never deletes. Apply
# mode logs and then issues a `DELETE` against the same endpoint (204 = ok,
# 404 = already gone in a race).
#
# Returns:
#   @{
#     IssueLog = updated issue log
#     Removed  = $true if a legacy rule was found and deleted, $false otherwise
#   }

function Remove-LegacyBranchProtection {
    param(
        [string]$orgAndRepoName,
        [string]$defaultBranch,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog = $issueLog
        Removed  = $false
    }

    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        Write-Warning "$modeTag No default branch supplied for $orgAndRepoName; skipping legacy branch-protection check."
        return $result
    }

    $endpoint = "repos/$orgAndRepoName/branches/$defaultBranch/protection"

    # `gh api` exits non-zero on 4xx, so a 404 (no protection rule present)
    # is the common-case "no-op" path we have to swallow. Capture stderr so
    # we can distinguish the 404 from a genuine error.
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $null = gh api $endpoint 2>$stderrFile
        $exit = $LASTEXITCODE
        $stderr = ""
        if (Test-Path $stderrFile) { $stderr = (Get-Content -Path $stderrFile -Raw) }

        if ($exit -eq 0) {
            # 200 OK -> a classic branch-protection rule exists.
            Write-Host "$modeTag $orgAndRepoName has a legacy classic branch-protection rule on '$defaultBranch'." -ForegroundColor Yellow

            if ($planOnly) {
                Write-Host "$modeTag Plan mode is enabled; not deleting the legacy rule."
                return $result
            }

            $deleteStderr = [System.IO.Path]::GetTempFileName()
            try {
                $null = gh api $endpoint --method DELETE 2>$deleteStderr
                $deleteExit = $LASTEXITCODE
                if ($deleteExit -ne 0) {
                    $deleteErr = ""
                    if (Test-Path $deleteStderr) { $deleteErr = (Get-Content -Path $deleteStderr -Raw) }
                    throw "gh api DELETE $endpoint exited $deleteExit : $deleteErr"
                }
                Write-Host "  Deleted legacy branch-protection rule on $orgAndRepoName/$defaultBranch." -ForegroundColor Green
                $result.Removed = $true
            } finally {
                Remove-Item -Path $deleteStderr -Force -ErrorAction SilentlyContinue
            }
        } elseif ($stderr -match "HTTP 404" -or $stderr -match "Branch not protected") {
            # No classic branch-protection rule present. Expected case.
            Write-Host "$modeTag $orgAndRepoName has no legacy classic branch-protection rule on '$defaultBranch'."
        } else {
            throw "gh api $endpoint exited $exit : $stderr"
        }
    } catch {
        Write-Warning "  Failed to check/remove legacy branch protection for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "legacy-branch-protection-cleanup-failed" `
            -message "Failed to check or remove legacy classic branch-protection on $orgAndRepoName/$defaultBranch." `
            -data $null `
            -issueLog $result.IssueLog
    } finally {
        Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
    }

    return $result
}
