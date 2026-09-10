#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the Free Memory operation catalog, the native
    (Add-Type) memory-flush type, and Invoke-WtMemoryFlush. The C# is
    compiled here for real, proving it is valid and exposes its static
    members; its P/Invoke methods are never actually called. The flush
    itself runs entirely against injected fakes.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtMemoryFlushCatalog' {
    BeforeAll {
        $script:FlushCatalog = @(Get-WtMemoryFlushCatalog)
    }

    It 'has exactly the four PRD entries in order' {
        @($FlushCatalog | Select-Object -ExpandProperty Name) | Should -Be @('WorkingSets', 'StandbyList', 'ModifiedPageList', 'RegistryCache')
    }

    It 'maps the three memory-list entries to the WinMemoryCleaner commands with SeProfileSingleProcessPrivilege' {
        $expected = @{ WorkingSets = 2; StandbyList = 4; ModifiedPageList = 3 }
        foreach ($name in $expected.Keys) {
            $entry = $FlushCatalog | Where-Object Name -eq $name
            $entry.Operation | Should -Be 'MemoryList'
            $entry.Command | Should -Be $expected[$name]
            $entry.Privilege | Should -Be 'SeProfileSingleProcessPrivilege'
        }
    }

    It 'maps RegistryCache to a privilege-free registry reconciliation with no command' {
        $entry = $FlushCatalog | Where-Object Name -eq 'RegistryCache'
        $entry.Operation | Should -Be 'RegistryReconcile'
        $entry.Command | Should -BeNullOrEmpty
        $entry.Privilege | Should -BeNullOrEmpty
    }

    It 'tags only WorkingSets CAUTION with a consequence; the rest SAFE without one' {
        foreach ($entry in $FlushCatalog) {
            if ($entry.Name -eq 'WorkingSets') {
                $entry.Risk | Should -Be 'CAUTION'
                $entry.Consequence | Should -Not -BeNullOrEmpty
            }
            else {
                $entry.Risk | Should -Be 'SAFE'
                $entry.Consequence | Should -BeNullOrEmpty
            }
        }
    }

    It 'gives every entry a non-empty DisplayLabel' {
        foreach ($entry in $FlushCatalog) {
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'WinToolify.NativeMemory source' {
    It 'contains no C# 6+ syntax (Windows PowerShell 5.1 compiles with the C# 5 compiler)' {
        $script:WtNativeMemorySource | Should -Not -BeNullOrEmpty
        $script:WtNativeMemorySource | Should -Not -Match '\$"'
        $script:WtNativeMemorySource | Should -Not -Match '=>'
        $script:WtNativeMemorySource | Should -Not -Match 'nameof\('
        $script:WtNativeMemorySource | Should -Not -Match 'out var'
        $script:WtNativeMemorySource | Should -Not -Match '\?\.'
    }

    It 'compiles with Add-Type via Initialize-WtNativeMemory and exposes the three helpers' {
        { Initialize-WtNativeMemory } | Should -Not -Throw
        $type = ([System.Management.Automation.PSTypeName]'WinToolify.NativeMemory').Type
        $type | Should -Not -BeNullOrEmpty
        $staticNames = @($type.GetMethods() | Where-Object { $_.IsStatic } | Select-Object -ExpandProperty Name)
        $staticNames | Should -Contain 'EnablePrivilege'
        $staticNames | Should -Contain 'SetMemoryListCommand'
        $staticNames | Should -Contain 'ReconcileRegistry'
    }

    It 'is idempotent - a second Initialize-WtNativeMemory does not throw on the already-loaded type' {
        Initialize-WtNativeMemory
        { Initialize-WtNativeMemory } | Should -Not -Throw
    }
}

Describe 'Invoke-WtMemoryFlush' {
    It 'calls the flush action once per selected entry, in catalog order, with the catalog entry object' {
        $seen = New-Object System.Collections.Generic.List[object]
        $flush = { param($Entry) $seen.Add($Entry.Name) }
        $mem = { 1000 }

        Invoke-WtMemoryFlush -SelectedNames @('RegistryCache', 'WorkingSets') -FlushAction $flush -GetAvailableMemoryAction $mem | Out-Null

        $seen.ToArray() | Should -Be @('WorkingSets', 'RegistryCache')
    }

    It 'continues past a throwing entry and reports it Succeeded=false with the message, others Succeeded=true' {
        $flush = {
            param($Entry)
            if ($Entry.Name -eq 'StandbyList') { throw 'NTSTATUS 0xC0000061' }
        }
        $mem = { 1000 }

        $result = Invoke-WtMemoryFlush -SelectedNames @('WorkingSets', 'StandbyList', 'RegistryCache') -FlushAction $flush -GetAvailableMemoryAction $mem

        @($result.Results).Count | Should -Be 3
        ($result.Results | Where-Object Name -eq 'StandbyList').Succeeded | Should -BeFalse
        ($result.Results | Where-Object Name -eq 'StandbyList').Error | Should -Match '0xC0000061'
        ($result.Results | Where-Object Name -eq 'WorkingSets').Succeeded | Should -BeTrue
        ($result.Results | Where-Object Name -eq 'RegistryCache').Succeeded | Should -BeTrue
        ($result.Results | Where-Object Name -eq 'WorkingSets').Error | Should -BeNullOrEmpty
    }

    It 'reads available memory exactly twice (before and after) and reports FreedMB = After - Before' {
        $script:MemCalls = 0
        $mem = {
            $script:MemCalls++
            if ($script:MemCalls -eq 1) { 4096 } else { 5120 }
        }

        $result = Invoke-WtMemoryFlush -SelectedNames @('StandbyList') -FlushAction { param($Entry) } -GetAvailableMemoryAction $mem

        $script:MemCalls | Should -Be 2
        $result.BeforeMB | Should -Be 4096
        $result.AfterMB | Should -Be 5120
        $result.FreedMB | Should -Be 1024
    }

    It 'clamps FreedMB to 0 when available memory dropped during the run - never negative' {
        $script:MemCalls2 = 0
        $mem = {
            $script:MemCalls2++
            if ($script:MemCalls2 -eq 1) { 6000 } else { 5900 }
        }

        $result = Invoke-WtMemoryFlush -SelectedNames @('StandbyList') -FlushAction { param($Entry) } -GetAvailableMemoryAction $mem

        $result.FreedMB | Should -Be 0
    }

    It 'ignores selected names that are not in the catalog' {
        $seen = New-Object System.Collections.Generic.List[object]
        $result = Invoke-WtMemoryFlush -SelectedNames @('NotAnArea', 'RegistryCache') -FlushAction { param($Entry) $seen.Add($Entry.Name) } -GetAvailableMemoryAction { 1 }

        $seen.ToArray() | Should -Be @('RegistryCache')
        @($result.Results).Count | Should -Be 1
    }
}

Describe 'Format-WtMemoryFlushLines' {
    BeforeAll {
        $script:FlushCatalogForFormat = @(Get-WtMemoryFlushCatalog)
    }

    It 'formats a normal fixture without throwing, with the before/after/freed values and per-area status in the output' {
        $flushResult = [PSCustomObject]@{
            BeforeMB = 4096
            AfterMB  = 5120
            FreedMB  = 1024
            Results  = @(
                [PSCustomObject]@{ Name = 'WorkingSets'; Succeeded = $true; Error = $null }
                [PSCustomObject]@{ Name = 'StandbyList'; Succeeded = $false; Error = 'NTSTATUS 0xC0000061' }
            )
        }

        { Format-WtMemoryFlushLines -Result $flushResult -Catalog $FlushCatalogForFormat } | Should -Not -Throw

        $lines = Format-WtMemoryFlushLines -Result $flushResult -Catalog $FlushCatalogForFormat
        $lines | Should -Not -BeNullOrEmpty
        $joined = $lines -join "`n"
        $joined | Should -Match '4096 MB'
        $joined | Should -Match '5120 MB'
        $joined | Should -Match '1024 MB'
        $joined | Should -Match 'Working sets \(all processes\)'
        $joined | Should -Match 'NTSTATUS 0xC0000061'
    }
}
