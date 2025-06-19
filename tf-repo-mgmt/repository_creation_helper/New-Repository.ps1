param (
  [string]$tempPath = "~/temp-avm-repo-creation",
  [string]$tempRepoFolderName = "avm-terraform-governance",
  [string]$governanceRepoUrl = "https://github.com/Azure/avm-terraform-governance",
  [string]$moduleProvider = "azurerm",
  [string]$moduleName,
  [string]$moduleDisplayName,
  [string]$resourceProviderNamespace,
  [string]$resourceType,
  [string]$moduleAlternativeNames = "",
  [string]$ownerPrimaryGitHubHandle,
  [string]$ownerPrimaryDisplayName,
  [string]$ownerSecondaryGitHubHandle = "",
  [string]$ownerSecondaryDisplayName = "",
  [switch]$metaDataOnly
)

$metaDataVariables = [PSCustomObject]@{
  moduleId = $moduleName
  providerNamespace = $resourceProviderNamespace
  providerResourceType = $resourceType
  moduleDisplayName = $moduleDisplayName
  alternativeNames = $moduleAlternativeNames
  primaryOwnerGitHubHandle = $ownerPrimaryGitHubHandle
  primaryOwnerDisplayName = $ownerPrimaryDisplayName
  secondaryOwnerGitHubHandle = $ownerSecondaryGitHubHandle
  secondaryOwnerDisplayName = $ownerSecondaryDisplayName
}

$currentPath = Get-Location
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
Set-Location -Path $tempPath
git clone $governanceRepoUrl $tempRepoFolderName
Set-Location -Path $tempRepoFolderName
git checkout -b "chore/add/$moduleName"

$csvPath = "./tf-repo-mgmt/repository-meta-data/meta-data.csv"
$csvData = Get-Content -Path $csvPath | ConvertFrom-Csv
$csvData += $metaDataVariables
$csvData = $csvData | Sort-Object -Property moduleId
$csvData | Export-Csv -Path $csvPath -NoTypeInformation -UseQuotes AsNeeded -Force

git add $csvPath
git commit -m "chore: add $moduleName metadata"
git push --set-upstream origin "chore/add/$moduleName"

$prUrl = gh pr create --title "chore: add $moduleName metadata" --body "This PR adds metadata for the $moduleName module." --base main --head "chore/add/$moduleName" -a "@me" --repo $governanceRepoUrl

Write-Host "Created PR for repo meta data: $prUrl"

Set-Location $tempPath
Remove-Item -Path $tempRepoFolderName -Force -Recurse | Out-Null

Set-Location $currentPath

if($metaDataOnly) {
  Write-Host "Metadata only creation completed. Exiting."
  return
}

$moduleNameRegex = "^avm-(res|ptn|utl)-[a-z-]+$"

if($moduleName -notmatch $moduleNameRegex) {
  Write-Error "Module name must be in the format '$moduleNameRegex'" -Category InvalidArgument
  return
}

$repositoryName = "terraform-$moduleProvider-$moduleName"

Write-Host "Creating repository $moduleName"

gh repo create "Azure/$repositoryName" --public --template "Azure/terraform-azurerm-avm-template"

Write-Host "Created repository $moduleName"
Write-Host "Open https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName"
Write-Host "Click 'Complete Setup' to finish the repository configuration"
Write-Host "Elevate your permissions with JIT and then come back here to continue"
$response = ""
while($response -ne "yes") {
  $response = Read-Host "Type 'yes' Enter to continue..."
}

$tfvars = @{
  module_provider = $moduleProvider
  module_id = $moduleName
  module_name = $moduleDisplayName
  module_owner_github_handles = @{
    primary = $ownerPrimaryGitHubHandle
    secondary = $ownerSecondaryGitHubHandle
  }
}

$tfvars | ConvertTo-Json | Out-File -FilePath "terraform.tfvars.json" -Force

if(Test-Path "terraform.tfstate") {
  Remove-Item "terraform.tfstate" -Force
}
if(Test-Path ".terraform") {
  Remove-Item ".terraform" -Force -Recurse
}
if(Test-Path ".terraform.lock.hcl") {
  Remove-Item ".terraform.lock.hcl" -Force
}

terraform init
terraform apply -auto-approve

Write-Host "Please approve and merge the repo meta data Pull Request: $prUrl"
