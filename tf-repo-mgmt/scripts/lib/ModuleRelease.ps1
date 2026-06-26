# Module release helpers used by the module-release workflow.
#
# These functions patch-release AVM module repositories that already have a
# published release on the Terraform Registry. The Registry auto-publishes a
# new version whenever a tag is created, so "releasing" here is simply
# creating a GitHub release (which tags the target branch HEAD).

# Self-sufficient when dot-sourced standalone (for example by module-pre-commit
# and module-release, which load only this file): pull in the retry helpers if
# Invoke-WithRetry is not already available.
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "RetryHelpers.ps1")
}

# Compute the next semantic version from a current tag, preserving any
# leading "v" (e.g. "v1.2.3" -> "v1.2.4", "1.2.3" -> "1.3.0").
#
# This is a pure function with no side effects so it can be sanity-checked in
# isolation. Throws if the current version is not a 3-part numeric semver.
function Get-NextSemanticVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,
        [ValidateSet("major", "minor", "patch")]
        [string]$Bump = "patch"
    )

    $prefix = ""
    $version = $CurrentVersion
    if ($version.StartsWith("v")) {
        $prefix = "v"
        $version = $version.Substring(1)
    }

    $parts = $version.Split(".")
    if ($parts.Count -ne 3) {
        throw "Cannot parse semantic version '$CurrentVersion'; expected MAJOR.MINOR.PATCH."
    }

    $major = 0; $minor = 0; $patch = 0
    if (-not [int]::TryParse($parts[0], [ref]$major) -or
        -not [int]::TryParse($parts[1], [ref]$minor) -or
        -not [int]::TryParse($parts[2], [ref]$patch)) {
        throw "Cannot parse semantic version '$CurrentVersion'; all parts must be integers."
    }

    switch ($Bump) {
        "major" { $major++; $minor = 0; $patch = 0 }
        "minor" { $minor++; $patch = 0 }
        "patch" { $patch++ }
    }

    return "$prefix$major.$minor.$patch"
}

# Append a single markdown line to the GitHub Actions step summary, when one
# is available (it is only present inside a workflow run).
function Add-ModuleReleaseStepSummary {
    param(
        [string]$Line,
        [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
    )

    if ($StepSummaryPath) {
        Add-Content -Path $StepSummaryPath -Value $Line
    }
}

# Patch-release a single module repository.
#
# Behaviour mirrors the original inline implementation:
#   1. Resolve the latest published release tag. Modules that have never been
#      released are skipped (this workflow only patches already-released
#      modules).
#   2. Skip when the target branch has no commits beyond that tag.
#   3. Compute the next semantic version (preserving any leading "v").
#   4. When -DryRun, only log what would be released.
#   5. Otherwise create the GitHub release with generated notes; the Terraform
#      Registry auto-publishes the new version from the tag.
#
# Returns a result object describing the action taken:
#   @{ Action = "skipped-no-release" | "skipped-no-commits" | "dry-run" | "released";
#      RepoFullName; LatestVersion; NextVersion; AheadBy }
function Publish-ModuleRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoFullName,
        [ValidateSet("major", "minor", "patch")]
        [string]$Bump = "patch",
        [bool]$DryRun = $true,
        [string]$TargetBranch = "main"
    )

    $result = @{
        Action        = $null
        RepoFullName  = $RepoFullName
        LatestVersion = $null
        NextVersion   = $null
        AheadBy       = 0
    }

    # Resolve the latest published release. `gh release view` exits non-zero
    # when the repository has no releases at all; that is an expected "never
    # released" signal (not a transient failure), so we return empty and only
    # retry genuine transient API errors.
    $latest = Invoke-WithRetry -OperationName "gh release view ($RepoFullName)" -ScriptBlock {
        $cap = Invoke-NativeCapture { gh release view --repo $RepoFullName --json tagName -q .tagName }
        if ($cap.Code -ne 0) {
            if ($cap.All -match '(?i)release not found|no release|not found|HTTP 404') {
                return ""
            }
            throw "gh release view exited $($cap.Code) : $($cap.All)"
        }
        $cap.StdOut.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($latest)) {
        Write-Host "::notice title=$RepoFullName::No existing release found - skipping (this workflow only patches already-released modules)."
        Add-ModuleReleaseStepSummary -Line "- :fast_forward: ``$RepoFullName`` skipped (no existing release)"
        $result.Action = "skipped-no-release"
        return $result
    }
    $latest = $latest.Trim()
    $result.LatestVersion = $latest

    # Skip when the target branch has no commits beyond the latest tag.
    $ahead = Invoke-WithRetry -OperationName "gh api compare $latest...$TargetBranch ($RepoFullName)" -ScriptBlock {
        $cap = Invoke-NativeCapture { gh api "repos/$RepoFullName/compare/$latest...$TargetBranch" -q .ahead_by }
        if ($cap.Code -ne 0) {
            throw "gh api compare exited $($cap.Code) : $($cap.All)"
        }
        $cap.StdOut.Trim()
    }
    $aheadBy = 0
    if (-not [int]::TryParse(("$ahead").Trim(), [ref]$aheadBy)) {
        throw "Could not parse ahead_by '$ahead' for $RepoFullName."
    }
    $result.AheadBy = $aheadBy

    if ($aheadBy -eq 0) {
        Write-Host "::notice title=$RepoFullName::No new commits since $latest - skipping."
        Add-ModuleReleaseStepSummary -Line "- :fast_forward: ``$RepoFullName`` skipped (no new commits since ``$latest``)"
        $result.Action = "skipped-no-commits"
        return $result
    }

    $next = Get-NextSemanticVersion -CurrentVersion $latest -Bump $Bump
    $result.NextVersion = $next

    if ($DryRun) {
        Write-Host "::notice title=$RepoFullName::[dry-run] would release $next (was $latest, $aheadBy new commit(s))."
        Add-ModuleReleaseStepSummary -Line "- :test_tube: ``$RepoFullName`` dry-run -> would release ``$next`` (was ``$latest``, $aheadBy new commit(s))"
        $result.Action = "dry-run"
        return $result
    }

    # Creating the release tags the target branch HEAD; the Terraform Registry
    # auto-publishes the new version from the tag. Retry transient failures; if
    # a prior attempt actually created the release before a transient error was
    # reported, the "already exists" response is treated as success so we don't
    # surface a false failure.
    Invoke-WithRetry -OperationName "gh release create $next ($RepoFullName)" -ScriptBlock {
        $cap = Invoke-NativeCapture { gh release create $next --repo $RepoFullName --target $TargetBranch --title $next --generate-notes }
        if ($cap.Code -ne 0) {
            if ($cap.All -match '(?i)already exists|already_exists') {
                Write-Host "Release $next already exists for $RepoFullName; treating as success."
                return
            }
            throw "gh release create $next exited $($cap.Code) : $($cap.All)"
        }
    } | Out-Null

    Write-Host "::notice title=$RepoFullName::Released $next (was $latest, $aheadBy new commit(s))."
    Add-ModuleReleaseStepSummary -Line "- :rocket: ``$RepoFullName`` released ``$next`` (was ``$latest``, $aheadBy new commit(s))"
    $result.Action = "released"
    return $result
}
