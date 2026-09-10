#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the Windows Firewall and Fast Startup / hibernation
    guarded-toggle catalogs, their state readers and apply functions,
    and their Restore-WtUndoEntry branches ('FirewallProfile',
    'HibernationState'). Neither NetSecurity cmdlets nor powercfg run on
    the macOS dev host, so every test drives injectable action
    scriptblocks instead.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtFirewallCatalog' {
    It 'has exactly the enable and disable entries with correct risk' {
        $c = Get-WtFirewallCatalog
        @($c).Count | Should -Be 2
        ($c | Where-Object Name -eq 'EnableFirewall').Risk | Should -Be 'SAFE'
        ($c | Where-Object Name -eq 'DisableFirewall').Risk | Should -Be 'ADVANCED'
        ($c | Where-Object Name -eq 'DisableFirewall').Consequence | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-WtFirewallState' {
    It 'Applied only when every profile matches the target' {
        $entry = (Get-WtFirewallCatalog) | Where-Object Name -eq 'DisableFirewall'
        $allOff = { @(
            [PSCustomObject]@{ Name = 'Domain'; Enabled = $false }
            [PSCustomObject]@{ Name = 'Private'; Enabled = $false }
            [PSCustomObject]@{ Name = 'Public'; Enabled = $false }
        ) }
        $mixed = { @(
            [PSCustomObject]@{ Name = 'Domain'; Enabled = $true }
            [PSCustomObject]@{ Name = 'Private'; Enabled = $false }
            [PSCustomObject]@{ Name = 'Public'; Enabled = $false }
        ) }
        (Get-WtFirewallState -Entry $entry -GetProfilesAction $allOff).Applied | Should -BeTrue
        (Get-WtFirewallState -Entry $entry -GetProfilesAction $mixed).Applied | Should -BeFalse
    }
}

Describe 'Firewall state from the registry, avoiding the NetSecurity cmdlet cost on entry' {
    BeforeAll {
        $script:svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\'
        $script:polRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\'
        $script:regValues = @{}
        $script:readFake = { param($p, $n)
            $k = [string]$p + '|' + [string]$n
            if (-not $script:regValues.ContainsKey($k)) { return $null }
            $o = New-Object PSObject
            $o | Add-Member -NotePropertyName $n -NotePropertyValue $script:regValues[$k]
            $o
        }
        $script:setService = { param([string]$Profile, [int]$Value) $script:regValues[$script:svcRoot + $Profile + 'Profile|EnableFirewall'] = $Value }
        $script:setPolicy = { param([string]$Profile, [int]$Value) $script:regValues[$script:polRoot + $Profile + 'Profile|EnableFirewall'] = $Value }
    }
    BeforeEach { $script:regValues = @{} }

    Context 'Get-WtFirewallRegistryState' {
        It 'all three service values on: Enabled and Known' {
            foreach ($p in 'Domain', 'Standard', 'Public') { & $script:setService $p 1 }
            $s = Get-WtFirewallRegistryState -GetPropertyAction $script:readFake
            $s.Enabled | Should -BeTrue
            $s.Known | Should -BeTrue
        }
        It 'one profile off is not Enabled - all-or-nothing, the rule Get-WtFirewallState applies' {
            & $script:setService 'Domain' 1; & $script:setService 'Standard' 1; & $script:setService 'Public' 0
            $s = Get-WtFirewallRegistryState -GetPropertyAction $script:readFake
            $s.Enabled | Should -BeFalse
            $s.Known | Should -BeTrue
        }
        It 'a Group Policy value wins over the service value, either way round' {
            foreach ($p in 'Domain', 'Standard', 'Public') { & $script:setService $p 1 }
            & $script:setPolicy 'Public' 0
            (Get-WtFirewallRegistryState -GetPropertyAction $script:readFake).Enabled | Should -BeFalse
            $script:regValues = @{}
            & $script:setService 'Domain' 0; & $script:setService 'Standard' 1; & $script:setService 'Public' 1
            & $script:setPolicy 'Domain' 1
            (Get-WtFirewallRegistryState -GetPropertyAction $script:readFake).Enabled | Should -BeTrue
        }
        It 'a profile with no readable value at all: Known false, so the caller can ask the cmdlet' {
            & $script:setService 'Domain' 1; & $script:setService 'Standard' 1
            $s = Get-WtFirewallRegistryState -GetPropertyAction $script:readFake
            $s.Known | Should -BeFalse
            $s.Enabled | Should -BeFalse
        }
    }

    Context 'Get-WtFirewallLiveState' {
        It 'never touches NetSecurity when the registry answers' {
            foreach ($p in 'Domain', 'Standard', 'Public') { & $script:setService $p 1 }
            $s = Get-WtFirewallLiveState -GetPropertyAction $script:readFake -GetProfilesAction { throw 'NetSecurity must not be queried' }
            $s.Enabled | Should -BeTrue
            $s.Known | Should -BeTrue
        }
        It 'asks the cmdlet only when the registry is silent, and reports Known false when that throws too' {
            $on = { @(
                [PSCustomObject]@{ Name = 'Domain'; Enabled = $true }
                [PSCustomObject]@{ Name = 'Private'; Enabled = $true }
                [PSCustomObject]@{ Name = 'Public'; Enabled = $true }
            ) }
            $s = Get-WtFirewallLiveState -GetPropertyAction $script:readFake -GetProfilesAction $on
            $s.Enabled | Should -BeTrue
            $s.Known | Should -BeTrue
            $s2 = Get-WtFirewallLiveState -GetPropertyAction $script:readFake -GetProfilesAction { throw 'no module' }
            $s2.Known | Should -BeFalse
            $s2.Enabled | Should -BeFalse
        }
    }
}

Describe 'Firewall -Enabled takes a GpoBoolean, not a [bool]' {
    It 'converts a bool to the enum name the cmdlet accepts' {
        ConvertTo-WtGpoBoolean -Enabled $true | Should -BeExactly 'True'
        ConvertTo-WtGpoBoolean -Enabled $false | Should -BeExactly 'False'
    }
    It 'returns a string, never a bool - a bool is what the cmdlet rejects' {
        (ConvertTo-WtGpoBoolean -Enabled $false) -is [string] | Should -BeTrue
        (ConvertTo-WtGpoBoolean -Enabled $true) -is [string] | Should -BeTrue
    }
    It 'the default writer converts instead of passing the raw bool through' {
        $src = [string](Get-Command Invoke-WtApplyFirewallSelection).Definition
        $src | Should -Match 'Set-NetFirewallProfile[^\r\n]*-Enabled \(ConvertTo-WtGpoBoolean'
        $src | Should -Not -Match 'Set-NetFirewallProfile[^\r\n]*-Enabled \$Enabled'
    }
    It 'EVERY Set-NetFirewallProfile call site in the whole script converts through ConvertTo-WtGpoBoolean' {
        $tokens = $null
        $parseErrors = $null
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($script:TargetPath, [ref]$tokens, [ref]$parseErrors)
        $calls = @($fileAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            [string]$node.GetCommandName() -eq 'Set-NetFirewallProfile'
        }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $call.Extent.Text | Should -Match 'ConvertTo-WtGpoBoolean'
        }
    }
    It 'the apply delegate passes a bool on, and the writer is what converts it' {
        $got = $null
        $writer = { param($ProfileName, $Enabled) $script:got = @{ Profile = $ProfileName; Value = $Enabled } }
        $profiles = { @([PSCustomObject]@{ Name = 'Domain'; Enabled = $true }) }
        Invoke-WtApplyFirewallSelection -SelectedNames @('DisableFirewall') -GetProfilesAction $profiles `
            -SetProfileAction $writer -TestRootOverride $TestDrive | Out-Null
        $script:got.Profile | Should -Be 'Domain'
        $script:got.Value | Should -BeFalse
    }
}

Describe 'Invoke-WtApplyFirewallSelection' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ("fw-" + [Guid]::NewGuid().ToString('N'))
    }

    It 'captures per-profile state, applies the target, and undo restores it' {
        $script:profiles = @{ Domain = $true; Private = $true; Public = $true }
        $get = { foreach ($k in @('Domain', 'Private', 'Public')) { [PSCustomObject]@{ Name = $k; Enabled = $script:profiles[$k] } } }
        $set = { param($ProfileName, $Enabled) $script:profiles[$ProfileName] = [bool]$Enabled }

        $result = Invoke-WtApplyFirewallSelection -SelectedNames @('DisableFirewall') `
            -GetProfilesAction $get -SetProfileAction $set -TestRootOverride $root
        $result.Aborted | Should -BeFalse
        @($result.Results).Count | Should -Be 3
        @($result.Results | Where-Object { -not $_.Applied }).Count | Should -Be 0
        $script:profiles['Public'] | Should -BeFalse

        $entry = @(Get-WtUndoEntries -TestRootOverride $root)[0]
        @($entry.Items).Count | Should -Be 3
        @($entry.Items | Where-Object ProfileName -eq 'Domain')[0].WasEnabled | Should -BeTrue

        $restore = Restore-WtUndoEntry -EntryPath $entry.Path `
            -RestoreFirewallProfileItem { param($Item) $script:profiles[$Item.ProfileName] = [bool]$Item.WasEnabled }
        @($restore | Where-Object Outcome -ne 'Restored').Count | Should -Be 0
        $script:profiles['Domain'] | Should -BeTrue
    }

    It 'last selected direction wins when both are selected' {
        $script:profiles = @{ Domain = $false; Private = $false; Public = $false }
        $get = { foreach ($k in @('Domain', 'Private', 'Public')) { [PSCustomObject]@{ Name = $k; Enabled = $script:profiles[$k] } } }
        $set = { param($ProfileName, $Enabled) $script:profiles[$ProfileName] = [bool]$Enabled }
        $null = Invoke-WtApplyFirewallSelection -SelectedNames @('DisableFirewall', 'EnableFirewall') `
            -GetProfilesAction $get -SetProfileAction $set -TestRootOverride $root
        $script:profiles['Domain'] | Should -BeTrue
    }
}

Describe 'Restore-WtUndoEntry - FirewallProfile item type' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'calls RestoreFirewallProfileItem and reports Restored for a FirewallProfile item, naming it by profile' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Domain'; ProfileName = 'Domain'; WasEnabled = $true; TargetEnabled = $false; CatalogEntry = 'DisableFirewall' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'firewall-profile' -Items $items -TestRootOverride $FakeRoot

        $seen = @{}
        $fakeRestore = { param($Item) $seen.Called = $true; $seen.ProfileName = $Item.ProfileName; $seen.WasEnabled = $Item.WasEnabled }.GetNewClosure()

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreFirewallProfileItem $fakeRestore

        $seen.Called | Should -BeTrue
        $seen.ProfileName | Should -Be 'Domain'
        $seen.WasEnabled | Should -BeTrue
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Be 'Firewall Domain'
    }

    It 'reports Failed, not aborting the rest of the entry, when RestoreFirewallProfileItem throws' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Domain'; ProfileName = 'Domain'; WasEnabled = $true; TargetEnabled = $false; CatalogEntry = 'DisableFirewall' }
            [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Public'; ProfileName = 'Public'; WasEnabled = $true; TargetEnabled = $false; CatalogEntry = 'DisableFirewall' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'firewall-profile' -Items $items -TestRootOverride $FakeRoot

        $fakeRestore = { param($Item) if ($Item.ProfileName -eq 'Domain') { throw 'simulated failure' } }

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreFirewallProfileItem $fakeRestore

        ($results | Where-Object Name -eq 'Firewall Domain').Outcome | Should -Be 'Failed'
        ($results | Where-Object Name -eq 'Firewall Public').Outcome | Should -Be 'Restored'
    }
}

Describe 'Get-WtFastStartupCatalog' {
    It 'has exactly one CAUTION entry with a DisplayLabel and Consequence' {
        $c = Get-WtFastStartupCatalog
        @($c).Count | Should -Be 1
        $c[0].Name | Should -Be 'DisableFastStartup'
        $c[0].Risk | Should -Be 'CAUTION'
        $c[0].DisplayLabel | Should -Be 'Disable hibernation and Fast Startup (powercfg /h off)'
        $c[0].Consequence | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-WtFastStartupState' {
    It 'Applied only when the value is Present and equal to 0' {
        $entry = (Get-WtFastStartupCatalog) | Where-Object Name -eq 'DisableFastStartup'
        $off = { [PSCustomObject]@{ Present = $true; Value = 0 } }
        $on = { [PSCustomObject]@{ Present = $true; Value = 1 } }
        $absent = { [PSCustomObject]@{ Present = $false; Value = $null } }
        (Get-WtFastStartupState -Entry $entry -GetHibernateValueAction $off).Applied | Should -BeTrue
        (Get-WtFastStartupState -Entry $entry -GetHibernateValueAction $on).Applied | Should -BeFalse
        (Get-WtFastStartupState -Entry $entry -GetHibernateValueAction $absent).Applied | Should -BeFalse
    }
}

Describe 'Invoke-WtApplyFastStartupSelection' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ("fs-" + [Guid]::NewGuid().ToString('N'))
    }

    It 'returns Aborted=false with no results when DisableFastStartup is not selected' {
        $result = Invoke-WtApplyFastStartupSelection -SelectedNames @('SomeUnrelatedName') -TestRootOverride $root
        $result.Aborted | Should -BeFalse
        @($result.Results).Count | Should -Be 0
    }

    It 'captures WasEnabled=true from an absent value, applies, and undo restores it' {
        $script:hib = $null
        $get = {
            if ($null -eq $script:hib) { return [PSCustomObject]@{ Present = $false; Value = $null } }
            $v = 0
            if ($script:hib) { $v = 1 }
            return [PSCustomObject]@{ Present = $true; Value = $v }
        }
        $set = { param($On) $script:hib = [bool]$On }

        $result = Invoke-WtApplyFastStartupSelection -SelectedNames @('DisableFastStartup') `
            -GetHibernateValueAction $get -SetHibernateAction $set -TestRootOverride $root
        $result.Aborted | Should -BeFalse
        @($result.Results).Count | Should -Be 1
        $result.Results[0].Item.ItemType | Should -Be 'HibernationState'
        $result.Results[0].Item.WasEnabled | Should -BeTrue
        @($result.Results | Where-Object { -not $_.Applied }).Count | Should -Be 0
        $script:hib | Should -BeFalse

        $entry = @(Get-WtUndoEntries -TestRootOverride $root)[0]
        @($entry.Items).Count | Should -Be 1
        $entry.Items[0].WasEnabled | Should -BeTrue

        $restore = Restore-WtUndoEntry -EntryPath $entry.Path `
            -RestoreHibernationItem { param($Item) $script:hib = [bool]$Item.WasEnabled }
        @($restore | Where-Object Outcome -ne 'Restored').Count | Should -Be 0
        $script:hib | Should -BeTrue
    }
}

Describe 'Restore-WtUndoEntry - HibernationState item type' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'calls RestoreHibernationItem and reports Restored for a HibernationState item' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'HibernationState'; Name = 'Hibernation'; WasEnabled = $true; CatalogEntry = 'DisableFastStartup' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'fast-startup' -Items $items -TestRootOverride $FakeRoot

        $seen = @{}
        $fakeRestore = { param($Item) $seen.Called = $true; $seen.WasEnabled = $Item.WasEnabled }.GetNewClosure()

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreHibernationItem $fakeRestore

        $seen.Called | Should -BeTrue
        $seen.WasEnabled | Should -BeTrue
        $results[0].Outcome | Should -Be 'Restored'
        $results[0].Name | Should -Be 'Hibernation'
    }

    It 'reports Failed, not aborting the rest of the entry, when RestoreHibernationItem throws' {
        $items = @(
            [PSCustomObject]@{ ItemType = 'HibernationState'; Name = 'Hibernation'; WasEnabled = $true; CatalogEntry = 'DisableFastStartup' }
            [PSCustomObject]@{ ItemType = 'HibernationState'; Name = 'Hibernation2'; WasEnabled = $true; CatalogEntry = 'DisableFastStartup' }
        )
        $entryPath = Write-WtUndoEntry -Scope Machine -Action 'fast-startup' -Items $items -TestRootOverride $FakeRoot

        $fakeRestore = { param($Item) if ($Item.Name -eq 'Hibernation') { throw 'simulated failure' } }

        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreHibernationItem $fakeRestore

        ($results | Where-Object Name -eq 'Hibernation').Outcome | Should -Be 'Failed'
        ($results | Where-Object Name -eq 'Hibernation2').Outcome | Should -Be 'Restored'
    }
}

Describe 'Invoke-WtApplyFastStartupSelection -Enable' {
    It 'turns hibernation back on, captures WasEnabled=false and re-reads the enabled state' {
        $fakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:hib = 0
        $script:sets = @()
        $r = Invoke-WtApplyFastStartupSelection -SelectedNames @('DisableFastStartup') -Enable `
            -GetHibernateValueAction { [PSCustomObject]@{ Present = $true; Value = $script:hib } } `
            -SetHibernateAction { param($On) $script:sets += $On; $script:hib = $(if ($On) { 1 } else { 0 }) } `
            -TestRootOverride $fakeRoot
        @($sets) | Should -Be @($true)
        $r.Results[0].Applied | Should -BeTrue
        $r.Results[0].Item.WasEnabled | Should -BeFalse
        $entry = Get-ChildItem -Path $fakeRoot -Recurse -Filter '*.json' | Select-Object -First 1
        $entry.Name | Should -Match 'Enable Fast Startup'
    }
    It 'the FastStartup section exposes TurnOff with a translated action name' {
        $row = (Get-WtProfileSectionCatalog) | Where-Object Key -eq 'FastStartup'
        Mock Invoke-WtApplyFastStartupSelection { [PSCustomObject]@{ Aborted = $false; Results = @(); E = [bool]$Enable } }
        (& $row.TurnOff ([string[]]@('DisableFastStartup')) $null).E | Should -BeTrue
        $script:Translations['TR']['UndoAction.Enable Fast Startup'] | Should -Not -BeNullOrEmpty
    }
}
