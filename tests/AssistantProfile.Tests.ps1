#Requires -Modules Pester

<#
.SYNOPSIS
    The assistant's machine profile: the raw gatherer, the short/full
    projections and the masked-JSON cap. Every system source is
    injected - nothing here reads the real machine during tests.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtAssistantProfileData' {
    BeforeAll {
        $script:Boot = (Get-Date '2026-09-01T08:00:00')
        $script:Os = [PSCustomObject]@{ Caption = 'Microsoft Windows 10 IoT Enterprise LTSC'; BuildNumber = '19044'; OSArchitecture = '64-bit'; LastBootUpTime = $script:Boot; TotalVisibleMemorySize = 16690000; FreePhysicalMemory = 8300000 }
        $script:Seams = @{
            Os = $script:Os
            GetCs = { [PSCustomObject]@{ Model = 'B550M' } }
            GetCpuName = { '  AMD Ryzen 5 5600X 6-Core Processor  ' }
            GetCoreCount = { 12 }
            GetGpus = { @([PSCustomObject]@{ Name = 'NVIDIA GeForce RTX 3060'; DriverVersion = '32.0.15.6094' }) }
            GetVolumes = { @([PSCustomObject]@{ DeviceID = 'C:'; Size = 500GB; FreeSpace = 120GB; VolumeName = 'SECRETLABEL' }, [PSCustomObject]@{ DeviceID = 'D:'; Size = 1TB; FreeSpace = 900GB; VolumeName = 'DATA' }) }
            GetDisplayVersion = { '21H2' }
            IsAdmin = { $true }
            GetStartupNames = { @('OneDrive', 'C:\Users\ali\tool.exe', 'Steam') }
            GetInstalledCount = { 87 }
            GetTaskCount = { 11 }
            GetPendingReboot = { $true }
            GetDefender = { [PSCustomObject]@{ RealTimeProtectionEnabled = $true; AntivirusEnabled = $true } }
            GetChanges = { @(
                [PSCustomObject]@{ id = 'u9'; when = '2026-08-31T10:00:00.0000000+03:00'; action = 'Telemetry'; scope = 'Machine'; items = 3; restored = $false }
                [PSCustomObject]@{ id = 'u8'; when = '2026-08-30T10:00:00.0000000+03:00'; action = 'Services'; scope = 'Machine'; items = 1; restored = $true }
                [PSCustomObject]@{ id = 'u7'; when = '2026-08-29'; action = 'a'; scope = 'Machine'; items = 1; restored = $false }
                [PSCustomObject]@{ id = 'u6'; when = '2026-08-28'; action = 'b'; scope = 'Machine'; items = 1; restored = $false }
                [PSCustomObject]@{ id = 'u5'; when = '2026-08-27'; action = 'c'; scope = 'Machine'; items = 1; restored = $false }
                [PSCustomObject]@{ id = 'u4'; when = '2026-08-26'; action = 'd'; scope = 'Machine'; items = 1; restored = $false }
            ) }
            Now = (Get-Date '2026-09-01T20:30:00')
        }
    }

    It 'projects the short profile with exactly the spec fields, trimmed cpu, uptime from the boot time and the newest change' {
        $data = Get-WtAssistantProfileData @script:Seams
        $s = $data.Short
        @($s.PSObject.Properties.Name) | Should -Be @('windows', 'admin', 'hardware', 'volumes', 'pending_reboot', 'defender', 'counts', 'last_change')
        $s.windows.build | Should -Be '19044'
        $s.windows.display | Should -Be '21H2'
        $s.windows.arch | Should -Be '64-bit'
        $s.admin | Should -BeTrue
        $s.hardware.cpu | Should -Be 'AMD Ryzen 5 5600X 6-Core Processor'
        $s.hardware.ram_total_gb | Should -Be 15.9
        @($s.hardware.gpus) | Should -Be @('NVIDIA GeForce RTX 3060')
        @($s.hardware.PSObject.Properties.Name) | Should -Be @('cpu', 'ram_total_gb', 'gpus')
        @($s.volumes).Count | Should -Be 2
        @($s.volumes[0].PSObject.Properties.Name) | Should -Be @('drive', 'total_gb', 'free_gb')
        $s.pending_reboot | Should -BeTrue
        $s.defender.realtime | Should -BeTrue
        $s.counts.installed_programs | Should -Be 87
        $s.counts.startup_entries | Should -Be 3
        $s.counts.nonms_tasks | Should -Be 11
        $s.last_change.action | Should -Be 'Telemetry'
        $s.last_change.when | Should -Be '2026-08-31'
        $data.BootTime | Should -Be '2026-09-01T08:00:00'
    }

    It 'the full profile adds model, cores, ram_free, gpu drivers, startup names and at most five changes' {
        $f = (Get-WtAssistantProfileData @script:Seams).Full
        $f.hardware.model | Should -Be 'B550M'
        $f.hardware.cores | Should -Be 12
        $f.hardware.ram_free_gb | Should -Be 7.9
        $f.hardware.gpus[0].driver | Should -Be '32.0.15.6094'
        @($f.startup_names) | Should -Be @('OneDrive', 'C:\Users\ali\tool.exe', 'Steam')
        @($f.wintoolify_changes).Count | Should -Be 5
        $f.wintoolify_changes[1].restored | Should -BeTrue
        @($f.PSObject.Properties.Name) | Should -Not -Contain 'network'
    }

    It 'I5 minor: the local carrying -Os/-GetOs is $osData, not $os (consistency rename; -GetOs still resolves normally)' {
        $seams = @{} + $script:Seams
        $seams.Remove('Os'); $seams['GetOs'] = { [PSCustomObject]@{ Caption = 'Seam Windows'; BuildNumber = 'SEAM1'; OSArchitecture = 'x64'; LastBootUpTime = (Get-Date '2026-09-01T08:00:00'); TotalVisibleMemorySize = 1000; FreePhysicalMemory = 500 } }
        $data = Get-WtAssistantProfileData @seams
        $data.Short.windows.build | Should -Be 'SEAM1'
    }

    It 'a dead source costs its own field, never the profile' {
        $seams = @{} + $script:Seams
        $seams.Remove('Os'); $seams['GetOs'] = { throw 'no cim' }
        $seams['GetDefender'] = { throw 'no defender' }
        $seams['GetChanges'] = { throw 'no undo' }
        $seams['GetCpuName'] = { throw 'no registry' }
        $data = Get-WtAssistantProfileData @seams
        $data.Short.windows.build | Should -Be ''
        $data.Short.hardware.cpu | Should -Be ''
        $data.Short.defender | Should -Be 'unavailable'
        $data.Short.last_change | Should -BeNullOrEmpty
        @($data.Full.wintoolify_changes).Count | Should -Be 0
        $data.BootTime | Should -Be ''
    }
}

Describe 'ConvertTo-WtAssistantProfileJson' {
    BeforeAll {
        $script:Mask = @{ ComputerName = 'TESTPC'; UserName = 'ali'; Serial = 'SER123'; Macs = @('AA-BB-CC-DD-EE-FF') }
        $script:Data = Get-WtAssistantProfileData -Os ([PSCustomObject]@{ Caption = 'Windows 10 Pro'; BuildNumber = '19044'; OSArchitecture = '64-bit'; LastBootUpTime = (Get-Date '2026-09-01T08:00:00'); TotalVisibleMemorySize = 16690000; FreePhysicalMemory = 8300000 }) `
            -GetCs { [PSCustomObject]@{ Model = 'TESTPC-Board' } } -GetCpuName { 'Intel Core i7' } -GetCoreCount { 8 } `
            -GetGpus { @([PSCustomObject]@{ Name = 'GPU A'; DriverVersion = '1.2.3.4' }) } `
            -GetVolumes { @([PSCustomObject]@{ DeviceID = 'C:'; Size = 500GB; FreeSpace = 100GB; VolumeName = 'ali-disk' }) } `
            -GetDisplayVersion { '21H2' } -IsAdmin { $false } -GetStartupNames { @('C:\Users\ali\run.exe', 'SER123-agent', 'TESTPC-sync') } `
            -GetInstalledCount { 10 } -GetTaskCount { 2 } -GetPendingReboot { $false } -GetDefender { [PSCustomObject]@{ RealTimeProtectionEnabled = $true; AntivirusEnabled = $true } } `
            -GetChanges { @([PSCustomObject]@{ id = 'u1'; when = '2026-08-31T10:00:00'; action = 'Telemetry'; scope = 'Machine'; items = 3; restored = $false }) } -Now (Get-Date '2026-09-01T09:00:00')
    }

    It 'pins the caps: a normal short profile fits 800 and a full one 2500 characters, both valid json' {
        $short = ConvertTo-WtAssistantProfileJson -Profile $script:Data.Short -Mask $script:Mask -MaxChars 800
        $full = ConvertTo-WtAssistantProfileJson -Profile $script:Data.Full -Mask $script:Mask -MaxChars 2500
        $short.Length | Should -BeLessOrEqual 800
        $full.Length | Should -BeLessOrEqual 2500
        ($short | ConvertFrom-Json).windows.build | Should -Be '19044'
        ($full | ConvertFrom-Json).hardware.cores | Should -Be 8
        $short | Should -Not -Match "`n"
    }

    It 'leaks nothing: every mask value, its hex mac and the raw \Users\ path are absent from both profiles' {
        $full = ConvertTo-WtAssistantProfileJson -Profile $script:Data.Full -Mask $script:Mask -MaxChars 2500
        $short = ConvertTo-WtAssistantProfileJson -Profile $script:Data.Short -Mask $script:Mask -MaxChars 800
        foreach ($needle in @('TESTPC', 'SER123', 'AA-BB-CC-DD-EE-FF', 'AABBCCDDEEFF', '\Users\ali', 'ali-disk')) {
            $full.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be (-1) -Because $needle
            $short.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be (-1) -Because $needle
        }
        $full | Should -Match '<kullanici>'
        $full | Should -Match '<pc>'
    }

    It 'shrinks an oversized profile step by step until it fits, keeping windows and admin' {
        $big = $script:Data.Full | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json
        $big.hardware.gpus = @(1..40 | ForEach-Object { [PSCustomObject]@{ name = ('Very Long Graphics Adapter Name Number ' + $_); driver = '99.99.99.' + $_ } })
        $big.volumes = @(1..30 | ForEach-Object { [PSCustomObject]@{ drive = ([string][char](64 + $_)) + ':'; total_gb = 1000; free_gb = 500 } })
        $big.startup_names = @(1..60 | ForEach-Object { 'Startup entry with a long descriptive name ' + $_ })
        $json = ConvertTo-WtAssistantProfileJson -Profile $big -Mask $script:Mask -MaxChars 2500
        $json.Length | Should -BeLessOrEqual 2500
        $parsed = $json | ConvertFrom-Json
        $parsed.windows.build | Should -Be '19044'
        $parsed.PSObject.Properties.Name | Should -Contain 'admin'
        $tiny = ConvertTo-WtAssistantProfileJson -Profile $big -Mask $script:Mask -MaxChars 120
        $tiny.Length | Should -BeLessOrEqual 120
        ($tiny | ConvertFrom-Json).truncated | Should -BeTrue
    }
}

Describe 'profile cache freshness and orchestration' {
    BeforeAll {
        $script:Now = Get-Date '2026-09-01T12:00:00'
        $script:Cache = @{ v = 1; BuiltAt = (Get-Date '2026-09-01T09:00:00').ToString('o'); BootTime = '2026-09-01T08:00:00'; NewestChangeId = 'u9'; ShortJson = '{"uptime_hours":1}'; FullJson = '{"hardware":{"ram_free_gb":1},"uptime_hours":1}' }
    }

    It 'is fresh only while the boot epoch, the newest undo id and the six-hour age all hold' {
        Test-WtAssistantProfileCacheFresh -Cache $script:Cache -BootTime '2026-09-01T08:00:00' -NewestChangeId 'u9' -Now $script:Now | Should -BeTrue
        Test-WtAssistantProfileCacheFresh -Cache $script:Cache -BootTime '2026-09-01T11:00:00' -NewestChangeId 'u9' -Now $script:Now | Should -BeFalse
        Test-WtAssistantProfileCacheFresh -Cache $script:Cache -BootTime '2026-09-01T08:00:00' -NewestChangeId 'u10' -Now $script:Now | Should -BeFalse
        Test-WtAssistantProfileCacheFresh -Cache $script:Cache -BootTime '2026-09-01T08:00:00' -NewestChangeId 'u9' -Now (Get-Date '2026-09-01T15:00:01') | Should -BeFalse
        Test-WtAssistantProfileCacheFresh -Cache $null -BootTime 'x' -NewestChangeId '' -Now $script:Now | Should -BeFalse
        Test-WtAssistantProfileCacheFresh -Cache @{ v = 1; BuiltAt = 'garbage'; BootTime = ''; NewestChangeId = ''; ShortJson = '{}'; FullJson = '{}' } -BootTime '' -NewestChangeId '' -Now $script:Now | Should -BeFalse
        Test-WtAssistantProfileCacheFresh -Cache @{ v = 1; BuiltAt = $script:Cache.BuiltAt; BootTime = ''; NewestChangeId = ''; ShortJson = ''; FullJson = '{}' } -BootTime '' -NewestChangeId '' -Now $script:Now | Should -BeFalse
    }

    It 'builds cold once (OnCold fires, file written), serves warm afterwards, and rebuilds on Force, reboot or a new undo entry' {
        $root = Join-Path $TestDrive 'orch'
        $script:ColdCount = 0; $script:GatherCount = 0
        $os = [PSCustomObject]@{ LastBootUpTime = (Get-Date '2026-09-01T08:00:00'); FreePhysicalMemory = 4194304 }
        $gather = { param($Os) $script:GatherCount++; @{ Short = [PSCustomObject]@{ windows = [PSCustomObject]@{ build = '19044' }; uptime_hours = 0 }; Full = [PSCustomObject]@{ hardware = [PSCustomObject]@{ ram_free_gb = 0 }; uptime_hours = 0 }; BootTime = '2026-09-01T08:00:00' } }
        $common = @{ TestRootOverride = $root; GetOs = { $os }; Gather = $gather; GetMask = { @{ ComputerName = 'X'; UserName = 'Y'; Serial = ''; Macs = @() } }; OnCold = { $script:ColdCount++ } }
        $first = Get-WtAssistantMachineProfile @common -GetNewestChangeId { 'u9' } -Now $script:Now
        $first.Cold | Should -BeTrue
        $script:ColdCount | Should -Be 1
        ($first.Json | ConvertFrom-Json).windows.build | Should -Be '19044'
        (Read-WtAssistantProfileCache -TestRootOverride $root).NewestChangeId | Should -Be 'u9'
        $second = Get-WtAssistantMachineProfile @common -GetNewestChangeId { 'u9' } -Now (Get-Date '2026-09-01T13:00:00')
        $second.Cold | Should -BeFalse
        $script:GatherCount | Should -Be 1
        $second.Json | Should -Be $first.Json
        $full = Get-WtAssistantMachineProfile @common -Kind 'Full' -GetNewestChangeId { 'u9' } -Now (Get-Date '2026-09-01T13:00:00')
        ($full.Json | ConvertFrom-Json).hardware.ram_free_gb | Should -Be 0
        (Get-WtAssistantMachineProfile @common -GetNewestChangeId { 'u10' } -Now (Get-Date '2026-09-01T13:00:00')).Cold | Should -BeTrue
        (Get-WtAssistantMachineProfile @common -GetNewestChangeId { 'u10' } -Now (Get-Date '2026-09-01T13:00:00') -Force).Cold | Should -BeTrue
        $script:GatherCount | Should -Be 3
        $os.LastBootUpTime = (Get-Date '2026-09-01T12:30:00')
        (Get-WtAssistantMachineProfile @common -GetNewestChangeId { 'u10' } -Now (Get-Date '2026-09-01T13:00:00')).Cold | Should -BeTrue
    }

    It 'a gatherer that throws yields an empty json and no cache file, never an exception' {
        $root = Join-Path $TestDrive 'orch2'
        $r = Get-WtAssistantMachineProfile -TestRootOverride $root -GetOs { throw 'no' } -Gather { param($Os) throw 'boom' } -GetNewestChangeId { '' } -GetMask { @{ ComputerName = ''; UserName = ''; Serial = ''; Macs = @() } }
        $r.Json | Should -Be ''
        (Read-WtAssistantProfileCache -TestRootOverride $root) | Should -BeNullOrEmpty
    }
}
