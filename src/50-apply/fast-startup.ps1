# Invoke-WtApplyFastStartupSelection.
# Covered by: tests/FirewallFastStartup.Tests.ps1

function Invoke-WtApplyFastStartupSelection {
    <#
    .SYNOPSIS
        Guarded hibernation/Fast Startup disable via Invoke-WtGuardedChange.
        WasEnabled is $true when the pre-change value is absent or non-zero
        (Windows default is enabled), so undo can tell an already-off
        machine from one this run changed; -Enable means powercfg /h on.
    #>
    param(
        [Parameter(Mandatory)][string[]]$SelectedNames,
        [switch]$Enable,
        [scriptblock]$GetHibernateValueAction = { Get-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled' },
        [scriptblock]$SetHibernateAction = { param($On) if ($On) { powercfg /h on } else { powercfg /h off } },
        [string]$TestRootOverride
    )

    $catalog = Get-WtFastStartupCatalog
    $catalogNames = @($catalog | ForEach-Object Name)
    $picked = @($SelectedNames | Where-Object { $catalogNames -contains $_ })
    if ($picked.Count -eq 0) { return [PSCustomObject]@{ Aborted = $false; Results = @() } }
    $entry = $catalog | Where-Object Name -eq $picked[-1] | Select-Object -First 1

    $captureState = {
        $current = & $GetHibernateValueAction
        $wasEnabled = [bool](-not ($current.Present -and [int]$current.Value -eq 0))
        @(
            [PSCustomObject]@{
                ItemType     = 'HibernationState'
                Name         = 'Hibernation'
                WasEnabled   = $wasEnabled
                CatalogEntry = $entry.Name
            }
        )
    }

    $apply = { param($Item) & $SetHibernateAction ([bool]$Enable) }

    $reReadState = {
        param($Item)
        $current = & $GetHibernateValueAction
        $disabled = [bool]($current.Present -and [int]$current.Value -eq 0)
        if ($Enable) { return (-not $disabled) }
        return $disabled
    }

    if ($Enable) {
        if ($TestRootOverride) {
            return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
                -Scope Machine -ActionName 'Enable Fast Startup' -TestRootOverride $TestRootOverride
        }
        return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
            -Scope Machine -ActionName 'Enable Fast Startup'
    }
    if ($TestRootOverride) {
        return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
            -Scope Machine -ActionName 'Disable Fast Startup' -TestRootOverride $TestRootOverride
    }
    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
        -Scope Machine -ActionName 'Disable Fast Startup'
}
