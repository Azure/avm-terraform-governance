function Invoke-AvmPreCommitForRepository {
    param(
        [string]$orgAndRepoName,
        [string]$repoId,
        [string]$managedFilesBaseDir,
        [string]$repositoryConfigDir,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog = $issueLog
        HasChanges = $false
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-pre-commit-" + [System.Guid]::NewGuid().ToString())
    $defaultBranch = $null

    try {
        gh auth setup-git
        if ($LASTEXITCODE -ne 0) { throw "gh auth setup-git exited $LASTEXITCODE" }

        $defaultBranch = (gh repo view $orgAndRepoName --json defaultBranchRef --jq '.defaultBranchRef.name').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($defaultBranch)) {
            throw "Unable to resolve the default branch for $orgAndRepoName."
        }

        Write-Host "$modeTag Cloning $orgAndRepoName into $tempDir..." -ForegroundColor DarkGray
        gh repo clone $orgAndRepoName $tempDir -- --quiet --depth 1 --branch $defaultBranch
        if ($LASTEXITCODE -ne 0) { throw "gh repo clone exited $LASTEXITCODE" }

        Push-Location $tempDir
        try {
            Import-Module Avm.Authoring -Force
            avm pre-commit `
                --ecosystem terraform `
                --repo-id $repoId `
                --managed-files-local-path $managedFilesBaseDir `
                --config-local-path $repositoryConfigDir
            if ($LASTEXITCODE -ne 0) { throw "avm pre-commit exited $LASTEXITCODE" }

            $status = git status --porcelain
            $result.HasChanges = -not [string]::IsNullOrWhiteSpace($status)
            if (-not $result.HasChanges) {
                Write-Host "$modeTag $orgAndRepoName - avm pre-commit produced no changes."
                return $result
            }

            Write-Host "$modeTag $orgAndRepoName - avm pre-commit produced changes:" -ForegroundColor Cyan
            git status --short

            if ($planOnly) {
                Write-Host "$modeTag Plan mode is enabled; not opening a pre-commit PR."
                return $result
            }

            $commitAuthorName = "azure-verified-modules[bot]"
            $commitAuthorEmail = "1049636+azure-verified-modules[bot]@users.noreply.github.com"
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
            $branchName = "avm-bot/pre-commit-$timestamp"
            $prTitle = "chore: run avm pre-commit [skip ci]"
            $prBody = @"
Automated ``avm pre-commit`` run from [avm-terraform-governance](https://github.com/Azure/avm-terraform-governance).

This PR is opened and merged by the AVM bot. ``[skip ci]`` is set on the commit so downstream workflows are not retriggered.
"@

            git checkout -q -b $branchName
            if ($LASTEXITCODE -ne 0) { throw "git checkout -b $branchName exited $LASTEXITCODE" }

            git add --all
            if ($LASTEXITCODE -ne 0) { throw "git add --all exited $LASTEXITCODE" }

            git -c "user.name=$commitAuthorName" -c "user.email=$commitAuthorEmail" commit -q -m $prTitle
            if ($LASTEXITCODE -ne 0) { throw "git commit exited $LASTEXITCODE" }

            git push --quiet --set-upstream origin $branchName
            if ($LASTEXITCODE -ne 0) { throw "git push exited $LASTEXITCODE" }

            $prCreateOutput = gh pr create `
                --repo $orgAndRepoName `
                --base $defaultBranch `
                --head $branchName `
                --title $prTitle `
                --body $prBody
            if ($LASTEXITCODE -ne 0) { throw "gh pr create exited $LASTEXITCODE" }

            $prUrl = (@($prCreateOutput) | Where-Object { $_ -and $_.ToString().Trim() -ne "" } | Select-Object -Last 1).ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($prUrl)) { throw "gh pr create returned no URL on stdout" }
            Write-Host "Opened PR: $prUrl" -ForegroundColor DarkGray

            gh pr merge $prUrl `
                --repo $orgAndRepoName `
                --squash `
                --admin `
                --delete-branch `
                --subject $prTitle `
                --body ""
            if ($LASTEXITCODE -ne 0) { throw "gh pr merge exited $LASTEXITCODE" }
            Write-Host "Merged PR: $prUrl" -ForegroundColor Green
        } finally {
            Pop-Location
        }
    } catch {
        Write-Warning "Failed to run avm pre-commit for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "avm-pre-commit-failed" `
            -message "Failed to run avm pre-commit for $orgAndRepoName." `
            -data $_.Exception.Message `
            -issueLog $result.IssueLog
    } finally {
        if (Test-Path $tempDir) {
            try {
                Get-ChildItem -Path $tempDir -Recurse -Force | ForEach-Object {
                    try { $_.Attributes = "Normal" } catch { }
                }
                Remove-Item -Recurse -Force $tempDir
            } catch {
                Write-Warning "Failed to clean up $tempDir : $_"
            }
        }
    }

    return $result
}
