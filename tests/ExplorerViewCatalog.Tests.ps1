#Requires -Modules Pester

<#
.SYNOPSIS
    Covers Get-WtExplorerViewCatalog (the seven File Explorer
    default-view tweaks, driven by the shared value-shaped helpers) and
    Invoke-WtRestartExplorer (stop, poll for the re-spawned shell, start
    manually only on timeout). Registry access runs against injected
    fakes; process control against scripted probes.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    $script:Catalog = Get-WtExplorerViewCatalog

    function New-RegistryFake {
        <#
        .SYNOPSIS
            A GetPropertyAction fake keyed by "path|name" -> value; a
            missing key reports absent.
        #>
        param([hashtable]$Values)
        return {
            param($p, $n)
            $key = "$p|$n"
            if ($Values.ContainsKey($key)) {
                $o = New-Object PSObject
                $o | Add-Member -NotePropertyName $n -NotePropertyValue $Values[$key]
                return $o
            }
            return $null
        }.GetNewClosure()
    }

    function New-ProcessProbe {
        <#
        .SYNOPSIS
            A process probe: each call returns the next entry's ids
            (comma-separated, '' = no explorer running), then repeats
            the last one; State.Calls counts how many times it ran.
        #>
        param([string[]]$Sequence)
        $state = @{ Calls = 0 }
        $probe = {
            $i = [Math]::Min($state.Calls, $Sequence.Count - 1)
            $state.Calls++
            return @($Sequence[$i] -split ',' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
        }.GetNewClosure()
        return [PSCustomObject]@{ Probe = $probe; State = $state }
    }
}

Describe 'Get-WtExplorerViewCatalog' {
    It 'has the seven entries in their fixed catalog order, every change DWord, every entry restarting Explorer with a DisplayLabel' {
        @($Catalog | ForEach-Object Name) | Should -Be @('ShowFileExtensions', 'ShowHiddenFiles', 'OpenExplorerToThisPC', 'UseCompactView', 'ShowProtectedOsFiles', 'ShowFullPathInTitleBar', 'HideRecentAndFrequent')
        foreach ($entry in $Catalog) {
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty
            $entry.RestartsExplorer | Should -BeTrue
            foreach ($change in $entry.RegistryChanges) { $change.RegType | Should -Be 'DWord' }
        }
    }

    It 'writes exactly the expected paths, names and values' {
        $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        $expected = @(
            @{ Name = 'ShowFileExtensions';     Changes = @(@{ Path = $adv; Name = 'HideFileExt'; Value = 0 }) }
            @{ Name = 'ShowHiddenFiles';        Changes = @(@{ Path = $adv; Name = 'Hidden'; Value = 1 }) }
            @{ Name = 'OpenExplorerToThisPC';   Changes = @(@{ Path = $adv; Name = 'LaunchTo'; Value = 1 }) }
            @{ Name = 'UseCompactView';         Changes = @(@{ Path = $adv; Name = 'UseCompactMode'; Value = 1 }) }
            @{ Name = 'ShowProtectedOsFiles';   Changes = @(@{ Path = $adv; Name = 'ShowSuperHidden'; Value = 1 }) }
            @{ Name = 'ShowFullPathInTitleBar'; Changes = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath'; Value = 1 }) }
            @{ Name = 'HideRecentAndFrequent';  Changes = @(
                    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowRecent'; Value = 0 },
                    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowFrequent'; Value = 0 }) }
        )
        foreach ($exp in $expected) {
            $entry = $Catalog | Where-Object Name -eq $exp.Name
            $entry | Should -Not -BeNullOrEmpty -Because "$($exp.Name) must exist"
            @($entry.RegistryChanges).Count | Should -Be $exp.Changes.Count -Because "$($exp.Name) change count"
            for ($i = 0; $i -lt $exp.Changes.Count; $i++) {
                $entry.RegistryChanges[$i].Path | Should -Be $exp.Changes[$i].Path
                $entry.RegistryChanges[$i].Name | Should -Be $exp.Changes[$i].Name
                $entry.RegistryChanges[$i].Value | Should -Be $exp.Changes[$i].Value
            }
        }
        @($Catalog | Where-Object { @($_.RegistryChanges).Count -gt 1 } | ForEach-Object Name) | Should -Be @('HideRecentAndFrequent')
    }

    It 'tags ShowProtectedOsFiles CAUTION with a consequence and everything else SAFE' {
        ($Catalog | Where-Object Name -eq 'ShowProtectedOsFiles').Risk | Should -Be 'CAUTION'
        ($Catalog | Where-Object Name -eq 'ShowProtectedOsFiles').Consequence | Should -Not -BeNullOrEmpty
        $Catalog | Where-Object Name -ne 'ShowProtectedOsFiles' | ForEach-Object { $_.Risk | Should -Be 'SAFE' }
    }

    It 'Get-WtRegistryEntryState reports HideRecentAndFrequent NotApplied when only ShowRecent matches, Applied when both do' {
        $entry = $Catalog | Where-Object Name -eq 'HideRecentAndFrequent'
        $partial = New-RegistryFake -Values @{ 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer|ShowRecent' = 0 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $partial).Applied | Should -BeFalse
        $full = New-RegistryFake -Values @{ 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer|ShowRecent' = 0; 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer|ShowFrequent' = 0 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $full).Applied | Should -BeTrue
    }
}

Describe 'Invoke-WtRestartExplorer' {
    It 'reports StartedManually=$false and never calls the start action when a new Explorer instance appears on the second poll' {
        $probe = New-ProcessProbe -Sequence '100', '', '200'
        $calls = @{ Stop = 0; Start = 0 }
        $stop = { $calls.Stop++ }.GetNewClosure()
        $start = { $calls.Start++ }.GetNewClosure()

        $result = Invoke-WtRestartExplorer -StopAction $stop -GetProcessAction $probe.Probe -StartAction $start -TimeoutSeconds 5

        $result.Restarted | Should -BeTrue
        $result.StartedManually | Should -BeFalse
        $calls.Stop | Should -Be 1
        $calls.Start | Should -Be 0
        $probe.State.Calls | Should -Be 3
    }

    It 'does not mistake the not-yet-exited old instance for the new one' {
        $probe = New-ProcessProbe -Sequence '100', '100', '', '300'
        $calls = @{ Start = 0 }
        $result = Invoke-WtRestartExplorer -StopAction { } -GetProcessAction $probe.Probe -StartAction { $calls.Start++ }.GetNewClosure() -TimeoutSeconds 5

        $result.StartedManually | Should -BeFalse
        $calls.Start | Should -Be 0
        $probe.State.Calls | Should -Be 4
    }

    It 'calls the start action exactly once and reports StartedManually=$true when no new instance appears before the timeout' {
        $probe = New-ProcessProbe -Sequence '100', ''
        $calls = @{ Start = 0 }
        $start = { $calls.Start++ }.GetNewClosure()

        $result = Invoke-WtRestartExplorer -StopAction { } -GetProcessAction $probe.Probe -StartAction $start -TimeoutSeconds 0.6

        $result.StartedManually | Should -BeTrue
        $calls.Start | Should -Be 1
        $probe.State.Calls | Should -BeGreaterThan 2
    }
}
