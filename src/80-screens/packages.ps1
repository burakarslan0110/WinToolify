# Packages screen (show-all toggle).
# Covered by: tests/Screens.Tests.ps1

$script:WtShowAllPackages = $false

function Get-WtPackagesGroups {
    <#
    .SYNOPSIS
        The Apps screen's single group: installed packages only by
        default, everything with the H toggle, and automatically
        everything when fewer than 10 are installed so the screen never
        falls below the design floor. Live state is computed once and
        cached in Data with the catalog, since re-localizing every row
        and probing Get-AppxPackage -AllUsers are both too slow to
        repeat per row; a RemovalMethod='WinGet' row is invisible to
        Get-AppxPackage and routes through Get-WtPackageLiveInstalled
        instead. Every row is tagged PendingVerbKey='WillRemove' so
        marking an installed app for removal never displays as "Will
        apply".
    #>
    param(
        [bool]$ShowAll = $script:WtShowAllPackages,
        [scriptblock]$GetState,
        [scriptblock]$GetSnapshot = { Get-WtInstalledPackageSnapshot }
    )
    $catalog = @(Get-WtPackageCatalog)
    $states = @{}
    if ($GetState) {
        foreach ($e in $catalog) { $states[$e.Name] = & $GetState $e.Name }
    }
    else {
        $states = Get-WtPackageStatesFromSnapshot -Catalog $catalog -Snapshot @(& $GetSnapshot)
    }
    $installedCount = @($states.Values | Where-Object { $_.Installed }).Count
    $effectiveShowAll = ($ShowAll -or $installedCount -lt 10)
    return @{
        SectionKey = 'Packages'; HeaderKey = $null; HeaderField = 'Group'
        Data = @{ States = $states; ShowAll = $effectiveShowAll; Catalog = $catalog }
        GetCatalog = {
            param($g)
            $all = @($g.Data.Catalog | ForEach-Object { $_ | Add-Member -NotePropertyName 'PendingVerbKey' -NotePropertyValue 'WillRemove' -Force -PassThru })
            if ($g.Data.ShowAll) { return $all }
            return @($all | Where-Object { $g.Data.States[$_.Name].Installed })
        }
        GetEntryState = {
            param($e, $g)
            $s = $g.Data.States[$e.Name]
            $label = if ($s.Installed) { Get-Translation 'StateInstalled' } else { Get-Translation 'StateRemoved' }
            @{ Applied = $false; Available = [bool]$s.Installed; StateLabel = $label }
        }
    }
}

function Invoke-WtPackagesScreen {
    <#
    .SYNOPSIS
        Apps: the package catalog under its group sub-headers, with H
        toggling between "installed only" and the whole catalog.
        -Groups and -ExtraItems are scriptblocks, not arrays, so the
        rebuild Invoke-WtApplyScreen runs after OnHotkey returns $true
        re-reads $script:WtShowAllPackages instead of freezing the rows
        and hint at their first-build values.
    #>
    $toggle = {
        param($Char)
        if ($Char -eq 'h') { $script:WtShowAllPackages = -not $script:WtShowAllPackages; return $true }
        return $false
    }
    $hint = {
        $hintKey = if ($script:WtShowAllPackages) { 'PackagesToggleHintAll' } else { 'PackagesToggleHint' }
        @((New-WtListItem -Kind 'Info' -Name 'HideHint' -Label (Get-Translation $hintKey)))
    }
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'AppsMenu'
    return Invoke-WtApplyScreen -Breadcrumb $crumb -Groups { @((Get-WtPackagesGroups)) } -ExtraItems $hint `
        -CounterKey 'PackagesCount' -OnHotkey $toggle
}
