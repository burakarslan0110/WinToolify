# System settings screen.
# Covered by: tests/MenuTree.Tests.ps1

function Get-WtSystemSettingsGroups {
    <#
    .SYNOPSIS
        Basic Tools > System Settings: the eight persistent-setting
        sections on one screen, in apply order. Live-environment flags
        (GPU scheduling support, firewall state, DoH support) are carried
        in each group's Data so the delegates read them through the group
        argument, not a closure.
    #>
    param(
        [bool]$GpuSupported = (Test-WtGpuSchedulingSupported),
        [hashtable]$FirewallState = (Get-WtFirewallLiveState),
        [bool]$DohSupported = (Test-WtDohSupported)
    )
    $registryState = { param($e, $g) Get-WtRegistryEntryLiveState -Entry $e }
    $blankState = { param($e, $g) @{ Applied = $false; Available = $true; StateLabel = '' } }
    return @(
        @{ SectionKey = 'PowerPlan'; HeaderKey = 'GroupPowerPerformance'
           GetCatalog = { param($g) Get-WtPowerPlanCatalog }
           GetEntryState = { param($e, $g) $s = Get-WtPowerPlanState -Entry $e; @{ Applied = [bool]$s.Applied; Available = $true } } }
        @{ SectionKey = 'GamingTweaks'; HeaderKey = 'GroupGaming'; Data = @{ GpuSupported = $GpuSupported }
           GetCatalog = { param($g) Get-WtGamingTweakCatalog }
           GetEntryState = {
               param($e, $g)
               if ($e.Name -eq 'EnableGpuScheduling' -and -not $g.Data.GpuSupported) { return @{ Applied = $false; Available = $false; StateLabel = (Get-Translation 'NotSupportedWddm') } }
               Get-WtRegistryEntryLiveState -Entry $e
           } }
        @{ SectionKey = 'FastStartup'; HeaderKey = 'GroupStartup'
           GetCatalog = { param($g) Get-WtFastStartupCatalog }
           GetEntryState = { param($e, $g) $s = Get-WtFastStartupState -Entry $e; @{ Applied = [bool]$s.Applied; Available = $true } } }
        @{ SectionKey = 'Firewall'; HeaderKey = 'GroupFirewall'; Data = @{ FirewallEnabled = [bool]$FirewallState.Enabled; FirewallKnown = [bool]$FirewallState.Known }
           GetCatalog = { param($g) if ($g.Data.FirewallKnown) { @(Get-WtFirewallOfferEntry -CurrentlyEnabled $g.Data.FirewallEnabled) } else { @() } }
           GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true; StateLabel = $(if ($g.Data.FirewallEnabled) { Get-Translation 'FirewallCurrentlyOn' } else { Get-Translation 'FirewallCurrentlyOff' }) } } }
        @{ SectionKey = 'ContextMenu'; HeaderKey = 'GroupContextMenu'
           GetCatalog = { param($g) Get-WtContextMenuCatalog }
           GetEntryState = { param($e, $g) $s = Get-WtShellEntryState -Entry $e; @{ Applied = [bool]$s.Applied; Available = $true } } }
        @{ SectionKey = 'ExplorerView'; HeaderKey = 'GroupExplorerView'
           GetCatalog = { param($g) Get-WtExplorerViewCatalog }
           GetEntryState = $registryState }
        @{ SectionKey = 'DnsPreset'; HeaderKey = 'GroupDns'; Radio = $true; InfoKey = $(if ($DohSupported) { 'DohSupportedInfo' } else { 'DohNotSupportedDisclosure' })
           GetCatalog = { param($g) @(Get-WtDnsPresetCatalog | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DisplayLabel = ('{0}  ({1}, {2})' -f $_.Name, $_.IPv4Primary, $_.IPv4Secondary); Risk = 'CAUTION'; Consequence = $null } }) }
           GetEntryState = $blankState }
        @{ SectionKey = 'Blocklist'; HeaderKey = 'GroupBlocklist'
           GetCatalog = { param($g) Get-WtBlocklistTierCatalog }
           GetEntryState = $blankState }
    )
}

function Get-WtFirewallLiveState {
    <#
    .SYNOPSIS
        @{ Enabled; Known }. The registry is asked first (milliseconds);
        only when it has no answer does the NetSecurity cmdlet run (about
        a second cold). Known is false when neither can say (no module,
        no admin), and the screen then offers no firewall row.
    #>
    param(
        [scriptblock]$GetPropertyAction,
        [scriptblock]$GetProfilesAction
    )
    $registryArgs = @{}
    if ($GetPropertyAction) { $registryArgs['GetPropertyAction'] = $GetPropertyAction }
    $fromRegistry = Get-WtFirewallRegistryState @registryArgs
    if ($fromRegistry.Known) { return @{ Enabled = [bool]$fromRegistry.Enabled; Known = $true } }
    try {
        $enableEntry = @(Get-WtFirewallCatalog) | Where-Object Name -eq 'EnableFirewall' | Select-Object -First 1
        $stateArgs = @{}
        if ($GetProfilesAction) { $stateArgs['GetProfilesAction'] = $GetProfilesAction }
        return @{ Enabled = [bool](Get-WtFirewallState -Entry $enableEntry @stateArgs).Applied; Known = $true }
    }
    catch { return @{ Enabled = $false; Known = $false } }
}

function Invoke-WtSystemSettingsScreen {
    <#
    .SYNOPSIS
        Passes Groups as a scriptblock, not an evaluated array, since the
        firewall row's live probe must be re-taken on every rebuild - an
        evaluated array freezes that probe at screen entry.
    #>
    return Invoke-WtApplyScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'SystemSettings') -Groups { Get-WtSystemSettingsGroups }
}
