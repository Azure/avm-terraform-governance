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

Assert-Throws -MessagePattern "avm pre-commit returned status 'missing'.*" -Action {
    Assert-AvmPreCommitResult -preCommitResult $null
}

Write-Host "Avm pre-commit result tests passed."
