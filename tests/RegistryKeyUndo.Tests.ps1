#Requires -Modules Pester

<#
.SYNOPSIS
    The key-level registry primitives (Get-WtRegistryKeyValue /
    Set-WtRegistryKeyValues / Remove-WtRegistryKeyValue /
    Remove-WtRegistryKeyTree), the capture-time creation plan
    (Get-WtRegistryKeyCreationPlan), and the RegistryKey undo item type.
    [Microsoft.Win32.Registry]::LocalMachine throws on the macOS dev
    host, so every primitive takes an injectable action.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Key-level registry primitives' {
    It 'Get-WtRegistryKeyValue reports KeyPresent=$false, Present=$false when the action reports no key' {
        $result = Get-WtRegistryKeyValue -Hive LocalMachine -SubKey 'SOFTWARE\Classes\*\shell\TakeOwnership' -Name '' -GetKeyValueAction { param($h, $s, $n) $null }
        $result.KeyPresent | Should -BeFalse
        $result.Present | Should -BeFalse
        $result.Value | Should -BeNullOrEmpty
    }

    It 'Get-WtRegistryKeyValue reports KeyPresent=$true, Present=$false for a key that exists without the value' {
        $result = Get-WtRegistryKeyValue -Hive LocalMachine -SubKey 'SOFTWARE\Test' -Name 'X' -GetKeyValueAction { param($h, $s, $n) [PSCustomObject]@{ Present = $false; Value = $null } }
        $result.KeyPresent | Should -BeTrue
        $result.Present | Should -BeFalse
    }

    It 'Get-WtRegistryKeyValue passes hive, subkey and name through and surfaces the value' {
        $seen = @{}
        $action = { param($h, $s, $n) $seen.Hive = $h; $seen.SubKey = $s; $seen.Name = $n; [PSCustomObject]@{ Present = $true; Value = 'Take Ownership' } }.GetNewClosure()

        $result = Get-WtRegistryKeyValue -Hive LocalMachine -SubKey 'SOFTWARE\Classes\*\shell\TakeOwnership' -Name '' -GetKeyValueAction $action

        $seen.Hive | Should -Be 'LocalMachine'
        $seen.SubKey | Should -Be 'SOFTWARE\Classes\*\shell\TakeOwnership'
        $seen.Name | Should -Be ''
        $result.KeyPresent | Should -BeTrue
        $result.Present | Should -BeTrue
        $result.Value | Should -Be 'Take Ownership'
    }

    It 'Set-WtRegistryKeyValues hands the hive, subkey and the full value list to the action in one call' {
        $seen = @{ Calls = 0 }
        $action = { param($h, $s, $v) $seen.Calls++; $seen.Hive = $h; $seen.SubKey = $s; $seen.Values = @($v) }.GetNewClosure()
        $values = @(
            @{ Name = ''; Kind = 'String'; Value = 'Take Ownership' },
            @{ Name = 'HasLUAShield'; Kind = 'String'; Value = '' }
        )

        Set-WtRegistryKeyValues -Hive LocalMachine -SubKey 'SOFTWARE\Test' -Values $values -SetKeyValuesAction $action

        $seen.Calls | Should -Be 1
        $seen.Hive | Should -Be 'LocalMachine'
        $seen.SubKey | Should -Be 'SOFTWARE\Test'
        $seen.Values.Count | Should -Be 2
        $seen.Values[1].Name | Should -Be 'HasLUAShield'
    }

    It 'Remove-WtRegistryKeyValue and Remove-WtRegistryKeyTree pass their targets to their actions' {
        $seen = @{}
        Remove-WtRegistryKeyValue -Hive CurrentUser -SubKey 'Software\Test' -Name 'X' -RemoveKeyValueAction { param($h, $s, $n) $seen.V = "$h|$s|$n" }.GetNewClosure()
        Remove-WtRegistryKeyTree -Hive CurrentUser -SubKey 'Software\Test\Sub' -RemoveKeyTreeAction { param($h, $s) $seen.T = "$h|$s" }.GetNewClosure()

        $seen.V | Should -Be 'CurrentUser|Software\Test|X'
        $seen.T | Should -Be 'CurrentUser|Software\Test\Sub'
    }

    It 'rejects a hive that is not CurrentUser or LocalMachine' {
        { Get-WtRegistryKeyValue -Hive ClassesRoot -SubKey 'X' -Name '' -GetKeyValueAction { $null } } | Should -Throw
    }
}

Describe 'Get-WtRegistryKeyCreationPlan' {
    BeforeAll {
        $script:NewProbe = {
            param([string[]]$Existing)
            $set = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($e in $Existing) { $set.Add($e) | Out-Null }
            return { param($h, $s) $set.Contains($s) }.GetNewClosure()
        }
    }

    It 'returns the highest missing ancestor when the whole chain below the boundary is absent' {
        $probe = & $NewProbe @('SOFTWARE\Classes\*\shell')
        $plan = Get-WtRegistryKeyCreationPlan -Hive LocalMachine -SubKey 'SOFTWARE\Classes\*\shell\TakeOwnership\command' -RootBoundary 'SOFTWARE\Classes\*\shell' -TestKeyAction $probe
        $plan | Should -Be 'SOFTWARE\Classes\*\shell\TakeOwnership'
    }

    It 'returns $null when the full path already exists' {
        $probe = & $NewProbe @('SOFTWARE\Classes\*\shell', 'SOFTWARE\Classes\*\shell\TakeOwnership', 'SOFTWARE\Classes\*\shell\TakeOwnership\command')
        $plan = Get-WtRegistryKeyCreationPlan -Hive LocalMachine -SubKey 'SOFTWARE\Classes\*\shell\TakeOwnership\command' -RootBoundary 'SOFTWARE\Classes\*\shell' -TestKeyAction $probe
        $plan | Should -BeNullOrEmpty
    }

    It 'returns the leaf when only the leaf is missing' {
        $probe = & $NewProbe @('SOFTWARE\Classes\*\shell', 'SOFTWARE\Classes\*\shell\TakeOwnership')
        $plan = Get-WtRegistryKeyCreationPlan -Hive LocalMachine -SubKey 'SOFTWARE\Classes\*\shell\TakeOwnership\command' -RootBoundary 'SOFTWARE\Classes\*\shell' -TestKeyAction $probe
        $plan | Should -Be 'SOFTWARE\Classes\*\shell\TakeOwnership\command'
    }

    It 'never proposes the boundary itself, even when the probe says the boundary is missing' {
        $probe = & $NewProbe @()
        $plan = Get-WtRegistryKeyCreationPlan -Hive CurrentUser -SubKey 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -RootBoundary 'Software\Classes\CLSID' -TestKeyAction $probe
        $plan | Should -Be 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    }

    It 'throws when SubKey is not under RootBoundary' {
        $probe = & $NewProbe @()
        { Get-WtRegistryKeyCreationPlan -Hive CurrentUser -SubKey 'Software\Other\Thing' -RootBoundary 'Software\Classes\CLSID' -TestKeyAction $probe } | Should -Throw
        { Get-WtRegistryKeyCreationPlan -Hive CurrentUser -SubKey 'Software\Classes\CLSID' -RootBoundary 'Software\Classes\CLSID' -TestKeyAction $probe } | Should -Throw
        { Get-WtRegistryKeyCreationPlan -Hive CurrentUser -SubKey 'Software\Classes\CLSIDX\Y' -RootBoundary 'Software\Classes\CLSID' -TestKeyAction $probe } | Should -Throw
    }
}

Describe 'Restore-WtRegistryKeyItem' {
    BeforeEach {
        $script:Calls = @{ Tree = New-Object System.Collections.Generic.List[string]; Set = New-Object System.Collections.Generic.List[object]; Remove = New-Object System.Collections.Generic.List[string] }
        $script:TreeAction = { param($h, $s) $script:Calls.Tree.Add("$h|$s") }
        $script:SetAction = { param($h, $s, $v) $script:Calls.Set.Add([PSCustomObject]@{ Hive = $h; SubKey = $s; Values = @($v) }) }
        $script:RemoveAction = { param($h, $s, $n) $script:Calls.Remove.Add("$h|$s|$n") }
    }

    It 'with CreatedRoot set, removes exactly that tree once and never touches a value action' {
        $item = [PSCustomObject]@{
            ItemType = 'RegistryKey'; CatalogEntry = 'AddTakeOwnership'; Hive = 'LocalMachine'
            SubKey = 'SOFTWARE\Classes\*\shell\TakeOwnership\command'
            CreatedRoot = 'SOFTWARE\Classes\*\shell\TakeOwnership'
            PreviousValues = @([PSCustomObject]@{ Name = ''; Present = $false; Kind = 'String'; Value = $null })
        }

        Restore-WtRegistryKeyItem -Item $item -RemoveKeyTreeAction $TreeAction -SetKeyValuesAction $SetAction -RemoveKeyValueAction $RemoveAction

        $Calls.Tree.Count | Should -Be 1
        $Calls.Tree[0] | Should -Be 'LocalMachine|SOFTWARE\Classes\*\shell\TakeOwnership'
        $Calls.Set.Count | Should -Be 0
        $Calls.Remove.Count | Should -Be 0
    }

    It 'with CreatedRoot null, writes back Present values, removes absent ones, and never removes a tree' {
        $item = [PSCustomObject]@{
            ItemType = 'RegistryKey'; CatalogEntry = 'AddTakeOwnership'; Hive = 'LocalMachine'
            SubKey = 'SOFTWARE\Classes\*\shell\TakeOwnership'
            CreatedRoot = $null
            PreviousValues = @(
                [PSCustomObject]@{ Name = ''; Present = $true; Kind = 'String'; Value = 'Old Label' },
                [PSCustomObject]@{ Name = 'HasLUAShield'; Present = $false; Kind = 'String'; Value = $null },
                [PSCustomObject]@{ Name = 'Position'; Present = $true; Kind = 'String'; Value = 'Top' }
            )
        }

        Restore-WtRegistryKeyItem -Item $item -RemoveKeyTreeAction $TreeAction -SetKeyValuesAction $SetAction -RemoveKeyValueAction $RemoveAction

        $Calls.Tree.Count | Should -Be 0
        $Calls.Remove.Count | Should -Be 1
        $Calls.Remove[0] | Should -Be 'LocalMachine|SOFTWARE\Classes\*\shell\TakeOwnership|HasLUAShield'
        $written = @($Calls.Set | ForEach-Object { $_.Values } | ForEach-Object { $_ })
        $written.Count | Should -Be 2
        ($written | Where-Object Name -eq '').Value | Should -Be 'Old Label'
        ($written | Where-Object Name -eq 'Position').Value | Should -Be 'Top'
        ($written | Where-Object Name -eq 'Position').Kind | Should -Be 'String'
        $Calls.Set | ForEach-Object { $_.SubKey | Should -Be 'SOFTWARE\Classes\*\shell\TakeOwnership' }
    }
}

Describe 'Restore-WtUndoEntry - RegistryKey item type' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'routes a RegistryKey item to RestoreRegistryKeyItem, names it Hive\SubKey, and isolates a failure to that item' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'RegistryKey'; CatalogEntry = 'AddTakeOwnership'; Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\*\shell\TakeOwnership'; CreatedRoot = 'SOFTWARE\Classes\*\shell\TakeOwnership'; PreviousValues = @() },
            [PSCustomObject]@{ ItemType = 'RegistryKey'; CatalogEntry = 'AddTakeOwnership'; Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\*\shell\TakeOwnership\command'; CreatedRoot = $null; PreviousValues = @() }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'context-menu' -Items $items -TestRootOverride $FakeRoot

        $fakeRestore = {
            param($Item)
            if ($Item.SubKey -like '*\command') { throw 'simulated failure' }
        }

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreRegistryKeyItem $fakeRestore

        $results.Count | Should -Be 2
        ($results | Where-Object Name -eq 'LocalMachine\SOFTWARE\Classes\*\shell\TakeOwnership\command').Outcome | Should -Be 'Failed'
        ($results | Where-Object Name -eq 'LocalMachine\SOFTWARE\Classes\*\shell\TakeOwnership').Outcome | Should -Be 'Restored'
    }

    It 'round-trips a multi-entry PreviousValues array through Write-WtJson / Read-WtJson intact' {
        $items = @(
            [PSCustomObject]@{
                ItemType = 'RegistryKey'; CatalogEntry = 'AddTakeOwnership'; Hive = 'LocalMachine'
                SubKey = 'SOFTWARE\Classes\Directory\shell\TakeOwnership'; CreatedRoot = $null
                PreviousValues = @(
                    [PSCustomObject]@{ Name = ''; Present = $true; Kind = 'String'; Value = 'Old' },
                    [PSCustomObject]@{ Name = 'AppliesTo'; Present = $false; Kind = 'String'; Value = $null },
                    [PSCustomObject]@{ Name = 'Position'; Present = $true; Kind = 'String'; Value = 'middle' }
                )
            }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'context-menu' -Items $items -TestRootOverride $FakeRoot

        $reloaded = Read-WtJson -Path $entryPath
        $prev = @($reloaded.Items[0].PreviousValues)
        $prev.Count | Should -Be 3
        $prev[0].Name | Should -Be ''
        $prev[0].Present | Should -BeTrue
        $prev[0].Value | Should -Be 'Old'
        $prev[1].Name | Should -Be 'AppliesTo'
        $prev[1].Present | Should -BeFalse
        $prev[2].Kind | Should -Be 'String'
        $prev[2].Value | Should -Be 'middle'
    }
}

Describe 'Context menu removal' {
    It 'Get-WtRegistryKeyRemovalRoot returns the first segment under the boundary and refuses anything else' {
        Get-WtRegistryKeyRemovalRoot -SubKey 'SOFTWARE\Classes\*\shell\TakeOwnership\command' -RootBoundary 'SOFTWARE\Classes\*\shell' | Should -Be 'SOFTWARE\Classes\*\shell\TakeOwnership'
        Get-WtRegistryKeyRemovalRoot -SubKey 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -RootBoundary 'Software\Classes\CLSID' | Should -Be 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
        { Get-WtRegistryKeyRemovalRoot -SubKey 'SOFTWARE\Classes' -RootBoundary 'SOFTWARE\Classes\*\shell' } | Should -Throw
        { Get-WtRegistryKeyRemovalRoot -SubKey 'SOFTWARE\Classes\*\shell' -RootBoundary 'SOFTWARE\Classes\*\shell' } | Should -Throw
        { Get-WtRegistryKeyRemovalRoot -SubKey 'SOFTWARE\Classes\*\shell\\' -RootBoundary 'SOFTWARE\Classes\*\shell' } | Should -Throw
        { Get-WtRegistryKeyRemovalRoot -SubKey 'SOFTWARE\Classes\*\shell\\\\' -RootBoundary 'SOFTWARE\Classes\*\shell' } | Should -Throw
    }
    It 'every shipped context-menu entry yields one root per verb key, never the boundary' {
        foreach ($entry in @(Get-WtContextMenuCatalog)) {
            $roots = @($entry.KeyChanges | ForEach-Object { Get-WtRegistryKeyRemovalRoot -SubKey $_.SubKey -RootBoundary $_.RootBoundary } | Sort-Object -Unique)
            $roots.Count | Should -BeGreaterThan 0 -Because $entry.Name
            foreach ($r in $roots) { @($entry.KeyChanges | ForEach-Object RootBoundary) | Should -Not -Contain $r }
        }
        @((Get-WtContextMenuCatalog | Where-Object Name -eq 'AddTakeOwnership').KeyChanges | ForEach-Object { Get-WtRegistryKeyRemovalRoot -SubKey $_.SubKey -RootBoundary $_.RootBoundary } | Sort-Object -Unique).Count | Should -Be 3
    }
    It 'Invoke-WtRemoveShellEntrySelection deletes each root once, records RegistryKeyTree items and re-reads absence' {
        $script:existing = New-Object 'System.Collections.Generic.HashSet[string]'
        'SOFTWARE\Classes\*\shell\TakeOwnership', 'SOFTWARE\Classes\Directory\shell\TakeOwnership', 'SOFTWARE\Classes\Drive\shell\TakeOwnership' | ForEach-Object { $existing.Add($_) | Out-Null }
        $script:deleted = New-Object 'System.Collections.Generic.List[string]'
        $script:undo = $null
        $r = Invoke-WtRemoveShellEntrySelection -Catalog (Get-WtContextMenuCatalog) -SelectedNames @('AddTakeOwnership') -ActionName 'Remove Context Menu Entries' `
            -TestKeyAction { param($h, $s) $script:existing.Contains($s) } `
            -RemoveKeyTreeAction { param($h, $s) $script:deleted.Add($s); $script:existing.Remove($s) | Out-Null } `
            -WriteUndoAction { param($Scope, $ActionName, $Items, $TestRootOverride) $script:undo = @{ Action = $ActionName; Items = @($Items) } }
        @($deleted | Sort-Object) | Should -Be @('SOFTWARE\Classes\*\shell\TakeOwnership', 'SOFTWARE\Classes\Directory\shell\TakeOwnership', 'SOFTWARE\Classes\Drive\shell\TakeOwnership')
        @($r.Results | ForEach-Object Applied) | Should -Be @($true, $true, $true)
        $undo.Action | Should -Be 'Remove Context Menu Entries'
        @($undo.Items | ForEach-Object ItemType) | Should -Be @('RegistryKeyTree', 'RegistryKeyTree', 'RegistryKeyTree')
        $undo.Items[0].CatalogEntry | Should -Be 'AddTakeOwnership'
        $undo.Items[0].Hive | Should -Be 'LocalMachine'
    }
    It 'Restore-WtUndoEntry re-writes the catalog keys under a removed root and reports NotRestorable for an unknown entry' {
        $fakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $items = @(
            [PSCustomObject]@{ ItemType = 'RegistryKeyTree'; CatalogEntry = 'AddRestartExplorer'; Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer' }
            [PSCustomObject]@{ ItemType = 'RegistryKeyTree'; CatalogEntry = 'NoSuchEntry'; Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\X\Y' }
        )
        $path = Write-WtUndoEntry -Scope Machine -Action 'Remove Context Menu Entries' -Items $items -TestRootOverride $fakeRoot
        $script:written = New-Object 'System.Collections.Generic.List[string]'
        $results = @(Restore-WtUndoEntry -EntryPath $path -RestoreRegistryKeyTreeItem { param($Item) Restore-WtRegistryKeyTreeItem -Item $Item -SetKeyValuesAction { param($h, $s, $v) $script:written.Add($s) } })
        ($results | Where-Object Name -like '*WtRestartExplorer').Outcome | Should -Be 'Restored'
        ($results | Where-Object Name -like '*X\Y').Outcome | Should -Be 'NotRestorable'
        @($written | Sort-Object) | Should -Be @('SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer', 'SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer\command')
    }
    It 'the ContextMenu section exposes TurnOff with a translated action name' {
        $row = (Get-WtProfileSectionCatalog) | Where-Object Key -eq 'ContextMenu'
        Mock Invoke-WtRemoveShellEntrySelection { [PSCustomObject]@{ Aborted = $false; Results = @(); A = $ActionName } }
        (& $row.TurnOff ([string[]]@('AddTakeOwnership')) $null).A | Should -Be 'Remove Context Menu Entries'
        $script:Translations['TR']['UndoAction.Remove Context Menu Entries'] | Should -Not -BeNullOrEmpty
    }
    It 'dedupes per Hive, not just per root - two hives sharing the same SubKey each get their own RegistryKeyTree item' {
        $catalog = @(
            [PSCustomObject]@{
                Name       = 'FakeDualHiveEntry'
                KeyChanges = @(
                    [PSCustomObject]@{ Hive = 'CurrentUser'; SubKey = 'Software\Classes\Test\shell\Verb'; RootBoundary = 'Software\Classes\Test\shell'; Values = @() }
                    [PSCustomObject]@{ Hive = 'LocalMachine'; SubKey = 'Software\Classes\Test\shell\Verb'; RootBoundary = 'Software\Classes\Test\shell'; Values = @() }
                )
            }
        )
        $script:deletedDual = New-Object 'System.Collections.Generic.List[string]'
        $script:undoDual = $null
        Invoke-WtRemoveShellEntrySelection -Catalog $catalog -SelectedNames @('FakeDualHiveEntry') -ActionName 'Remove Context Menu Entries' `
            -TestKeyAction { param($h, $s) $false } `
            -RemoveKeyTreeAction { param($h, $s) $script:deletedDual.Add("$h|$s") } `
            -WriteUndoAction { param($Scope, $ActionName, $Items, $TestRootOverride) $script:undoDual = @($Items) } | Out-Null
        $undoDual.Count | Should -Be 2
        @($undoDual | ForEach-Object Hive | Sort-Object) | Should -Be @('CurrentUser', 'LocalMachine')
        @($undoDual | ForEach-Object SubKey | Sort-Object -Unique) | Should -Be @('Software\Classes\Test\shell\Verb')
        @($deletedDual | Sort-Object) | Should -Be @('CurrentUser|Software\Classes\Test\shell\Verb', 'LocalMachine|Software\Classes\Test\shell\Verb')
    }
    It 'the CurrentUser entry (RestoreClassicContextMenu) removes and restores the CLSID root, never HKLM' {
        $script:existingClsid = New-Object 'System.Collections.Generic.HashSet[string]'
        $existingClsid.Add('Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}') | Out-Null
        $script:deletedClsid = New-Object 'System.Collections.Generic.List[string]'
        $script:undoClsid = $null
        Invoke-WtRemoveShellEntrySelection -Catalog (Get-WtContextMenuCatalog) -SelectedNames @('RestoreClassicContextMenu') -ActionName 'Remove Context Menu Entries' `
            -TestKeyAction { param($h, $s) $script:existingClsid.Contains($s) } `
            -RemoveKeyTreeAction { param($h, $s) $script:deletedClsid.Add("$h|$s"); $script:existingClsid.Remove($s) | Out-Null } `
            -WriteUndoAction { param($Scope, $ActionName, $Items, $TestRootOverride) $script:undoClsid = @($Items) } | Out-Null
        $undoClsid.Count | Should -Be 1
        $undoClsid[0].Hive | Should -Be 'CurrentUser'
        $undoClsid[0].SubKey | Should -Be 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
        @($deletedClsid) | Should -Be @('CurrentUser|Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}')

        $script:writtenClsid = New-Object 'System.Collections.Generic.List[string]'
        $outcome = Restore-WtRegistryKeyTreeItem -Item $undoClsid[0] -SetKeyValuesAction { param($h, $s, $v) $script:writtenClsid.Add($s) }
        $outcome | Should -Be 'Restored'
        @($writtenClsid) | Should -Be @('Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
    }
    It 'a SelectedNames entry missing from the catalog produces no item and no deletion' {
        $script:deletedMissing = New-Object 'System.Collections.Generic.List[string]'
        $script:undoMissing = $null
        $r = Invoke-WtRemoveShellEntrySelection -Catalog (Get-WtContextMenuCatalog) -SelectedNames @('NoSuchCatalogEntry') -ActionName 'Remove Context Menu Entries' `
            -TestKeyAction { param($h, $s) $true } `
            -RemoveKeyTreeAction { param($h, $s) $script:deletedMissing.Add("$h|$s") } `
            -WriteUndoAction { param($Scope, $ActionName, $Items, $TestRootOverride) $script:undoMissing = @($Items) }
        $undoMissing.Count | Should -Be 0
        $deletedMissing.Count | Should -Be 0
        $r.Results.Count | Should -Be 0
    }
}
