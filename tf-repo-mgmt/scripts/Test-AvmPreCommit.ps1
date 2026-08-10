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

Write-Host "Avm pre-commit result tests passed."
