param(
    [array]$FilesToCompare = @(
        @{
            OldCsvPath = "./temp/TerraformPatternModules.csv"
            NewCsvPath = "./TerraformPatternModules.csv"
            OutputPathNewOnly = "./temp/TerraformPatternModulesNewOnly.csv"
            OutputPathOldOnly = "./temp/TerraformPatternModulesOldOnly.csv"
            MatchOnKey = "ModuleName"
        },
        @{
            OldCsvPath = "./temp/TerraformResourceModules.csv"
            NewCsvPath = "./TerraformResourceModules.csv"
            OutputPathNewOnly = "./temp/TerraformResourceModulesNewOnly.csv"
            OutputPathOldOnly = "./temp/TerraformResourceModulesOldOnly.csv"
            MatchOnKey = "ModuleName"
        },
        @{
            OldCsvPath = "./temp/TerraformUtilityModules.csv"
            NewCsvPath = "./TerraformUtilityModules.csv"
            OutputPathNewOnly = "./temp/TerraformUtilityModulesNewOnly.csv"
            OutputPathOldOnly = "./temp/TerraformUtilityModulesOldOnly.csv"
            MatchOnKey = "ModuleName"
        }
    )
)

foreach($file in $FilesToCompare) {

    $oldCsvData = Import-Csv -Path $file.OldCsvPath
    $newCsvData = Import-Csv -Path $file.NewCsvPath
    $Key = $file.MatchOnKey

    $newOnly = @()
    $oldOnly = @()

    foreach ($row in $newCsvData) {
        $oldRows = $oldCsvData | Where-Object { $_.$Key -eq $row.$Key }

        if($oldRows.Count -eq 0) {
            $newOnly += $row
        }
    }

    foreach ($row in $oldCsvData) {
        $newRows = $newCsvData | Where-Object { $_.$Key -eq $row.$Key }

        if($newRows.Count -eq 0) {
            $oldOnly += $row
        }
    }


    $newOnly | Export-Csv -Path $file.OutputPathNewOnly -NoTypeInformation -Force
    $oldOnly | Export-Csv -Path $file.OutputPathOldOnly -NoTypeInformation -Force
}
