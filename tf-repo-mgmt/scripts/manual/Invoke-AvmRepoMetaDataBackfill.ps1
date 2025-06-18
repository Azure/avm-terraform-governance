param(
  $client_id, # This is the Client ID of the GitHub App
  $private_key_path = "azure-verified-modules.pem", # This is the path to the private key for the GitHub App
  $metaDataFilePath = "./repository-meta-data/meta-data.csv" # This is the path to the meta data CSV file
)

# Authenticate with GitHub CLI using the GitHub App
./scripts/manual/Connect-AsApp.ps1 -client_id $client_id -private_key_path $private_key_path

# Get the CSV Files
./scripts/manual/Invoke-AvmRepoCsvDownload.ps1

# Get the list of installed repositories for the GitHub App
$repositories = ./scripts/Get-RepositoriesWhereAppInstalled.ps1

$resourceModulesCSVData = Import-Csv -Path "./temp/TerraformResourceModules.csv"
$patternModulesCSVData = Import-Csv -Path "./temp/TerraformPatternModules.csv"
$utilityModulesCSVData = Import-Csv -Path "./temp/TerraformUtilityModules.csv"

$metaDataVariables = @(
  @{
      key = "ProviderNamespace"
      name = "providerNamespace"
  },
  @{
      key = "ResourceType"
      name = "providerResourceType"
  },
  @{
      key = "ModuleDisplayName"
      name = "moduleDisplayName"
  },
  @{
      key = "AlternativeNames"
      name = "alternativeNames"
  },
  @{
      key = "PrimaryModuleOwnerGHHandle"
      name = "primaryOwnerGitHubHandle"
  },
  @{
      key = "PrimaryModuleOwnerDisplayName"
      name = "primaryOwnerDisplayName"
  },
  @{
      key = "SecondaryModuleOwnerGHHandle"
      name = "secondaryOwnerGitHubHandle"
  },
  @{
      key = "SecondaryModuleOwnerDisplayName"
      name = "secondaryOwnerDisplayName"
  }
)

$csvData = @()
foreach($repository in $repositories) {
  $repositoryCSVData = $null

  if($repository.repoSubType -eq "resource") {
    $repositoryCSVData = $resourceModulesCSVData | Where-Object { $_.ModuleName -eq $repository.repoId }
  }
  if($repository.repoSubType -eq "pattern") {
    $repositoryCSVData = $patternModulesCSVData | Where-Object { $_.ModuleName -eq $repository.repoId }
  }
  if($repository.repoSubType -eq "utility") {
    $repositoryCSVData = $utilityModulesCSVData | Where-Object { $_.ModuleName -eq $repository.repoId }
  }

  if($null -eq $repositoryCSVData) {
    Write-Warning "Repository $($repository.repoId) not found in CSV data"
    continue
  }

  Write-Host "Repository $($repository.repoId) found in CSV data" -ForegroundColor Green

  # Clean up repository variables
  $respositoryVariables = gh variable list --repo "$($repository.repoUrl)" --json "name" | ConvertFrom-Json
  foreach($variable in $respositoryVariables) {
    if($variable.name -like "AVM_*") {
      Write-Host "Removing existing variable: $($variable.name) from repository: $($repository.repoId)"
      gh variable delete "$($variable.name)" --repo "$($repository.repoUrl)"
    }
  }

  $csvRow = [ordered]@{}
  $csvRow["moduleId"] = $repository.repoId
  foreach($item in $metaDataVariables) {
    $metaDataItem = ""
    if($repositoryCSVData.PSObject.Properties.Name -contains $item.key) {
      $metaDataItem = $repositoryCSVData.($item.key)
      Write-Host "Meta data item $($item.name) found for: $($repository.repoId)"
    }

    $csvRow[$item.name] = $metaDataItem
  }
  $csvData += $csvRow
}

# Write the updated meta data to the CSV file
$csvData | Export-Csv -Path $metaDataFilePath -NoTypeInformation -UseQuotes AsNeeded -Encoding UTF8