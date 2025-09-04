param(
    [array]$repositories = @(
        @{
            repoId = "avm-res-network-virtualnetwork"
            repoUrl = "https://github.com/Azure/terraform-azurerm-avm-res-network-virtualnetwork"
            repoSubType = "Resource"
        }
    ),
    [string]$metaDataConfigFilePath = "./repository-meta-data/config.json",
    [string]$metaDataFilePath = "./repository-meta-data/meta-data.csv",
    [string]$outputDirectory = ".",
    [string]$applicationName = "azure-verified-modules",
    [string]$applicationId = "1049636",
    [switch]$includeDetailedVersionData
)

# Meta Data
$metaDataConfig = Get-Content -Path $metaDataConfigFilePath | ConvertFrom-Json
$metaData = Get-Content -Path $metaDataFilePath | ConvertFrom-Csv

$repositoryData = @()
$warnings = @()

foreach($repository in $repositories) {
    $repositoryDataMap = @{}
    $repositoryDataMap["repo.moduleID"] = $repository.repoId
    $repositoryDataMap["repo.repositoryUrl"] = $repository.repoUrl
    $repositoryDataMap["repo.moduleType"] = $repository.repoSubType

    $repoSplit = $repository.repoUrl.Split("/")

    $orgName = $repoSplit[3]
    $repoName = $repoSplit[4]

    $repoSplit = $repoName.Split("-")
    $providerName = $repoSplit[1]

    $filteredMetaData = $metaData | Where-Object { $_.moduleId -eq $repository.repoId }

    if($filteredMetaData.Count -eq 0) {
        $warning = @{
            repoId = $repository.repoId
            message = "No metadata found for repository $($repository.repoId). Skipping..."
        }
        Write-Warning $warning.message
        $warnings += $warning
        continue
    }

    $isOrphaned = ($null -eq $filteredMetaData.primaryOwnerGitHubHandle -or $filteredMetaData.primaryOwnerGitHubHandle -eq "")
    $repositoryDataMap["calculated.isOrphaned"] = $isOrphaned

    $repositoryDataMap["calculated.moduleDescription"] = "AVM $($repository.repoSubType) Module for $($filteredMetaData.moduleDisplayName)"
    foreach($metaDataObject in $filteredMetaData.PSObject.Properties) {
        $repositoryDataMap["metadata.$($metaDataObject.Name)"] = $metaDataObject.Value
    }

    # Lookup Terraform Registry Status
    $url = "https://registry.terraform.io/v1/modules/$orgName/$($repository.repoId)/$providerName"
    $registryEntry = Invoke-RestMethod $url -StatusCodeVariable statusCode -SkipHttpErrorCheck

    if($statusCode -ne 404) {
        $repositoryDataMap["registry.registryUrl"] = "https://registry.terraform.io/modules/$orgName/$($repository.repoId)/$providerName/latest"
        foreach($registryEntryProperty in $registryEntry.PSObject.Properties) {
            $repositoryDataMap["registry.$($registryEntryProperty.Name)"] = $registryEntryProperty.Value
        }

        $firstVersionUrl = "https://registry.terraform.io/v2/modules/$orgName/$($repository.repoId)/$providerName/$($registryEntry.versions[0])"
        $firstVersionResponse = Invoke-RestMethod $firstVersionUrl -StatusCodeVariable statusCode -SkipHttpErrorCheck
        if($statusCode -eq 200) {
            $repositoryDataMap["registry.firstVersion.version"] = $firstVersionResponse.version
            $repositoryDataMap["registry.firstVersion.tag"] = $firstVersionResponse.tag
            $repositoryDataMap["registry.firstVersion.published_at"] = $firstVersionResponse."published-at"
            $repositoryDataMap["calculated.firstPublishedMonthAndYear"] = $firstVersionResponse."published-at".ToString("yyyy-MM")
        }
        $repositoryDataMap["calculated.publishedStatus"] = "Published"
        $repositoryDataMap["calculated.moduleStatus"] = $isOrphaned ? "Orphaned" : "Available"
        $repositoryDataMap["registry.versions"] = $registryEntry.versions
        if($includeDetailedVersionData) {
            $detailedVersionData = @()
            foreach($version in $registryEntry.versions) {
                $versionUrl = "https://registry.terraform.io/v2/modules/$orgName/$($repository.repoId)/$providerName/$($version)"
                $versionResponse = Invoke-RestMethod $versionUrl -StatusCodeVariable statusCode -SkipHttpErrorCheck
                if($statusCode -eq 200) {
                    $detailedVersionData += @{
                        version = $versionResponse.data.attributes.version
                        releaseDate = $versionResponse.data.attributes."published-at"
                        tag = $versionResponse.data.attributes.version
                        downloads = $versionResponse.data.attributes.downloads
                    }
                }
            }
            $repositoryDataMap["registry.versionsDetailed"] = $detailedVersionData
        }
    } else {
        $repositoryDataMap["calculated.publishedStatus"] = "Not Published"
        $repositoryDataMap["calculated.moduleStatus"] = "Proposed"
    }

    $repositoryData += $repositoryDataMap
}

$repositoryData | ConvertTo-Json -Depth 100 | Out-File -FilePath "$outputDirectory/repositoryData.json" -Force -Encoding utf8
Write-Host "Repository data written to $outputDirectory/repositoryData.json"

foreach($output in $metaDataConfig.outputs) {
    $fileName = $output.fileName
    $filteredFields = $metaDataConfig.metaData | Where-Object { $_.mapsTo.output -contains $output.name }

    $fieldMapping = @()

    foreach($filteredField in $filteredFields) {
        $fieldMappingData = $filteredField.mapsTo | Where-Object { $_.output -eq $output.name }

        $fieldMapping += @{
            order = $fieldMappingData.outputColumnOrder
            name = $fieldMappingData.outputColumnName
            source = $filteredField.source
            required = $null -eq $filteredField.required ? $false : $filteredField.required
            requiredFilters = $filteredField.requiredFilters
        }
    }

    $fieldMapping = $fieldMapping | Sort-Object order

    $outputData = @()
    foreach($dataItem in $repositoryData) {

        if($output.filters) {
            $meetsAllFilters = $true

            foreach($filter in $output.filters) {
                $field = $metaDataConfig.metaData | Where-Object { $_.name -eq $filter.name }
                if($null -eq $field) {
                    Write-Warning "Filter field '$($filter.name)' not found in metadata configuration."
                    continue
                }

                if($filter.match -eq "equals") {
                    if($dataItem[$field.source] -ne $filter.value) {
                        $meetsAllFilters = $false
                        break
                    }
                }
            }

            if(!$meetsAllFilters) {
                continue
            }
        }

        $outputItem = [ordered]@{}
        foreach($fieldMap in $fieldMapping) {
            $outputItem[$fieldMap.name] = $dataItem[$fieldMap.source]
            if($null -eq $outputItem[$fieldMap.name]) {
                $outputItem[$fieldMap.name] = ""
            }

            if($outputItem[$fieldMap.name] -eq "") {
                if($fieldMap.required) {
                    $warning = @{
                        repoId = $dataItem["repo.moduleID"]
                        message = "Required field '$($fieldMap.name)' is missing for repository $($dataItem["repo.moduleID"])."
                    }
                    Write-Warning $warning.message
                    $warnings += $warning
                }
                if($fieldMap.requiredFilters -and $fieldMap.requiredFilters.Count -gt 0) {
                    $required = $false
                    foreach($filter in $fieldMap.requiredFilters) {
                        if($filter.match -eq "equals") {
                            $field = $metaDataConfig.metaData | Where-Object { $_.name -eq $filter.name }
                            if($dataItem[$field.source] -eq $filter.value) {
                                $required = $true
                                break
                            }
                        }
                    }
                    if($required) {
                        $warning = @{
                            repoId = $dataItem["repo.moduleID"]
                            message = "Required field '$($fieldMap.name)' is missing for repository $($dataItem["repo.moduleID"]) as required filters are not met."
                        }
                        Write-Warning $warning.message
                        $warnings += $warning
                    }
                }
            }
        }
        $outputData += $outputItem
    }
    $outputData | ConvertTo-Csv -NoTypeInformation -UseQuotes AsNeeded | Out-File -FilePath "$outputDirectory/$fileName" -Force -Encoding utf8
    Write-Host "Output written to $outputDirectory/$fileName"
}

if($warnings.Count -eq 0) {
    Write-Host "No issues found"
} else {
    Write-Host "Issues found ($($warnings.Count))"
    $warningsJson = ConvertTo-Json $warnings -Depth 100
    $warningsJson | Out-File "$outputDirectory/warning.log.json"
    Write-Host "Warnings written to $outputDirectory/warning.log.json"
}

# PR
$currentPath = Get-Location
$outputDirectoryAbsolute = (Resolve-Path $outputDirectory).Path
$tempFolder = "$outputDirectory/temp"
$tempRepoFolderName = "repository-data-sync"

New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
Set-Location -Path $tempFolder
$avmDocsRepositoryName = "https://github.com/Azure/Azure-Verified-Modules"
git clone $avmDocsRepositoryName $tempRepoFolderName
Set-Location -Path $tempRepoFolderName

Copy-Item -Path "$outputDirectoryAbsolute/*.csv" -Destination "./docs/static/module-indexes" -Force

git add .
$gitStatus = git status --porcelain

if(!$gitStatus) {
    Write-Host "No changes to commit. Exiting..."
    exit 0
}

git reset --hard HEAD

$existingPR = gh pr list --state open --search "chore: terraform csv update" --json number,title,url,headRefName --repo $avmDocsRepositoryName | ConvertFrom-Json

$dateStamp = (Get-Date).ToString("yyyyMMddHHmmss")
$branchName = "chore/repository-data-sync/$dateStamp"

$isNewBranch = $false
if($existingPR.Count -gt 0) {
    $existingBranch = $existingPR[0].headRefName.Replace("refs/heads/", "")
    git switch $existingBranch
} else {
    git checkout -b $branchName
    $isNewBranch = $true
}

Copy-Item -Path "$outputDirectoryAbsolute/*.csv" -Destination "./docs/static/module-indexes" -Force

git add .
$gitStatus = git status --porcelain

if(!$gitStatus) {
    Write-Host "No changes to commit. Exiting..."
    exit 0
}

gh auth setup-git
git config user.name "$applicationName[bot]"
git config user.email "$applicationId+$applicationName[bot]@users.noreply.github.com"

git commit -m "chore: terraform csv update $dateStamp"

if($isNewBranch) {
    git push --set-upstream origin "chore/repository-data-sync/$dateStamp"
    $prUrl = gh pr create --title "chore: terraform csv update $dateStamp" --body "This PR updates the Terraform CSV files with the latest data." --base main --head $branchName
    Write-Host "Created PR for repository data sync: $prUrl"
} else {
    git push
    $prUrl = $existingPR[0].url
    Write-Host "Updated existing PR for repository data sync: $prUrl"
}

Set-Location -Path $currentPath
Remove-Item -Path $tempFolder -Force -Recurse | Out-Null







