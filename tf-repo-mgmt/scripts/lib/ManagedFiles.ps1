# Builds the managed-files map (target path -> absolute source path) that is
# passed to the Terraform github module. Walking the filesystem here keeps
# Terraform free of `path.module`-relative directory traversal and lets us
# apply overlay merging + exclusions in one place.

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
    # `-Force` is required because PowerShell treats dot-prefixed entries as
    # hidden on Linux/macOS (the runner OS for sync), and without it
    # `Get-ChildItem -Recurse` silently skips `.github/`, `.devcontainer/`,
    # `.vscode/`, `.editorconfig`, `.gitattributes`, `.terraform-docs.yml`,
    # etc. Windows does not flag dotfiles as hidden, so the bug is invisible
    # locally.
    Get-ChildItem -Path $baseDirAbsolute -Recurse -File -Force | ForEach-Object {
        $relativePath = $_.FullName.Substring($prefixLength) -replace '\\', '/'
        $absoluteSource = $_.FullName -replace '\\', '/'
        $map[$relativePath] = $absoluteSource
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
