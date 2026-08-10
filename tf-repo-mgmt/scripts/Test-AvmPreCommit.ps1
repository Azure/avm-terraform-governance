Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/AvmPreCommit.ps1")

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$MessagePattern
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got '$($_.Exception.Message)'."
        }
        return
    }

    throw "Expected an error matching '$MessagePattern'."
}

Assert-AvmPreCommitResult -preCommitResult ([pscustomobject]@{
    Status = "pass"
    Steps = @()
})

Assert-Throws -MessagePattern "avm pre-commit returned status 'fail'.*transform: fail*" -Action {
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

Assert-Throws -MessagePattern "avm pre-commit returned status 'fail'.*check convention: fail - Required file 'README.md' does not exist.*'.gitignore' is missing required glob '.terraform'.*docs: fail - 'README.md' is out of date.*" -Action {
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
                            Message = "Required file 'README.md' does not exist."
                        }
                        [pscustomobject]@{
                            Message = "'.gitignore' is missing required glob '.terraform'."
                        }
                    )
                }
            }
            [pscustomobject]@{
                Step = "docs"
                Status = "fail"
                Error = $null
                Result = [pscustomobject]@{
                    Issues = @(
                        [pscustomobject]@{
                            Message = "'README.md' is out of date."
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
