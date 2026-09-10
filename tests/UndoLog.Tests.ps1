#Requires -Modules Pester

<#
.SYNOPSIS
    Covers Write-WtUndoEntry / Get-WtUndoEntries / Restore-WtUndoEntry.
    Service/package restore actions are injectable (RestoreServiceItem /
    RestorePackageItem) so ordering, aggregation, and error handling can be
    tested without real Set-Service / Add-AppxPackage calls, which do not
    exist on macOS. Also covers Format-WtUndoEntryLabel, the only testable
    logic Show-WtUndoMenu introduces; the menu itself is Write-Host/
    Read-Host glue over already-tested Get-WtUndoEntries/Restore-WtUndoEntry
    and has no dedicated test file.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Write-WtUndoEntry / Get-WtUndoEntries round trip' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'writes an entry that reloads with every field intact, including Scope' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'DiagTrack'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'services' -Items $items -TestRootOverride $FakeRoot

        $reloaded = Read-WtJson -Path $entryPath
        $reloaded.Scope | Should -Be 'Machine'
        $reloaded.Action | Should -Be 'services'
        $reloaded.Id | Should -Not -BeNullOrEmpty
        $reloaded.Timestamp | Should -Not -BeNullOrEmpty
        $reloaded.Items.Count | Should -Be 1
        $reloaded.Items[0].Name | Should -Be 'DiagTrack'
        $reloaded.Items[0].PreviousStartType | Should -Be 'Automatic'
    }

    It 'merges Machine- and User-scoped entries into one newest-first list, ordered by recorded Timestamp' {
        $itemsA = @([PSCustomObject]@{ ItemType = 'Service'; Name = 'A'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' })
        $itemsB = @([PSCustomObject]@{ ItemType = 'Package'; PackageFullName = 'B'; InstallLocation = 'x'; IsProvisioned = $false })

        $pathB = Write-WtUndoEntry -Scope User -Action 'pkg-b' -Items $itemsB -TestRootOverride $FakeRoot
        Start-Sleep -Milliseconds 20
        $pathA = Write-WtUndoEntry -Scope Machine -Action 'svc-a' -Items $itemsA -TestRootOverride $FakeRoot

        $entryA = Read-WtJson -Path $pathA
        $entryA.Timestamp = (Get-Date '2020-01-01T00:00:00Z').ToString('o')
        Write-WtJson -Path $pathA -InputObject $entryA

        $entryB = Read-WtJson -Path $pathB
        $entryB.Timestamp = (Get-Date '2025-01-01T00:00:00Z').ToString('o')
        Write-WtJson -Path $pathB -InputObject $entryB

        $entries = Get-WtUndoEntries -TestRootOverride $FakeRoot
        $entries.Count | Should -Be 2
        $entries[0].Action | Should -Be 'pkg-b'
        $entries[1].Action | Should -Be 'svc-a'
    }

    It 'skips a corrupt file in either scope without preventing the remaining entries from listing' {
        $items = @([PSCustomObject]@{ ItemType = 'Service'; Name = 'Good'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' })
        Write-WtUndoEntry -Scope Machine -Action 'good-entry' -Items $items -TestRootOverride $FakeRoot | Out-Null

        $undoDir = Get-WtDataPath -Scope Machine -SubPath 'undo' -TestRootOverride $FakeRoot
        Set-Content -LiteralPath (Join-Path $undoDir '20200101-000000-corrupt.json') -Encoding UTF8 -Value '{ not valid json'

        $entries = Get-WtUndoEntries -TestRootOverride $FakeRoot -WarningAction SilentlyContinue
        @($entries).Count | Should -Be 1
        $entries[0].Action | Should -Be 'good-entry'
    }
}

Describe 'Restore-WtUndoEntry' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'returns per-item results, not a single verdict, when one item fails and one succeeds' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'GoodSvc'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' },
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'BadSvc'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'mixed' -Items $items -TestRootOverride $FakeRoot

        $fakeRestore = {
            param($item)
            if ($item.Name -eq 'BadSvc') { throw 'simulated failure' }
        }

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem $fakeRestore

        $results.Count | Should -Be 2
        ($results | Where-Object Name -eq 'GoodSvc').Outcome | Should -Be 'Restored'
        ($results | Where-Object Name -eq 'BadSvc').Outcome | Should -Be 'Failed'
    }

    It 'marks RestoredAt without deleting the entry' {
        $items = @([PSCustomObject]@{ ItemType = 'Service'; Name = 'X'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' })
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'once' -Items $items -TestRootOverride $FakeRoot

        Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem { param($item) } | Out-Null

        Test-Path -LiteralPath $entryPath | Should -BeTrue
        $reloaded = Read-WtJson -Path $entryPath
        $reloaded.RestoredAt | Should -Not -BeNullOrEmpty
    }

    It 'hands the source item back with each result so a screen can name it' {
        $items = @([PSCustomObject]@{ ItemType = 'Service'; Name = 'Named'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' })
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'named' -Items $items -TestRootOverride $FakeRoot

        $results = @(Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem { param($item) })

        $results[0].Item.Name | Should -Be 'Named'
        $results[0].Item.ItemType | Should -Be 'Service'
    }

    It 'does not mark RestoredAt when every item failed, so the entry stays listed for a retry' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'A'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'B'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'allfail' -Items $items -TestRootOverride $FakeRoot

        $results = @(Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem { param($item) throw 'nope' })

        @($results | ForEach-Object Outcome) | Should -Be @('Failed', 'Failed')
        $reloaded = Read-WtJson -Path $entryPath
        ($reloaded.PSObject.Properties.Name -contains 'RestoredAt') | Should -BeFalse
        @(Get-WtUndoScreenItems -Entries @(Get-WtUndoEntries -TestRootOverride $FakeRoot | Where-Object Action -eq 'allfail')).Count | Should -Be 1
    }

    It 'marks RestoredAt when at least one item was restored, and when nothing is restorable at all' {
        $mixed = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'Good'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'Bad'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
        )
        $mixedPath = Write-WtUndoEntry -Scope Machine -Action 'mixed' -Items $mixed -TestRootOverride $FakeRoot
        Restore-WtUndoEntry -EntryPath $mixedPath -RestoreServiceItem { param($item) if ($item.Name -eq 'Bad') { throw 'nope' } } | Out-Null
        (Read-WtJson -Path $mixedPath).RestoredAt | Should -Not -BeNullOrEmpty

        $dead = @([PSCustomObject]@{ ItemType = 'SomethingUnknown'; Name = 'Z' })
        $deadPath = Write-WtUndoEntry -Scope User -Action 'dead' -Items $dead -TestRootOverride $FakeRoot
        @(Restore-WtUndoEntry -EntryPath $deadPath)[0].Outcome | Should -Be 'NotRestorable'
        (Read-WtJson -Path $deadPath).RestoredAt | Should -Not -BeNullOrEmpty
    }

    It 'returns NotRestorable (not Failed) for a package whose recorded manifest no longer exists - using the real default restore action' {
        $missingInstallLocation = Join-Path $TestDrive 'gone-package-install-location'
        $items = @(
            [PSCustomObject]@{ ItemType = 'Package'; PackageFullName = 'Contoso.Gone'; InstallLocation = $missingInstallLocation; IsProvisioned = $false }
        )
        $entryPath = Write-WtUndoEntry -Scope User -Action 'pkg-removal' -Items $items -TestRootOverride $FakeRoot

        $results = Restore-WtUndoEntry -EntryPath $entryPath

        @($results).Count | Should -Be 1
        $results[0].Outcome | Should -Be 'NotRestorable'
    }

    It 'returns NotRestorable (not Failed) for a WinGet capture item, which has no install location at all' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'Package'; PackageFullName = 'Microsoft.OneDrive'; InstallLocation = $null; IsProvisioned = $false; RemovalMethod = 'WinGet' }
        )
        $entryPath = Write-WtUndoEntry -Scope User -Action 'pkg-removal' -Items $items -TestRootOverride $FakeRoot

        $results = Restore-WtUndoEntry -EntryPath $entryPath

        @($results).Count | Should -Be 1
        $results[0].Outcome | Should -Be 'NotRestorable'
        $results[0].Name | Should -Be 'Microsoft.OneDrive'
    }

    It 'calls RestoreRegistryItem and reports Restored for a Registry item, naming it Path\Name' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'Registry'; Path = 'HKLM:\SOFTWARE\Test'; Name = 'X'; RegType = 'DWord'; PreviousPresent = $true; PreviousValue = 0 }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'registry-change' -Items $items -TestRootOverride $FakeRoot

        $seen = @{}
        $fakeRestore = { param($Item) $seen.Called = $true; $seen.Path = $Item.Path; $seen.Name = $Item.Name }.GetNewClosure()

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreRegistryItem $fakeRestore

        $seen.Called | Should -BeTrue
        $seen.Path | Should -Be 'HKLM:\SOFTWARE\Test'
        @($results).Count | Should -Be 1
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Be 'HKLM:\SOFTWARE\Test\X'
    }

    It 'defaults to NotRestorable (not Failed) for an item type with no matching restore branch' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'SomeFutureType'; Name = 'X' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'unknown-type' -Items $items -TestRootOverride $FakeRoot

        $results = Restore-WtUndoEntry -EntryPath $entryPath

        @($results).Count | Should -Be 1
        $results[0].Outcome | Should -Be 'NotRestorable'
        $results[0].Name | Should -Be 'SomeFutureType'
    }

    It 'calls RestoreDnsItem and reports Restored for a DnsConfig item, naming it by adapter' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'DnsConfig'; InterfaceIndex = 12; PreviousIPv4 = @(); PreviousIPv6 = @(); AddedDohAddresses = @('1.1.1.1'); PreviousDohEntries = @() }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'dns-change' -Items $items -TestRootOverride $FakeRoot

        $seen = @{}
        $fakeRestore = { param($Item) $seen.Called = $true; $seen.InterfaceIndex = $Item.InterfaceIndex }.GetNewClosure()

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreDnsItem $fakeRestore

        $seen.Called | Should -BeTrue
        $seen.InterfaceIndex | Should -Be 12
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Be 'Adapter 12'
    }

    It 'calls RestoreHostsItem and reports Restored for a HostsBlock item, naming it by tier and line count' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'HostsBlock'; Tier = 'Spy'; Lines = @("0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)") }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'hosts-block' -Items $items -TestRootOverride $FakeRoot

        $seen = @{}
        $fakeRestore = { param($Item) $seen.Called = $true; $seen.Tier = $Item.Tier }.GetNewClosure()

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreHostsItem $fakeRestore

        $seen.Called | Should -BeTrue
        $seen.Tier | Should -Be 'Spy'
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Be 'hosts (Spy, 1 lines)'
    }

    It 'calls RestoreFirewallItem and reports Restored for a FirewallBlock item, naming it by tier and rule count' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'FirewallBlock'; Tier = 'Extra'; RuleNames = @('WinToolify-Block-Extra-0', 'WinToolify-Block-Extra-1') }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'firewall-block' -Items $items -TestRootOverride $FakeRoot

        $seen = @{}
        $fakeRestore = { param($Item) $seen.RuleNames = @($Item.RuleNames) }.GetNewClosure()

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreFirewallItem $fakeRestore

        @($seen.RuleNames) | Should -Be @('WinToolify-Block-Extra-0', 'WinToolify-Block-Extra-1')
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Be 'Extra firewall rules (2)'
    }
}

Describe 'Format-WtUndoEntryLabel' {
    It 'renders timestamp, action, and a pluralized item count' {
        $entry = [PSCustomObject]@{
            Timestamp = '2026-08-17T14:30:00'
            Action    = 'Disable Services'
            Items     = @(1, 2, 3)
        }
        Format-WtUndoEntryLabel -Entry $entry | Should -Be '2026-08-17 14:30:00 - Disable Services (3 items)'
    }

    It 'uses the singular "item" for a single-item entry' {
        $entry = [PSCustomObject]@{
            Timestamp = '2026-08-17T14:30:00'
            Action    = 'Remove Package'
            Items     = @(1)
        }
        Format-WtUndoEntryLabel -Entry $entry | Should -Be '2026-08-17 14:30:00 - Remove Package (1 item)'
    }

    It 'counts catalog entries, not registry values: two values of one entry are one item' {
        $entry = [PSCustomObject]@{
            Timestamp = '2026-08-30T17:34:41'
            Action    = 'Apply Edge Settings'
            Items     = @(
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\A'; Name = 'V1' }
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\B'; Name = 'V2' }
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E002'; Path = 'HKLM:\C'; Name = 'V3' }
            )
        }
        Format-WtUndoEntryLabel -Entry $entry | Should -Be '2026-08-30 17:34:41 - Apply Edge Settings (2 items)'
    }

    It 'counts a firewall profile per profile and a service per name, the way the confirm panel lists them' {
        $entry = [PSCustomObject]@{
            Timestamp = '2026-08-23T17:34:44'
            Action    = 'Set Firewall State'
            Items     = @(
                [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Domain'; ProfileName = 'Domain'; WasEnabled = $false; TargetEnabled = $true; CatalogEntry = 'EnableFirewall' }
                [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Private'; ProfileName = 'Private'; WasEnabled = $false; TargetEnabled = $true; CatalogEntry = 'EnableFirewall' }
                [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Public'; ProfileName = 'Public'; WasEnabled = $false; TargetEnabled = $true; CatalogEntry = 'EnableFirewall' }
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'DiagTrack'; Template = 'DiagTrack'; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual' }
            )
        }
        Format-WtUndoEntryLabel -Entry $entry | Should -Be '2026-08-23 17:34:44 - Set Firewall State (4 items)'
    }

    It 'leaves out items already put back one by one from an apply screen' {
        $entry = [PSCustomObject]@{
            Timestamp = '2026-08-23T13:09:38'
            Action    = 'Disable Services'
            Items     = @(
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'lfsvc'; Template = 'lfsvc'; PreviousStatus = 'Running'; PreviousStartType = 'Manual' }
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'PcaSvc'; Template = 'PcaSvc'; PreviousStatus = 'Running'; PreviousStartType = 'Manual'; RestoredAt = '2026-08-24T10:00:00' }
            )
        }
        Format-WtUndoEntryLabel -Entry $entry | Should -Be '2026-08-23 13:09:38 - Disable Services (1 item)'
    }

    It 'notes an already-restored entry' {
        $entry = [PSCustomObject]@{
            Timestamp  = '2026-08-17T14:30:00'
            Action     = 'Disable Services'
            Items      = @(1)
            RestoredAt = '2026-08-17T15:00:00'
        }
        Format-WtUndoEntryLabel -Entry $entry | Should -Match '\[previously restored\]$'
    }
}

Describe 'Restore-WtUndoEntry - PowerPlan / PowerSetting item types and LIFO order' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'calls RestorePowerPlanItem and reports Restored for a PowerPlan item, naming it by previous scheme' {
        $items = @([PSCustomObject]@{ ItemType = 'PowerPlan'; CatalogEntry = 'UltimatePerformance'; PreviousActiveScheme = 'aaaa'; TargetScheme = 'bbbb'; CreatedScheme = 'bbbb' })
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'power' -Items $items -TestRootOverride $FakeRoot
        $script:PlanCalls = 0
        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestorePowerPlanItem { param($item) $script:PlanCalls++ }
        $script:PlanCalls | Should -Be 1
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Match 'aaaa'
    }

    It 'calls RestorePowerSettingItem and reports Restored for a PowerSetting item, naming it by setting label and scheme' {
        $items = @([PSCustomObject]@{ ItemType = 'PowerSetting'; CatalogEntry = 'DisableCoreParking'; SchemeGuid = 'aaaa'; SubGroupGuid = 's'; SettingGuid = 'g'; SettingLabel = 'CPMINCORES'; PreviousAc = 10; PreviousDc = 10 })
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'power' -Items $items -TestRootOverride $FakeRoot
        $script:SettingCalls = 0
        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestorePowerSettingItem { param($item) $script:SettingCalls++ }
        $script:SettingCalls | Should -Be 1
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Match 'CPMINCORES'
        $results[0].Name | Should -Match 'aaaa'
    }

    It 'restores items last-captured-first: the PowerSetting item is restored before the PowerPlan item that precedes it' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'PowerPlan'; CatalogEntry = 'UltimatePerformance'; PreviousActiveScheme = 'aaaa'; TargetScheme = 'bbbb'; CreatedScheme = 'bbbb' },
            [PSCustomObject]@{ ItemType = 'PowerSetting'; CatalogEntry = 'DisableCoreParking'; SchemeGuid = 'bbbb'; SubGroupGuid = 's'; SettingGuid = 'g'; SettingLabel = 'CPMINCORES'; PreviousAc = 10; PreviousDc = 10 }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'power' -Items $items -TestRootOverride $FakeRoot
        $order = New-Object System.Collections.Generic.List[string]
        Restore-WtUndoEntry -EntryPath $entryPath -RestorePowerPlanItem { param($item) $order.Add('plan') } -RestorePowerSettingItem { param($item) $order.Add('setting') } | Out-Null
        $order.ToArray() | Should -Be @('setting', 'plan')
    }

    It 'restores a two-Service entry second-captured-first' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'FirstSvc'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' },
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'SecondSvc'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'svc' -Items $items -TestRootOverride $FakeRoot
        $order = New-Object System.Collections.Generic.List[string]
        Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem { param($item) $order.Add($item.Name) } | Out-Null
        $order.ToArray() | Should -Be @('SecondSvc', 'FirstSvc')
    }
}

Describe 'Restore-WtUndoEntry - per-user template Start' {
    It 'puts the recorded template Start back and leaves it alone when not recorded' {
        $script:templateWrites = @()
        $items = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'CaptureService_45ce1'; Template = 'CaptureService'; IsPerUser = $true; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual'; PreviousTemplateStart = 3 }
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'Fax'; Template = 'Fax'; IsPerUser = $false; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual' }
        )
        $entryPath = Write-WtUndoEntry -Scope 'Machine' -Action 'Disable Services' -Items $items -TestRootOverride $TestDrive
        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem { param($Item) if ($Item.PSObject.Properties.Name -contains 'PreviousTemplateStart' -and $null -ne $Item.PreviousTemplateStart) { $script:templateWrites += "$($Item.Template)=$($Item.PreviousTemplateStart)" } }
        @($results | ForEach-Object Outcome) | Should -Be @('Restored', 'Restored')
        $script:templateWrites | Should -Be @('CaptureService=3')
    }
}

Describe 'Restore-WtUndoEntry - the default service restore delegate' {
    It 'starts a service that was running before the change' {
        $src = (Get-Command Restore-WtUndoEntry).ScriptBlock.ToString()
        $src | Should -Match "PreviousStatus -eq 'Running'"
        $src | Should -Match 'Start-Service'
    }
    It 'stops a service the Automatic target started - it was Stopped before' {
        $src = (Get-Command Restore-WtUndoEntry).ScriptBlock.ToString()
        $src | Should -Match "elseif \(\`$Item\.PreviousStatus -eq 'Stopped'\)"
        $src | Should -Match 'Stop-Service -Name \$Item\.Name -Force'
    }
}
