# Removes deprecated files from a target repository before any Terraform
# step. Intersects the deprecated-paths list against the repo's
# default-branch tree, then either logs `[PLAN]` matches (when planOnly is
# `$true`) or shallow-clones the repo and pushes a single
# `chore: remove deprecated files [skip ci]` commit (when planOnly is
# `$false`).
#
# Returns:
#   @{
#     IssueLog     = updated issue log
#     DeletedPaths = paths that were actually removed (empty in plan mode,
#                    or if nothing matched, or if the push failed). The
#                    import bootstrap uses this to filter the cached tree so
#                    it does not try to import a file that was just deleted.
#   }

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

function Remove-DeprecatedRepoFiles {
    param(
        [string]$orgAndRepoName,
        [string[]]$deprecatedPaths,
        [hashtable]$repoTree,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog     = $issueLog
        DeletedPaths = @()
    }

    if (!$repoTree -or !$repoTree.Success) {
        Write-Warning "$modeTag No repo tree available for $orgAndRepoName; skipping deprecated-files cleanup."
        return $result
    }

    $defaultBranch = $repoTree.DefaultBranch
    $matches = @(Get-MatchingDeprecatedPaths -candidatePaths $deprecatedPaths -repoFilePaths $repoTree.BlobPaths)

    if ($matches.Count -eq 0) {
        Write-Host "$modeTag No deprecated files present in $orgAndRepoName; nothing to remove."
        return $result
    }

    Write-Host "$modeTag $orgAndRepoName (default_branch=$defaultBranch) - $($matches.Count) deprecated path(s) to remove:" -ForegroundColor Cyan
    foreach ($m in $matches) {
        Write-Host "$modeTag   $orgAndRepoName :: $m"
    }

    if ($planOnly) {
        Write-Host "$modeTag Plan mode is enabled; not deleting deprecated files."
        return $result
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-cleanup-" + [System.Guid]::NewGuid().ToString())
    $commitAuthorName = "azure-verified-modules[bot]"
    $commitAuthorEmail = "1049636+azure-verified-modules[bot]@users.noreply.github.com"
    $commitMessage = "chore: remove deprecated files [skip ci]"

    try {
        # Register gh as git's credential helper so the clone/push below
        # authenticate via $env:GH_TOKEN without ever embedding the token
        # in a URL (which would leak into process listings, git remote
        # config, and reflogs).
        gh auth setup-git
        if ($LASTEXITCODE -ne 0) { throw "gh auth setup-git exited $LASTEXITCODE" }

        Write-Host "  Cloning $orgAndRepoName into $tempDir..." -ForegroundColor DarkGray
        gh repo clone $orgAndRepoName $tempDir -- --quiet --depth 1 --branch $defaultBranch
        if ($LASTEXITCODE -ne 0) { throw "gh repo clone exited $LASTEXITCODE" }

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
                $result.DeletedPaths = $matches
            }
        } finally {
            Pop-Location
        }
    } catch {
        Write-Warning "  Failed to remove deprecated files from $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "deprecated-files-cleanup-failed" -message "Failed to remove deprecated files from $orgAndRepoName." -data ($matches -join ", ") -issueLog $result.IssueLog
    } finally {
        if (Test-Path $tempDir) {
            try {
                # Git on Windows often marks .git/objects/pack files as
                # read-only; clear that before removing so cleanup actually
                # succeeds.
                Get-ChildItem -Path $tempDir -Recurse -Force | ForEach-Object {
                    try { $_.Attributes = "Normal" } catch { }
                }
                Remove-Item -Recurse -Force $tempDir
            } catch {
                Write-Warning "  Failed to clean up $tempDir : $_"
            }
        }
    }

    return $result
}
