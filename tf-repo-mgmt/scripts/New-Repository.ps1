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
  [switch]$metaDataOnly,
  [switch]$skipRepoCreation,
  [switch]$skipMetaDataCreation,
  [string]$repositorySyncModulePath = "./repository_sync",
  [switch]$skipCleanup
)

$ProgressPreference = "SilentlyContinue"

$moduleNameRegex = "^avm-(res|ptn|utl)-[a-z-]+$"

if($moduleName -notmatch $moduleNameRegex) {
  Write-Error "Module name must be in the format '$moduleNameRegex'" -Category InvalidArgument
  return
}

if(!$skipMetaDataCreation) {

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
}

$repositoryName = "terraform-$moduleProvider-$moduleName"
$repositoryUrl = "https://github.com/Azure/$repositoryName"

if(!$skipRepoCreation) {
  Write-Host ""
  Write-Host "Creating repository $moduleName"

  gh repo create "Azure/$repositoryName" --public --template "Azure/terraform-azurerm-avm-template"

  Write-Host ""
  Write-Host "Created repository $moduleName" -ForegroundColor Green
  Write-Host "Open https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName" -ForegroundColor Yellow
  Write-Host "Click 'Complete Setup' to finish the repository configuration" -ForegroundColor Yellow
  Write-Host "Elevate your permissions with JIT and then come back here to continue" -ForegroundColor Yellow


  Write-Host "Hit Enter to open the open source portal in your browser and complete the setup:" -ForegroundColor Yellow
  Read-Host
  Start-Process "https://repos.opensource.microsoft.com/orgs/Azure/repos/$repositoryName"

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

  $response = ""
  while($response -ne "yes") {
    Write-Host "Once the form is complete and you have elevated with JIT, type 'yes' and hit Enter to continue:" -ForegroundColor Yellow
    $response = Read-Host
  }
}

./scripts/Get-AvmLabels.ps1

./scripts/Invoke-RepositorySync.ps1 `
  -repositoryCreationModeEnabled `
  -planOnly $false `
  -repoId $moduleName `
  -repoUrl $repositoryUrl `
  -skipCleanup:$skipCleanup.IsPresent `
  -primaryModuleOwnerGitHubHandle $ownerPrimaryGitHubHandle `
  -secondaryModuleOwnerGitHubHandle $ownerSecondaryGitHubHandle

Write-Host ""
Write-Host "Terraform apply completed successfully." -ForegroundColor Green

if(!$skipMetaDataCreation) {
  Write-Host "Please approve and merge the repo meta data Pull Request: $prUrl" -ForegroundColor Yellow
  Write-Host "Hit Enter to open the Pull Request in your browser and merge it:" -ForegroundColor Yellow
  Read-Host
  Start-Process $prUrl
}

Write-Host ""
Write-Host "Repository URL:" -ForegroundColor Cyan
Write-Host $repositoryUrl

$ownerMention = ""

if($ownerPrimaryGitHubHandle -ne "") {
  $ownerMention = "@$ownerPrimaryGitHubHandle "
}

$issueComment = @"
$($ownerMention)The module repository has now been created. You can find it at $repositoryUrl.

The final step of repository configuration is still in progress, but you will be able to start developing your code immediately.

The final step is to create the environment and credentials require to run the end to end tests. If the environment called ``test`` is not available in 48 hours, please let me know.

Thanks
"@

Write-Host ""
Write-Host "Here is some text for the GitHub issue comment to notify the module owner about the repository creation:" -ForegroundColor Cyan
Write-Host $issueComment
Write-Host ""
Write-Host ""
Write-Host "All done, thanks!" -ForegroundColor Green
Write-Host ""
Write-Host "Note that the repo sync happens once a day at 15:30 UTC. It will only run for this repository once the GitHub App has been installed in it." -ForegroundColor Yellow
Write-Host "Should you wish to run the sync sooner, you can do so by running the following command once the open source team confirm the app has been installed:" -ForegroundColor Yellow
$workflowDispatchScript = @"
./scripts/Invoke-WorkflowDispatch.ps1 ``
  -inputs @{
    repositories = "$moduleName"
    plan_only = `$false
  }
"@

Write-Host $workflowDispatchScript -ForegroundColor Yellow
