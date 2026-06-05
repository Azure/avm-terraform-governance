# Retry wrappers used by the repository sync pipeline.
#
# All three functions return an array of `@{ success = $bool; output = ... }`
# hashtables, one per command. PowerShell unwraps single-element arrays, so
# single-command callers can access fields directly via `$result.success`
# without indexing into `[0]`.

function Invoke-TerraformWithRetry {
    param(
        [hashtable[]]$commands,
        [string]$workingDirectory,
        [string]$outputLog = "output.log",
        [string]$errorLog = "error.log",
        [int]$maxRetries = 50,
        [int]$retryDelayIncremental = 10,
        [string[]]$retryOn = @("429 Too Many Requests", "Client.Timeout exceeded while awaiting headers", "Error: Failed to install provider", "Error: Failed to query available provider packages", "403 API rate limit"),
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutputParsedFromJson
    )

    foreach ($command in $commands) {
        $command.Arguments = @("-chdir=$workingDirectory") + $command.Arguments
    }

    return Invoke-CommandWithRetry `
        -parentCommand "terraform" `
        -commands $commands `
        -outputLog $outputLog `
        -errorLog $errorLog `
        -maxRetries $maxRetries `
        -retryDelayIncremental $retryDelayIncremental `
        -retryOn $retryOn `
        -printOutput:$printOutput.IsPresent `
        -printOutputOnError:$printOutputOnError.IsPresent `
        -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
}

function Invoke-GitHubCliWithRetry {
    param(
        [hashtable[]]$commands,
        [string]$outputLog = "output.log",
        [string]$errorLog = "error.log",
        [int]$maxRetries = 50,
        [int]$retryDelayIncremental = 10,
        [string[]]$retryOn = @("API rate limit exceeded"),
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutputParsedFromJson
    )

    return Invoke-CommandWithRetry `
        -parentCommand "gh" `
        -commands $commands `
        -outputLog $outputLog `
        -errorLog $errorLog `
        -maxRetries $maxRetries `
        -retryDelayIncremental $retryDelayIncremental `
        -retryOn $retryOn `
        -printOutput:$printOutput.IsPresent `
        -printOutputOnError:$printOutputOnError.IsPresent `
        -returnOutputParsedFromJson:$returnOutputParsedFromJson.IsPresent
}

function Invoke-CommandWithRetry {
    param(
        $parentCommand,
        [hashtable[]]$commands,
        [string]$outputLog = "output.log",
        [string]$errorLog = "error.log",
        [int]$maxRetries = 10,
        [int]$retryDelayIncremental = 10,
        [string[]]$retryOn = @("API rate limit exceeded"),
        [switch]$printOutput,
        [switch]$printOutputOnError,
        [switch]$returnOutputParsedFromJson
    )

    $retryCount = 0
    $shouldRetry = $true

    $returnOutputs = @()

    while ($shouldRetry -and $retryCount -le $maxRetries) {
        $shouldRetry = $false

        foreach ($command in $commands) {
            $arguments = $command.Arguments

            $localLogPath = $outputLog
            if ($command.OutputLog) {
                $localLogPath = $command.OutputLog
            }

            Write-Host "Running $parentCommand with arguments: $($arguments -join ' ')"
            $process = Start-Process `
                -FilePath $parentCommand `
                -ArgumentList $arguments `
                -RedirectStandardOutput $localLogPath `
                -RedirectStandardError $errorLog `
                -PassThru `
                -NoNewWindow `
                -Wait

            if ($process.ExitCode -ne 0) {
                Write-Host "$parentCommand failed with exit code $($process.ExitCode)."

                if ($retryOn -contains "*") {
                    $shouldRetry = $true
                } else {
                    $errorOutput = Get-Content -Path $errorLog
                    foreach ($line in $errorOutput) {
                        foreach ($retryError in $retryOn) {
                            if ($line -like "*$retryError*") {
                                Write-Host "Retrying $parentCommand due to error: $line"
                                $shouldRetry = $true
                            }
                        }
                    }
                }

                if ($shouldRetry) {
                    Write-Host "Retrying $parentCommand due to error:"
                    Get-Content -Path $errorLog | Write-Host
                    $retryCount++
                    break
                } else {
                    Write-Host "$parentCommand failed with exit code $($process.ExitCode). Check the logs for details."
                    if ($printOutputOnError) {
                        Write-Host "Output Log:"
                        Get-Content -Path $localLogPath | Write-Host
                    }
                    Write-Host "Error Log:"
                    Get-Content -Path $errorLog | Write-Host
                    $returnOutputs += @{
                        success = $false
                    }
                    return $returnOutputs
                }
            } else {
                if ($printOutput) {
                    Write-Host "Output Log:"
                    Get-Content -Path $localLogPath | Write-Host
                }
                if ($returnOutputParsedFromJson) {
                    $outputContent = Get-Content -Path $localLogPath -Raw
                    $parsedOutput = $outputContent | ConvertFrom-Json
                    $returnOutputs += @{
                        success = $true
                        output  = $parsedOutput
                    }
                } else {
                    $returnOutputs += @{
                        success = $true
                    }
                }
            }
        }
        if ($shouldRetry) {
            if ($retryCount -gt $maxRetries) {
                Write-Host "Max retries reached. Exiting."
                $returnOutputs = @( @{
                        success = $false
                    })
                return $returnOutputs
            }
            Write-Host "Retrying $parentCommand commands (attempt $retryCount of $maxRetries)..."
            $retryDelay = $retryDelayIncremental * $retryCount
            Write-Host "Waiting for $retryDelay seconds before retrying..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    return $returnOutputs
}
