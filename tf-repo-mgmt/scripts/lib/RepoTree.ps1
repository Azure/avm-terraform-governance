# Single fetch of the target repo's default-branch tree, returned in a shape
# the deprecated-files cleanup and the import bootstrap both consume.
#
# The previous implementation called `gh api repos/<>` plus
# `gh api repos/<>/git/trees/<branch>?recursive=1` twice per sync (once for
# cleanup, once for bootstrap). Consolidating to one call halves the GitHub
# REST traffic per repo and removes a class of race conditions where the
# default branch could change between the two reads.

function Get-RepositoryDefaultBranchTree {
    param(
        [string]$orgAndRepoName
    )

    $repoInfo = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName")
                OutputLog = "repo-info.json"
            }
        ) `
        -returnOutputParsedFromJson

    if (!$repoInfo -or !$repoInfo.success -or !$repoInfo.output.default_branch) {
        Write-Warning "Failed to fetch repo info for $orgAndRepoName (success=$($repoInfo.success), default_branch='$($repoInfo.output.default_branch)')."
        return @{
            Success       = $false
            DefaultBranch = $null
            BlobPaths     = @()
        }
    }

    $defaultBranch = $repoInfo.output.default_branch

    $treeResult = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/git/trees/$($defaultBranch)?recursive=1")
                OutputLog = "repo-tree.json"
            }
        ) `
        -returnOutputParsedFromJson

    if (!$treeResult -or !$treeResult.success -or !$treeResult.output.tree) {
        Write-Warning "Failed to fetch git tree for $orgAndRepoName (success=$($treeResult.success), tree_count=$($treeResult.output.tree.Count))."
        return @{
            Success       = $false
            DefaultBranch = $defaultBranch
            BlobPaths     = @()
        }
    }

    $blobPaths = @($treeResult.output.tree | Where-Object { $_.type -eq "blob" } | ForEach-Object { $_.path })

    return @{
        Success       = $true
        DefaultBranch = $defaultBranch
        BlobPaths     = $blobPaths
    }
}
