# Undo log: write, read, restore, closed/retired state.
# Covered by: tests/UndoLog.Tests.ps1, tests/UndoRetire.Tests.ps1

function Write-WtUndoEntry {
    <#
    .SYNOPSIS
        Records the pre-change state of a set of items as one JSON file
        under the scope-appropriate undo\ directory, named
        yyyyMMdd-HHmmss-<action>.json. Must be called with state captured
        BEFORE the change is applied - a backup written afterwards records
        the new state and is worthless for undo.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Items,

        [string]$TestRootOverride
    )

    $timestamp = Get-Date
    $id = '{0}-{1}' -f $timestamp.ToString('yyyyMMdd-HHmmss'), $Action

    $dataPathArgs = @{ Scope = $Scope; SubPath = 'undo' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    $undoDir = Get-WtDataPath @dataPathArgs
    $entryPath = Join-Path $undoDir "$id.json"

    $entry = [PSCustomObject]@{
        Id        = $id
        Timestamp = $timestamp.ToString('o')
        Action    = $Action
        Scope     = $Scope
        Items     = $Items
    }

    Write-WtJson -Path $entryPath -InputObject $entry
    return $entryPath
}

function Get-WtUndoEntries {
    <#
    .SYNOPSIS
        Reads both the Machine- and User-scoped undo\ directories and
        returns the merged set newest first, ordered by the recorded
        Timestamp field, not filename or mtime. A corrupt entry is skipped,
        not fatal, with Read-WtJson's warning captured (-WarningVariable)
        rather than printed, since this runs behind a painted frame.
    #>
    param(
        [string]$TestRootOverride
    )

    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($scope in @('Machine', 'User')) {
        $dataPathArgs = @{ Scope = $scope; SubPath = 'undo' }
        if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
        $undoDir = Get-WtDataPath @dataPathArgs

        $files = Get-ChildItem -LiteralPath $undoDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $entry = Read-WtJson -Path $file.FullName -WarningAction SilentlyContinue
            if ($null -eq $entry) {
                continue
            }
            $entry | Add-Member -NotePropertyName 'Path' -NotePropertyValue $file.FullName -Force
            $entries.Add($entry)
        }
    }

    return @($entries | Sort-Object -Property { [datetime]$_.Timestamp } -Descending)
}

function Restore-WtUndoEntry {
    <#
    .SYNOPSIS
        Restores every item in an undo entry and returns a per-item result
        (Restored / Failed / NotRestorable) rather than one aggregate verdict,
        in reverse capture order - load-bearing for a combined Ultimate
        Performance + core parking entry, where forward order would delete
        the Ultimate copy before the core-parking indexes could be written
        back into it. -ItemFilter (Item -> bool) restores only matching items
        for a per-setting revert, stamping each with its own RestoredAt; the
        entry is marked closed only once nothing restorable is left in it, and
        never deleted. Returns via .ToArray(), not @($results): wrapping a
        List[object] of PSCustomObjects directly in @() throws "Argument types
        do not match".
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EntryPath,

        [scriptblock]$ItemFilter,

        [scriptblock]$RestoreServiceItem = {
            param($Item)
            if ($Item.PSObject.Properties.Name -contains 'PreviousTemplateStart' -and $null -ne $Item.PreviousTemplateStart) {
                Set-WtServiceTemplateStart -Template $Item.Template -Start ([int]$Item.PreviousTemplateStart)
            }
            Set-Service -Name $Item.Name -StartupType $Item.PreviousStartType -ErrorAction Stop
            if ($Item.PreviousStatus -eq 'Running') {
                Start-Service -Name $Item.Name -ErrorAction Stop
            }
            elseif ($Item.PreviousStatus -eq 'Stopped') {
                Stop-Service -Name $Item.Name -Force -ErrorAction Stop
            }
        },

        [scriptblock]$RestorePackageItem = {
            param($Item)
            if (-not $Item.InstallLocation) { return 'NotRestorable' }
            $manifestPath = Join-Path $Item.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifestPath)) {
                return 'NotRestorable'
            }
            if ($Item.IsProvisioned) {
                Add-AppxProvisionedPackage -Online -PackagePath $manifestPath -SkipLicense -ErrorAction Stop | Out-Null
            }
            else {
                Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            }
            return 'Restored'
        },

        [scriptblock]$RestoreRegistryItem = {
            param($Item)
            if ($Item.PreviousPresent) {
                Set-WtRegistryValue -Path $Item.Path -Name $Item.Name -RegType $Item.RegType -Value $Item.PreviousValue
            }
            else {
                Remove-WtRegistryValue -Path $Item.Path -Name $Item.Name
            }
        },

        [scriptblock]$RestoreDnsItem = {
            param($Item)
            if (@($Item.PreviousIPv4).Count -eq 0 -and @($Item.PreviousIPv6).Count -eq 0) {
                Set-DnsClientServerAddress -InterfaceIndex $Item.InterfaceIndex -ResetServerAddresses
            }
            else {
                Set-DnsClientServerAddress -InterfaceIndex $Item.InterfaceIndex -ServerAddresses (@($Item.PreviousIPv4) + @($Item.PreviousIPv6))
            }
            foreach ($addr in @($Item.AddedDohAddresses)) {
                Remove-DnsClientDohServerAddress -ServerAddress $addr -Confirm:$false -ErrorAction SilentlyContinue
            }
            foreach ($prev in @($Item.PreviousDohEntries)) {
                try {
                    Set-DnsClientDohServerAddress -ServerAddress $prev.Address -DohTemplate $prev.Template -AllowFallbackToUdp ([bool]$prev.AllowFallbackToUdp) -AutoUpgrade ([bool]$prev.AutoUpgrade) -ErrorAction Stop
                }
                catch {
                    Add-DnsClientDohServerAddress -ServerAddress $prev.Address -DohTemplate $prev.Template -AllowFallbackToUdp ([bool]$prev.AllowFallbackToUdp) -AutoUpgrade ([bool]$prev.AutoUpgrade) -ErrorAction SilentlyContinue
                }
            }
        },

        [scriptblock]$RestoreHostsItem = {
            param($Item)
            $hostsPath = Join-Path $env:WinDir 'System32\drivers\etc\hosts'
            $content = [System.IO.File]::ReadAllText($hostsPath, [System.Text.Encoding]::UTF8)
            $updated = Remove-WtHostsBlocklistLines -Content $content -Lines $Item.Lines
            [System.IO.File]::WriteAllText($hostsPath, $updated, [System.Text.Encoding]::UTF8)
        },

        [scriptblock]$RestoreFirewallItem = {
            param($Item)
            foreach ($ruleName in @($Item.RuleNames)) {
                Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            }
        },

        [scriptblock]$RestoreFirewallProfileItem = {
            param($Item)
            Set-NetFirewallProfile -Profile $Item.ProfileName -Enabled (ConvertTo-WtGpoBoolean -Enabled ([bool]$Item.WasEnabled))
        },

        [scriptblock]$RestoreHibernationItem = {
            param($Item)
            if ([bool]$Item.WasEnabled) { powercfg /h on } else { powercfg /h off }
        },

        [scriptblock]$RestorePowerPlanItem = {
            param($Item)
            Restore-WtPowerPlanItem -Item $Item
        },

        [scriptblock]$RestorePowerSettingItem = {
            param($Item)
            Restore-WtPowerSettingItem -Item $Item
        },

        [scriptblock]$RestoreRegistryKeyItem = {
            param($Item)
            Restore-WtRegistryKeyItem -Item $Item
        },

        [scriptblock]$RestoreRegistryKeyTreeItem = {
            param($Item)
            Restore-WtRegistryKeyTreeItem -Item $Item
        }
    )

    $entry = Read-WtJson -Path $EntryPath
    if ($null -eq $entry) {
        return @()
    }

    $results = New-Object System.Collections.Generic.List[object]
    $orderedItems = @($entry.Items)
    [array]::Reverse($orderedItems)
    $restoredItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in $orderedItems) {
        if (Test-WtUndoItemClosed -Item $item) { continue }
        if ($ItemFilter -and -not (& $ItemFilter $item)) { continue }
        $itemName = switch ($item.ItemType) {
            'Service' { $item.Name }
            'Package' { $item.PackageFullName }
            'Registry' { "$($item.Path)\$($item.Name)" }
            'DnsConfig' { "Adapter $($item.InterfaceIndex)" }
            'HostsBlock' { "hosts ($($item.Tier), $(@($item.Lines).Count) lines)" }
            'FirewallBlock' { "$($item.Tier) firewall rules ($(@($item.RuleNames).Count))" }
            'FirewallProfile' { $item.Name }
            'HibernationState' { $item.Name }
            'PowerPlan' { "Power plan -> $($item.PreviousActiveScheme)" }
            'PowerSetting' { "$($item.SettingLabel) on $($item.SchemeGuid)" }
            'RegistryKey' { "$($item.Hive)\$($item.SubKey)" }
            'RegistryKeyTree' { "$($item.Hive)\$($item.SubKey)" }
            default { $item.ItemType }
        }
        $outcome = 'Failed'
        try {
            if ($item.ItemType -eq 'Service') {
                & $RestoreServiceItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'Package') {
                $outcome = & $RestorePackageItem $item
            }
            elseif ($item.ItemType -eq 'Registry') {
                & $RestoreRegistryItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'DnsConfig') {
                & $RestoreDnsItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'HostsBlock') {
                & $RestoreHostsItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'FirewallBlock') {
                & $RestoreFirewallItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'FirewallProfile') {
                & $RestoreFirewallProfileItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'HibernationState') {
                & $RestoreHibernationItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'PowerPlan') {
                & $RestorePowerPlanItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'PowerSetting') {
                & $RestorePowerSettingItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'RegistryKey') {
                & $RestoreRegistryKeyItem $item
                $outcome = 'Restored'
            }
            elseif ($item.ItemType -eq 'RegistryKeyTree') {
                $outcome = & $RestoreRegistryKeyTreeItem $item
            }
            else {
                $outcome = 'NotRestorable'
            }
        }
        catch {
            $outcome = 'Failed'
        }
        $results.Add([PSCustomObject]@{
            ItemType = $item.ItemType
            Name     = $itemName
            Outcome  = $outcome
            Item     = $item
        })
        if ($outcome -eq 'Restored') { $restoredItems.Add($item) }
    }

    if ($ItemFilter) {
        $stamp = (Get-Date).ToString('o')
        foreach ($item in $restoredItems) { $item | Add-Member -NotePropertyName 'RestoredAt' -NotePropertyValue $stamp -Force }
        $pending = @(@($entry.Items) | Where-Object { -not (Test-WtUndoItemClosed -Item $_) })
        if ($restoredItems.Count -gt 0 -and $pending.Count -eq 0) {
            $entry | Add-Member -NotePropertyName 'RestoredAt' -NotePropertyValue $stamp -Force
        }
        if ($restoredItems.Count -gt 0) { Write-WtJson -Path $EntryPath -InputObject $entry }
        return $results.ToArray()
    }

    $restoredAny = [bool]($results | Where-Object { $_.Outcome -eq 'Restored' } | Select-Object -First 1)
    $failedAny = [bool]($results | Where-Object { $_.Outcome -eq 'Failed' } | Select-Object -First 1)
    if ($restoredAny -or -not $failedAny) {
        $entry | Add-Member -NotePropertyName 'RestoredAt' -NotePropertyValue ((Get-Date).ToString('o')) -Force
        Write-WtJson -Path $EntryPath -InputObject $entry
    }

    return $results.ToArray()
}

function Test-WtUndoItemClosed {
    <#
    .SYNOPSIS
        PURE: is this single item finished with? Either a per-setting
        revert put it back (RestoredAt) or another action wiped what it
        records and it was retired (RetiredAt). A closed item is skipped
        by the restore loop and no longer keeps its entry pending.
    #>
    param([Parameter(Mandatory)][object]$Item)
    $names = $Item.PSObject.Properties.Name
    if (($names -contains 'RestoredAt') -and $Item.RestoredAt) { return $true }
    if (($names -contains 'RetiredAt') -and $Item.RetiredAt) { return $true }
    return $false
}

function Test-WtUndoEntryClosed {
    <#
    .SYNOPSIS
        PURE: is this entry finished with? Either the user restored it
        (RestoredAt) or another action wiped the state it records and it
        was retired (RetiredAt). Either way the Undo screen must not
        offer it - restoring it would put back a setting that no longer
        exists anywhere.
    #>
    param([Parameter(Mandatory)][object]$Entry)
    $names = $Entry.PSObject.Properties.Name
    if (($names -contains 'RestoredAt') -and $Entry.RestoredAt) { return $true }
    if (($names -contains 'RetiredAt') -and $Entry.RetiredAt) { return $true }
    return $false
}

function Set-WtUndoEntryRetired {
    <#
    .SYNOPSIS
        Marks still-open undo records as retired because the caller has just
        wiped the state they record; the entry file stays on disk. Without
        -ItemFilter the whole entry is retired; with it, only the matching
        items, closing the entry only once nothing restorable is left in it -
        e.g. an 'Apply Blocklist' entry carries HostsBlock and FirewallBlock
        together, and resetting the firewall must not drop the hosts undo too.
        Returns how many entries were touched.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ActionNames,
        [Parameter(Mandatory)][string]$RetiredBy,
        [scriptblock]$ItemFilter,
        [string]$TestRootOverride
    )
    $entryArgs = @{}
    if ($TestRootOverride) { $entryArgs['TestRootOverride'] = $TestRootOverride }

    $stamp = (Get-Date).ToString('o')
    $touched = 0
    foreach ($entry in @(Get-WtUndoEntries @entryArgs)) {
        if ($ActionNames -notcontains [string]$entry.Action) { continue }
        if (Test-WtUndoEntryClosed -Entry $entry) { continue }

        if (-not $ItemFilter) {
            $entry | Add-Member -NotePropertyName 'RetiredAt' -NotePropertyValue $stamp -Force
            $entry | Add-Member -NotePropertyName 'RetiredBy' -NotePropertyValue $RetiredBy -Force
            Write-WtJson -Path ([string]$entry.Path) -InputObject $entry
            $touched++
            continue
        }

        $stamped = 0
        foreach ($item in @($entry.Items)) {
            if (Test-WtUndoItemClosed -Item $item) { continue }
            if (-not (& $ItemFilter $item)) { continue }
            $item | Add-Member -NotePropertyName 'RetiredAt' -NotePropertyValue $stamp -Force
            $item | Add-Member -NotePropertyName 'RetiredBy' -NotePropertyValue $RetiredBy -Force
            $stamped++
        }
        if ($stamped -eq 0) { continue }

        $open = @(@($entry.Items) | Where-Object { -not (Test-WtUndoItemClosed -Item $_) })
        if ($open.Count -eq 0) {
            $entry | Add-Member -NotePropertyName 'RetiredAt' -NotePropertyValue $stamp -Force
            $entry | Add-Member -NotePropertyName 'RetiredBy' -NotePropertyValue $RetiredBy -Force
        }
        Write-WtJson -Path ([string]$entry.Path) -InputObject $entry
        $touched++
    }
    return $touched
}
