# Invoke-WtGuardedChange.
# Covered by: tests/FirewallFastStartup.Tests.ps1

function Invoke-WtGuardedChange {
    <#
    .SYNOPSIS
        Shared orchestrator behind both the service and package apply
        paths: capture pre-change state -> write undo entry -> apply per
        item -> re-read post-apply state. Order is load-bearing: applying
        before the undo entry is written means a crash mid-apply leaves no
        record of what to restore. The re-read runs after Apply returns
        regardless of whether Apply threw, since a cmdlet can succeed while
        policy or a pending reboot leaves the item unchanged.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$CaptureState,

        [Parameter(Mandatory)]
        [scriptblock]$Apply,

        [Parameter(Mandatory)]
        [scriptblock]$ReReadState,

        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [scriptblock]$WriteUndoAction = {
            param($Scope, $ActionName, $Items, $TestRootOverride)
            if ($TestRootOverride) {
                Write-WtUndoEntry -Scope $Scope -Action $ActionName -Items $Items -TestRootOverride $TestRootOverride
            }
            else {
                Write-WtUndoEntry -Scope $Scope -Action $ActionName -Items $Items
            }
        },

        [string]$TestRootOverride
    )

    $items = @(& $CaptureState)

    & $WriteUndoAction $Scope $ActionName $items $TestRootOverride | Out-Null

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $applyError = $null
        try {
            & $Apply $item
        }
        catch {
            $applyError = $_.Exception.Message
        }

        $applied = $false
        try {
            $applied = [bool](& $ReReadState $item)
        }
        catch {
            $applied = $false
        }

        $results.Add([PSCustomObject]@{
            Item    = $item
            Applied = $applied
            Error   = $applyError
        })
    }

    return [PSCustomObject]@{ Aborted = $false; Results = $results.ToArray() }
}
