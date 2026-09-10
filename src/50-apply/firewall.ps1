# Invoke-WtApplyFirewallSelection.
# Covered by: tests/FirewallFastStartup.Tests.ps1

function Invoke-WtApplyFirewallSelection {
    <#
    .SYNOPSIS
        Guarded firewall toggle across all three profiles. Both catalog
        directions selected at once is contradictory; the last name in
        the selection wins (the staging screen only ever offers one).
    #>
    param(
        [Parameter(Mandatory)][string[]]$SelectedNames,
        [scriptblock]$GetProfilesAction = { Get-NetFirewallProfile -Profile Domain, Private, Public },
        [scriptblock]$SetProfileAction = { param($ProfileName, $Enabled) Set-NetFirewallProfile -Profile $ProfileName -Enabled (ConvertTo-WtGpoBoolean -Enabled ([bool]$Enabled)) },
        [string]$TestRootOverride
    )

    $catalog = Get-WtFirewallCatalog
    $catalogNames = @($catalog | ForEach-Object Name)
    $picked = @($SelectedNames | Where-Object { $catalogNames -contains $_ })
    if ($picked.Count -eq 0) { return [PSCustomObject]@{ Aborted = $false; Results = @() } }
    $entry = $catalog | Where-Object Name -eq $picked[-1] | Select-Object -First 1

    $captureState = {
        @(& $GetProfilesAction) | ForEach-Object {
            [PSCustomObject]@{
                ItemType      = 'FirewallProfile'
                Name          = "Firewall $($_.Name)"
                ProfileName   = [string]$_.Name
                WasEnabled    = [bool]$_.Enabled
                TargetEnabled = [bool]$entry.TargetEnabled
                CatalogEntry  = $entry.Name
            }
        }
    }

    $apply = { param($Item) & $SetProfileAction $Item.ProfileName ([bool]$Item.TargetEnabled) }

    $reReadState = {
        param($Item)
        $p = @(& $GetProfilesAction) | Where-Object { [string]$_.Name -eq $Item.ProfileName } | Select-Object -First 1
        return [bool]($p -and ([bool]$p.Enabled -eq [bool]$Item.TargetEnabled))
    }

    if ($TestRootOverride) {
        return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
            -Scope Machine -ActionName 'Set Firewall State' -TestRootOverride $TestRootOverride
    }
    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
        -Scope Machine -ActionName 'Set Firewall State'
}
