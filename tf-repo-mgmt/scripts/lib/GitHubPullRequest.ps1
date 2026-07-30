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

# Self-sufficient when dot-sourced standalone (for example by
# module-pre-commit, which loads only this file): pull in the retry helpers if
# Invoke-WithRetry is not already available.
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "RetryHelpers.ps1")
}

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
            Invoke-WithRetry -OperationName "gh auth setup-git" -ScriptBlock {
                $cap = Invoke-NativeCapture { gh auth setup-git }
                if ($cap.Code -ne 0) { throw "gh auth setup-git exited $($cap.Code) : $($cap.All)" }
            } | Out-Null
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

        # `git push` is idempotent: a retry after a partially-completed push
        # reports "Everything up-to-date" and exits 0. The captured stderr is
        # included in the thrown message so transport errors (RPC failed, host
        # resolution, 5xx) are recognised as retryable.
        Invoke-WithRetry -OperationName "git push $BranchName ($OrgAndRepoName)" -ScriptBlock {
            $cap = Invoke-NativeCapture { git push --quiet --set-upstream origin $BranchName }
            if ($cap.Code -ne 0) { throw "git push exited $($cap.Code) : $($cap.All)" }
        } | Out-Null

        Write-Host "  Pushed branch $BranchName; opening PR..." -ForegroundColor DarkGray
        # If a transient error is reported after the PR was actually created,
        # a naive retry of `gh pr create` fails with "already exists". That case
        # is recovered by querying the existing PR's URL so the operation reads
        # as success.
        $prUrl = Invoke-WithRetry -OperationName "gh pr create $BranchName ($OrgAndRepoName)" -ScriptBlock {
            $cap = Invoke-NativeCapture {
                gh pr create `
                    --repo $OrgAndRepoName `
                    --base $BaseBranch `
                    --head $BranchName `
                    --title $PrTitle `
                    --body $PrBody
            }
            if ($cap.Code -ne 0) {
                if ($cap.All -match '(?i)already exists') {
                    $viewCap = Invoke-NativeCapture { gh pr view $BranchName --repo $OrgAndRepoName --json url -q .url }
                    if ($viewCap.Code -ne 0) { throw "gh pr view (after already-exists) exited $($viewCap.Code) : $($viewCap.All)" }
                    $recovered = $viewCap.StdOut.Trim()
                    if ([string]::IsNullOrWhiteSpace($recovered)) { throw "gh pr view returned no URL for existing PR on $BranchName" }
                    return $recovered
                }
                throw "gh pr create exited $($cap.Code) : $($cap.All)"
            }
            # `gh pr create` writes the new PR's URL to stdout. Select the line
            # that looks like a PR URL so any informational stdout lines are
            # ignored.
            $created = (@($cap.StdOut -split "`n") | Where-Object { $_ -match '^\s*https?://' } | Select-Object -Last 1)
            if (-not $created) { throw "gh pr create returned no URL on stdout: $($cap.All)" }
            $created.Trim()
        }
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
            try {
                # On retry after a merge that actually succeeded server-side, the
                # PR is no longer open, so "already merged" / "not in the open
                # state" responses are absorbed as success. All other non-zero
                # exits (including transient API errors) throw to drive a retry.
                Invoke-WithRetry -OperationName "gh pr merge ($OrgAndRepoName)" -ScriptBlock {
                    $cap = Invoke-NativeCapture { gh pr merge $prUrl @mergeArgs }
                    if ($cap.Code -ne 0) {
                        if ($cap.All -match '(?i)already merged|has already been merged|not in the open state') {
                            Write-Host "  PR for $OrgAndRepoName already merged; treating as success." -ForegroundColor Green
                            return
                        }
                        throw "gh pr merge exited $($cap.Code) : $($cap.All)"
                    }
                } | Out-Null
                $result.Merged = $true
                Write-Host "  Merged PR for $OrgAndRepoName." -ForegroundColor Green
            }
            catch {
                if ($MergeMustSucceed) {
                    throw
                }
                Write-Warning "  Failed to merge PR for $OrgAndRepoName; leaving it open. $($_.Exception.Message)"
            }
        }

        # Close any older open bot PRs (same title prefix) so only the latest
        # backfill PR remains. The just-opened PR is excluded; when it was
        # merged above it is no longer open anyway. This cleanup is best-effort:
        # transient errors are retried, but a persistent failure only warns
        # rather than failing the whole sync.
        if ($CloseOlderWithTitlePrefix) {
            $openPrsJson = $null
            try {
                $openPrsJson = Invoke-WithRetry -OperationName "gh pr list ($OrgAndRepoName)" -ScriptBlock {
                    $cap = Invoke-NativeCapture { gh pr list --repo $OrgAndRepoName --state open --base $BaseBranch --json number,url,title }
                    if ($cap.Code -ne 0) { throw "gh pr list exited $($cap.Code) : $($cap.All)" }
                    $cap.StdOut
                }
            }
            catch {
                Write-Warning "  Failed to list open PRs for $OrgAndRepoName; skipping cleanup. $($_.Exception.Message)"
            }
            if (-not [string]::IsNullOrWhiteSpace($openPrsJson)) {
                $openPrs = $openPrsJson | ConvertFrom-Json
                foreach ($openPr in $openPrs) {
                    if ($openPr.url -eq $prUrl) { continue }
                    if (-not $openPr.title.StartsWith($CloseOlderWithTitlePrefix)) { continue }
                    Write-Host "  Closing superseded PR $($openPr.url)..." -ForegroundColor DarkGray
                    try {
                        # A retry after a successful close finds the PR already
                        # closed; that signal is absorbed as success.
                        Invoke-WithRetry -OperationName "gh pr close $($openPr.number) ($OrgAndRepoName)" -ScriptBlock {
                            $cap = Invoke-NativeCapture { gh pr close $openPr.number --repo $OrgAndRepoName --delete-branch }
                            if ($cap.Code -ne 0) {
                                if ($cap.All -match '(?i)already closed|not in the open state|Not Found|HTTP 404') {
                                    return
                                }
                                throw "gh pr close exited $($cap.Code) : $($cap.All)"
                            }
                        } | Out-Null
                    }
                    catch {
                        Write-Warning "  Failed to close superseded PR $($openPr.url). $($_.Exception.Message)"
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
