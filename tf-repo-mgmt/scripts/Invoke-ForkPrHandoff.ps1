<#
.SYNOPSIS
Dispatches the central fork-pr-handoff workflow in the AVM Terraform governance
repo for a given module repository's fork PR, and (optionally) watches the run
to completion.

.DESCRIPTION
End-to-end test workflows in AVM module repos cannot run on PRs from forks
because GitHub does not expose secrets to fork-triggered workflows. The
fork-pr-handoff workflow in Azure/avm-terraform-governance performs a
one-shot, maintainer-owned handoff: it creates an `e2e/pr-<N>` release branch
in the module repo, squash-merges the fork PR into it (preserving the original
author and Co-authored-by trailers), closes the fork PR, and opens a
release-branch PR on which pr-check.yml runs with full credentials.

This script triggers the workflow via repository_dispatch. The caller's
authenticated `gh` session is used.

.PARAMETER TargetRepo
The owner/name of the module repository hosting the fork PR
(e.g. Azure/terraform-azurerm-avm-res-storage-storageaccount).

.PARAMETER PrNumber
The number of the fork PR to hand off.

.PARAMETER GovernanceRepo
The governance repo hosting the workflow. Defaults to Azure/avm-terraform-governance.

.PARAMETER WaitForCompletion
When $true (default), polls the resulting workflow run until it completes and
throws if it failed.

.PARAMETER WaitTimeoutSeconds
Maximum seconds to wait when -WaitForCompletion is $true. Defaults to 600.

.EXAMPLE
./Invoke-ForkPrHandoff.ps1 `
  -TargetRepo Azure/terraform-azurerm-avm-res-storage-storageaccount `
  -PrNumber 123
#>
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^[^/]+/[^/]+$')]
  [string]$TargetRepo,

  [Parameter(Mandatory)]
  [ValidateRange(1, 2147483647)]
  [int]$PrNumber,

  [string]$GovernanceRepo = "Azure/avm-terraform-governance",

  [bool]$WaitForCompletion = $true,

  [int]$WaitTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

& gh --version *>$null
if ($LASTEXITCODE -ne 0) {
  throw "GitHub CLI ('gh') is not installed or not on PATH. See https://cli.github.com/."
}

& gh auth status *>$null
if ($LASTEXITCODE -ne 0) {
  throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
}

$beforeDispatch = (Get-Date).ToUniversalTime()

Write-Host "Dispatching fork-pr-handoff in $GovernanceRepo for fork PR #$PrNumber in $TargetRepo..."

$payload = @{
  event_type     = 'fork-pr-handoff'
  client_payload = @{
    target_repo = $TargetRepo
    pr_number   = $PrNumber
  }
} | ConvertTo-Json -Depth 5 -Compress

# Use a temp file to avoid stdin/pipe edge cases with native commands.
$tempFile = New-TemporaryFile
try {
  $payload | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
  gh api "repos/$GovernanceRepo/dispatches" --method POST --input $tempFile.FullName
  $dispatchExit = $LASTEXITCODE
} finally {
  Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}
if ($dispatchExit -ne 0) {
  throw "Failed to dispatch fork-pr-handoff to $GovernanceRepo (gh exit $dispatchExit)."
}

Write-Host "Dispatch sent. Locating workflow run..."

$run = $null
for ($i = 0; $i -lt 12 -and -not $run; $i++) {
  Start-Sleep -Seconds 5
  $runsJson = gh run list --repo $GovernanceRepo --workflow fork-pr-handoff.yml --event repository_dispatch --limit 5 --json databaseId,url,status,conclusion,createdAt
  if ($LASTEXITCODE -ne 0) { continue }
  $runs = $runsJson | ConvertFrom-Json
  if ($runs) {
    $run = $runs | Where-Object { ([datetime]$_.createdAt).ToUniversalTime() -ge $beforeDispatch.AddSeconds(-30) } | Select-Object -First 1
  }
  if (-not $run) { Write-Host "Run not yet visible (attempt $($i + 1) of 12)..." }
}

if (-not $run) {
  Write-Warning "Could not locate the dispatched run. It may still be queueing. Check https://github.com/$GovernanceRepo/actions/workflows/fork-pr-handoff.yml"
  return
}

Write-Host "Workflow run: $($run.url)"

if (-not $WaitForCompletion) {
  return
}

Write-Host "Watching run to completion (timeout: ${WaitTimeoutSeconds}s)..."
$watchJob = Start-Job -ScriptBlock {
  param($runId, $repo)
  & gh run watch $runId --repo $repo --exit-status
  $LASTEXITCODE
} -ArgumentList $run.databaseId, $GovernanceRepo

$completed = Wait-Job -Job $watchJob -Timeout $WaitTimeoutSeconds
if (-not $completed) {
  Stop-Job -Job $watchJob -ErrorAction SilentlyContinue
  Remove-Job -Job $watchJob -Force -ErrorAction SilentlyContinue
  throw "Timed out after ${WaitTimeoutSeconds}s waiting for fork-pr-handoff run. See $($run.url)."
}

$exitCode = Receive-Job -Job $watchJob
Remove-Job -Job $watchJob -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) {
  throw "Fork PR handoff workflow failed (exit $exitCode). See $($run.url)."
}

Write-Host "Fork PR handoff completed successfully."
