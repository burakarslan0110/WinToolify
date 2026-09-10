#Requires -Modules Pester

<#
.SYNOPSIS
    The assistant's persistent memory files under LOCALAPPDATA\WinToolify\
    assistant: the profile cache, notes, and endpoint consent (/unut).
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'profile cache file' {
    It 'round-trips, answers null for a missing or corrupt file, and Remove deletes it' {
        $root = Join-Path $TestDrive 'pc'
        (Read-WtAssistantProfileCache -TestRootOverride $root) | Should -BeNullOrEmpty
        Save-WtAssistantProfileCache -Cache @{ v = 1; BuiltAt = '2026-09-01T10:00:00.0000000+03:00'; BootTime = '2026-09-01T08:00:00'; NewestChangeId = 'u9'; ShortJson = '{"a":1}'; FullJson = '{"b":2}' } -TestRootOverride $root
        $c = Read-WtAssistantProfileCache -TestRootOverride $root
        $c.ShortJson | Should -Be '{"a":1}'
        $c.NewestChangeId | Should -Be 'u9'
        Set-Content -LiteralPath (Get-WtAssistantMemoryPath -FileName 'profile.json' -TestRootOverride $root) -Value '{not json' -Encoding UTF8
        (Read-WtAssistantProfileCache -TestRootOverride $root) | Should -BeNullOrEmpty
        Remove-WtAssistantProfileCache -TestRootOverride $root
        (Test-Path -LiteralPath (Get-WtAssistantMemoryPath -FileName 'profile.json' -TestRootOverride $root)) | Should -BeFalse
    }
}

Describe 'notes file' {
    It 'adds trimmed notes, refuses empty ones, dedupes, caps at ten by dropping the oldest, and removes by number' {
        $root = Join-Path $TestDrive 'notes'
        @(Read-WtAssistantNotes -TestRootOverride $root).Count | Should -Be 0
        (Add-WtAssistantNote -Text '   ' -TestRootOverride $root).Saved | Should -BeFalse
        $long = 'x' * 250
        $r = Add-WtAssistantNote -Text $long -TestRootOverride $root -Now (Get-Date '2026-09-01T10:00:00')
        $r.Saved | Should -BeTrue
        $r.Text.Length | Should -Be 200
        $r.Count | Should -Be 1
        (Add-WtAssistantNote -Text $long -TestRootOverride $root -Now (Get-Date '2026-09-01T11:00:00')).Count | Should -Be 1
        @(Read-WtAssistantNotes -TestRootOverride $root)[0].at | Should -Match '^2026-09-01T11'
        @(Read-WtAssistantNotes -TestRootOverride $root)[0] -is [hashtable] | Should -BeTrue
        foreach ($i in 1..9) { $null = Add-WtAssistantNote -Text ('note ' + $i) -TestRootOverride $root }
        @(Read-WtAssistantNotes -TestRootOverride $root).Count | Should -Be 10
        $eleventh = Add-WtAssistantNote -Text 'note 10' -TestRootOverride $root
        $eleventh.Dropped | Should -BeTrue
        $notes = @(Read-WtAssistantNotes -TestRootOverride $root)
        $notes.Count | Should -Be 10
        $notes[0].text | Should -Be 'note 1'
        (Remove-WtAssistantNote -Index 1 -TestRootOverride $root) | Should -BeTrue
        @(Read-WtAssistantNotes -TestRootOverride $root)[0].text | Should -Be 'note 2'
        (Remove-WtAssistantNote -Index 99 -TestRootOverride $root) | Should -BeFalse
        Set-Content -LiteralPath (Get-WtAssistantMemoryPath -FileName 'facts.json' -TestRootOverride $root) -Value '{bad' -Encoding UTF8
        @(Read-WtAssistantNotes -TestRootOverride $root).Count | Should -Be 0
    }
}

Describe 'endpoint consent and /unut' {
    It 'remembers an endpoint once, ordinal, and round-trips through permissions.json' {
        $root = Join-Path $TestDrive 'ep'
        $perms = Read-WtAssistantPermissions -TestRootOverride $root
        $perms.ContainsKey('always') | Should -BeFalse
        (Test-WtAssistantEndpointAllowed -Endpoint 'https://api.x.com/v1' -Permissions $perms) | Should -BeFalse
        $perms = Add-WtAssistantEndpointAllowed -Endpoint 'https://api.x.com/v1' -Permissions $perms -Now (Get-Date '2026-09-01T12:00:00')
        $perms = Add-WtAssistantEndpointAllowed -Endpoint 'https://api.x.com/v1' -Permissions $perms
        @($perms.endpoints).Count | Should -Be 1
        Save-WtAssistantPermissions -Permissions $perms -TestRootOverride $root
        $back = Read-WtAssistantPermissions -TestRootOverride $root
        $back.ContainsKey('always') | Should -BeFalse
        (Test-WtAssistantEndpointAllowed -Endpoint 'https://api.x.com/v1' -Permissions $back) | Should -BeTrue
        (Test-WtAssistantEndpointAllowed -Endpoint 'https://API.x.com/v1' -Permissions $back) | Should -BeFalse
        [string]$back.endpoints[0].at | Should -Match '^2026-09-01T12'
    }

    It 'round-trips the /araclar off-list and reads an older file without one as empty' {
        $root = Join-Path $TestDrive 'dis'
        $perms = Read-WtAssistantPermissions -TestRootOverride $root
        @($perms.disabled).Count | Should -Be 0
        $perms.disabled = @('web_search', 'fetch_page')
        Save-WtAssistantPermissions -Permissions $perms -TestRootOverride $root
        $back = Read-WtAssistantPermissions -TestRootOverride $root
        @($back.disabled) | Should -Be @('web_search', 'fetch_page')
        Set-Content -LiteralPath (Get-WtAssistantMemoryPath -FileName 'permissions.json' -TestRootOverride $root) -Value '{"v":1,"always":[],"endpoints":[]}' -Encoding UTF8
        @((Read-WtAssistantPermissions -TestRootOverride $root).disabled).Count | Should -Be 0
        Save-WtAssistantPermissions -Permissions @{ v = 1; always = @(); endpoints = @() } -TestRootOverride $root
        @((Read-WtAssistantPermissions -TestRootOverride $root).disabled).Count | Should -Be 0
        Set-Content -LiteralPath (Get-WtAssistantMemoryPath -FileName 'permissions.json' -TestRootOverride $root) -Value '{"v":1,"always":[{"tool":"apply_wintoolify","id":"A|apply","at":"x"}],"endpoints":[],"disabled":["web_search"],"enabled":["apply_wintoolify"]}' -Encoding UTF8
        $old = Read-WtAssistantPermissions -TestRootOverride $root
        @($old.disabled) | Should -Be @('web_search')
        Save-WtAssistantPermissions -Permissions $old -TestRootOverride $root
        $raw = Get-Content -LiteralPath (Get-WtAssistantMemoryPath -FileName 'permissions.json' -TestRootOverride $root) -Raw
        $raw | Should -Not -Match '"always"'
        $raw | Should -Not -Match '"enabled"'
    }

    It 'Clear-WtAssistantMemory deletes the four files and reports how many existed' {
        $root = Join-Path $TestDrive 'wipe'
        Save-WtAssistantPermissions -Permissions @{ v = 1; always = @(); endpoints = @() } -TestRootOverride $root
        $null = Add-WtAssistantNote -Text 'n' -TestRootOverride $root
        Save-WtAssistantProfileCache -Cache @{ v = 1; BuiltAt = 'x'; BootTime = ''; NewestChangeId = ''; ShortJson = '{}'; FullJson = '{}' } -TestRootOverride $root
        (Clear-WtAssistantMemory -TestRootOverride $root) | Should -Be 3
        foreach ($f in @('profile.json', 'chat.json', 'permissions.json', 'facts.json')) { (Test-Path -LiteralPath (Get-WtAssistantMemoryPath -FileName $f -TestRootOverride $root)) | Should -BeFalse }
        (Clear-WtAssistantMemory -TestRootOverride $root) | Should -Be 0
    }
}
