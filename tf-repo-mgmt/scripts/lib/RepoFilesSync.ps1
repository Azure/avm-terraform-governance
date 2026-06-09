# Combined repo-file sync. For each target repo this:
#
# 1. Determines which deprecated paths are present on the repo's default
#    branch (to delete).
# 2. Builds the desired managed-file set (source bytes from
#    `managed-files/<...>` plus the rendered `.github/CODEOWNERS` content).
# 3. Compares each desired path's git blob SHA to the cached SHA in the
#    pre-fetched repo tree.
#    - Add    = desired path not present in the tree.
#    - Update = desired path present but blob SHA differs.
# 4. If nothing to remove/add/update, logs a no-op message and returns
#    without cloning, creating a branch, or opening a PR.
# 5. Otherwise, shallow-clones the default branch into a temp dir, checks
#    out a fresh bot branch `avm-bot/managed-files-sync-<utc>`, applies the
#    file mutations, commits as `azure-verified-modules[bot]` with a
#    `[skip ci]` message, pushes the branch, opens a PR, and immediately
#    merges it with `gh pr merge --squash --admin --delete-branch` so the
#    AVM GitHub App's ruleset bypass settles the merge in a single step.
#
# Plan mode (`-planOnly $true`) only reports the diff with a `[PLAN]` prefix
# and never clones or pushes.
#
# Returns:
#   @{
#     IssueLog     = updated issue log
#     RemovedPaths = deprecated paths that were removed
#     AddedPaths   = managed paths newly created in the target repo
#     UpdatedPaths = managed paths whose contents changed
#   }

function Get-MatchingDeprecatedPaths {
    param(
        [string[]]$candidatePaths,
        [string[]]$repoFilePaths
    )

    $matchedPaths = @()
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
        if ($hit) { $matchedPaths += $candidate }
    }
    return $matchedPaths
}

# Compute git's blob SHA-1 for the given content bytes.
#
#   git hash-object <file>  ==  sha1("blob " + length + "\0" + content)
#
# Computed in-process so we can avoid spawning `git hash-object` once per
# managed file (hundreds of subprocesses per repo would dwarf the actual
# sync work).
function Get-GitBlobSha {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }

    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $combined = New-Object byte[] ($header.Length + $Bytes.Length)
    [Array]::Copy($header, 0, $combined, 0, $header.Length)
    [Array]::Copy($Bytes, 0, $combined, $header.Length, $Bytes.Length)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash($combined)
        return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha1.Dispose()
    }
}

# Render `.github/CODEOWNERS` exactly as the previous Terraform
# `templatefile()` did so that the blob SHA matches what is already in
# target repos and we don't trigger spurious updates on the first sync.
# Always uses LF line endings to match the prior Terraform-generated file
# (Terraform ran on a Linux runner; LF is also what `.gitattributes`
# enforces for text files in this repo).
function Get-RenderedCodeownersContent {
    param(
        [string]$ownerSlug,
        [string[]]$defaultTeams,
        [string[]]$fileProtectionTeams
    )

    $defaultOwners = ""
    if ($defaultTeams -and $defaultTeams.Count -gt 0) {
        $defaultOwners = (($defaultTeams | ForEach-Object { "@$ownerSlug/$_" }) -join " ")
    }
    $fileProtectionOwners = ""
    if ($fileProtectionTeams -and $fileProtectionTeams.Count -gt 0) {
        $fileProtectionOwners = (($fileProtectionTeams | ForEach-Object { "@$ownerSlug/$_" }) -join " ")
    }

    # Mirrors templates/CODEOWNERS.tftpl line-for-line. `"`n"` is an LF
    # literal in PowerShell on every platform.
    $lf = "`n"
    $content = "# This file is managed by avm-terraform-governance. Do not edit manually." + $lf
    $content += "# See: https://github.com/Azure/avm-terraform-governance" + $lf
    if ($defaultOwners -ne "") {
        $content += $lf
        $content += "# Default code owners for all files in the repository." + $lf
        $content += "* $defaultOwners" + $lf
    }
    if ($fileProtectionOwners -ne "") {
        $content += $lf
        $content += "# The CODEOWNERS file itself is protected to prevent unauthorized changes." + $lf
        $content += ".github/CODEOWNERS $fileProtectionOwners" + $lf
    }
    return $content
}

# Build the desired managed-file set as `{ path -> @{ Bytes; Sha } }`.
# `Bytes` is the raw file content (no encoding round-trip, so SHA matches
# git's hash-object exactly); `Sha` is the precomputed git blob SHA;
# `Mode` is the git tree-entry mode ("100644" / "100755") that should be
# stamped on the index entry in every target repo.
function Get-DesiredManagedFiles {
    param(
        [hashtable]$managedFiles,
        [string]$codeownersPath,
        [string]$codeownersContent
    )

    $desired = @{}

    foreach ($targetPath in $managedFiles.Keys) {
        $entry = $managedFiles[$targetPath]
        $sourcePath = $entry.Source
        $mode = $entry.Mode
        if (-not $mode) { $mode = "100644" }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            Write-Warning "Managed file source missing on disk: $sourcePath (target=$targetPath)"
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($sourcePath)
        $desired[$targetPath] = @{
            Bytes = $bytes
            Sha   = Get-GitBlobSha -Bytes $bytes
            Mode  = $mode
        }
    }

    if ($codeownersPath -and $null -ne $codeownersContent) {
        # `New-Object System.Text.UTF8Encoding($false)` => UTF-8 without BOM,
        # matching what Terraform's `templatefile()` produced.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $codeownersBytes = $utf8NoBom.GetBytes($codeownersContent)
        $desired[$codeownersPath] = @{
            Bytes = $codeownersBytes
            Sha   = Get-GitBlobSha -Bytes $codeownersBytes
            Mode  = "100644"
        }
    }

    return $desired
}

function Sync-RepoFiles {
    param(
        [string]$orgAndRepoName,
        [string[]]$deprecatedPaths,
        [hashtable]$managedFiles,
        [string]$codeownersContent,
        [hashtable]$repoTree,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog     = $issueLog
        RemovedPaths = @()
        AddedPaths   = @()
        UpdatedPaths = @()
    }

    if (!$repoTree -or !$repoTree.Success) {
        Write-Warning "$modeTag No repo tree available for $orgAndRepoName; skipping repo-file sync."
        return $result
    }

    $defaultBranch = $repoTree.DefaultBranch
    $codeownersPath = ".github/CODEOWNERS"

    $matchedDeprecated = @()
    if ($deprecatedPaths -and $deprecatedPaths.Count -gt 0) {
        $matchedDeprecated = @(Get-MatchingDeprecatedPaths -candidatePaths $deprecatedPaths -repoFilePaths $repoTree.BlobPaths)
    }

    $desired = Get-DesiredManagedFiles `
        -managedFiles $managedFiles `
        -codeownersPath $codeownersPath `
        -codeownersContent $codeownersContent

    # Treat deprecated removals as winning over managed adds in the rare
    # case both lists name the same path (defensive; shouldn't happen in
    # practice).
    $deprecatedLookup = @{}
    foreach ($p in $matchedDeprecated) { $deprecatedLookup[$p] = $true }
    foreach ($p in @($desired.Keys)) {
        if ($deprecatedLookup.ContainsKey($p)) { $desired.Remove($p) | Out-Null }
    }

    $existingBlobs = @{}
    $existingModes = @{}
    if ($repoTree.Blobs) {
        foreach ($k in $repoTree.Blobs.Keys) { $existingBlobs[$k] = $repoTree.Blobs[$k] }
    }
    if ($repoTree.Modes) {
        foreach ($k in $repoTree.Modes.Keys) { $existingModes[$k] = $repoTree.Modes[$k] }
    }

    $toAdd = @()
    $toUpdate = @()
    foreach ($targetPath in ($desired.Keys | Sort-Object)) {
        $desiredSha = $desired[$targetPath].Sha
        $desiredMode = $desired[$targetPath].Mode
        if (-not $existingBlobs.ContainsKey($targetPath)) {
            $toAdd += $targetPath
        } else {
            $existingSha = $existingBlobs[$targetPath]
            $existingMode = $existingModes[$targetPath]
            if (-not $existingMode) { $existingMode = "100644" }
            # Update on either content drift OR executable-bit drift, so
            # flipping +x in this governance repo's index is enough to
            # propagate the mode change to every target on the next sync.
            if ($existingSha -ne $desiredSha -or $existingMode -ne $desiredMode) {
                $toUpdate += $targetPath
            }
        }
    }

    $toRemove = @($matchedDeprecated | Sort-Object)
    $hasChanges = ($toRemove.Count -gt 0) -or ($toAdd.Count -gt 0) -or ($toUpdate.Count -gt 0)

    if (-not $hasChanges) {
        Write-Host "$modeTag $orgAndRepoName (default_branch=$defaultBranch) - no managed-file changes required."
        return $result
    }

    Write-Host "$modeTag $orgAndRepoName (default_branch=$defaultBranch) - managed-file changes:" -ForegroundColor Cyan
    if ($toRemove.Count -gt 0) {
        Write-Host "$modeTag   remove ($($toRemove.Count)):" -ForegroundColor Cyan
        foreach ($p in $toRemove) { Write-Host "$modeTag     - $p" }
    }
    if ($toAdd.Count -gt 0) {
        Write-Host "$modeTag   add ($($toAdd.Count)):" -ForegroundColor Cyan
        foreach ($p in $toAdd) { Write-Host "$modeTag     + $p" }
    }
    if ($toUpdate.Count -gt 0) {
        Write-Host "$modeTag   update ($($toUpdate.Count)):" -ForegroundColor Cyan
        foreach ($p in $toUpdate) { Write-Host "$modeTag     ~ $p" }
    }

    if ($planOnly) {
        Write-Host "$modeTag Plan mode is enabled; not opening a sync PR."
        return $result
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-sync-" + [System.Guid]::NewGuid().ToString())
    $commitAuthorName = "azure-verified-modules[bot]"
    $commitAuthorEmail = "1049636+azure-verified-modules[bot]@users.noreply.github.com"
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $branchName = "avm-bot/managed-files-sync-$timestamp"
    $prTitle = "chore: sync managed files [skip ci]"
    $commitMessage = $prTitle
    $prBody = New-RepoFileSyncPrBody -RemovedPaths $toRemove -AddedPaths $toAdd -UpdatedPaths $toUpdate

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
            git checkout -q -b $branchName
            if ($LASTEXITCODE -ne 0) { throw "git checkout -b $branchName exited $LASTEXITCODE" }

            foreach ($path in $toRemove) {
                git rm -r -f -- $path | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "  git rm failed for '$path'; continuing with the rest."
                }
            }

            foreach ($path in ($toAdd + $toUpdate)) {
                $absolute = Join-Path $tempDir $path
                $parent = Split-Path -Parent $absolute
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                [System.IO.File]::WriteAllBytes($absolute, $desired[$path].Bytes)
                git add -- $path | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "  git add failed for '$path'; continuing with the rest."
                    continue
                }
                # Stamp the executable bit on the index entry explicitly so
                # the tree-entry mode in the target matches this repo's
                # index, independent of the runner's `core.filemode` and
                # the on-disk perms `WriteAllBytes` produced. Both
                # `--chmod=+x` and `--chmod=-x` are idempotent.
                $chmodFlag = if ($desired[$path].Mode -eq "100755") { "+x" } else { "-x" }
                git update-index --chmod=$chmodFlag -- $path | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "  git update-index --chmod=$chmodFlag failed for '$path'; continuing with the rest."
                }
            }

            $status = git status --porcelain
            if ([string]::IsNullOrWhiteSpace($status)) {
                Write-Warning "  No staged changes after applying mutations; skipping commit/PR."
                return $result
            }

            git -c "user.name=$commitAuthorName" -c "user.email=$commitAuthorEmail" commit -q -m $commitMessage
            if ($LASTEXITCODE -ne 0) { throw "git commit exited $LASTEXITCODE" }

            git push --quiet --set-upstream origin $branchName
            if ($LASTEXITCODE -ne 0) { throw "git push exited $LASTEXITCODE" }

            Write-Host "  Pushed sync branch $branchName; opening PR..." -ForegroundColor DarkGray
            $prCreateOutput = gh pr create `
                --repo $orgAndRepoName `
                --base $defaultBranch `
                --head $branchName `
                --title $prTitle `
                --body $prBody
            if ($LASTEXITCODE -ne 0) { throw "gh pr create exited $LASTEXITCODE" }
            # `gh pr create` normally writes a single line (the PR URL) to
            # stdout, but defend against future status lines by taking the
            # last non-empty line.
            $prUrl = (@($prCreateOutput) | Where-Object { $_ -and $_.ToString().Trim() -ne "" } | Select-Object -Last 1).ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($prUrl)) { throw "gh pr create returned no URL on stdout" }
            Write-Host "  Opened PR: $prUrl" -ForegroundColor DarkGray

            # `--admin` lets the AVM GitHub App use its ruleset bypass to
            # merge immediately without waiting for required checks; the
            # commit subject is forced so the squashed commit on default
            # also carries `[skip ci]` and does not retrigger downstream
            # workflows.
            gh pr merge $prUrl `
                --repo $orgAndRepoName `
                --squash `
                --admin `
                --delete-branch `
                --subject $commitMessage `
                --body ""
            if ($LASTEXITCODE -ne 0) { throw "gh pr merge exited $LASTEXITCODE" }
            Write-Host "  Merged PR for $orgAndRepoName." -ForegroundColor Green

            $result.RemovedPaths = $toRemove
            $result.AddedPaths = $toAdd
            $result.UpdatedPaths = $toUpdate
        } finally {
            Pop-Location
        }
    } catch {
        Write-Warning "  Failed to sync managed files for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "managed-files-sync-failed" `
            -message "Failed to sync managed files for $orgAndRepoName." `
            -data ("remove=[" + ($toRemove -join ", ") + "] add=[" + ($toAdd -join ", ") + "] update=[" + ($toUpdate -join ", ") + "]") `
            -issueLog $result.IssueLog
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

function New-RepoFileSyncPrBody {
    param(
        [string[]]$RemovedPaths,
        [string[]]$AddedPaths,
        [string[]]$UpdatedPaths
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Automated managed-files sync from [avm-terraform-governance](https://github.com/Azure/avm-terraform-governance).")
    [void]$lines.Add("")
    [void]$lines.Add("This PR is opened and merged by the AVM bot. `` [skip ci] `` is set on the commit so downstream workflows are not retriggered.")
    [void]$lines.Add("")
    if ($RemovedPaths -and $RemovedPaths.Count -gt 0) {
        [void]$lines.Add("**Removed ($($RemovedPaths.Count))**")
        foreach ($p in $RemovedPaths) { [void]$lines.Add("- ``$p``") }
        [void]$lines.Add("")
    }
    if ($AddedPaths -and $AddedPaths.Count -gt 0) {
        [void]$lines.Add("**Added ($($AddedPaths.Count))**")
        foreach ($p in $AddedPaths) { [void]$lines.Add("- ``$p``") }
        [void]$lines.Add("")
    }
    if ($UpdatedPaths -and $UpdatedPaths.Count -gt 0) {
        [void]$lines.Add("**Updated ($($UpdatedPaths.Count))**")
        foreach ($p in $UpdatedPaths) { [void]$lines.Add("- ``$p``") }
        [void]$lines.Add("")
    }
    return ($lines -join "`n")
}
