Import-Module Az.ResourceGraph

$clientId = Get-AutomationVariable -Name 'ARM_CLIENT_ID'

Disable-AzContextAutosave -Scope Process
$Result = (Connect-AzAccount -Identity -AccountId $clientId).context

$testSubscriptions = Get-AutomationVariable -Name 'TEST_SUBSCRIPTION_IDS' | ConvertFrom-Json

Write-Output "Found $($testSubscriptions.Length) subscriptions"

$reaperDelay = Get-AutomationVariable -Name 'REAPER_DELAY_HOURS'
$resourceGraphQueryLookBackDays = Get-AutomationVariable -Name 'RESOURCE_GRAPH_QUERY_LOOK_BACK_DAYS'

foreach($testSubscription in $testSubscriptions) {

    $subscriptionId = $testSubscription.id

    Write-Output "Connecting to Subscription Id: $subscriptionId"
    $Result = Remove-AzContext -InputObject (Get-AzContext) -Force
    $Result = Set-AzContext -Subscription $subscriptionId

    $connectedSubscriptionId = (Get-AzContext).Subscription.id

    Write-Output "Connected to Subscription Id: $connectedSubscriptionId"

    $currentDate = Get-Date
    $reapDate = ($currentDate).AddHours(0 - $reaperDelay)

    Write-Output "Current time stamp: $currentDate"
    Write-Output "Reap time stamp: $reapDate"

    $resourceGroups = Get-AzResourceGroup
    $isFirstRun = $true

    while($resourceGroups.Length -gt 0) {

        $resourceGraphQuery = @"
resourcecontainerchanges
    | where subscriptionId == "$subscriptionId"
    | where properties.targetResourceType == "microsoft.resources/subscriptions/resourcegroups"
    | where properties.changeType == "Create"
    | where todatetime(properties.changeAttributes.timestamp) > now(-$($resourceGraphQueryLookBackDays)d)
    | extend changeTime = todatetime(properties.changeAttributes.timestamp), resourceGroupName = split(properties.targetResourceId, "/")[4]
    | order by changeTime desc
    | project changeTime, resourceGroupName
"@
        $resourceGroupQueryResults = Search-AzGraph -Query $resourceGraphQuery -First 1000

        $resourceGroupDates = @{}

        foreach($resourceGroupQueryResult in $resourceGroupQueryResults) {
            if($resourceGroupDates.ContainsKey($resourceGroupQueryResult.resourceGroupName)) {
                continue
            }
            $resourceGroupDates.Add($resourceGroupQueryResult.resourceGroupName, $resourceGroupQueryResult.changeTime)
        }

        Write-Output "Found $($resourceGroupDates.Count) resource groups created in last $resourceGraphQueryLookBackDays days:"
        Write-Verbose (ConvertTo-Json $resourceGroupDates)

        $eventuallyConsistentResourceGroups = @()

        foreach($resourceGroup in $resourceGroups) {
            $resourceGroupName = $resourceGroup.ResourceGroupName
            Write-Output "Checking resource group: $resourceGroupName"
            if($resourceGroupName -eq "NetworkWatcherRG") {
                Write-Output "Skipping $resourceGroupName"
                continue
            }

            if(!$resourceGroupDates.ContainsKey($resourceGroupName)) {
                if($isFirstRun) {
                    Write-Output "Can't find the created date for $resourceGroupName, skipping in case it is new, but will check again shortly..."
                    $eventuallyConsistentResourceGroups += $resourceGroup
                } else {
                    Write-Output "Can't find the created date for $resourceGroupName after waiting for eventual consistency. Deleting it anyway..."
                    Remove-AzResourceGroup -Name $resourceGroupName -Force
                }
                continue
            }

            $createdDate = $resourceGroupDates[$resourceGroupName]
            if($reapDate -gt $createdDate) {
                Write-Output "Reaper time has passed, deleting $resourceGroupName"
                Remove-AzResourceGroup -Name $resourceGroupName -Force
            } else {
                Write-Output "Reaper time has not passed yet for $resourceGroupName, it is $createdDate"
            }
        }

        if($eventuallyConsistentResourceGroups.Length -gt 0) {
            Write-Output "Found $($eventuallyConsistentResourceGroups.Length) resource groups with no created date. Waiting 60 seconds, then trying again..."
            Start-Sleep -seconds 60
        }

        $resourceGroups = $eventuallyConsistentResourceGroups
        $isFirstRun = $false
    }
}
