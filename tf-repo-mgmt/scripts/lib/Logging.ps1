# Logging helpers used by the repository sync pipeline.

function Add-IssueToLog {
    param(
        [string]$orgAndRepoName,
        [string]$type,
        [string]$message,
        [object]$data,
        [array]$issueLog,
        [ValidateSet("warning", "error")]
        [string]$severity = "error",
        [string]$issueLogFile = "issue.log"
    )

    $issueLogItem = @{
        orgAndRepoName = $orgAndRepoName
        type           = $type
        severity       = $severity
        message        = $message
        data           = $data
    }

    $issueLog += $issueLogItem

    $issueLogItemJson = ConvertTo-Json $issueLogItem -Depth 100
    Add-Content -Path $issueLogFile -Value $issueLogItemJson

    return $issueLog
}
