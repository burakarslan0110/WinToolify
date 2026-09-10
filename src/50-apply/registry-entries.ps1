# Generic registry-entry state/capture/apply/remove engine.
# Covered by: tests/OffState.Tests.ps1, tests/TelemetryCatalogs.Tests.ps1

function Get-WtRegistryEntryState {
    <#
    .SYNOPSIS
        Live state of one RegistryChanges-shaped catalog entry (AI & Copilot,
        Gaming Tweaks): Applied only when every one of its RegistryChanges
        values is present and matches its target - a partially-applied
        entry reports NotApplied, since "mostly applied" is not a state the
        SAFE/CAUTION selector UI can represent honestly. Tests inject a
        fake -GetPropertyAction, since the Registry PSProvider does not
        exist on macOS.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,

        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    foreach ($change in $Entry.RegistryChanges) {
        $current = Get-WtRegistryValue -Path $change.Path -Name $change.Name -GetPropertyAction $GetPropertyAction
        if (-not $current.Present -or $current.Value -ne $change.Value) {
            return [PSCustomObject]@{ Applied = $false }
        }
    }

    return [PSCustomObject]@{ Applied = $true }
}

function Get-WtRegistryEntryCaptureItems {
    <#
    .SYNOPSIS
        PURE-ish: one Registry undo item per RegistryChanges value of each
        selected, known catalog entry, holding the CURRENT value
        (PreviousPresent / PreviousValue). Shared by the apply path
        (Invoke-WtApplyRegistryEntrySelection) and the remove path
        (Invoke-WtRemoveRegistryEntrySelection) so both capture undo items
        identically. -RequireRemovable skips entries
        Test-WtRegistryEntryRemovable rejects (the remove path only; the
        apply path never filters by removability).
        Returns a single array object (comma-protected) so an empty result
        never collapses to $null - assign it to a variable; never wrap the
        call in @().
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Names,

        [switch]$RequireRemovable
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Names) {
        $entry = $Catalog | Where-Object Name -eq $name
        if (-not $entry) { continue }
        if ($RequireRemovable -and -not (Test-WtRegistryEntryRemovable -Entry $entry)) { continue }
        foreach ($change in $entry.RegistryChanges) {
            $current = Get-WtRegistryValue -Path $change.Path -Name $change.Name
            $items.Add([PSCustomObject]@{
                ItemType        = 'Registry'
                CatalogEntry    = $entry.Name
                Path            = $change.Path
                Name            = $change.Name
                RegType         = $change.RegType
                PreviousPresent = $current.Present
                PreviousValue   = $current.Value
            })
        }
    }
    return , $items.ToArray()
}

function Invoke-WtApplyRegistryEntrySelection {
    <#
    .SYNOPSIS
        Wires any RegistryChanges-shaped catalog selection to
        Invoke-WtGuardedChange: writes every RegistryChanges value for each
        selected catalog entry, recording one undo item per registry value
        (not per catalog entry) so Restore-WtUndoEntry's per-item
        granularity still works even though one entry maps to multiple
        values. -CaptureState assigns Get-WtRegistryEntryCaptureItems'
        result before returning it - returning it directly would
        re-collapse the comma-protected array. Uses the real
        Set-WtRegistryValue / Get-WtRegistryValue calls, exercised
        manually rather than unit-tested. Deliberately does not call
        gpupdate /force.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [string[]]$SelectedNames,

        [Parameter(Mandatory)]
        [string]$ActionName
    )

    $captureState = {
        $captured = Get-WtRegistryEntryCaptureItems -Catalog $Catalog -Names $SelectedNames
        return $captured
    }

    $apply = {
        param($Item)
        $entry = $Catalog | Where-Object Name -eq $Item.CatalogEntry
        $change = $entry.RegistryChanges | Where-Object { $_.Path -eq $Item.Path -and $_.Name -eq $Item.Name }
        Set-WtRegistryValue -Path $Item.Path -Name $Item.Name -RegType $change.RegType -Value $change.Value
    }

    $reReadState = {
        param($Item)
        $entry = $Catalog | Where-Object Name -eq $Item.CatalogEntry
        $change = $entry.RegistryChanges | Where-Object { $_.Path -eq $Item.Path -and $_.Name -eq $Item.Name }
        $current = Get-WtRegistryValue -Path $Item.Path -Name $Item.Name
        return ($current.Present -and $current.Value -eq $change.Value)
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName $ActionName
}

function Get-WtRegistryChangeOffAction {
    <#
    .SYNOPSIS
        PURE: how a RegistryChanges item goes back to its Windows default.
        'Delete' (the default when the item declares nothing - policy
        values and values Windows never writes), 'Set' (write OffValue with
        the item's RegType - values Windows itself ships, e.g. Explorer\
        Advanced toggles), or 'None' (no honest default; the entry cannot
        be removed from a screen and stays Undo-screen only). Throws on
        any other declared value - a typo (e.g. 'Non') must not silently
        fall through to deleting a value that has no honest default.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Change)
    $props = $Change.PSObject.Properties.Name
    if (-not (($props -contains 'OffAction') -and $Change.OffAction)) { return 'Delete' }
    $action = [string]$Change.OffAction
    if ($action -cin @('Delete', 'Set', 'None')) { return $action }
    throw "Get-WtRegistryChangeOffAction: unknown OffAction '$action' for $($Change.Path)\$($Change.Name)"
}

function Test-WtRegistryEntryRemovable {
    <#
    .SYNOPSIS
        PURE: an entry can be turned back to the Windows default only when
        every one of its RegistryChanges knows how (no 'None').
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Entry)
    foreach ($change in @($Entry.RegistryChanges)) {
        if ((Get-WtRegistryChangeOffAction -Change $change) -eq 'None') { return $false }
    }
    return $true
}

function Invoke-WtRemoveRegistryEntrySelection {
    <#
    .SYNOPSIS
        The TurnOff twin of Invoke-WtApplyRegistryEntrySelection: puts every
        RegistryChanges value of each selected entry back to its Windows
        default through Invoke-WtGuardedChange - the same Registry undo
        item per value (so Restore-WtUndoEntry re-applies the on state),
        Remove-WtRegistryValue for 'Delete', Set-WtRegistryValue of
        OffValue for 'Set'. Entries with a 'None' change are skipped (the
        screen never marks them). Applied in the result means "the off
        state was re-read", never "the write returned".
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [string[]]$SelectedNames,

        [Parameter(Mandatory)]
        [string]$ActionName
    )

    $captureState = {
        $captured = Get-WtRegistryEntryCaptureItems -Catalog $Catalog -Names $SelectedNames -RequireRemovable
        return $captured
    }

    $findChange = {
        param($Item)
        $entry = $Catalog | Where-Object Name -eq $Item.CatalogEntry
        return ($entry.RegistryChanges | Where-Object { $_.Path -eq $Item.Path -and $_.Name -eq $Item.Name } | Select-Object -First 1)
    }

    $apply = {
        param($Item)
        $change = & $findChange $Item
        if ((Get-WtRegistryChangeOffAction -Change $change) -eq 'Set') {
            Set-WtRegistryValue -Path $Item.Path -Name $Item.Name -RegType $change.RegType -Value $change.OffValue
        }
        else {
            Remove-WtRegistryValue -Path $Item.Path -Name $Item.Name
        }
    }

    $reReadState = {
        param($Item)
        $change = & $findChange $Item
        $current = Get-WtRegistryValue -Path $Item.Path -Name $Item.Name
        if ((Get-WtRegistryChangeOffAction -Change $change) -eq 'Set') {
            return ($current.Present -and $current.Value -eq $change.OffValue)
        }
        return (-not $current.Present)
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName $ActionName
}
