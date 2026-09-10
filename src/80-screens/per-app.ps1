# Per-app permission screen.
# Covered by: tests/PerAppPermission.Tests.ps1

function Get-WtRegistryEntryLiveState {
    <#
    .SYNOPSIS
        The common GetEntryState for registry-backed catalogs
        (Telemetry, Explorer View, Gaming, ...): Applied from the live
        registry, always available.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Entry)
    $state = Get-WtRegistryEntryState -Entry $Entry
    return @{ Applied = [bool]$state.Applied; Available = $true }
}

function Invoke-WtApplyPerAppPermissionGroups {
    <#
    .SYNOPSIS
        Commit-side adapter for PerAppPermissions: groups staged
        "<capability>|<package family name>" names by capability and runs
        the guarded apply once per group (one undo entry each), aggregating
        results; the first Aborted group stops the rest, like sections do.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [Parameter(Mandatory)][string]$Sid,
        [ValidateSet('Deny', 'Allow')][string]$Value = 'Deny',
        [scriptblock]$ApplyAction = {
            param($Capability, $Sid, [string[]]$Names, $Value)
            $action = if ($Value -eq 'Allow') { 'Revert Per-App Permission' } else { 'Apply Per-App Permission' }
            Invoke-WtApplyPerAppPermissionSelection -Capability $Capability -Sid $Sid -SelectedNames $Names -Value $Value -ActionName $action
        }
    )
    $groups = [ordered]@{}
    foreach ($n in $Names) {
        $idx = $n.IndexOf('|')
        if ($idx -lt 1 -or $idx -ge ($n.Length - 1)) { continue }
        $cap = $n.Substring(0, $idx)
        $app = $n.Substring($idx + 1)
        if (-not $groups.Contains($cap)) { $groups[$cap] = New-Object System.Collections.Generic.List[string] }
        $groups[$cap].Add($app)
    }
    $results = New-Object System.Collections.Generic.List[object]
    $aborted = $false
    foreach ($cap in @($groups.Keys)) {
        $r = & $ApplyAction $cap $Sid ([string[]]$groups[$cap].ToArray()) $Value
        if ($r -and $r.Aborted) { $aborted = $true; break }
        if ($r) { foreach ($x in @($r.Results)) { $results.Add($x) } }
    }
    return [PSCustomObject]@{ Aborted = $aborted; Results = $results.ToArray() }
}

function Get-WtFirewallOfferEntry {
    <#
    .SYNOPSIS
        The single firewall catalog entry worth offering: the direction
        opposite to the live state (enabled -> offer Disable, ADVANCED;
        disabled -> offer Enable, SAFE).
    #>
    param(
        [Parameter(Mandatory)][bool]$CurrentlyEnabled,
        [array]$Catalog = (Get-WtFirewallCatalog)
    )
    $target = if ($CurrentlyEnabled) { 'DisableFirewall' } else { 'EnableFirewall' }
    return ($Catalog | Where-Object Name -eq $target | Select-Object -First 1)
}

# --- settings screens (mark with Space, apply with Enter) -----------------

function Invoke-WtPerAppScreen {
    <#
    .SYNOPSIS
        One screen, two panes: pick a capability, then the apps it needs
        (check rows); stages each as "<capability>|<package family name>".
        Re-enumerated every rebuild, not cached, so a repeat Enter sees
        post-apply state instead of re-recording the same undo.
    #>
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'PrivacySettings', 'PerAppPermissions'
    $sid = Get-WtConsoleUserSid
    if (-not $sid) {
        $script:WtPanelBreadcrumb = $crumb
        Wait-WtEnter -Lines @((Get-Translation 'CouldNotDetermineAccount'))
        return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
    }
    $capabilities = @(Get-WtAppPermissionCatalog)
    $capItems = @($capabilities | ForEach-Object { New-WtListItem -Kind 'Radio' -Name $_.Name -Label (Get-WtSelectorDisplayLabel -Entry $_) -Data $_ })
    $capSelection = New-Object 'System.Collections.Generic.HashSet[string]'
    while ($true) {
        $r = Invoke-WtListScreen -Breadcrumb $crumb -Items $capItems -MultiSelect $false -Selection $capSelection -FooterText (Get-Translation 'NavFooter')
        if ($r.Emit -eq 'Back' -or $r.Emit -eq 'Quit') { return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false } }
        if ($r.Emit -ne 'Activate' -or -not $r.Item) { continue }
        $capability = $r.Item.Data
        $apps = @(Get-WtAppsForCapability -Capability $capability.Name -Sid $sid)
        if ($apps.Count -eq 0) {
            $script:WtPanelBreadcrumb = [string]$r.Item.Label
            Wait-WtEnter -Lines @((Get-Translation 'NoAppsRequestedCapability'))
            continue
        }
        $capName = [string]$capability.Name
        $capLabel = [string]$r.Item.Label
        $group = @{
            SectionKey = 'PerAppPermissions'; HeaderKey = $null
            Data = @{ Capability = $capName; Sid = $sid; CapLabel = $capLabel }
            GetCatalog = {
                param($g)
                @(Get-WtAppsForCapability -Capability $g.Data.Capability -Sid $g.Data.Sid | ForEach-Object {
                    [PSCustomObject]@{
                        Name         = ('{0}|{1}' -f $g.Data.Capability, $_.Name)
                        DisplayLabel = ('{0}: {1}' -f $g.Data.CapLabel, $_.DisplayLabel)
                        Risk         = 'SAFE'
                        Consequence  = $null
                        Selectable   = [bool]$_.Selectable
                    }
                })
            }
            GetEntryState = { param($e, $g) @{ Applied = (-not $e.Selectable); Available = $true } }
        }
        $inner = Invoke-WtApplyScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'PrivacySettings', 'PerAppPermissions' -Suffix $capLabel) -Groups @($group)
        if ($inner.Nav -eq 'Exit') { return $inner }
    }
}
