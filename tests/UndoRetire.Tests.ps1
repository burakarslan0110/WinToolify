#Requires -Modules Pester

<#
.SYNOPSIS
    Retiring undo records: when an action wipes state another screen
    recorded, that screen's undo entry must stop offering to restore
    something that no longer exists - without confusing that with a
    user-initiated restore, and without dropping the untouched parts of
    a mixed entry.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Test-WtUndoEntryClosed' {
    It 'is false for a fresh entry' {
        Test-WtUndoEntryClosed -Entry ([PSCustomObject]@{ Action = 'Apply DNS Preset' }) | Should -BeFalse
    }

    It 'is true for an entry the user already restored' {
        Test-WtUndoEntryClosed -Entry ([PSCustomObject]@{ Action = 'Apply DNS Preset'; RestoredAt = '2026-08-23T10:00:00' }) | Should -BeTrue
    }

    It 'is true for a retired entry' {
        Test-WtUndoEntryClosed -Entry ([PSCustomObject]@{ Action = 'Apply DNS Preset'; RetiredAt = '2026-08-23T10:00:00'; RetiredBy = 'ResetTcpIpStack' }) | Should -BeTrue
    }

    It 'is false when the stamp is present but empty' {
        Test-WtUndoEntryClosed -Entry ([PSCustomObject]@{ Action = 'Apply DNS Preset'; RetiredAt = '' }) | Should -BeFalse
    }
}

Describe 'Test-WtUndoItemClosed' {
    It 'is false for a fresh item' {
        Test-WtUndoItemClosed -Item ([PSCustomObject]@{ ItemType = 'HostsBlock' }) | Should -BeFalse
    }

    It 'is true for an item a per-setting revert already restored' {
        Test-WtUndoItemClosed -Item ([PSCustomObject]@{ ItemType = 'HostsBlock'; RestoredAt = '2026-08-23T10:00:00' }) | Should -BeTrue
    }

    It 'is true for a retired item' {
        Test-WtUndoItemClosed -Item ([PSCustomObject]@{ ItemType = 'FirewallBlock'; RetiredAt = '2026-08-23T10:00:00' }) | Should -BeTrue
    }
}

Describe 'Set-WtUndoEntryRetired - whole entry' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('wt-retire-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    AfterEach {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stamps a matching entry and reports how many records it touched' {
        Write-WtUndoEntry -Scope Machine -Action 'Apply DNS Preset' -Items @([PSCustomObject]@{ Name = 'Cloudflare' }) -TestRootOverride $root | Out-Null

        Set-WtUndoEntryRetired -ActionNames @('Apply DNS Preset') -RetiredBy 'ResetTcpIpStack' -TestRootOverride $root | Should -Be 1

        $entry = @(Get-WtUndoEntries -TestRootOverride $root)[0]
        $entry.RetiredAt | Should -Not -BeNullOrEmpty
        $entry.RetiredBy | Should -Be 'ResetTcpIpStack'
    }

    It 'leaves an entry with a different action alone' {
        Write-WtUndoEntry -Scope Machine -Action 'Set Service Start Type' -Items @([PSCustomObject]@{ Name = 'Spooler' }) -TestRootOverride $root | Out-Null

        Set-WtUndoEntryRetired -ActionNames @('Apply DNS Preset') -RetiredBy 'ResetTcpIpStack' -TestRootOverride $root | Should -Be 0

        (@(Get-WtUndoEntries -TestRootOverride $root)[0]).PSObject.Properties.Name | Should -Not -Contain 'RetiredAt'
    }

    It 'retires every action name it is given' {
        Write-WtUndoEntry -Scope Machine -Action 'Apply Power Plan Settings' -Items @([PSCustomObject]@{ Name = 'Ultimate' }) -TestRootOverride $root | Out-Null
        Write-WtUndoEntry -Scope Machine -Action 'Revert Power Plan Settings' -Items @([PSCustomObject]@{ Name = 'Balanced' }) -TestRootOverride $root | Out-Null

        Set-WtUndoEntryRetired -ActionNames @('Apply Power Plan Settings', 'Revert Power Plan Settings') -RetiredBy 'RestorePowerSchemeDefaults' -TestRootOverride $root | Should -Be 2
    }

    It 'does not touch an entry the user has already restored' {
        $path = Write-WtUndoEntry -Scope Machine -Action 'Apply DNS Preset' -Items @([PSCustomObject]@{ Name = 'Cloudflare' }) -TestRootOverride $root
        $entry = Read-WtJson -Path $path
        $entry | Add-Member -NotePropertyName 'RestoredAt' -NotePropertyValue '2026-08-23T09:00:00' -Force
        Write-WtJson -Path $path -InputObject $entry

        Set-WtUndoEntryRetired -ActionNames @('Apply DNS Preset') -RetiredBy 'ResetTcpIpStack' -TestRootOverride $root | Should -Be 0
    }

    It 'returns zero when there is no undo history at all' {
        Set-WtUndoEntryRetired -ActionNames @('Apply DNS Preset') -RetiredBy 'ResetTcpIpStack' -TestRootOverride $root | Should -Be 0
    }
}

Describe 'Set-WtUndoEntryRetired - one layer of a mixed entry' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('wt-retire-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Write-WtUndoEntry -Scope Machine -Action 'Apply Blocklist' -Items @(
            [PSCustomObject]@{ ItemType = 'HostsBlock'; Tier = 'spy' }
            [PSCustomObject]@{ ItemType = 'FirewallBlock'; Tier = 'spy' }
        ) -TestRootOverride $root | Out-Null
    }
    AfterEach {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'retires only the layer the filter names and leaves the other restorable' {
        $touched = Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' `
            -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } -TestRootOverride $root
        $touched | Should -Be 1

        $entry = @(Get-WtUndoEntries -TestRootOverride $root)[0]
        $firewall = @($entry.Items | Where-Object { $_.ItemType -eq 'FirewallBlock' })[0]
        $hosts = @($entry.Items | Where-Object { $_.ItemType -eq 'HostsBlock' })[0]

        Test-WtUndoItemClosed -Item $firewall | Should -BeTrue
        Test-WtUndoItemClosed -Item $hosts | Should -BeFalse
        $firewall.RetiredBy | Should -Be 'ResetFirewallRules'
    }

    It 'keeps the entry itself open while any layer is still restorable' {
        Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' `
            -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } -TestRootOverride $root | Out-Null

        $entry = @(Get-WtUndoEntries -TestRootOverride $root)[0]
        Test-WtUndoEntryClosed -Entry $entry | Should -BeFalse
    }

    It 'closes the entry once the last open layer is retired too' {
        Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' `
            -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } -TestRootOverride $root | Out-Null
        Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetHostsFile' `
            -ItemFilter { param($Item) $Item.ItemType -eq 'HostsBlock' } -TestRootOverride $root | Out-Null

        $entry = @(Get-WtUndoEntries -TestRootOverride $root)[0]
        Test-WtUndoEntryClosed -Entry $entry | Should -BeTrue
        $entry.RetiredBy | Should -Be 'ResetHostsFile'
    }

    It 'reports nothing touched when the filter matches no open item' {
        Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' `
            -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } -TestRootOverride $root | Out-Null

        Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' `
            -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } -TestRootOverride $root | Should -Be 0
    }
}

Describe 'Undo screen hides retired entries' {
    It 'lists an open entry' {
        $entries = @([PSCustomObject]@{ Path = 'x.json'; Action = 'Apply DNS Preset'; Timestamp = '2026-08-23T10:00:00'; Items = @(1) })
        @(Get-WtUndoScreenItems -Entries $entries | Where-Object Kind -eq 'Action').Count | Should -Be 1
    }

    It 'hides a retired entry the same way it hides a restored one' {
        $entries = @(
            [PSCustomObject]@{ Path = 'x.json'; Action = 'Apply DNS Preset'; Timestamp = '2026-08-23T10:00:00'; Items = @(1); RetiredAt = '2026-08-23T11:00:00'; RetiredBy = 'ResetTcpIpStack' }
            [PSCustomObject]@{ Path = 'y.json'; Action = 'Apply Blocklist'; Timestamp = '2026-08-23T10:30:00'; Items = @(1); RestoredAt = '2026-08-23T11:30:00' }
        )
        $items = @(Get-WtUndoScreenItems -Entries $entries)
        @($items | Where-Object Kind -eq 'Action').Count | Should -Be 0
        $items[0].Name | Should -Be 'UndoEmpty'
    }

    It 'still lists an entry whose other layer is retired but whose own is not' {
        $entries = @([PSCustomObject]@{
                Path = 'z.json'; Action = 'Apply Blocklist'; Timestamp = '2026-08-23T10:00:00'
                Items = @(
                    [PSCustomObject]@{ ItemType = 'FirewallBlock'; RetiredAt = '2026-08-23T11:00:00' }
                    [PSCustomObject]@{ ItemType = 'HostsBlock' }
                )
            })
        @(Get-WtUndoScreenItems -Entries $entries | Where-Object Kind -eq 'Action').Count | Should -Be 1
    }
}
