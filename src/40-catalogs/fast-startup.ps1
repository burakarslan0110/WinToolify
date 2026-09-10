# Fast Startup catalog and state.
# Covered by: tests/FirewallFastStartup.Tests.ps1

# ---------------------------------------------------------------------------
# Power bundle - Fast Startup / hibernation guarded toggle
# ---------------------------------------------------------------------------

function Get-WtFastStartupCatalog {
    <#
    .SYNOPSIS
        The Fast Startup / hibernation toggle as a state-tracked catalog:
        a single CAUTION entry (powercfg /h off disables hibernation and
        removes Fast Startup, since it relies on hiberfil.sys). Turning it
        back on is the section's TurnOff (-Enable) or Restore-WtUndoEntry.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'FastStartup' -Catalog @(
        [PSCustomObject]@{ Name = 'DisableFastStartup'; DisplayLabel = 'Disable hibernation and Fast Startup (powercfg /h off)'; Risk = 'CAUTION'; Consequence = 'Hibernate disappears from the power menu; hiberfil.sys is deleted; boots do a full kernel init' }
    )
}

function Get-WtFastStartupState {
    <#
    .SYNOPSIS
        Live-state check for the Get-WtFastStartupCatalog entry: Applied
        only when HibernateEnabled is present and equal to 0. Absent
        (never set) and non-zero both mean hibernation/Fast Startup are
        still on - Windows' own default is enabled.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Entry,
        [scriptblock]$GetHibernateValueAction = { Get-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled' }
    )
    $current = & $GetHibernateValueAction
    $applied = [bool]($current.Present -and [int]$current.Value -eq 0)
    return [PSCustomObject]@{ Applied = $applied }
}
