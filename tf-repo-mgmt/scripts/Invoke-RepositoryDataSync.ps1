param(
    [array]$repositories = @(
        @{
            repoId = "avm-res-network-virtualnetwork"
            repoUrl = "https://github.com/Azure/terraform-azurerm-avm-res-network-virtualnetwork"
            repoSubType = "Resource"
            repoOwnerTeam = "@Azure/avm-res-network-virtualnetwork-module-owners-tf"
            repoContributorTeam = "@Azure/avm-res-network-virtualnetwork-module-contributors-tf"
        }
    ),
    [string]$metaDataConfigFilePath = "./repository-meta-data/config.json",
    [string]$metaDataFilePath = "./repository-meta-data/meta-data.csv"
)

# Meta Data
$metaDataConfig = Get-Content -Path $metaDataConfigFilePath | ConvertFrom-Json
$metaData = Get-Content -Path $metaDataFilePath | ConvertFrom-Csv

$repositoryData = @()
$warnings = @()

foreach($repository in $repositories) {
    $repositoryDataMap = @{}
    $repositoryDataMap["calculated.moduleID"] = $repository.repoId
    $repositoryDataMap["calculated.repositoryUrl"] = $repository.repoUrl
    $repositoryDataMap["calculated.moduleType"] = $repository.repoSubType
    $repositoryDataMap["calculated.repoOwnerTeam"] = $repository.repoOwnerTeam
    $repositoryDataMap["calculated.repoContributorTeam"] = $repository.repoContributorTeam

    $repoSplit = $repository.repoUrl.Split("/")

    $orgName = $repoSplit[3]
    $repoName = $repoSplit[4]

    $repoSplit = $repoName.Split("-")
    $providerName = $repoSplit[1]

    $metaData | Where-Object { $_.moduleId -eq $repository.repoId }
    $repositoryDataMap["calculated.moduleDescription"] = "AVM $($repository.repoSubType) Module for $($metaData.moduleDisplayName)"
    foreach($metaDataObject in $metaData.PSObject.Properties) {
        $repositoryDataMap["metadata.$($metaDataObject.Name)"] = $metaDataObject.Value
    }

    # Lookup Terraform Registry Status
    $url = "https://registry.terraform.io/v1/modules/$orgName/$($repository.repoId)/$providerName"
    $registryEntry = Invoke-RestMethod $url -StatusCodeVariable statusCode -SkipHttpErrorCheck

    if($statusCode -ne 404) {
        foreach($registryEntryProperty in $registryEntry.PSObject.Properties) {
            $repositoryDataMap["registry.$($registryEntryProperty.Name)"] = $registryEntryProperty.Value
        }

        $currentVersionUrl = "https://registry.terraform.io/v1/modules/$orgName/$($repository.repoId)/$providerName/$($registryEntry.version)"
        $currentVersionResponse = Invoke-RestMethod $currentVersionUrl -StatusCodeVariable statusCode -SkipHttpErrorCheck
        if($statusCode -eq 200) {
            foreach($currentVersionProperty in $currentVersionResponse.PSObject.Properties) {
                $repositoryDataMap["registry.currentVersion.$($currentVersionProperty.Name)"] = $currentVersionProperty.Value
            }
        }

        $firstVersionUrl = "https://registry.terraform.io/v1/modules/$orgName/$($repository.repoId)/$providerName/$($registryEntry.versions[0])"
        $firstVersionResponse = Invoke-RestMethod $firstVersionUrl -StatusCodeVariable statusCode -SkipHttpErrorCheck
        if($statusCode -eq 200) {
            foreach($firstVersionProperty in $firstVersionResponse.PSObject.Properties) {
                $repositoryDataMap["registry.firstVersion.$($firstVersionProperty.Name)"] = $firstVersionProperty.Value
            }
            $repositoryDataMap["calculated.firstPublishedMonthAndYear"] = $firstVersionResponse.published_at.ToString("yyyy-MM")
        }
    }

    $repositoryData += $repositoryDataMap
}

$repositoryData | ConvertTo-Json -Depth 10 | Out-File -FilePath "repositoryData.json" -Force -Encoding utf8


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
        }
    }

    $fieldMapping = $fieldMapping | Sort-Object order

    $outputData = @()
    foreach($dataItem in $repositoryData) {
        $outputItem = [ordered]@{}
        foreach($fieldMap in $fieldMapping) {
            $outputItem[$fieldMap.name] = $dataItem[$fieldMap.source]
        }
        $outputData += $outputItem
    }
    $outputData | Sort-Object | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $fileName -Force -Encoding utf8
}


foreach($repositoryType in $repositoryTypes) {
    $filteredRepositoryData = $repositoryData | Where-Object { $_.moduleType -eq $repositoryType }
    foreach($repository in $filteredRepositoryData) {
        $repository.Remove("moduleType")
        $repository.Remove("registryFirstPublishedDate")
        $repository.Remove("registryCurrentVersion")
        $repository.Remove("registryModuleOwner")
        $repository.Remove("PublishedStatus")
        $repository.Remove("IsOrphaned")
    }


    $filteredRepositoryData | Sort-Object { $_.ProviderNamespace, $_.ResourceType } | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath "Terraform$($repositoryTypeTitleCase)Modules.csv" -Force -Encoding utf8
}

if($warnings.Count -eq 0) {
    Write-Host "No issues found"
} else {
    Write-Host "Issues found ($($warnings.Count))"
    $warningsJson = ConvertTo-Json $warnings -Depth 100
    $warningsJson | Out-File "warning.log.json"
}
