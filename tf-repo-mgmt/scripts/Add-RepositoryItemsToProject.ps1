# Requires Environment Variables for GitHub Actions
# GH_TOKEN - a token (e.g. GitHub App installation token) that has organization
#            "Projects" read/write permission for the target project's owner.
#
# The GitHub CLI picks up GH_TOKEN automatically, so no `gh auth login` is
# required before running this script.
#
# Adds a single repository's issues and pull requests to an org GitHub Project
# (ProjectV2). This is the central, cap-free alternative to the built-in
# Projects "auto-add" workflows (which are limited to 20 per project) and avoids
# committing a per-repo workflow + installing an app/secret on every repo.
#
# Behaviour:
#   * Enumerates the repo's OPEN issues and OPEN pull requests by default. Draft
#     PRs are `state: OPEN`, so they are always included.
#   * With -includeClosed, also enumerates CLOSED issues and CLOSED/MERGED PRs
#     (a heavy, occasional historical back-fill).
#   * Only items NOT already on the target project are added (checked via each
#     item's `projectItems`). `addProjectV2ItemById` is itself idempotent, so
#     this is belt-and-braces and keeps the run rate-limit friendly.
#   * With -planOnly, logs what WOULD be added without mutating the project.
#   * -lookbackDays (default 3) bounds each run to items updated in the last N
#     days: enumeration is ordered newest-updated-first and stops paging as soon
#     as it crosses the cutoff, so steady-state runs fetch ~1 page per collection.
#     -lookbackDays 0 disables the look-back and sweeps everything not already on
#     the project (the one-off initial back-fill).
#
# All GitHub GraphQL calls (queries and the add mutation) are routed through
# Invoke-GitHubCliWithRetry with incremental back-off and an extended retry-match
# list so transient failures and primary/secondary rate limits are ridden out
# rather than failing the run.

param(
    [string]$repoUrl = "https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo",
    [string]$projectUrl = "",
    [string]$projectOwner = "Azure",
    [int]$projectNumber = 1011,
    [bool]$includeClosed = $false,
    [int]$lookbackDays = 3,
    [bool]$planOnly = $false,
    [string]$outputDirectory = "."
)

# Dot-source the shared cmdlet libs. `$PSScriptRoot` makes resolution independent
# of the caller's working directory (the workflow runs from `tf-repo-mgmt/`, but
# local debug runs can be from anywhere).
$libDir = Join-Path $PSScriptRoot "lib"
. (Join-Path $libDir "Logging.ps1")
. (Join-Path $libDir "RetryHelpers.ps1")

# Extended retry-match list: the default only covers "API rate limit exceeded".
# We additionally cover GitHub's secondary/abuse rate limits and common transient
# gateway/timeout failures so a busy run backs off and retries instead of failing.
$retryOn = @(
    "API rate limit exceeded",
    "secondary rate limit",
    "exceeded a secondary rate limit",
    "was submitted too quickly",
    "abuse detection",
    "502 Bad Gateway",
    "503 Service Unavailable",
    "504 Gateway Time-out",
    "Gateway Timeout",
    "timeout awaiting response",
    "Timeout was reached",
    "connection reset",
    "Server Error",
    "EOF"
)

$projectLogFile = Join-Path $outputDirectory "project-sync.log"
$projectLogFileJson = Join-Path $outputDirectory "project-sync.log.json"
$issueLog = @()

# Invokes `gh api graphql`, routing through the repo's retry/back-off helper.
# The GraphQL document is written to a temp file and passed via `-F query=@file`
# so multi-line queries never have to survive Start-Process argument quoting.
function Invoke-GhGraphQl {
    param(
        [string]$query,
        [string[]]$stringFields = @(), # passed via -f (always string)
        [string[]]$typedFields = @(),  # passed via -F (magic int/bool/null conversion)
        [int]$maxRetries = 10
    )

    $queryFile = New-TemporaryFile
    Set-Content -Path $queryFile -Value $query -Encoding utf8

    $arguments = @("api", "graphql")
    $arguments += @("-F", "query=@$($queryFile.FullName)")
    foreach ($field in $stringFields) { $arguments += @("-f", $field) }
    foreach ($field in $typedFields) { $arguments += @("-F", $field) }

    try {
        $result = Invoke-GitHubCliWithRetry `
            -commands @(@{ Arguments = $arguments }) `
            -outputLog "gh.project.output.log" `
            -errorLog "gh.project.error.log" `
            -maxRetries $maxRetries `
            -retryDelayIncremental 10 `
            -retryOn $retryOn `
            -printOutputOnError `
            -returnOutputParsedFromJson

        # Invoke-GitHubCliWithRetry returns an array (one entry per command).
        # PowerShell usually unwraps a single-element array, but normalise to be
        # safe so callers can rely on `.success` / `.output`.
        if ($result -is [array]) { $result = $result[0] }
        return $result
    }
    finally {
        Remove-Item $queryFile -Force -ErrorAction SilentlyContinue
    }
}

# Resolves a ProjectV2 node id from an owner + project number. Tries the owner as
# an organization first (the AVM All Up project is org-owned) and falls back to a
# user-owned project so a -projectUrl override still works.
function Resolve-ProjectV2Id {
    param([string]$owner, [int]$number)

    $orgQuery = @'
query($owner: String!, $number: Int!) {
  organization(login: $owner) {
    projectV2(number: $number) { id title }
  }
}
'@
    $result = Invoke-GhGraphQl -query $orgQuery -stringFields @("owner=$owner") -typedFields @("number=$number")
    if ($result.success -and $result.output.data.organization.projectV2.id) {
        return @{
            Id    = $result.output.data.organization.projectV2.id
            Title = $result.output.data.organization.projectV2.title
        }
    }

    $userQuery = @'
query($owner: String!, $number: Int!) {
  user(login: $owner) {
    projectV2(number: $number) { id title }
  }
}
'@
    $result = Invoke-GhGraphQl -query $userQuery -stringFields @("owner=$owner") -typedFields @("number=$number")
    if ($result.success -and $result.output.data.user.projectV2.id) {
        return @{
            Id    = $result.output.data.user.projectV2.id
            Title = $result.output.data.user.projectV2.title
        }
    }

    return $null
}

# Enumerates nodes in a repository collection ("issues" or "pullRequests") for
# the given GraphQL states, newest-updated-first. Walks the cursor manually so we
# can stop as soon as an item older than $cutoffUtc is seen (every later node is
# older, given the UPDATED_AT DESC ordering) - this is the look-back that keeps
# steady-state runs cheap. A $cutoffUtc of [datetime]::MinValue means "no
# look-back" (full sweep). Returns @{ Nodes = <array>; RateRemaining = <int?> }
# so the caller can surface remaining GraphQL budget, or $null on hard failure.
function Get-RepositoryItems {
    param(
        [string]$owner,
        [string]$name,
        [ValidateSet("issues", "pullRequests")]
        [string]$collection,
        [string]$statesGql,
        [datetime]$cutoffUtc = [datetime]::MinValue
    )

    $extraFields = ""
    if ($collection -eq "pullRequests") { $extraFields = "isDraft" }

    # Single-quoted template with placeholder tokens avoids escaping the GraphQL
    # `$owner`/`$name`/`$endCursor` variables against PowerShell interpolation.
    # `rateLimit { remaining }` is essentially free and gives per-repo observability
    # of the remaining primary GraphQL budget. `projectItems(first: 20)` is ample
    # for the membership check (an item on >20 projects would just be re-added,
    # which is idempotent).
    $template = @'
query($owner: String!, $name: String!, $endCursor: String) {
  rateLimit { remaining }
  repository(owner: $owner, name: $name) {
    __COLLECTION__(states: [__STATES__], first: 100, after: $endCursor, orderBy: { field: UPDATED_AT, direction: DESC }) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        number
        updatedAt
        __EXTRA__
        projectItems(first: 20) { nodes { project { number } } }
      }
    }
  }
}
'@
    $query = $template.Replace("__COLLECTION__", $collection).Replace("__STATES__", $statesGql).Replace("__EXTRA__", $extraFields)

    $nodes = @()
    $endCursor = $null
    $rateRemaining = $null
    $reachedCutoff = $false
    $useCutoff = $cutoffUtc -gt [datetime]::MinValue

    while ($true) {
        $stringFields = @("owner=$owner", "name=$name")
        # $endCursor is a nullable String; omit it on the first page so gh sends
        # null (an absent nullable variable is treated as null by GraphQL).
        if ($endCursor) { $stringFields += "endCursor=$endCursor" }

        $result = Invoke-GhGraphQl -query $query -stringFields $stringFields
        if (-not $result.success) {
            return $null
        }

        $data = $result.output.data
        if ($data.rateLimit -and $null -ne $data.rateLimit.remaining) {
            $rateRemaining = [int]$data.rateLimit.remaining
        }

        $connection = $data.repository.$collection
        if (-not $connection) { break }

        foreach ($node in @($connection.nodes)) {
            if ($useCutoff -and $node.updatedAt) {
                $nodeUpdatedUtc = ([datetimeoffset]$node.updatedAt).UtcDateTime
                if ($nodeUpdatedUtc -lt $cutoffUtc) {
                    # Newest-first ordering guarantees every later node is older.
                    $reachedCutoff = $true
                    break
                }
            }
            $nodes += $node
        }

        if ($reachedCutoff) { break }
        if (-not $connection.pageInfo.hasNextPage) { break }
        $endCursor = $connection.pageInfo.endCursor
    }

    return @{ Nodes = @($nodes); RateRemaining = $rateRemaining }
}

# Returns $true if the item's projectItems already include the target project.
function Test-ItemOnProject {
    param($item, [int]$number)

    foreach ($projectItem in @($item.projectItems.nodes)) {
        if ($projectItem.project -and ([int]$projectItem.project.number) -eq $number) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Resolve target project (owner/number can be overridden by a full project URL)
# ---------------------------------------------------------------------------
if ($projectUrl -and $projectUrl.Trim() -ne "") {
    if ($projectUrl -match "orgs/([^/]+)/projects/(\d+)") {
        $projectOwner = $Matches[1]
        $projectNumber = [int]$Matches[2]
    }
    elseif ($projectUrl -match "users/([^/]+)/projects/(\d+)") {
        $projectOwner = $Matches[1]
        $projectNumber = [int]$Matches[2]
    }
    else {
        Write-Warning "Could not parse projectUrl '$projectUrl'; falling back to owner '$projectOwner' / number $projectNumber."
    }
}

$repoSplit = $repoUrl.Split("/")
$orgName = $repoSplit[3]
$repoName = $repoSplit[4]
$orgAndRepoName = "$orgName/$repoName"

Write-Host "$([Environment]::NewLine)<--->" -ForegroundColor Green
Write-Host "Adding issues/PRs for $orgAndRepoName to project $projectOwner/$projectNumber (includeClosed=$includeClosed, lookbackDays=$lookbackDays, planOnly=$planOnly)" -ForegroundColor Green
Write-Host "<--->$([Environment]::NewLine)" -ForegroundColor Green

$project = Resolve-ProjectV2Id -owner $projectOwner -number $projectNumber
if ($null -eq $project) {
    $message = "Could not resolve ProjectV2 id for $projectOwner/$projectNumber. Check the project exists and the token has organization Projects read/write permission."
    Write-Error $message
    $issueLog = Add-IssueToLog `
        -orgAndRepoName $orgAndRepoName `
        -type "project-sync" `
        -message $message `
        -severity "error" `
        -issueLog $issueLog `
        -issueLogFile $projectLogFile
    if ($issueLog.Count -gt 0) {
        ConvertTo-Json $issueLog -Depth 100 | Out-File $projectLogFileJson
    }
    exit 0
}

$projectId = $project.Id
Write-Host "Resolved project '$($project.Title)' -> $projectId"

# ---------------------------------------------------------------------------
# Look-back cutoff. A value > 0 bounds each run to items updated within the last
# N days (enumeration is newest-first and stops paging once it crosses the
# cutoff). A value <= 0 disables the look-back and sweeps everything not already
# on the project (the one-off initial back-fill). [datetime]::MinValue is the
# "no look-back" sentinel that Get-RepositoryItems understands.
# ---------------------------------------------------------------------------
if ($lookbackDays -gt 0) {
    $cutoffUtc = [datetime]::UtcNow.AddDays(-$lookbackDays)
    Write-Host "Look-back: last $lookbackDays day(s) - items updated on/after $($cutoffUtc.ToString('u'))"
}
else {
    $cutoffUtc = [datetime]::MinValue
    Write-Host "Look-back: disabled - full sweep of all items not already on the project"
}

# ---------------------------------------------------------------------------
# Build the work list: collection -> GraphQL states
# ---------------------------------------------------------------------------
$collections = @(
    @{ Name = "issues"; States = if ($includeClosed) { "OPEN, CLOSED" } else { "OPEN" } },
    @{ Name = "pullRequests"; States = if ($includeClosed) { "OPEN, CLOSED, MERGED" } else { "OPEN" } }
)

$totalFound = 0
$totalAlready = 0
$totalAdded = 0
$totalWouldAdd = 0
$totalFailed = 0
$rateRemaining = $null

foreach ($collection in $collections) {
    $itemsResult = Get-RepositoryItems -owner $orgName -name $repoName -collection $collection.Name -statesGql $collection.States -cutoffUtc $cutoffUtc
    if ($null -eq $itemsResult) {
        $message = "Failed to enumerate $($collection.Name) (states: $($collection.States)) for $orgAndRepoName after retries."
        Write-Warning $message
        $issueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "project-sync" `
            -message $message `
            -severity "warning" `
            -issueLog $issueLog `
            -issueLogFile $projectLogFile
        continue
    }

    $items = @($itemsResult.Nodes)
    if ($null -ne $itemsResult.RateRemaining) { $rateRemaining = $itemsResult.RateRemaining }

    Write-Host "Found $($items.Count) $($collection.Name) (states: $($collection.States)) for $orgAndRepoName"
    $totalFound += $items.Count

    foreach ($item in $items) {
        if (Test-ItemOnProject -item $item -number $projectNumber) {
            $totalAlready++
            continue
        }

        if ($planOnly) {
            Write-Host "  [plan] would add $($collection.Name) #$($item.number) ($($item.id))"
            $totalWouldAdd++
            continue
        }

        $mutation = @'
mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
    item { id }
  }
}
'@
        $addResult = Invoke-GhGraphQl -query $mutation -stringFields @("projectId=$projectId", "contentId=$($item.id)")

        if ($addResult.success -and $addResult.output.data.addProjectV2ItemById.item.id) {
            Write-Host "  added $($collection.Name) #$($item.number) -> $($addResult.output.data.addProjectV2ItemById.item.id)"
            $totalAdded++
        }
        else {
            $message = "Failed to add $($collection.Name) #$($item.number) ($($item.id)) to project $projectOwner/$projectNumber for $orgAndRepoName."
            Write-Warning $message
            $totalFailed++
            $issueLog = Add-IssueToLog `
                -orgAndRepoName $orgAndRepoName `
                -type "project-sync" `
                -message $message `
                -data @{ collection = $collection.Name; number = $item.number; contentId = $item.id } `
                -severity "warning" `
                -issueLog $issueLog `
                -issueLogFile $projectLogFile
        }
    }
}

Write-Host "$([Environment]::NewLine)Project sync summary for $orgAndRepoName" -ForegroundColor Cyan
Write-Host "  found:        $totalFound"
Write-Host "  already on:   $totalAlready"
if ($planOnly) {
    Write-Host "  would add:    $totalWouldAdd (planOnly)"
}
else {
    Write-Host "  added:        $totalAdded"
    Write-Host "  failed:       $totalFailed"
}
if ($null -ne $rateRemaining) {
    Write-Host "  graphql budget remaining: $rateRemaining"
}

if ($issueLog.Count -gt 0) {
    ConvertTo-Json $issueLog -Depth 100 | Out-File $projectLogFileJson
}

exit 0
