# Shared helpers for opening (and optionally merging) AVM-bot pull requests.
#
# These were extracted from RepoFilesSync.ps1 so the same "commit -> push ->
# open PR -> admin-merge" engine can be reused by every workflow that raises a
# bot PR (managed-file sync, CODEOWNERS sync, pre-commit backfill, ...).
#
# Design contract:
#   * The CALLER owns the working tree. The caller must clone/checkout the
#     target repository and `cd` into it (or pass -WorkingDirectory) before
#     calling Submit-AvmBotPullRequest, and is responsible for any cleanup.
#   * The CALLER owns staging when it needs precise control over the index
#     (for example RepoFilesSync stamps the executable bit with
#     `git update-index --chmod`). Such callers stage before calling and do
#     NOT pass -StageAll. Callers that just want "everything that changed"
#     (for example the pre-commit backfill) pass -StageAll and the helper
#     runs `git add -A`.

$avmBotName = "azure-verified-modules[bot]"
$avmBotEmail = "1049636+azure-verified-modules[bot]@users.noreply.github.com"

# Open a pull request from the current (or supplied) working tree.
#
# Returns a result object:
#   @{ Changed = [bool]; PrUrl = <string|null>; Merged = [bool] }
# Changed is $false (and no PR is opened) when the tree has no changes.
function Submit-AvmBotPullRequest {
    param(
        [Parameter(Mandatory = $true)][string]$OrgAndRepoName,
        [Parameter(Mandatory = $true)][string]$BaseBranch,
        [Parameter(Mandatory = $true)][string]$BranchName,
        [Parameter(Mandatory = $true)][string]$CommitMessage,
        [Parameter(Mandatory = $true)][string]$PrTitle,
        [string]$PrBody = "",
        [string]$WorkingDirectory,
        [string]$MergeSubject,
        [string]$BotName = $avmBotName,
        [string]$BotEmail = $avmBotEmail,
        [switch]$StageAll,
        [switch]$Merge,
        [switch]$MergeMustSucceed,
        [string]$CloseOlderWithTitlePrefix,
        [switch]$SkipGitAuthSetup
    )

    $result = @{ Changed = $false; PrUrl = $null; Merged = $false }

    $pushedLocation = $false
    if ($WorkingDirectory) {
        Push-Location $WorkingDirectory
        $pushedLocation = $true
    }

    try {
        # Register gh as git's credential helper so push authenticates via
        # $env:GH_TOKEN without ever embedding the token in a URL (which would
        # leak into process listings, git remote config, and reflogs).
        if (-not $SkipGitAuthSetup) {
            gh auth setup-git
            if ($LASTEXITCODE -ne 0) { throw "gh auth setup-git exited $LASTEXITCODE" }
        }

        # `git status --porcelain` reports untracked files too, so this guard
        # works whether or not the caller has already staged.
        $status = git status --porcelain
        if ([string]::IsNullOrWhiteSpace($status)) {
            Write-Host "  No changes to commit for $OrgAndRepoName; skipping PR."
            return $result
        }

        git checkout -q -b $BranchName
        if ($LASTEXITCODE -ne 0) { throw "git checkout -b $BranchName exited $LASTEXITCODE" }

        if ($StageAll) {
            git add -A
            if ($LASTEXITCODE -ne 0) { throw "git add -A exited $LASTEXITCODE" }
        }

        git -c "user.name=$BotName" -c "user.email=$BotEmail" commit -q -m $CommitMessage
        if ($LASTEXITCODE -ne 0) { throw "git commit exited $LASTEXITCODE" }

        git push --quiet --set-upstream origin $BranchName
        if ($LASTEXITCODE -ne 0) { throw "git push exited $LASTEXITCODE" }

        Write-Host "  Pushed branch $BranchName; opening PR..." -ForegroundColor DarkGray
        $prCreateOutput = gh pr create `
            --repo $OrgAndRepoName `
            --base $BaseBranch `
            --head $BranchName `
            --title $PrTitle `
            --body $PrBody
        if ($LASTEXITCODE -ne 0) { throw "gh pr create exited $LASTEXITCODE" }

        # `gh pr create` normally writes a single line (the PR URL) to stdout,
        # but defend against future status lines by taking the last non-empty
        # line.
        $prUrl = (@($prCreateOutput) | Where-Object { $_ -and $_.ToString().Trim() -ne "" } | Select-Object -Last 1).ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($prUrl)) { throw "gh pr create returned no URL on stdout" }
        Write-Host "  Opened PR: $prUrl" -ForegroundColor DarkGray

        $result.Changed = $true
        $result.PrUrl = $prUrl

        if ($Merge) {
            # `--admin` lets the AVM GitHub App use its ruleset bypass to merge
            # immediately without waiting for required checks. A forced subject
            # (with empty body) is supplied when the caller wants the squashed
            # commit to carry a specific message (for example `[skip ci]`).
            $mergeArgs = @("--repo", $OrgAndRepoName, "--squash", "--admin", "--delete-branch")
            if ($MergeSubject) {
                $mergeArgs += @("--subject", $MergeSubject, "--body", "")
            }
            gh pr merge $prUrl @mergeArgs
            if ($LASTEXITCODE -ne 0) {
                if ($MergeMustSucceed) {
                    throw "gh pr merge exited $LASTEXITCODE"
                }
                Write-Warning "  Failed to merge PR for $OrgAndRepoName; leaving it open."
            }
            else {
                $result.Merged = $true
                Write-Host "  Merged PR for $OrgAndRepoName." -ForegroundColor Green
            }
        }

        # Close any older open bot PRs (same title prefix) so only the latest
        # backfill PR remains. The just-opened PR is excluded; when it was
        # merged above it is no longer open anyway.
        if ($CloseOlderWithTitlePrefix) {
            $openPrsJson = gh pr list --repo $OrgAndRepoName --state open --base $BaseBranch --json number,url,title
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($openPrsJson)) {
                $openPrs = $openPrsJson | ConvertFrom-Json
                foreach ($openPr in $openPrs) {
                    if ($openPr.url -eq $prUrl) { continue }
                    if (-not $openPr.title.StartsWith($CloseOlderWithTitlePrefix)) { continue }
                    Write-Host "  Closing superseded PR $($openPr.url)..." -ForegroundColor DarkGray
                    gh pr close $openPr.number --repo $OrgAndRepoName --delete-branch
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "  Failed to close superseded PR $($openPr.url)."
                    }
                }
            }
        }

        return $result
    }
    finally {
        if ($pushedLocation) { Pop-Location }
    }
}

# Approve and squash-merge all open bot pull requests in a repository that
# match a search query (used by the admin pre-commit merge workflow). Merge
# failures are non-fatal so one bad repo does not block the rest.
#
# Returns @{ Merged = <string[] of merged PR urls> }.
function Merge-AvmBotPullRequests {
    param(
        [Parameter(Mandatory = $true)][string]$OrgAndRepoName,
        [string]$AppSlug = "azure-verified-modules",
        [string]$SearchQuery = "chore: pre-commit",
        [switch]$Approve,
        [string]$ApproveBody = "Approved by admin-merge-pre-commit-prs workflow."
    )

    $prsJson = gh pr list --repo $OrgAndRepoName --state open --search $SearchQuery --app $AppSlug --json number,url,title
    if ($LASTEXITCODE -ne 0) {
        throw "gh pr list exited $LASTEXITCODE for $OrgAndRepoName."
    }

    $merged = @()
    if ([string]::IsNullOrWhiteSpace($prsJson)) {
        Write-Host "  No matching open PRs for $OrgAndRepoName."
        return @{ Merged = $merged }
    }

    $prs = @($prsJson | ConvertFrom-Json)
    if ($prs.Count -eq 0) {
        Write-Host "  No matching open PRs for $OrgAndRepoName."
        return @{ Merged = $merged }
    }

    foreach ($pr in $prs) {
        Write-Host "  Processing PR #$($pr.number) ($($pr.url)) in $OrgAndRepoName..."
        if ($Approve) {
            gh pr review $pr.number --repo $OrgAndRepoName --approve --body $ApproveBody
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  Failed to approve PR #$($pr.number) for $OrgAndRepoName; skipping merge."
                continue
            }
        }
        gh pr merge $pr.number --repo $OrgAndRepoName --squash --delete-branch
        if ($LASTEXITCODE -eq 0) {
            $merged += $pr.url
            Write-Host "  Merged PR #$($pr.number) for $OrgAndRepoName." -ForegroundColor Green
        }
        else {
            Write-Warning "  Failed to merge PR #$($pr.number) for $OrgAndRepoName."
        }
    }

    return @{ Merged = $merged }
}
