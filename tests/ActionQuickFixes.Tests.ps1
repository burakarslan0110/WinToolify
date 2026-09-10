#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the Quick Fixes rows (Start menu repair, Explorer cache
    rebuild, audio service restart, close not-responding apps). Every
    Windows-touching call is behind an injectable scriptblock, so
    nothing here starts a service, deletes a cache, or kills a process.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Quick Fixes translation keys' {
    BeforeAll {
        $script:QuickFixKeys = @(
            'RepairStartMenu', 'StartMenuRepairStart', 'StartMenuNoPackages', 'StartMenuPackageOk',
            'StartMenuPackageFailed', 'StartMenuManifestMissing', 'StartMenuTempStateCleared',
            'StartMenuTempStateMissing', 'StartMenuHostsStopped', 'StartMenuHostsNotRunning',
            'StartMenuRepairSummary',
            'RebuildExplorerCaches', 'IconCacheStopping', 'IconCacheDeleted', 'IconCacheNoneLocked',
            'IconCacheStillLocked', 'IconCacheRefreshing', 'IconCacheRestartingShell',
            'RestartAudioServices', 'AudioRestartStart', 'AudioServiceMissing', 'AudioRestartDone',
            'AudioRestartIncomplete',
            'CloseNotRespondingApps', 'HungAppScanning', 'HungAppNone', 'HungAppRecovered',
            'HungAppNoTitle', 'HungAppConsequence', 'HungAppClosing', 'HungAppClosed', 'HungAppSummary'
        )
        $script:QuickFixLabelKeys = @('RepairStartMenu', 'RebuildExplorerCaches', 'RestartAudioServices', 'CloseNotRespondingApps')
    }

    It 'resolves every new key in both dictionaries' {
        foreach ($key in $QuickFixKeys) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }

    It 'keeps every new value ASCII, so the file parses under any codepage' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in $QuickFixKeys) {
                foreach ($ch in ([string]$script:Translations[$lang][$key]).ToCharArray()) {
                    [int]$ch | Should -BeLessOrEqual 127 -Because "$lang '$key' must be ASCII-folded"
                }
            }
        }
    }

    It 'keeps every row label inside the 45-character panel budget' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in $QuickFixLabelKeys) {
                ([string]$script:Translations[$lang][$key]).Length | Should -BeLessOrEqual 45 -Because "$lang '$key'"
            }
        }
    }

    It 'actually translates the four row labels instead of copying English into TR' {
        foreach ($key in $QuickFixLabelKeys) {
            $script:Translations['EN'][$key] | Should -Not -Be $script:Translations['TR'][$key] -Because "'$key' must be translated"
        }
    }
}

Describe 'Get-WtStartMenuPackageNames and Select-WtStartMenuPackages' {
    BeforeAll {
        $script:FakeAppx = @(
            [PSCustomObject]@{ Name = 'Microsoft.Windows.StartMenuExperienceHost'; PackageFullName = 'StartMenu_1.0_neutral_cw5n1h2txyewy'; InstallLocation = 'C:\Windows\SystemApps\StartMenu' }
            [PSCustomObject]@{ Name = 'Microsoft.Windows.StartMenuExperienceHost'; PackageFullName = 'StartMenu_1.0_neutral_cw5n1h2txyewy'; InstallLocation = 'C:\Windows\SystemApps\StartMenu' }
            [PSCustomObject]@{ Name = 'Microsoft.Windows.ShellExperienceHost'; PackageFullName = 'ShellExp_2.0_neutral_cw5n1h2txyewy'; InstallLocation = 'C:\Windows\SystemApps\ShellExp' }
            [PSCustomObject]@{ Name = 'Microsoft.WindowsCalculator'; PackageFullName = 'Calc_3.0_x64_8wekyb3d8bbwe'; InstallLocation = 'C:\Program Files\WindowsApps\Calc' }
        )
    }

    It 'names the Start menu packages and nothing else' {
        $names = @(Get-WtStartMenuPackageNames)
        $names | Should -Contain 'Microsoft.Windows.StartMenuExperienceHost'
        $names | Should -Contain 'Microsoft.Windows.ShellExperienceHost'
        $names | Should -Not -Contain 'Microsoft.WindowsCalculator'
    }

    It 'keeps only the Start menu packages, deduplicated by PackageFullName' {
        $picked = @(Select-WtStartMenuPackages -Packages $FakeAppx)
        @($picked | ForEach-Object { $_.PackageFullName }) | Should -Be @('StartMenu_1.0_neutral_cw5n1h2txyewy', 'ShellExp_2.0_neutral_cw5n1h2txyewy')
    }

    It 'builds the manifest path under the package install location' {
        $picked = @(Select-WtStartMenuPackages -Packages $FakeAppx)
        $picked[0].ManifestPath | Should -Be (Join-Path 'C:\Windows\SystemApps\StartMenu' 'AppxManifest.xml')
    }

    It 'keeps a package with no install location, with an empty manifest path, so the repair can report it FAILED' {
        $picked = @(Select-WtStartMenuPackages -Packages @([PSCustomObject]@{ Name = 'Microsoft.Windows.Search'; PackageFullName = 'Search_1_neutral'; InstallLocation = '' }))
        $picked.Count | Should -Be 1
        $picked[0].ManifestPath | Should -BeNullOrEmpty
    }

    It 'returns an empty list when the machine has none of them' {
        @(Select-WtStartMenuPackages -Packages @([PSCustomObject]@{ Name = 'Microsoft.WindowsCalculator'; PackageFullName = 'Calc_3.0'; InstallLocation = 'C:\Calc' })).Count | Should -Be 0
    }
}

Describe 'Invoke-WtStartMenuRepair' {
    BeforeEach {
        $script:Written = New-Object System.Collections.Generic.List[string]
        $script:Registered = New-Object System.Collections.Generic.List[string]
        $script:Order = New-Object System.Collections.Generic.List[string]
        $script:Recorder = { param($Line, $Color) $script:Written.Add([string]$Line) }
        $script:TwoPackages = @(
            [PSCustomObject]@{ Name = 'Microsoft.Windows.StartMenuExperienceHost'; PackageFullName = 'StartMenu_1.0'; InstallLocation = 'C:\SystemApps\StartMenu' }
            [PSCustomObject]@{ Name = 'Microsoft.Windows.ShellExperienceHost'; PackageFullName = 'ShellExp_2.0'; InstallLocation = 'C:\SystemApps\ShellExp' }
        )
    }

    It 'writes its first line before it touches a package, so the panel never looks frozen' {
        $null = Invoke-WtStartMenuRepair `
            -GetPackages { $script:TwoPackages } `
            -TestManifest { param($Path) $true } `
            -RegisterPackage { param($Path) $script:Registered.Add([string]$Path) } `
            -ClearTempState { $true } `
            -StopHosts { [string[]]@('StartMenuExperienceHost') } `
            -Write $script:Recorder
        $Written[0] | Should -Be (Get-Translation 'StartMenuRepairStart')
    }

    It 'registers every manifest and prints OK per package by name' {
        $result = Invoke-WtStartMenuRepair `
            -GetPackages { $script:TwoPackages } `
            -TestManifest { param($Path) $true } `
            -RegisterPackage { param($Path) $script:Registered.Add([string]$Path) } `
            -ClearTempState { $true } `
            -StopHosts { [string[]]@('StartMenuExperienceHost', 'ShellExperienceHost') } `
            -Write $script:Recorder
        $result.Registered | Should -Be 2
        $result.Failed | Should -Be 0
        @($Registered) | Should -Be @(
            (Join-Path 'C:\SystemApps\StartMenu' 'AppxManifest.xml')
            (Join-Path 'C:\SystemApps\ShellExp' 'AppxManifest.xml')
        )
        $ok = [string](Get-Translation 'StartMenuPackageOk')
        @($Written | Where-Object { $_.EndsWith(': ' + $ok, [System.StringComparison]::Ordinal) }).Count | Should -Be 2
    }

    It 'reports FAILED with the reason when a manifest is gone, and never registers it' {
        $result = Invoke-WtStartMenuRepair `
            -GetPackages { $script:TwoPackages } `
            -TestManifest { param($Path) $false } `
            -RegisterPackage { param($Path) $script:Registered.Add([string]$Path) } `
            -ClearTempState { $true } -StopHosts { [string[]]@() } -Write $script:Recorder
        $result.Registered | Should -Be 0
        $result.Failed | Should -Be 2
        @($Registered).Count | Should -Be 0
        ($Written -join "`n") | Should -BeLike ('*' + (Get-Translation 'StartMenuManifestMissing') + '*')
    }

    It 'reports FAILED with the deployment error instead of a silent success' {
        $result = Invoke-WtStartMenuRepair `
            -GetPackages { $script:TwoPackages } `
            -TestManifest { param($Path) $true } `
            -RegisterPackage { param($Path) throw 'Deployment failed with HRESULT 0x80073CF9' } `
            -ClearTempState { $true } -StopHosts { [string[]]@() } -Write $script:Recorder
        $result.Registered | Should -Be 0
        $result.Failed | Should -Be 2
        ($Written -join "`n") | Should -BeLike '*0x80073CF9*'
    }

    It 'says so when the machine has no Start menu package at all' {
        $result = Invoke-WtStartMenuRepair `
            -GetPackages { @() } -TestManifest { param($Path) $true } `
            -RegisterPackage { param($Path) $script:Registered.Add([string]$Path) } `
            -ClearTempState { $true } -StopHosts { [string[]]@() } -Write $script:Recorder
        $result.Registered | Should -Be 0
        @($Registered).Count | Should -Be 0
        $Written | Should -Contain (Get-Translation 'StartMenuNoPackages')
    }

    It 'stops the shell hosts BEFORE the packages (0x80073D02) and again after TempState, and says when there was nothing to clear' {
        $null = Invoke-WtStartMenuRepair `
            -GetPackages { $script:TwoPackages } -TestManifest { param($Path) $true } `
            -RegisterPackage { param($Path) $script:Order.Add('register') } `
            -ClearTempState { $script:Order.Add('tempstate'); $false } `
            -StopHosts { $script:Order.Add('stophosts'); [string[]]@() } `
            -Write $script:Recorder
        @($Order) | Should -Be @('stophosts', 'register', 'register', 'tempstate', 'stophosts')
        $Written | Should -Contain (Get-Translation 'StartMenuTempStateMissing')
        $Written | Should -Contain (Get-Translation 'StartMenuHostsNotRunning')
    }

    It 'stops the hosts again and retries a package once when registering it fails, and reports OK when the retry works' {
        $script:Attempts = 0
        $result = Invoke-WtStartMenuRepair `
            -GetPackages { @($script:TwoPackages[0]) } -TestManifest { param($Path) $true } `
            -RegisterPackage {
                param($Path)
                $script:Attempts++
                $script:Order.Add('register')
                if ($script:Attempts -eq 1) { throw 'Deployment failed with HRESULT: 0x80073D02' }
            } `
            -ClearTempState { $script:Order.Add('tempstate'); $true } `
            -StopHosts { $script:Order.Add('stophosts'); [string[]]@('StartMenuExperienceHost') } `
            -Write $script:Recorder
        @($Order) | Should -Be @('stophosts', 'register', 'stophosts', 'register', 'tempstate', 'stophosts')
        $result.Registered | Should -Be 1
        $result.Failed | Should -Be 0
        ($Written -join "`n") | Should -Not -BeLike '*0x80073D02*'
    }

    It 'reports the host it stopped exactly once, however many stops it took' {
        $result = Invoke-WtStartMenuRepair `
            -GetPackages { $script:TwoPackages } -TestManifest { param($Path) $true } `
            -RegisterPackage { param($Path) $script:Registered.Add([string]$Path) } `
            -ClearTempState { $true } `
            -StopHosts { [string[]]@('StartMenuExperienceHost', 'ShellExperienceHost') } `
            -Write $script:Recorder
        @($result.StoppedHosts) | Should -Be @('StartMenuExperienceHost', 'ShellExperienceHost')
    }
}

Describe 'Get-WtExplorerCacheTargets and Format-WtExplorerCacheLines' {
    It 'covers iconcache*.db and thumbcache*.db under Explorer plus the legacy IconCache.db' {
        $targets = @(Get-WtExplorerCacheTargets -LocalAppData 'C:\Users\test\AppData\Local')
        $explorer = Join-Path 'C:\Users\test\AppData\Local' 'Microsoft\Windows\Explorer'
        @($targets | ForEach-Object { $_.Filter }) | Should -Be @('iconcache*.db', 'thumbcache*.db', 'IconCache.db')
        $targets[0].Directory | Should -Be $explorer
        $targets[1].Directory | Should -Be $explorer
        $targets[2].Directory | Should -Be 'C:\Users\test\AppData\Local'
    }

    It 'reports the freed bytes and the all-clear line when nothing stayed locked' {
        $lines = @(Format-WtExplorerCacheLines -Result ([PSCustomObject]@{ DeletedCount = 3; FreedBytes = 2097152; Locked = [string[]]@() }))
        ($lines -join "`n") | Should -BeLike '*2.0 MB*'
        $lines | Should -Contain (Get-Translation 'IconCacheNoneLocked')
    }

    It 'names every file the shell would not release instead of pretending the job is done' {
        $lines = @(Format-WtExplorerCacheLines -Result ([PSCustomObject]@{ DeletedCount = 1; FreedBytes = 512; Locked = [string[]]@('C:\Users\test\AppData\Local\IconCache.db') }))
        $lines | Should -Contain (Get-Translation 'IconCacheStillLocked')
        ($lines -join "`n") | Should -BeLike '*IconCache.db*'
        $lines | Should -Not -Contain (Get-Translation 'IconCacheNoneLocked')
    }
}

Describe 'Remove-WtExplorerCacheFiles' {
    BeforeEach {
        $script:CacheTargets = @([PSCustomObject]@{ Directory = 'C:\cache'; Filter = 'iconcache*.db' })
        $script:CacheFiles = @(
            [PSCustomObject]@{ FullName = 'C:\cache\iconcache_16.db'; Length = 1024 }
            [PSCustomObject]@{ FullName = 'C:\cache\iconcache_32.db'; Length = 3072 }
        )
        $script:Attempts = New-Object System.Collections.Generic.List[string]
    }

    It 'deletes on the first pass and sums the bytes it actually freed' {
        $result = Remove-WtExplorerCacheFiles -Targets $script:CacheTargets `
            -GetFiles { param($Directory, $Filter) $script:CacheFiles } `
            -RemoveFile { param($Path) $script:Attempts.Add([string]$Path) } `
            -Wait { }
        $result.DeletedCount | Should -Be 2
        $result.FreedBytes | Should -Be 4096
        @($result.Locked).Count | Should -Be 0
        @($Attempts).Count | Should -Be 2
    }

    It 'retries a file the shell has not released yet and succeeds on a later pass' {
        $result = Remove-WtExplorerCacheFiles -Targets $script:CacheTargets `
            -GetFiles { param($Directory, $Filter) @($script:CacheFiles[0]) } `
            -RemoveFile { param($Path) $script:Attempts.Add([string]$Path); if ($script:Attempts.Count -lt 3) { throw 'The process cannot access the file' } } `
            -Wait { }
        $result.DeletedCount | Should -Be 1
        @($Attempts).Count | Should -Be 3
        @($result.Locked).Count | Should -Be 0
    }

    It 'gives up at the budget and names the file that is still locked' {
        $script:FakeClock = [datetime]'2026-01-01T00:00:00'
        $result = Remove-WtExplorerCacheFiles -Targets $script:CacheTargets -BudgetSeconds 10 `
            -GetFiles { param($Directory, $Filter) @($script:CacheFiles[0]) } `
            -RemoveFile { param($Path) $script:Attempts.Add([string]$Path); throw 'The process cannot access the file' } `
            -GetNow { $script:FakeClock = $script:FakeClock.AddSeconds(6); $script:FakeClock } `
            -Wait { }
        $result.DeletedCount | Should -Be 0
        $result.FreedBytes | Should -Be 0
        @($result.Locked) | Should -Be @('C:\cache\iconcache_16.db')
        @($Attempts).Count | Should -Be 2
    }
}

Describe 'Invoke-WtRebuildExplorerCaches' {
    BeforeEach {
        $script:Steps = New-Object System.Collections.Generic.List[string]
        $script:Written = New-Object System.Collections.Generic.List[string]
        $script:Recorder = { param($Line, $Color) $script:Written.Add([string]$Line) }
    }

    It 'stops the shell, deletes, refreshes the icons and restarts Explorer LAST' {
        $null = Invoke-WtRebuildExplorerCaches `
            -StopExplorer { $script:Steps.Add('stop') } `
            -RemoveCaches { $script:Steps.Add('remove'); [PSCustomObject]@{ DeletedCount = 2; FreedBytes = 2048; Locked = [string[]]@() } } `
            -RefreshIcons { $script:Steps.Add('ie4uinit') } `
            -RestartShell { $script:Steps.Add('restart'); [PSCustomObject]@{ Restarted = $true; StartedManually = $false } } `
            -Write $script:Recorder
        @($Steps) | Should -Be @('stop', 'remove', 'ie4uinit', 'restart')
    }

    It 'writes its first line before stopping the shell, and reports what was freed' {
        $result = Invoke-WtRebuildExplorerCaches `
            -StopExplorer { } `
            -RemoveCaches { [PSCustomObject]@{ DeletedCount = 2; FreedBytes = 2048; Locked = [string[]]@() } } `
            -RefreshIcons { } `
            -RestartShell { [PSCustomObject]@{ Restarted = $true; StartedManually = $false } } `
            -Write $script:Recorder
        $Written[0] | Should -Be (Get-Translation 'IconCacheStopping')
        $result.DeletedCount | Should -Be 2
        ($Written -join "`n") | Should -BeLike '*2.0 KB*'
        $Written | Should -Contain (Get-Translation 'RestartExplorerDone')
    }

    It 'says the shell did not come back instead of ending on a success line' {
        $null = Invoke-WtRebuildExplorerCaches `
            -StopExplorer { } `
            -RemoveCaches { [PSCustomObject]@{ DeletedCount = 0; FreedBytes = 0; Locked = [string[]]@('C:\cache\thumbcache_96.db') } } `
            -RefreshIcons { } `
            -RestartShell { [PSCustomObject]@{ Restarted = $false; StartedManually = $true } } `
            -Write $script:Recorder
        $Written | Should -Contain (Get-Translation 'RestartExplorerFailed')
        $Written | Should -Contain (Get-Translation 'IconCacheStillLocked')
    }
}

Describe 'Get-WtAudioServiceNames and Invoke-WtRestartAudioServices' {
    BeforeEach {
        $script:Calls = New-Object System.Collections.Generic.List[string]
        $script:Written = New-Object System.Collections.Generic.List[string]
        $script:Recorder = { param($Line, $Color) $script:Written.Add([string]$Line) }
    }

    It 'lists the two services in dependency order' {
        @(Get-WtAudioServiceNames) | Should -Be @('AudioEndpointBuilder', 'Audiosrv')
    }

    It 'stops Audiosrv first and starts AudioEndpointBuilder first' {
        $null = Invoke-WtRestartAudioServices `
            -StopService { param($Name) $script:Calls.Add('stop:' + $Name) } `
            -StartService { param($Name) $script:Calls.Add('start:' + $Name) } `
            -GetStatus { param($Name) 'Running' } `
            -Write $script:Recorder
        @($Calls) | Should -Be @('stop:Audiosrv', 'stop:AudioEndpointBuilder', 'start:AudioEndpointBuilder', 'start:Audiosrv')
    }

    It 'never calls Restart-Service - -Force on AudioEndpointBuilder stops Audiosrv and never starts it again' {
        $ast = (Get-Command Invoke-WtRestartAudioServices).ScriptBlock.Ast
        $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $commands | Should -Not -Contain 'Restart-Service'
        $commands | Should -Contain 'Stop-Service'
        $commands | Should -Contain 'Start-Service'
    }

    It 'prints the final status of both services and calls it done when both run' {
        $result = Invoke-WtRestartAudioServices -StopService { param($Name) } -StartService { param($Name) } `
            -GetStatus { param($Name) 'Running' } -Write $script:Recorder
        $result.AllRunning | Should -BeTrue
        @($result.Services | ForEach-Object { $_.Name }) | Should -Be @('AudioEndpointBuilder', 'Audiosrv')
        $Written | Should -Contain (Get-Translation 'AudioRestartDone')
    }

    It 'says a service is not installed rather than printing a blank status' {
        $result = Invoke-WtRestartAudioServices -StopService { param($Name) } -StartService { param($Name) } `
            -GetStatus { param($Name) if ($Name -ceq 'Audiosrv') { 'Running' } else { '' } } -Write $script:Recorder
        $result.AllRunning | Should -BeFalse
        ($Written -join "`n") | Should -BeLike ('*' + (Get-Translation 'AudioServiceMissing') + '*')
        $Written | Should -Contain (Get-Translation 'AudioRestartIncomplete')
    }

    It 'prints the error and reports the restart incomplete when a start fails' {
        $result = Invoke-WtRestartAudioServices -StopService { param($Name) } `
            -StartService { param($Name) throw 'Access is denied' } `
            -GetStatus { param($Name) 'Stopped' } -Write $script:Recorder
        $result.AllRunning | Should -BeFalse
        ($Written -join "`n") | Should -BeLike '*Access is denied*'
        $Written | Should -Contain (Get-Translation 'AudioRestartIncomplete')
    }
}

Describe 'Get-WtHungProcessSample, Select-WtStillHungProcesses and Format-WtHungProcessLines' {
    BeforeAll {
        $script:FakeProcesses = @(
            [PSCustomObject]@{ Id = 101; Name = 'notepad'; MainWindowHandle = 66048; Responding = $false; MainWindowTitle = 'Untitled - Notepad' }
            [PSCustomObject]@{ Id = 102; Name = 'svchost'; MainWindowHandle = 0; Responding = $false; MainWindowTitle = '' }
            [PSCustomObject]@{ Id = 103; Name = 'chrome'; MainWindowHandle = 131584; Responding = $true; MainWindowTitle = 'A tab' }
            [PSCustomObject]@{ Id = 104; Name = 'guarded'; MainWindowHandle = 197120; Responding = $false; MainWindowTitle = 'Guarded' }
        )
    }

    It 'keeps only windowed processes that are not answering' {
        $sample = @(Get-WtHungProcessSample -GetProcesses { $script:FakeProcesses })
        @($sample | ForEach-Object { $_.Id }) | Should -Be @(101, 104)
    }

    It 'skips a process whose Responding read throws instead of emptying the whole list' {
        $sample = @(Get-WtHungProcessSample -GetProcesses { $script:FakeProcesses } `
            -ReadResponding { param($Process) if ($Process.Id -eq 104) { throw 'Access is denied' }; [bool]$Process.Responding })
        @($sample | ForEach-Object { $_.Id }) | Should -Be @(101)
    }

    It 'keeps a process whose title read throws, with an empty title' {
        $sample = @(Get-WtHungProcessSample -GetProcesses { @($script:FakeProcesses[0]) } `
            -ReadTitle { param($Process) throw 'Access is denied' })
        $sample.Count | Should -Be 1
        $sample[0].Title | Should -Be ''
    }

    It 'keeps only what looked hung in BOTH samples, so an app that is merely busy is not killed' {
        $first = @(
            [PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled' }
            [PSCustomObject]@{ Id = 205; Name = 'word'; Title = 'Saving' }
        )
        $second = @(
            [PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled' }
            [PSCustomObject]@{ Id = 300; Name = 'excel'; Title = 'Book1' }
        )
        @(Select-WtStillHungProcesses -First $first -Second $second | ForEach-Object { $_.Id }) | Should -Be @(101)
    }

    It 'refuses a recycled process id whose name changed between the samples' {
        $first = @([PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled' })
        $second = @([PSCustomObject]@{ Id = 101; Name = 'calc'; Title = 'Calculator' })
        @(Select-WtStillHungProcesses -First $first -Second $second).Count | Should -Be 0
    }

    It 'lists id, name and title, and substitutes a phrase for a missing title' {
        $lines = @(Format-WtHungProcessLines -Processes @(
            [PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled - Notepad' }
            [PSCustomObject]@{ Id = 104; Name = 'guarded'; Title = '' }
        ))
        ($lines -join "`n") | Should -BeLike '*notepad*101*Untitled - Notepad*'
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'HungAppNoTitle') + '*')
    }

    It 'says so instead of returning an empty list when nothing is hung' {
        @(Format-WtHungProcessLines -Processes @()) | Should -Be @((Get-Translation 'HungAppNone'))
    }
}

Describe 'Invoke-WtCloseHungProcesses' {
    BeforeEach {
        $script:Written = New-Object System.Collections.Generic.List[string]
        $script:Killed = New-Object System.Collections.Generic.List[int]
        $script:Recorder = { param($Line, $Color) $script:Written.Add([string]$Line) }
    }

    It 'closes every confirmed process and counts them' {
        $result = Invoke-WtCloseHungProcesses -Processes @(
            [PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled' }
            [PSCustomObject]@{ Id = 205; Name = 'word'; Title = 'Doc' }
        ) -StopProcess { param($Id) $script:Killed.Add([int]$Id) } -Write $script:Recorder
        @($Killed) | Should -Be @(101, 205)
        $result.Closed | Should -Be 2
        $result.Failed | Should -Be 0
    }

    It 'prints the error for a process it could not close and still reports the rest' {
        $result = Invoke-WtCloseHungProcesses -Processes @(
            [PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled' }
            [PSCustomObject]@{ Id = 4; Name = 'System'; Title = '' }
        ) -StopProcess { param($Id) if ($Id -eq 4) { throw 'Access is denied' }; $script:Killed.Add([int]$Id) } -Write $script:Recorder
        $result.Closed | Should -Be 1
        $result.Failed | Should -Be 1
        ($Written -join "`n") | Should -BeLike '*Access is denied*'
    }

    It 'writes its first line before the first kill, so the panel repaints' {
        $null = Invoke-WtCloseHungProcesses -Processes @([PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'x' }) `
            -StopProcess { param($Id) $script:Written.Add('kill') } -Write $script:Recorder
        $Written[0] | Should -Be (Get-Translation 'HungAppClosing')
    }
}

Describe 'Invoke-WtCloseNotRespondingAppsAction' {
    BeforeEach {
        $script:Notified = New-Object System.Collections.Generic.List[string]
        $script:ClosedIds = New-Object System.Collections.Generic.List[int]
        $script:Sampled = 0
        $script:Waited = 0
        $script:Notifier = { param($Lines) foreach ($line in @($Lines)) { $script:Notified.Add([string]$line) } }
    }

    It 'samples twice, waiting between them, before it closes anything' {
        $null = Invoke-WtCloseNotRespondingAppsAction `
            -Sample { $script:Sampled++; @([PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'x' }) } `
            -Announce { } -Wait { $script:Waited++ } `
            -ConfirmGate { param($Lines) $true } `
            -Notify $script:Notifier `
            -Close { param($Processes) foreach ($p in @($Processes)) { $script:ClosedIds.Add([int]$p.Id) } }
        $Sampled | Should -Be 2
        $Waited | Should -Be 1
        @($ClosedIds) | Should -Be @(101)
    }

    It 'never opens the gate when the first sample is clean' {
        $null = Invoke-WtCloseNotRespondingAppsAction `
            -Sample { $script:Sampled++; @() } -Announce { } -Wait { $script:Waited++ } `
            -ConfirmGate { param($Lines) throw 'the gate must not be reached' } `
            -Notify $script:Notifier `
            -Close { param($Processes) throw 'nothing may be closed' }
        $Sampled | Should -Be 1
        $Waited | Should -Be 0
        $Notified | Should -Contain (Get-Translation 'HungAppNone')
    }

    It 'closes nothing when the app answered on the second sample' {
        $null = Invoke-WtCloseNotRespondingAppsAction `
            -Sample { $script:Sampled++; if ($script:Sampled -eq 1) { @([PSCustomObject]@{ Id = 101; Name = 'word'; Title = 'Saving' }) } else { @() } } `
            -Announce { } -Wait { } `
            -ConfirmGate { param($Lines) throw 'the gate must not be reached' } `
            -Notify $script:Notifier `
            -Close { param($Processes) throw 'nothing may be closed' }
        $Notified | Should -Contain (Get-Translation 'HungAppRecovered')
    }

    It 'closes nothing when the gate is refused' {
        $null = Invoke-WtCloseNotRespondingAppsAction `
            -Sample { @([PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'x' }) } `
            -Announce { } -Wait { } -ConfirmGate { param($Lines) $false } `
            -Notify $script:Notifier `
            -Close { param($Processes) throw 'nothing may be closed' }
        $Notified | Should -Contain (Get-Translation 'ActionCancelled')
    }

    It 'shows the id, name and title of every process in the gate lines' {
        $script:GateLines = @()
        $null = Invoke-WtCloseNotRespondingAppsAction `
            -Sample { @([PSCustomObject]@{ Id = 101; Name = 'notepad'; Title = 'Untitled - Notepad' }) } `
            -Announce { } -Wait { } `
            -ConfirmGate { param($Lines) $script:GateLines = @($Lines); $false } `
            -Notify { param($Lines) } -Close { param($Processes) }
        ($script:GateLines -join "`n") | Should -BeLike '*notepad*101*Untitled - Notepad*'
    }
}

Describe 'Quick Fixes rows on the Action Tools screen' {
    BeforeAll {
        $script:QuickFixGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupQuickFixes' } | Select-Object -First 1
        $script:QuickFixRows = @(& $script:QuickFixGroup.GetRows)
    }

    It 'lists the eight quick-fix rows in catalogue order' {
        @($QuickFixRows | ForEach-Object { $_.Name }) | Should -Be @(
            'RestartExplorerAction'
            'RepairStartMenu'
            'RebuildExplorerCaches'
            'RestartAudioServices'
            'RestartPrinter'
            'ClearPrintQueue'
            'CloseNotRespondingApps'
            'FreeMemory'
        )
    }

    It 'builds the three shell/audio repairs as captured actions and the app killer as an inline one' {
        foreach ($name in @('RepairStartMenu', 'RebuildExplorerCaches', 'RestartAudioServices')) {
            $row = $QuickFixRows | Where-Object { $_.Name -eq $name }
            $row.Kind | Should -Be 'Action' -Because "$name is a row"
            $row.Data.Captured | Should -BeTrue -Because "$name streams its output into the panel"
        }
        $inline = $QuickFixRows | Where-Object { $_.Name -eq 'CloseNotRespondingApps' }
        $inline.Data.Captured | Should -Not -BeTrue -Because 'it must ask for confirmation before any capture starts'
        $inline.Data.Action | Should -Not -BeNullOrEmpty
    }

    It 'badges the three rows that change something CAUTION and the audio restart SAFE' {
        ($QuickFixRows | Where-Object { $_.Name -eq 'RepairStartMenu' }).Risk | Should -Be 'CAUTION'
        ($QuickFixRows | Where-Object { $_.Name -eq 'RebuildExplorerCaches' }).Risk | Should -Be 'CAUTION'
        ($QuickFixRows | Where-Object { $_.Name -eq 'CloseNotRespondingApps' }).Risk | Should -Be 'CAUTION'
        ($QuickFixRows | Where-Object { $_.Name -eq 'RestartAudioServices' }).Risk | Should -Be 'SAFE'
    }

    It 'keeps Read-Host and every panel prompt out of the captured helpers - they would deadlock behind the capture' {
        foreach ($name in @('Invoke-WtStartMenuRepair', 'Invoke-WtRebuildExplorerCaches', 'Invoke-WtRestartAudioServices', 'Invoke-WtCloseHungProcesses')) {
            $ast = (Get-Command $name).ScriptBlock.Ast
            $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
            $commands | Should -Not -Contain 'Read-Host' -Because "$name runs inside Invoke-WtCapturedAction"
            $commands | Should -Not -Contain 'Read-WtPanelAnswer' -Because "$name runs inside Invoke-WtCapturedAction"
            $commands | Should -Not -Contain 'Confirm-WtDestructiveAction' -Because "$name runs inside Invoke-WtCapturedAction"
        }
    }
}
