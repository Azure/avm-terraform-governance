param (
  [string]$tempPath = "~/temp-avm-repo-creation",
  [string]$governanceRepoUrl = "https://github.com/Azure/avm-terraform-governance",
  [string]$openSourceRepoUrl = "https://github.com/microsoft/github-operations",
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
  [switch]$metaDataOnly,
  [switch]$skipRepoCreation,
  [switch]$skipRepoSync,
  [switch]$skipMetaDataCreation,
  [string]$repositorySyncModulePath = "./repository_sync",
  [switch]$skipCleanup,
  [switch]$skipCreateAppInstallationRequest,
  [string]$appInstallationRequestRepo = "microsoft/github-operations"
)

$ProgressPreference = "SilentlyContinue"

./scripts/Test-Tooling.ps1

$moduleNameRegex = "^avm-(res|ptn|utl)-[a-z-]+$"

if ($moduleName -notmatch $moduleNameRegex) {
  Write-Error "Module name must be in the format '$moduleNameRegex'" -Category InvalidArgument
  return
}

if($moduleDisplayName -eq "") {
  Write-Error "Module display name must be provided." -Category InvalidArgument
  return
}

if($moduleName.StartsWith("avm-res")) {
  if($resourceProviderNamespace -eq "") {
    Write-Error "Resource provider namespace must be provided for resource modules." -Category InvalidArgument
    return
  }
  if($resourceType -eq "") {
    Write-Error "Resource type must be provided for resource modules." -Category InvalidArgument
    return
  }
}

if($ownerPrimaryGitHubHandle -eq "") {
  Write-Error "Primary owner GitHub handle must be provided." -Category InvalidArgument
  return
}

if($ownerPrimaryDisplayName -eq "") {
  Write-Error "Primary owner display name must be provided." -Category InvalidArgument
  return
}

if (!$skipMetaDataCreation) {

  $metaDataVariables = [PSCustomObject]@{
    moduleId                   = $moduleName
    providerNamespace          = $resourceProviderNamespace
    providerResourceType       = $resourceType
    moduleDisplayName          = $moduleDisplayName
    alternativeNames           = $moduleAlternativeNames
    primaryOwnerGitHubHandle   = $ownerPrimaryGitHubHandle
    primaryOwnerDisplayName    = $ownerPrimaryDisplayName
    secondaryOwnerGitHubHandle = $ownerSecondaryGitHubHandle
    secondaryOwnerDisplayName  = $ownerSecondaryDisplayName
  }

  $currentPath = Get-Location
  New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
  Set-Location -Path $tempPath
  gh repo fork --remote --clone --default-branch-only $governanceRepoUrl
  $tempRepoFolderName = $governanceRepoUrl.Split('/')[-1]
  Set-Location -Path $tempRepoFolderName
  $tempOrgAndRepoName = $openSourceRepoUrl.Split('/')[-2..-1] -join '/'
  gh repo set-default $tempOrgAndRepoName
  git fetch upstream
  git reset --hard upstream/main
  git checkout -b "chore/add/$moduleName"

  $csvPath = "./tf-repo-mgmt/repository-meta-data/meta-data.csv"
  $csvData = Get-Content -Path $csvPath | ConvertFrom-Csv
  $csvData += $metaDataVariables
  $csvData = $csvData | Sort-Object -Property moduleId
  $csvData | Export-Csv -Path $csvPath -NoTypeInformation -UseQuotes AsNeeded -Force

  git add $csvPath
  git commit -m "chore: add $moduleName metadata"
  git push --set-upstream origin "chore/add/$moduleName"

  $prUrl = gh pr create --title "chore: add $moduleName metadata" --body "This PR adds metadata for the $moduleName module."

  Write-Host "Created PR for repo meta data: $prUrl"

  Set-Location $tempPath
  Remove-Item -Path $tempRepoFolderName -Force -Recurse | Out-Null

  Set-Location $currentPath

  if ($metaDataOnly) {
    Write-Host "Metadata only creation completed. Exiting."
    return
  }
}

$repositoryName = "terraform-$moduleProvider-$moduleName"
$repositoryUrl = "https://github.com/Azure/$repositoryName"

if (!$skipRepoCreation) {
  Write-Host ""
  Write-Host "Creating repository $moduleName"

  gh repo create "Azure/$repositoryName" --public --template "Azure/terraform-azurerm-avm-template"

  Write-Host ""
  Write-Host "Created repository $moduleName" -ForegroundColor Green
  Write-Host "Open https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName" -ForegroundColor Yellow
  if(!$env:CODESPACES) {
    Write-Host "Hit Enter to open the open source portal in your browser now" -ForegroundColor Yellow
    Read-Host
    Start-Process "https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName"
  }

  $response = ""
  while ($response -ne "yes" -and $response -ne "no") {
    Write-Host "Do you see the 'Complete Setup' link? Type 'yes' or 'no' and hit Enter:" -ForegroundColor Yellow
    $response = Read-Host
  }

  if($response -eq "yes") {
    Write-Host "Click 'Complete Setup' to finish the repository configuration" -ForegroundColor Yellow
    Write-Host "Elevate your permissions with JIT and then come back here to continue" -ForegroundColor Yellow

    Write-Host ""
    Write-Host "You can copy and paste the following settings..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Project name:" -ForegroundColor Cyan
    Write-Host "Azure Verified Module (Terraform) for '$moduleName'"
    Write-Host ""
    Write-Host "Project description:" -ForegroundColor Cyan
    Write-Host "Azure Verified Module (Terraform) for '$moduleName'. Part of AVM project - https://aka.ms/avm"
    Write-Host ""
    Write-Host "Business goals:" -ForegroundColor Cyan
    Write-Host "Create IaC module that will accelerate deployment on Azure using Microsoft best practice."
    Write-Host ""
    Write-Host "Will this be used in a Microsoft product or service?:" -ForegroundColor Cyan
    Write-Host "This is open source project and can be leveraged in Microsoft service and product."
    Write-Host ""
  }

  if($response -eq "no") {
    Write-Host "Click the 'Compliance' tab and fill out the 3 sections." -ForegroundColor Yellow
    Write-Host "Elevate your permissions with JIT and then come back here to continue" -ForegroundColor Yellow
  }

  $response = ""
  while ($response -ne "yes") {
    Write-Host "Once the form is complete and you have elevated with JIT, type 'yes' and hit Enter to continue:" -ForegroundColor Yellow
    $response = Read-Host
  }
}

if(!$skipRepoSync){
  ./scripts/Get-AvmLabels.ps1

  ./scripts/Invoke-RepositorySync.ps1 `
    -repositoryCreationModeEnabled `
    -planOnly $false `
    -repoId $moduleName `
    -repoUrl $repositoryUrl `
    -skipCleanup:$skipCleanup.IsPresent

  Write-Host ""
  Write-Host "Terraform apply completed successfully." -ForegroundColor Green
}

Write-Host ""
Write-Host "Repository URL:" -ForegroundColor Cyan
Write-Host $repositoryUrl

$ownerMention = ""

if ($ownerPrimaryGitHubHandle -ne "") {
  $ownerMention = "@$ownerPrimaryGitHubHandle "
}

if (!$skipCreateAppInstallationRequest) {
  Write-Host "Creating app installation request..." -ForegroundColor Yellow
  $currentPath = Get-Location
  New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
  Set-Location -Path $tempPath
  gh repo fork --remote --clone --default-branch-only $openSourceRepoUrl
  $tempRepoFolderName = $openSourceRepoUrl.Split('/')[-1]
  Set-Location -Path $tempRepoFolderName
  $tempOrgAndRepoName = $openSourceRepoUrl.Split('/')[-2..-1] -join '/'
  gh repo set-default $tempOrgAndRepoName
  git fetch upstream
  git reset --hard upstream/main
  git checkout -b "chore/app-install-avm/$moduleName"

  Install-Module powershell-yaml -Force
  $yamlPath = "./apps/azure/azure-verified-modules.yaml"
  $yamlData = Get-Content -Path $yamlPath | ConvertFrom-Yaml
  $repoList = @($yamlData.repositories)
  $repoList += $repositoryName
  $repoList = $repoList | Sort-Object
  $yamlData.repositories = $repoList
  $yamlData | ConvertTo-Yaml -Options WithIndentedSequences | Set-Content -Path $yamlPath -Force

  git add $yamlPath
  git commit -m "chore: add $moduleName metadata"
  git push --set-upstream origin "chore/app-install-avm/$moduleName"

  $prUrl = gh pr create --title "chore: app install avm $moduleName" --body "This PR requests an app install for the $moduleName module."

  Set-Location $tempPath
  Remove-Item -Path $tempRepoFolderName -Force -Recurse | Out-Null

  Set-Location $currentPath
  Write-Host "Created app installation request PR: $prUrl" -ForegroundColor Cyan
}

$completionMessage = @"
$($ownerMention)The module repository has now been created. You can find it at $repositoryUrl.

The final step of repository configuration is still in progress, but you will be able to start developing your code immediately.

Once the app installation request is approved, your repo will be configured with an environment called ``test``.
Monitor the issue above for updates on the app installation request.
This provides secrets for the test workflows and grants access to an Azure subscription and allows you to run your tests.
If you do not see this environment in your repository after 48 hours, please let us know.

Thanks!
"@

Write-Host ""
Write-Host $completionMessage -ForegroundColor Green
