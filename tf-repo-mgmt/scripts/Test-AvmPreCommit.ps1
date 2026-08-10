Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/AvmPreCommit.ps1")

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$MessagePattern,
        [string]$ExpectedMessage,
        [string]$MessageNotPattern
    )

    try {
        & $Action
    } catch {
        $message = $_.Exception.Message
        if ($ExpectedMessage -and $message -cne $ExpectedMessage) {
            throw "Expected error '$ExpectedMessage', got '$message'."
        }
        if ($MessagePattern -and $message -notlike $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got '$message'."
        }
        if ($MessageNotPattern -and $message -like $MessageNotPattern) {
            throw "Expected error not matching '$MessageNotPattern', got '$message'."
        }
        return
    }

    throw "Expected an error matching '$MessagePattern'."
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Description
    )

    if ($Actual -ne $Expected) {
        throw "Expected $Description to be '$Expected', got '$Actual'."
    }
}

Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
    Status = "pass"
    Steps = @()
})

Assert-Throws `
    -ExpectedMessage "avm pre-commit returned status 'fail'. Failed steps: transform: fail - Mapotf failed.." `
    -MessageNotPattern "*Issues:*" `
    -Action {
    Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
        Status = "fail"
        Steps = @(
            [pscustomobject]@{
                Step = "transform"
                Status = "fail"
                Error = "Mapotf failed."
            }
        )
    })
}

Assert-Throws `
    -MessagePattern "avm pre-commit returned status 'fail'.*check convention: fail - Issues: Required file '_header.md' does not exist. | Required directory 'tests' must contain at least 1 immediate child item; found 0.*" `
    -Action {
    Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
        Status = "fail"
        Steps = @(
            [pscustomobject]@{
                Step = "check convention"
                Status = "fail"
                Error = $null
                Result = [pscustomobject]@{
                    Issues = @(
                        [pscustomobject]@{
                            Message = "Required file '_header.md' does not exist."
                        }
                        [pscustomobject]@{
                            Message = "Required directory 'tests' must contain at least 1 immediate child item; found 0."
                        }
                    )
                }
            }
        )
    })
}

Assert-Throws -MessagePattern "avm pre-commit returned status 'missing'.*" -Action {
    Assert-AvmPreCommitResult -preCommitResult $null
}

$script:moduleImportCount = 0
$script:moduleUpdateCount = 0
$script:preCommitInvocationCount = 0
$script:preCommitErrorCodes = @()
$script:moduleUpdateParameters = @{}

function Import-Module {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [switch]$Force
    )

    $script:moduleImportCount++
}

function Update-PSResource {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Scope,
        [switch]$TrustRepository
    )

    $script:moduleUpdateCount++
    $script:moduleUpdateParameters = @{} + $PSBoundParameters
}

function Invoke-AvmPreCommit {
    param(
        [string]$Ecosystem,
        [string]$RepoId,
        [string]$ManagedFilesLocalPath,
        [string]$ConfigLocalPath
    )

    $script:preCommitInvocationCount++
    if ($script:preCommitInvocationCount -le $script:preCommitErrorCodes.Count) {
        $exception = [System.InvalidOperationException]::new("A newer version of Avm.Authoring is required.")
        $exception | Add-Member -NotePropertyName Code -NotePropertyValue $script:preCommitErrorCodes[$script:preCommitInvocationCount - 1]
        throw $exception
    }

    return [pscustomobject]@{
        Status = "pass"
        Steps = @()
    }
}

try {
    $script:preCommitErrorCodes = @("AVM1050")
    $result = Invoke-AvmPreCommitWithUpgradeRetry `
        -repoId "avm-res-test" `
        -managedFilesBaseDir "managed-files" `
        -repositoryConfigDir "repository-config"

    Assert-Equal -Actual $result.Status -Expected "pass" -Description "pre-commit status after upgrade"
    Assert-Equal -Actual $script:preCommitInvocationCount -Expected 2 -Description "pre-commit invocation count"
    Assert-Equal -Actual $script:moduleImportCount -Expected 2 -Description "module import count"
    Assert-Equal -Actual $script:moduleUpdateCount -Expected 1 -Description "module update count"
    Assert-Equal -Actual $script:moduleUpdateParameters.Name -Expected "Avm.Authoring" -Description "updated module name"
    Assert-Equal -Actual $script:moduleUpdateParameters.Scope -Expected "CurrentUser" -Description "module update scope"
    Assert-Equal -Actual $script:moduleUpdateParameters.TrustRepository.IsPresent -Expected $true -Description "trusted repository switch"

    $script:moduleImportCount = 0
    $script:moduleUpdateCount = 0
    $script:preCommitInvocationCount = 0
    $script:preCommitErrorCodes = @("AVM9999")

    Assert-Throws `
        -ExpectedMessage "A newer version of Avm.Authoring is required." `
        -Action {
        Invoke-AvmPreCommitWithUpgradeRetry `
            -repoId "avm-res-test" `
            -managedFilesBaseDir "managed-files" `
            -repositoryConfigDir "repository-config"
    }

    Assert-Equal -Actual $script:preCommitInvocationCount -Expected 1 -Description "unrelated error invocation count"
    Assert-Equal -Actual $script:moduleImportCount -Expected 1 -Description "unrelated error import count"
    Assert-Equal -Actual $script:moduleUpdateCount -Expected 0 -Description "unrelated error update count"

    $script:moduleImportCount = 0
    $script:moduleUpdateCount = 0
    $script:preCommitInvocationCount = 0
    $script:preCommitErrorCodes = @("AVM1050", "AVM1050")

    Assert-Throws `
        -ExpectedMessage "A newer version of Avm.Authoring is required." `
        -Action {
        Invoke-AvmPreCommitWithUpgradeRetry `
            -repoId "avm-res-test" `
            -managedFilesBaseDir "managed-files" `
            -repositoryConfigDir "repository-config"
    }

    Assert-Equal -Actual $script:preCommitInvocationCount -Expected 2 -Description "retry failure invocation count"
    Assert-Equal -Actual $script:moduleImportCount -Expected 2 -Description "retry failure import count"
    Assert-Equal -Actual $script:moduleUpdateCount -Expected 1 -Description "retry failure update count"
} finally {
    Remove-Item Function:Import-Module
    Remove-Item Function:Update-PSResource
    Remove-Item Function:Invoke-AvmPreCommit
}

Write-Host "Avm pre-commit result tests passed."
