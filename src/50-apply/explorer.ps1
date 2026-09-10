# Explorer restart and its prompt.
# Covered by: tests/ApplyFlow.Tests.ps1

function Invoke-WtRestartExplorer {
    <#
    .SYNOPSIS
        Restarts the Windows shell so context-menu and view changes become
        visible: stops explorer.exe, then polls for a re-spawned instance
        (never a fixed sleep), starting one manually only on timeout. A
        "new" instance is one whose pid was not running before the stop.
    #>
    param(
        [scriptblock]$StopAction = {
            Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        },

        [scriptblock]$GetProcessAction = {
            return @(Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object Id)
        },

        [scriptblock]$StartAction = {
            Start-Process -FilePath 'explorer.exe' | Out-Null
        },

        [double]$TimeoutSeconds = 10
    )

    $before = @(& $GetProcessAction)
    & $StopAction | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $now = @(& $GetProcessAction)
        $fresh = @($now | Where-Object { $before -notcontains $_ })
        if ($fresh.Count -gt 0) {
            return [PSCustomObject]@{ Restarted = $true; StartedManually = $false }
        }
        Start-Sleep -Milliseconds 250
    }

    & $StartAction | Out-Null
    $after = @(& $GetProcessAction)
    $started = @($after | Where-Object { $before -notcontains $_ })
    return [PSCustomObject]@{ Restarted = ($started.Count -gt 0); StartedManually = $true }
}

function Show-WtExplorerRestartPrompt {
    <#
    .SYNOPSIS
        After a Customization apply: when at least one APPLIED row's catalog
        entry is marked RestartsExplorer, offers one Explorer restart (y/N,
        per apply not per row). Yes runs Invoke-WtRestartExplorer; No prints
        a deferred notice so the user knows why nothing looks different yet.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Results,

        [scriptblock]$Ask = { param($Prompt) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @() -Prompt $Prompt -Layout 'Compact' },
        [scriptblock]$Restart = { Invoke-WtRestartExplorer },
        [scriptblock]$Report = { param($Lines) Wait-WtEnter -Lines $Lines }
    )

    $needsRestart = $false
    foreach ($row in $Results) {
        if (-not $row.Applied) { continue }
        $entry = $Catalog | Where-Object Name -eq $row.Item.CatalogEntry
        if ($entry -and $entry.RestartsExplorer) { $needsRestart = $true; break }
    }
    if (-not $needsRestart) { return }

    $answer = [string](& $Ask (Get-WtYesNoPrompt -Text (Get-Translation 'RestartExplorerPrompt')))
    if (-not (Test-WtAffirmativeAnswer -Answer $answer)) {
        & $Report @((Get-Translation 'RestartExplorerDeferred'))
        return
    }

    $restart = & $Restart
    & $Report @($(if ($restart -and $restart.Restarted) { Get-Translation 'RestartExplorerDone' } else { Get-Translation 'RestartExplorerFailed' }))
}
