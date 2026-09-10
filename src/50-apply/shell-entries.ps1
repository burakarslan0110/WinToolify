# Shell key entry state/apply/remove.
# Covered by: tests/ShellKeyEntries.Tests.ps1

function Get-WtShellEntryState {
    <#
    .SYNOPSIS
        Live state of one KeyChanges-shaped catalog entry (Context Menu):
        Applied only when every declared value of every KeyChanges item is
        present and equal to its target, the same all-or-nothing rule
        Get-WtRegistryEntryState uses. A key with no default value is
        NotApplied even when the target default is '' - absent is not empty.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,

        [scriptblock]$GetKeyValueAction
    )

    $readArgs = @{}
    if ($GetKeyValueAction) { $readArgs['GetKeyValueAction'] = $GetKeyValueAction }

    foreach ($change in $Entry.KeyChanges) {
        foreach ($value in $change.Values) {
            $current = Get-WtRegistryKeyValue -Hive $change.Hive -SubKey $change.SubKey -Name $value.Name @readArgs
            if (-not $current.Present -or $current.Value -ne $value.Value) {
                return [PSCustomObject]@{ Applied = $false }
            }
        }
    }

    return [PSCustomObject]@{ Applied = $true }
}

function Invoke-WtApplyShellEntrySelection {
    <#
    .SYNOPSIS
        Wires a KeyChanges-shaped catalog selection to Invoke-WtGuardedChange:
        one RegistryKey undo item per key, in declaration order so
        reverse-order restore removes a command subkey before its parent.
        Applied is decided by a post-apply re-read, never by the write
        returning without error. The delegates deliberately skip
        GetNewClosure: its closure cannot see functions dot-sourced into
        a Pester test scope, so they resolve $Catalog / $SelectedNames
        through the call stack instead.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedNames,

        [Parameter(Mandatory)]
        [string]$ActionName,

        [scriptblock]$GetKeyValueAction,
        [scriptblock]$TestKeyAction,
        [scriptblock]$SetKeyValuesAction,
        [scriptblock]$WriteUndoAction
    )

    $readArgs = @{}
    if ($GetKeyValueAction) { $readArgs['GetKeyValueAction'] = $GetKeyValueAction }
    $testArgs = @{}
    if ($TestKeyAction) { $testArgs['TestKeyAction'] = $TestKeyAction }
    $setArgs = @{}
    if ($SetKeyValuesAction) { $setArgs['SetKeyValuesAction'] = $SetKeyValuesAction }

    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($name in $SelectedNames) {
            $entry = $Catalog | Where-Object Name -eq $name
            if (-not $entry) { continue }
            foreach ($change in $entry.KeyChanges) {
                $createdRoot = Get-WtRegistryKeyCreationPlan -Hive $change.Hive -SubKey $change.SubKey -RootBoundary $change.RootBoundary @testArgs
                $previous = New-Object System.Collections.Generic.List[object]
                foreach ($value in $change.Values) {
                    $current = Get-WtRegistryKeyValue -Hive $change.Hive -SubKey $change.SubKey -Name $value.Name @readArgs
                    $previous.Add([PSCustomObject]@{
                        Name    = $value.Name
                        Present = $current.Present
                        Kind    = $value.Kind
                        Value   = $current.Value
                    })
                }
                $items.Add([PSCustomObject]@{
                    ItemType       = 'RegistryKey'
                    CatalogEntry   = $entry.Name
                    Hive           = $change.Hive
                    SubKey         = $change.SubKey
                    CreatedRoot    = $createdRoot
                    PreviousValues = $previous.ToArray()
                })
            }
        }
        return $items.ToArray()
    }

    $findChange = {
        param($Item)
        $entry = $Catalog | Where-Object Name -eq $Item.CatalogEntry
        return ($entry.KeyChanges | Where-Object { $_.Hive -eq $Item.Hive -and $_.SubKey -eq $Item.SubKey } | Select-Object -First 1)
    }

    $apply = {
        param($Item)
        $change = & $findChange $Item
        $values = @($change.Values | ForEach-Object { @{ Name = $_.Name; Kind = $_.Kind; Value = $_.Value } })
        Set-WtRegistryKeyValues -Hive $Item.Hive -SubKey $Item.SubKey -Values $values @setArgs
    }

    $reReadState = {
        param($Item)
        $change = & $findChange $Item
        foreach ($value in $change.Values) {
            $current = Get-WtRegistryKeyValue -Hive $Item.Hive -SubKey $Item.SubKey -Name $value.Name @readArgs
            if (-not $current.Present -or $current.Value -ne $value.Value) { return $false }
        }
        return $true
    }

    $guardArgs = @{}
    if ($WriteUndoAction) { $guardArgs['WriteUndoAction'] = $WriteUndoAction }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName $ActionName @guardArgs
}

function Invoke-WtRemoveShellEntrySelection {
    <#
    .SYNOPSIS
        The TurnOff twin of Invoke-WtApplyShellEntrySelection: deletes,
        for each selected entry, every distinct removal root through
        Invoke-WtGuardedChange. One RegistryKeyTree undo item per root;
        Restore-WtUndoEntry re-writes the catalog keys beneath it.
    #>
    param(
        [Parameter(Mandatory)][array]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedNames,
        [Parameter(Mandatory)][string]$ActionName,
        [scriptblock]$TestKeyAction,
        [scriptblock]$RemoveKeyTreeAction,
        [scriptblock]$WriteUndoAction
    )
    $removeArgs = @{}
    if ($RemoveKeyTreeAction) { $removeArgs['RemoveKeyTreeAction'] = $RemoveKeyTreeAction }
    $keyExists = {
        param($Hive, $SubKey)
        if ($TestKeyAction) { return [bool](& $TestKeyAction $Hive $SubKey) }
        $key = [Microsoft.Win32.Registry]::$Hive.OpenSubKey($SubKey)
        if ($null -eq $key) { return $false }
        $key.Close()
        return $true
    }
    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($name in $SelectedNames) {
            $entry = $Catalog | Where-Object Name -eq $name
            if (-not $entry) { continue }
            foreach ($change in $entry.KeyChanges) {
                $root = Get-WtRegistryKeyRemovalRoot -SubKey $change.SubKey -RootBoundary $change.RootBoundary
                if (-not $seen.Add(($change.Hive + '|' + $root).ToLowerInvariant())) { continue }
                $items.Add([PSCustomObject]@{
                    ItemType     = 'RegistryKeyTree'
                    CatalogEntry = $entry.Name
                    Hive         = $change.Hive
                    SubKey       = $root
                })
            }
        }
        return $items.ToArray()
    }
    $apply = { param($Item) Remove-WtRegistryKeyTree -Hive $Item.Hive -SubKey $Item.SubKey @removeArgs }
    $reReadState = { param($Item) return (-not (& $keyExists $Item.Hive $Item.SubKey)) }
    $guardArgs = @{}
    if ($WriteUndoAction) { $guardArgs['WriteUndoAction'] = $WriteUndoAction }
    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName $ActionName @guardArgs
}
