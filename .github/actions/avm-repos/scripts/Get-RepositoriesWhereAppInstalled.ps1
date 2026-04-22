# Requires Environment Variables for GitHub Actions
# GH_TOKEN
# Must run gh auth login -h "GitHub.com" before running this script

param(
  [array]$repoFilter = @(),
  [array]$validProviders = @("azure", "azurerm", "azapi"),
  [array]$reposToSkip = @(
    "bicep-registry-modules",
    "terraform-azure-modules",
    "ALZ-PowerShell-Module",
    "Azure-Verified-Modules",
    "Azure-Verified-Modules-Grept",
    "avmtester",
    "tflint-ruleset-avm",
    "avm-gh-app",
    "avm-container-images-cicd-agents-and-runners",
    "Azure-Verified-Modules-Workflows",
    "avm-terraform-governance",
    "terraform-azurerm-avm-ptn-ai-foundry-enterprise",
    "terraform-azurerm-avm-ptn-enterprise-rag"
  ),
  [array]$additionalReposToSkip = @(),
  [string]$outputDirectory = ".",
  [string]$metaDataFilePath = "./tf-repo-mgmt/repository-meta-data/meta-data.csv"
)

Write-Host "Generating matrix for AVM repositories"

$env:ARM_USE_AZUREAD = "true"
$repos = @()

Write-Host "Getting repositories from app installation"

# Get the list of installed repositories for the GitHub App
$itemsPerPage = 100
$page = 1
$incompleteResults = $true

$installedRepositories = @()

while ($incompleteResults)
{
  $response = ConvertFrom-Json $(gh api "/installation/repositories?per_page=$itemsPerPage&page=$page")
  $installedRepositories += $response.repositories
  $incompleteResults = $page * $itemsPerPage -lt $response.total_count
  $page++
}

$issues = @()

$moduleTypes = @{
  "res"      = "resource"
  "ptn"      = "pattern"
  "utl"      = "utility"
  "template" = "template"
}

$finalReposToSkip = $reposToSkip + $additionalReposToSkip

Write-Host "Skipping repositories: $(ConvertTo-Json $finalReposToSkip)"

$metaData = @()
if (Test-Path $metaDataFilePath)
{
  $metaData = Get-Content -Path $metaDataFilePath | ConvertFrom-Csv
}
else
{
  throw "Meta data file not found at $metaDataFilePath. Cannot validate expected archive state."
}

foreach ($installedRepository in $installedRepositories | Sort-Object -Property name)
{
  if ($finalReposToSkip -contains $installedRepository.name)
  {
    Write-Host "Skipping $($installedRepository.name) as it is in the skip list..."
    continue
  }

  # Use regex to check if the repository name starts with "terraform-(azurerm|azure|azapi)-avm-(res|ptn|utl|template)"
  $matchesNamingConvention = $installedRepository.name -match "^terraform-(azurerm|azure|azapi)-avm-(res|ptn|utl|template)"

  $moduleName = $null
  if ($matchesNamingConvention)
  {
    $parts = $installedRepository.name.Split("-")
    $moduleName = $parts[2..($parts.Length - 1)] -join "-"
  }

  if ($installedRepository.archived)
  {
    $expectedArchived = $false
    if ($matchesNamingConvention)
    {
      $metaDataEntry = $metaData | Where-Object { $_.moduleId -eq $moduleName }
      if ($null -ne $metaDataEntry -and $metaDataEntry.isArchived -eq "true")
      {
        $expectedArchived = $true
      }
    }

    if ($expectedArchived)
    {
      Write-Host "Skipping $($installedRepository.name) as it is archived (expected per meta-data)..."
      continue
    }

    $issue = @{
      repoId   = $installedRepository.name
      message  = "$($installedRepository.name) is archived but is not flagged as archived in meta-data.csv. Either un-archive the repository or set isArchived=true in meta-data.csv."
      severity = "error"
    }
    Write-Warning $issue.message
    $issues += $issue
    continue
  }

  if (!$matchesNamingConvention)
  {
    $issue = @{
      repoId   = $installedRepository.name
      message  = "Skipping $($installedRepository.name) as it does not match the required naming convention: terraform-(azurerm|azure|azapi)-avm-(res|ptn|utl|template)..."
      severity = "error"
    }
    Write-Warning $issue.message
    $issues += $issue
    continue
  }

  $repoMetaData = $metaData | Where-Object { $_.moduleId -eq $moduleName } | Select-Object -First 1
  if ($null -eq $repoMetaData)
  {
    $issue = @{
      repoId   = $installedRepository.name
      message  = "$($installedRepository.name) does not have a corresponding entry in meta-data.csv (expected moduleId '$moduleName'). Add an entry to meta-data.csv."
      severity = "warning"
    }
    Write-Warning $issue.message
    $issues += $issue
  }

  $repos += @{
    repoId              = $moduleName
    repoName            = $installedRepository.name
    repoFullName        = $installedRepository.full_name
    repoUrl             = $installedRepository.html_url
    repoType            = "avm"
    repoSubType         = ($moduleTypes[$parts[3]] ?? "unknown")
    repoMetaData        = $repoMetaData
  }
}

if (!$issues.Count -eq 0)
{
  Write-Host "Issues found for"
  $issuesJson = ConvertTo-Json $issues -Depth 100
  $issuesJson | Out-File "$outputDirectory/issues.log.json"
}

if ($repoFilter.Length -gt 0)
{
  Write-Host "Filtering repositories"
  $repos = $repos | Where-Object { $repoFilter -contains $_.repoId }
}

Write-Host "Found $($repos.Count) repositories"

return $repos | Sort-Object -Property repoId
