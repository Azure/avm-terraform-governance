# Builds the managed-files map
# (target path -> @{ Source = absolute source path; Mode = git index mode })
# that is passed to Sync-RepoFiles. Walking the filesystem here keeps the
# rest of the sync free of directory traversal and lets us apply overlay
# merging + exclusions in one place.
#
# `Mode` is the git tree-entry mode ("100644" or "100755") read from this
# governance repo's own git index, so the executable bit recorded here is
# the single source of truth for every downstream AVM repo. To flip a
# managed file's executable bit, run `git update-index --chmod=+x` (or
# `-x`) on it in this repo and commit; the next sync will propagate that
# mode to every target repo.

function Add-ManagedFilesFromDir {
    param(
        [string]$baseDir,
        [hashtable]$map
    )
    if ([string]::IsNullOrEmpty($baseDir)) { return }
    if (-not (Test-Path -Path $baseDir -PathType Container)) {
        Write-Warning "Managed files directory does not exist: $baseDir"
        return
    }
    $baseDirAbsolute = (Resolve-Path -Path $baseDir).Path
    $prefixLength = $baseDirAbsolute.Length + 1

    # Look up tree-entry modes (`100644` / `100755`) from this repo's own
    # git index once per managed dir. The runner's filesystem permission
    # bits are unreliable as a source of truth: on Windows the executable
    # bit is meaningless to git, and on Linux a fresh checkout can lose
    # the +x bit if `core.filemode` is misconfigured. Reading the index
    # avoids both problems.
    $modeMap = @{}
    $lsFilesOutput = & git -C $baseDirAbsolute ls-files --stage -- . 2>$null
    if ($LASTEXITCODE -eq 0 -and $lsFilesOutput) {
        foreach ($line in @($lsFilesOutput)) {
            # Format: <mode> SP <sha> SP <stage>\t<path-relative-to-cwd>
            if ($line -match '^(\d{6})\s+[0-9a-f]+\s+\d+\t(.+)$') {
                $modeMap[($matches[2] -replace '\\', '/')] = $matches[1]
            }
        }
    } else {
        Write-Warning "Failed to read git index modes from '$baseDirAbsolute' (exit=$LASTEXITCODE); managed files from this directory will default to mode 100644."
    }

    # `-Force` is required because PowerShell treats dot-prefixed entries as
    # hidden on Linux/macOS (the runner OS for sync), and without it
    # `Get-ChildItem -Recurse` silently skips `.github/`, `.devcontainer/`,
    # `.vscode/`, `.editorconfig`, `.gitattributes`, `.terraform-docs.yml`,
    # etc. Windows does not flag dotfiles as hidden, so the bug is invisible
    # locally.
    Get-ChildItem -Path $baseDirAbsolute -Recurse -File -Force | ForEach-Object {
        $relativePath = $_.FullName.Substring($prefixLength) -replace '\\', '/'
        $absoluteSource = $_.FullName -replace '\\', '/'
        $mode = $modeMap[$relativePath]
        if (-not $mode) { $mode = "100644" }
        $map[$relativePath] = @{
            Source = $absoluteSource
            Mode   = $mode
        }
    }
}

function Build-ManagedFilesMap {
    param(
        [string]$baseDir,
        [string]$overlay,
        [string[]]$excluded,
        [string]$repoId
    )

    $rootDir = Join-Path $baseDir "root"
    $overlayDir = ""
    if ($overlay -ne "") {
        $overlayDir = Join-Path $baseDir $overlay
    }

    $map = @{}
    Add-ManagedFilesFromDir -baseDir $rootDir -map $map
    if ($overlayDir -ne "") {
        Add-ManagedFilesFromDir -baseDir $overlayDir -map $map
    }

    foreach ($excludedPath in $excluded) {
        if ($map.ContainsKey($excludedPath)) {
            $map.Remove($excludedPath) | Out-Null
            Write-Host "Excluded managed file from sync: $excludedPath"
        }
    }

    Write-Host "Resolved $($map.Count) managed file(s) for repository '$repoId' (overlay='$overlay', exclusions=$($excluded.Count))."

    return $map
}
