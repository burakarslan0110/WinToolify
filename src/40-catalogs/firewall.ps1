# Firewall catalog, state, GPO boolean conversion.
# Covered by: tests/FirewallFastStartup.Tests.ps1

# ---------------------------------------------------------------------------
# Network Privacy bundle - Windows Firewall guarded toggle
# ---------------------------------------------------------------------------

function Get-WtFirewallCatalog {
    <#
    .SYNOPSIS
        The Windows Firewall toggle as a state-tracked catalog: one
        entry per direction so live state, staging, profiles and undo
        all speak the same Name-based protocol. The UI offers only the
        direction opposite to the current state.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'Firewall' -Catalog @(
        [PSCustomObject]@{ Name = 'EnableFirewall'; DisplayLabel = 'Windows Firewall: enable all profiles'; Risk = 'SAFE'; Consequence = $null; TargetEnabled = $true }
        [PSCustomObject]@{ Name = 'DisableFirewall'; DisplayLabel = 'Windows Firewall: disable all profiles'; Risk = 'ADVANCED'; Consequence = 'All three firewall profiles (Domain, Private, Public) stop filtering traffic until re-enabled'; TargetEnabled = $false }
    )
}

function Get-WtFirewallState {
    <#
    .SYNOPSIS
        Live-state check for a Get-WtFirewallCatalog entry: Applied is
        true only when every one of the three profiles already matches
        the entry's TargetEnabled (mirrors Get-WtGamingTweak-style state
        checks elsewhere - all-or-nothing, no partial "Applied").
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Entry,
        [scriptblock]$GetProfilesAction = { Get-NetFirewallProfile -Profile Domain, Private, Public }
    )
    $profiles = @(& $GetProfilesAction)
    if ($profiles.Count -eq 0) { return [PSCustomObject]@{ Applied = $false } }
    $mismatch = @($profiles | Where-Object { [bool]$_.Enabled -ne [bool]$Entry.TargetEnabled })
    return [PSCustomObject]@{ Applied = ($mismatch.Count -eq 0) }
}

function Get-WtFirewallRegistryState {
    <#
    .SYNOPSIS
        The firewall's on/off state straight from the registry, in a few
        milliseconds: @{ Enabled; Known }. Skips Get-NetFirewallProfile,
        which costs about a second on first use in a process (the
        NetSecurity import plus a CIM session). Known is false when a
        profile has no readable value, so the caller falls back to the
        cmdlet.
    #>
    param(
        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )
    $enabledCount = 0
    foreach ($profile in 'Domain', 'Standard', 'Public') {
        $value = $null
        foreach ($path in @(
            ('HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\' + $profile + 'Profile')
            ('HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\' + $profile + 'Profile')
        )) {
            $read = Get-WtRegistryValue -Path $path -Name 'EnableFirewall' -GetPropertyAction $GetPropertyAction
            if ($read.Present) { $value = $read.Value; break }
        }
        if ($null -eq $value) { return @{ Enabled = $false; Known = $false } }
        if ([int]$value -ne 0) { $enabledCount++ }
    }
    return @{ Enabled = ($enabledCount -eq 3); Known = $true }
}

function ConvertTo-WtGpoBoolean {
    <#
    .SYNOPSIS
        PURE: a [bool] as the enum name Set-NetFirewallProfile's -Enabled
        parameter accepts ('True'/'False'). A string, not a [GpoBoolean]
        literal: PowerShell cannot cast [bool] to that type directly, and
        the type resolves lazily via the NetSecurity module, so naming it
        here would break parsing on a host without it.
    #>
    param([Parameter(Mandatory)][bool]$Enabled)
    return [string]$Enabled
}
