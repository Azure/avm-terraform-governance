# Retry wrappers used by the repository sync pipeline.
#
# The Start-Process-based wrappers (Invoke-*WithRetry) return an array of
# `@{ success = $bool; output = ... }` hashtables, one per command. PowerShell
# unwraps single-element arrays, so single-command callers can access fields
# directly via `$result.success` without indexing into `[0]`.
#
# Invoke-WithRetry is a lighter-weight, scriptblock-based wrapper for the
# inline `gh`/`git` calls in the PR, release and file-sync engines, where the
# caller needs to capture stdout into a variable and make its own success
# decision. It retries transient I/O failures with exponential backoff and
# re-throws everything else (so deterministic failures surface immediately).

# The canonical set of transient error fragments worth retrying for GitHub
# REST/CLI and git network operations: secondary rate limits, 5xx responses,
# and the usual transport hiccups. Matched case-insensitively as substrings.
function Get-GitHubTransientErrorPattern {
    return @(
        "rate limit",
        "secondary rate limit",
        "was submitted too quickly",
        "abuse detection",
        "Too Many Requests",
        "HTTP 408",
        "HTTP 429",
        "HTTP 500",
        "HTTP 502",
        "HTTP 503",
        "HTTP 504",
        "Internal Server Error",
        "Bad gateway",
        "Service Unavailable",
        "Gateway Timeout",
        "Client.Timeout exceeded",
        "i/o timeout",
        "timed out",
        "timeout",
        "Could not resolve host",
        "Connection reset",
        "Connection refused",
        "Connection timed out",
        "TLS handshake",
        "remote end hung up",
        "early EOF",
        "RPC failed",
        "unexpected disconnect",
        "Resource temporarily unavailable",
        "temporarily unavailable"
    )
}

# Run a native-command scriptblock and capture stdout and stderr into SEPARATE
# strings plus the exit code. When a native command's stderr is merged with
# 2>&1, PowerShell wraps each stderr line as an ErrorRecord, so they can be
# split back out by type. This lets callers parse clean stdout on success while
# still surfacing stderr text (transport errors, rate-limit notices) in the
# message they throw on failure.
function Invoke-NativeCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    & $ScriptBlock 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $stderrLines.Add([string]$_)
        }
        else {
            $stdoutLines.Add([string]$_)
        }
    }
    $code = $LASTEXITCODE

    return [pscustomobject]@{
        Code   = $code
        StdOut = ($stdoutLines -join "`n")
        StdErr = ($stderrLines -join "`n")
        All    = ((@($stdoutLines) + @($stderrLines)) -join "`n")
    }
}

# Run a scriptblock, retrying transient failures with exponential backoff.
#
# The scriptblock is responsible for signalling failure by `throw`-ing (for
# native commands, check $LASTEXITCODE and throw a message that INCLUDES the
# captured stderr so transient patterns can be matched). On a thrown error the
# message is tested against $RetryableErrorPatterns: a match (or -RetryOnAnyError)
# triggers a backed-off retry, anything else is re-thrown immediately. The last
# attempt always re-throws. Returns whatever the scriptblock returns on success.
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [string]$OperationName = "operation",
        [int]$MaxAttempts = 5,
        [int]$InitialDelaySeconds = 5,
        [int]$MaxDelaySeconds = 60,
        [double]$BackoffMultiplier = 2.0,
        [string[]]$RetryableErrorPatterns = (Get-GitHubTransientErrorPattern),
        [switch]$RetryOnAnyError
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $message = "$($_.Exception.Message)"
            $isLastAttempt = $attempt -ge $MaxAttempts

            $isRetryable = $RetryOnAnyError.IsPresent
            if (-not $isRetryable) {
                foreach ($pattern in $RetryableErrorPatterns) {
                    if ($message -like "*$pattern*") { $isRetryable = $true; break }
                }
            }

            if ($isLastAttempt -or -not $isRetryable) {
                if (-not $isRetryable) {
                    Write-Host "$OperationName failed with a non-retryable error: $message"
                }
                else {
                    Write-Host "$OperationName still failing after $attempt attempt(s); giving up: $message"
                }
                throw
            }

            Write-Host "::warning title=retry::$OperationName failed (attempt $attempt of $MaxAttempts): $message. Retrying in $delay second(s)..."
            Start-Sleep -Seconds $delay
            $delay = [int][Math]::Min([double]$MaxDelaySeconds, $delay * $BackoffMultiplier)
            if ($delay -lt 1) { $delay = 1 }
        }
    }
}

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
        [string[]]$retryOn = (Get-GitHubTransientErrorPattern),
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
