#Requires -Modules Pester

<#
.SYNOPSIS
    The anonymizer and the structured context gatherers behind the agent
    tools. Every system source is injected - nothing here reads the real
    machine during tests.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Mask = @{ ComputerName = 'BURAK-PC'; UserName = 'Burak'; Serial = 'SER1234X'; Macs = @('AA-BB-CC-DD-EE-FF') }
}

Describe 'Protect-WtAssistantText' {
    It 'masks the computer name, user name, profile path, serial and mac - case-insensitively' {
        $text = 'Host BURAK-PC user burak path C:\Users\Burak\Desktop serial SER1234X mac AA-BB-CC-DD-EE-FF'
        $masked = Protect-WtAssistantText -Text $text -Mask $Mask
        $masked | Should -Not -Match 'BURAK-PC'
        $masked | Should -Not -Match 'SER1234X'
        $masked | Should -Match '<pc>'
        $masked | Should -Match '<kullanici>'
        $masked | Should -Match ([regex]::Escape('C:\Users\<kullanici>\Desktop'))
        $masked | Should -Match '<seri>'
        $masked | Should -Match '<mac-1>'
    }

    It 'masks public IPv4 but keeps private, loopback and link-local ranges' {
        $text = 'private 192.168.1.20 and 10.0.0.5 and 172.16.9.1 loopback 127.0.0.1 apipa 169.254.1.1 public 93.184.216.34'
        $masked = Protect-WtAssistantText -Text $text -Mask $Mask
        $masked | Should -Match '192\.168\.1\.20'
        $masked | Should -Match '10\.0\.0\.5'
        $masked | Should -Match '172\.16\.9\.1'
        $masked | Should -Match '127\.0\.0\.1'
        $masked | Should -Match '169\.254\.1\.1'
        $masked | Should -Not -Match '93\.184\.216\.34'
        $masked | Should -Match '<ip>'
    }

    It 'never shreds text over a too-short user name' {
        $shortMask = @{ ComputerName = 'PC'; UserName = 'al'; Serial = ''; Macs = @() }
        Protect-WtAssistantText -Text 'normal metal quality' -Mask $shortMask | Should -Be 'normal metal quality'
    }

    It 'leaves ordinary words whole for a three-letter user name, and still masks the name standing alone' {
        $aliMask = @{ ComputerName = 'BURAK-PC'; UserName = 'Ali'; Serial = ''; Macs = @() }
        $masked = Protect-WtAssistantText -Text 'Quality install; Alias record; ALIGNMENT_FAULT' -Mask $aliMask
        $masked | Should -Be 'Quality install; Alias record; ALIGNMENT_FAULT'
        Protect-WtAssistantText -Text 'user Ali logged on' -Mask $aliMask | Should -Be 'user <kullanici> logged on'
        Protect-WtAssistantText -Text 'user burak logged on' -Mask $Mask | Should -Be 'user <kullanici> logged on'
    }

    It 'masks the profile path with no length floor at all, in both the raw and the JSON-escaped spelling' {
        $shortMask = @{ ComputerName = 'BURAK-PC'; UserName = 'Al'; Serial = ''; Macs = @() }
        Protect-WtAssistantText -Text 'C:\Users\Al\Documents\vergi.xlsx' -Mask $shortMask |
            Should -Be 'C:\Users\<kullanici>\Documents\vergi.xlsx'
        $json = ConvertTo-Json -InputObject ([PSCustomObject]@{ path = 'C:\Users\Al\Documents\vergi.xlsx' }) -Depth 4 -Compress
        $masked = Protect-WtAssistantText -Text $json -Mask $shortMask
        $masked | Should -Not -Match ([regex]::Escape('Users\\Al\\'))
        $masked | Should -Match ([regex]::Escape('Users\\<kullanici>\\'))
    }

    It 'does not eat another user out of the profile path when one name prefixes the other' {
        $shortMask = @{ ComputerName = 'BURAK-PC'; UserName = 'Al'; Serial = ''; Macs = @() }
        Protect-WtAssistantText -Text 'C:\Users\Alice\Documents\x.txt' -Mask $shortMask |
            Should -Be 'C:\Users\Alice\Documents\x.txt'
    }

    It 'boundary-gates the computer name and the serial too' {
        $edge = @{ ComputerName = 'PC'; UserName = ''; Serial = 'AB12'; Macs = @() }
        Protect-WtAssistantText -Text 'PCIe link down for AB1234 controller' -Mask $edge |
            Should -Be 'PCIe link down for AB1234 controller'
        Protect-WtAssistantText -Text 'host PC serial AB12' -Mask $edge | Should -Be 'host <pc> serial <seri>'
    }

    It 'builds the mask context from injected sources, collecting the console user and the profile folder names' {
        $mask = Get-WtAssistantMaskContext -ComputerName 'X' -UserName 'Y' -GetSerial { 'S' } -GetMacs { @('M1', 'M2') } -GetConsoleUser { 'Ayse' } -GetProfileNames { @('Y', 'ayse', 'Ali', 'Public', 'Default', 'Default User', 'All Users', 'defaultuser0', 'WDAGUtilityAccount', '') }
        $mask.Serial | Should -Be 'S'
        @($mask.Macs).Count | Should -Be 2
        $mask.ConsoleUserName | Should -Be 'Ayse'
        @($mask.UserNames) | Should -Be @('Y', 'Ayse', 'Ali')
        $bare = Get-WtAssistantMaskContext -ComputerName 'X' -UserName 'Y' -GetSerial { '' } -GetMacs { @() } -GetConsoleUser { throw 'no cim' } -GetProfileNames { throw 'no disk' }
        @($bare.UserNames) | Should -Be @('Y')
        $bare.ConsoleUserName | Should -Be ''
    }

    It 'masks a MAC even when the source text spells it differently than the mask - colon in Mask, dash in text' {
        $colonMask = @{ ComputerName = 'BURAK-PC'; UserName = 'Burak'; Serial = ''; Macs = @('AA:BB:CC:DD:EE:FF') }
        $masked = Protect-WtAssistantText -Text 'adapter mac AA-BB-CC-DD-EE-FF' -Mask $colonMask
        $masked | Should -Not -Match 'AA-BB-CC-DD-EE-FF'
        $masked | Should -Match '<mac-1>'
    }

    It 'masks a MAC even when the source text spells it differently than the mask - dash in Mask, colon in text' {
        $masked = Protect-WtAssistantText -Text 'adapter mac AA:BB:CC:DD:EE:FF' -Mask $Mask
        $masked | Should -Not -Match 'AA:BB:CC:DD:EE:FF'
        $masked | Should -Match '<mac-1>'
    }

    It 'masks a MAC written with no separator at all' {
        $masked = Protect-WtAssistantText -Text 'adapter mac AABBCCDDEEFF' -Mask $Mask
        $masked | Should -Not -Match 'AABBCCDDEEFF'
        $masked | Should -Match '<mac-1>'
    }

    It 'without -SkipIpMask, a driver version number that looks like a dotted quad is still masked - unchanged default behaviour' {
        $masked = Protect-WtAssistantText -Text 'Update driver 4.8.0.0 to 6.0.9200.16384; gateway 93.184.216.34' -Mask $Mask
        $masked | Should -Be 'Update driver <ip> to 6.0.9200.16384; gateway <ip>'
    }

    It '-SkipIpMask leaves every IPv4-shaped substring alone but still masks identity' {
        $text = 'Update driver 4.8.0.0 to 6.0.9200.16384; gateway 93.184.216.34; host BURAK-PC user burak'
        $masked = Protect-WtAssistantText -Text $text -Mask $Mask -SkipIpMask
        $masked | Should -Be 'Update driver 4.8.0.0 to 6.0.9200.16384; gateway 93.184.216.34; host <pc> user <kullanici>'
    }

    It 'masks a MAC that was never collected as <mac>, while a collected one keeps its number' {
        $masked = Protect-WtAssistantText -Text 'ours AA-BB-CC-DD-EE-FF theirs 00:11:22:33:44:55 and 0a-1b-2c-3d-4e-5f' -Mask $Mask -SkipIpMask
        $masked | Should -Be 'ours <mac-1> theirs <mac> and <mac>'
        (Protect-WtAssistantText -Text 'id 00:11:22:33:44:55:66 and <mac-1>' -Mask $Mask -SkipIpMask) | Should -Be 'id 00:11:22:33:44:55:66 and <mac-1>'
    }

    It 'keeps the well-known public resolvers and ping targets readable, and still masks any other public IPv4' {
        $keep = @(Get-WtAssistantPublicResolverList)
        foreach ($ip in '1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220', '94.140.14.14', '94.140.15.15') { $keep | Should -Contain $ip }
        (Protect-WtAssistantText -Text 'DNS: 1.1.1.1, 8.8.8.8 gw 192.168.1.1 pub 85.100.20.3 ver 4.8.0.0' -Mask $Mask) | Should -Be 'DNS: 1.1.1.1, 8.8.8.8 gw 192.168.1.1 pub <ip> ver <ip>'
        (Protect-WtAssistantText -Text '  8.8.8.8: 23.45.67.89' -Mask $Mask) | Should -Be '  8.8.8.8: <ip>'
    }

    It 'masks the console user and every profile folder name inside a path, but only real account names as bare words' {
        $customMask = Get-WtAssistantMaskContext -ComputerName 'X' -UserName 'admin2' -GetSerial { '' } -GetMacs { @() } -GetConsoleUser { 'Ayse' } -GetProfileNames { @('admin2', 'Ayse', 'Ali', 'Public') }
        $text = 'C:\Users\Ali\x C:\Users\Ayse\y C:\Users\Public\z user Ayse and admin2; Alias record; Quality'
        (Protect-WtAssistantText -Text $text -Mask $customMask) | Should -Be 'C:\Users\<kullanici>\x C:\Users\<kullanici>\y C:\Users\Public\z user <kullanici> and <kullanici>; Alias record; Quality'
        (Protect-WtAssistantText -Text 'C:\Users\Burak\d and C:\Users\Other\e' -Mask $Mask) | Should -Be 'C:\Users\<kullanici>\d and C:\Users\Other\e'
    }

    It 'masks the forward-slash spelling of the profile path too' {
        $mask = Get-WtAssistantMaskContext -ComputerName 'X' -UserName 'admin2' -GetSerial { '' } -GetMacs { @() } -GetConsoleUser { '' } -GetProfileNames { @('Ayse') }
        (Protect-WtAssistantText -Text 'C:/Users/Ayse/x and C:\Users\Ayse\y' -Mask $mask) | Should -Be 'C:/Users/<kullanici>/x and C:\Users\<kullanici>\y'
    }
}

Describe 'ConvertTo-WtAssistantBool' {
    It 'reads a stringified boolean the way the model meant it, not the way [bool] does' {
        foreach ($no in 'false', 'False', 'FALSE', '0', 'no', 'off', 'hayir', '', '   ') {
            ConvertTo-WtAssistantBool -Value $no | Should -BeFalse -Because "'$no'"
        }
        ConvertTo-WtAssistantBool -Value $null | Should -BeFalse
        foreach ($yes in 'true', 'TRUE', '1', 'yes', 'evet') {
            ConvertTo-WtAssistantBool -Value $yes | Should -BeTrue -Because "'$yes'"
        }
        ConvertTo-WtAssistantBool -Value $true | Should -BeTrue
        ConvertTo-WtAssistantBool -Value 0 | Should -BeFalse
        ConvertTo-WtAssistantBool -Value 3 | Should -BeTrue
    }

    It 'falls back to the caller Default for anything it does not recognize' {
        ConvertTo-WtAssistantBool -Value 'belki' | Should -BeFalse
        ConvertTo-WtAssistantBool -Value 'belki' -Default $true | Should -BeTrue
        ConvertTo-WtAssistantBool -Value $null -Default $true | Should -BeTrue
    }
}

Describe 'Get-WtAssistantSystemOverview' {
    It 'assembles the overview from injected sources and survives a dead source' {
        $overview = Get-WtAssistantSystemOverview `
            -GetOs { [PSCustomObject]@{ Caption = 'Microsoft Windows 10 IoT Enterprise LTSC'; BuildNumber = '19044'; OSArchitecture = '64-bit'; TotalVisibleMemorySize = 16GB / 1KB; FreePhysicalMemory = 4GB / 1KB; LastBootUpTime = (Get-Date).AddHours(-30) } } `
            -GetCs { [PSCustomObject]@{ Model = 'ThinkPad T14' } } `
            -GetCpu { [PSCustomObject]@{ Name = 'Ryzen 7'; NumberOfCores = 8; NumberOfLogicalProcessors = 16 } } `
            -GetGpus { @([PSCustomObject]@{ Name = 'NVIDIA GTX'; DriverVersion = '551.23' }) } `
            -GetVolumes { @([PSCustomObject]@{ DeviceID = 'C:'; Size = 500GB; FreeSpace = 40GB }) } `
            -GetDisplayVersion { '21H2' } `
            -GetPowerPlan { 'GUID  (Yuksek performans)' } `
            -GetPendingReboot { throw 'dead source' } `
            -GetTopProcesses { @('chrome  2 GB') }
        $overview.windows.build | Should -Be '19044'
        $overview.windows.display_version | Should -Be '21H2'
        $overview.hardware.cpu | Should -Be 'Ryzen 7'
        $overview.volumes[0].drive | Should -Be 'C:'
        [int]$overview.uptime_hours | Should -BeGreaterThan 28
        $overview.pending_reboot | Should -Be @()   # the dead source became empty, not a crash
    }
}

Describe 'Get-WtAssistantRecentErrors' {
    It 'shapes injected events and clamps the hours' {
        $events = @([PSCustomObject]@{
            TimeCreated = [datetime]'2026-08-30 10:00'; LogName = 'System'; LevelDisplayName = 'Error'
            Id = 7000; ProviderName = 'Service Control Manager'; Message = ("ilk satir onemli`nikinci satir uzun")
        })
        $r = Get-WtAssistantRecentErrors -Hours 9999 -GetEvents { param($LogName, $Start) $events }
        $r.hours | Should -Be 168
        $r.events[0].source | Should -Be 'Service Control Manager'
        $r.events[0].message | Should -Be 'ilk satir onemli'
        @($r.events).Count | Should -Be 2   # one injected set per log, both logs queried
    }

    It 'serializes cleanly through the text pipeline even when a busy machine produces many events - cut at a line boundary, never mid-row' {
        $busy = { param($LogName, $Start)
            1..40 | ForEach-Object {
                [PSCustomObject]@{
                    TimeCreated = (Get-Date); LevelDisplayName = 'Error'; Id = 12293
                    ProviderName = 'Microsoft-Windows-DistributedCOM'
                    Message = ('Volume Shadow Copy Service error: Unexpected error querying for the IVssWriterCallback interface. hr = 0x80070005, Access is denied. This is often caused by incorrect security settings. Operation: Gathering Writer Data')
                }
            }
        }
        $result = Get-WtAssistantRecentErrors -Hours 48 -GetEvents $busy
        @($result.events).Count | Should -Be 40
        $result.events[0].message.Length | Should -BeLessOrEqual 140
        $text = ConvertTo-WtAssistantToolText -Value $result
        $text.Length | Should -BeLessOrEqual 2500
        $lines = @($text -split "`n")
        $lines[-1] | Should -Match '^omitted: \d+ lines$'
        $text | Should -Not -Match '[{}]'
    }
}

Describe 'Get-WtAssistantWintoolifyChanges' {
    It 'projects the REAL undo entry shape: Write-WtUndoEntry writes Id/Timestamp/Action/Scope/Items' {
        $entries = @(
            [PSCustomObject]@{ Id = '20260817-233917-Disable Services'; Timestamp = '2026-08-17T23:39:17.0000000+03:00'; Action = 'Disable Services'; Scope = 'Machine'; Items = @(1, 2, 3) }
            [PSCustomObject]@{ Id = '20260818-215231-Apply AI Privacy Settings'; Timestamp = '2026-08-18T21:52:31.0000000+03:00'; Action = 'Apply AI Privacy Settings'; Scope = 'User'; Items = @(1); RestoredAt = '2026-08-19T10:00:00' }
        )
        $r = Get-WtAssistantWintoolifyChanges -GetEntries { $entries }
        @($r.changes).Count | Should -Be 2
        $r.changes[0].action | Should -Be 'Disable Services'
        $r.changes[0].scope | Should -Be 'Machine'
        $r.changes[0].items | Should -Be 3
        $r.changes[0].restored | Should -BeFalse
        $r.changes[0].id | Should -Not -BeNullOrEmpty
        $r.changes[1].action | Should -Be 'Apply AI Privacy Settings'
        $r.changes[1].restored | Should -BeTrue
    }

    It 'projects undo entries defensively - unknown shapes do not crash it' {
        $entries = @(
            [PSCustomObject]@{ Timestamp = '2026-08-30T10:00:00'; Section = 'Services'; Items = @(1, 2); RestoredAt = $null }
            [PSCustomObject]@{ Timestamp = '2026-08-29T09:00:00' }
        )
        $r = Get-WtAssistantWintoolifyChanges -GetEntries { $entries }
        @($r.changes).Count | Should -Be 2
        $r.changes[0].action | Should -Be 'Services'
        $r.changes[0].items | Should -Be 2
        $r.changes[0].restored | Should -BeFalse
        $r.changes[1].action | Should -Be ''
    }
}

Describe 'lines-based gatherers' {
    It 'storage health carries the three line blocks and survives dead seams' {
        $r = Get-WtAssistantStorageHealth -GetVolumes { @('C: 40 GB bos') } -GetDiskHealth { throw 'no Get-PhysicalDisk' } -GetDiskErrors { @('yok') }
        @($r.volumes_lines) | Should -Be @('C: 40 GB bos')
        @($r.disk_health).Count | Should -Be 0
        @($r.disk_errors) | Should -Be @('yok')
    }

    It 'network status runs the tests only when asked' {
        $script:TestRuns = 0
        $seams = @{
            GetAdapters = { @('Ethernet baglandi') }
            GetIpSummary = { @('IPv4 192.168.1.20') }
            GetTests = { $script:TestRuns++; @('internet: ok', 'dns: ok') }
        }
        $quiet = Get-WtAssistantNetworkStatus -GetAdapters $seams.GetAdapters -GetIpSummary $seams.GetIpSummary -GetTests $seams.GetTests
        @($quiet.tests).Count | Should -Be 0
        $script:TestRuns | Should -Be 0
        $loud = Get-WtAssistantNetworkStatus -RunTests $true -GetAdapters $seams.GetAdapters -GetIpSummary $seams.GetIpSummary -GetTests $seams.GetTests
        @($loud.tests).Count | Should -Be 2
        $script:TestRuns | Should -Be 1
    }

    It 'startup software filters installed programs by the query, ordinal-insensitively' {
        $r = Get-WtAssistantStartupSoftware -Query 'CHROME' `
            -GetStartup { @('OneDrive') } -GetTasks { @('Updater') } `
            -GetInstalled { @('Google Chrome  126.0', 'Mozilla Firefox  128.0') }
        @($r.installed_matches) | Should -Be @('Google Chrome  126.0')
        $none = Get-WtAssistantStartupSoftware -GetStartup { @() } -GetTasks { @() } -GetInstalled { @('x') }
        @($none.installed_matches).Count | Should -Be 0
    }
}

Describe 'Get-WtAssistantServiceStatus' {
    It 'reports a named service and falls back to the catalog when unnamed' {
        $fakeService = { param($Name) [PSCustomObject]@{ Name = $Name; DisplayName = 'Print Spooler'; Status = 'Running'; StartType = 'Automatic' } }
        $named = Get-WtAssistantServiceStatus -Name 'Spooler' -GetService $fakeService
        @($named.services).Count | Should -Be 1
        $named.services[0].status | Should -Be 'Running'
        $catalog = Get-WtAssistantServiceStatus -GetCatalogNames { @('DiagTrack', 'Fax') } -GetService $fakeService
        @($catalog.services).Count | Should -Be 2
    }

    It 'a missing service becomes not-found, never a crash' {
        $r = Get-WtAssistantServiceStatus -Name 'YokBoyleServis' -GetService { param($Name) throw 'not found' }
        $r.services[0].status | Should -Be 'not-found'
    }
}

Describe 'Get-WtAssistantNetworkStatus default DNS test seam' {
    <#
    .SYNOPSIS
        A missing MANDATORY parameter makes PowerShell prompt on the raw
        console before any try/catch runs - invisible behind WinToolify's
        painted VT frame - so the default -GetTests seam is never invoked
        live here; the contract is pinned by reading its default value's
        own source text off the function's AST instead.
    #>
    It 'passes -Name to both DNS test helpers in the default GetTests seam' {
        $functionAst = (Get-Command Get-WtAssistantNetworkStatus).ScriptBlock.Ast
        $paramAst = $functionAst.Find(
            { param($node) $node -is [System.Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'GetTests' },
            $true
        )
        $paramAst | Should -Not -BeNullOrEmpty
        $defaultText = $paramAst.DefaultValue.Extent.Text
        $defaultText.Contains('Get-WtDnsTestPlanLines -Name $DnsName') | Should -BeTrue
        $defaultText.Contains('Get-WtDnsTestResultLines -Name $DnsName') | Should -BeTrue
    }
}

Describe 'inspection trio' {
    It 'read_registry refuses the credential hives and unknown roots without touching the registry' {
        $script:Touched = 0
        foreach ($bad in 'HKLM:\SAM\SAM', 'HKLM:\SECURITY\Policy', 'hklm:\software\microsoft\windows nt\currentversion\winlogon\credentials', 'C:\Windows', 'HKLM\SOFTWARE') {
            $r = Get-WtAssistantRegistryRead -Path $bad -GetKey { param($P) $script:Touched++; $null } -GetValues { param($P) $script:Touched++; $null }
            $r.error | Should -Not -BeNullOrEmpty -Because $bad
        }
        $script:Touched | Should -Be 0
    }

    It 'read_registry lists values and subkeys, or one named value, through the injected readers' {
        $fakeKey = [PSCustomObject]@{ GetSubKeyNames = { @('Sub1', 'Sub2') } }
        $getKey = { param($P) [PSCustomObject]@{ SubKeyNames = @('Sub1', 'Sub2') } }
        $getValues = { param($P) [PSCustomObject]@{ ProductName = 'Windows 10 IoT'; CurrentBuild = '19044'; PSPath = 'x'; PSChildName = 'y' } }
        $all = Get-WtAssistantRegistryRead -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -GetKey $getKey -GetValues $getValues
        $all.exists | Should -BeTrue
        @($all.values | ForEach-Object name) | Should -Contain 'ProductName'
        @($all.values | ForEach-Object name) | Should -Not -Contain 'PSPath'
        @($all.subkeys) | Should -Be @('Sub1', 'Sub2')
        $one = Get-WtAssistantRegistryRead -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuild' -GetKey $getKey -GetValues $getValues
        @($one.values).Count | Should -Be 1
        $one.values[0].value | Should -Be '19044'
        (Get-WtAssistantRegistryRead -Path 'HKCU:\Software\Nope' -GetKey { param($P) $null } -GetValues { param($P) $null }).exists | Should -BeFalse
    }

    It 'list_processes ranks by working set, clamps top and survives a protected process' {
        $procs = @(
            [PSCustomObject]@{ ProcessName = 'small'; Id = 1; WorkingSet64 = 10MB; CPU = 1.5 }
            [PSCustomObject]@{ ProcessName = 'big'; Id = 2; WorkingSet64 = 900MB; CPU = 20 }
            [PSCustomObject]@{ ProcessName = 'mid'; Id = 3; WorkingSet64 = 100MB; CPU = $null }
        )
        $r = Get-WtAssistantProcessList -Top 2 -GetProcesses { $procs }
        @($r.processes | ForEach-Object name) | Should -Be @('big', 'mid')
        $r.processes[0].ram_mb | Should -Be 900
        $r.count | Should -Be 3
        @((Get-WtAssistantProcessList -Top 0 -GetProcesses { $procs }).processes).Count | Should -Be 1
        @((Get-WtAssistantProcessList -Top 500 -GetProcesses { $procs }).processes).Count | Should -Be 3
    }

    It 'read_file_head refuses credential/key stores and relative paths without opening them' {
        foreach ($bad in 'C:\Users\x\AppData\Local\Microsoft\Credentials\abc', 'C:\Windows\System32\config\SAM', 'C:\k\site.pfx', 'C:\k\vault.kdbx', 'C:\Users\x\.ssh\id_rsa', 'relative\path.txt', ('C:\Users\x\AppData\Local\WinToolify\settings.json')) {
            (Get-WtAssistantFileHead -Path $bad).error | Should -Not -BeNullOrEmpty -Because $bad
        }
    }

    It 'read_file_head returns the first lines within the byte cap and flags truncation' {
        $file = Join-Path $TestDrive 'head.txt'
        [System.IO.File]::WriteAllLines($file, @(1..300 | ForEach-Object { 'line ' + $_ }))
        $r = Get-WtAssistantFileHead -Path $file -Lines 5
        @($r.lines) | Should -Be @('line 1', 'line 2', 'line 3', 'line 4', 'line 5')
        $r.truncated | Should -BeTrue
        $r.size_bytes | Should -BeGreaterThan 0
        $all = Get-WtAssistantFileHead -Path $file -Lines 500
        @($all.lines).Count | Should -Be 300
        $all.truncated | Should -BeFalse
        $capped = Get-WtAssistantFileHead -Path $file -Lines 500 -MaxBytes 100
        @($capped.lines).Count | Should -BeLessThan 300
        $capped.truncated | Should -BeTrue
        (Get-WtAssistantFileHead -Path (Join-Path $TestDrive 'yok.txt')).error | Should -Match 'not found'
    }

    It 'blocks path traversal in both readers without touching the target' {
        $script:Touched = 0
        foreach ($bad in 'HKLM:\..\SAM', 'HKLM:\SOFTWARE\..\SECURITY', 'HKLM:/SOFTWARE/../SECURITY') {
            $r = Get-WtAssistantRegistryRead -Path $bad -GetKey { param($P) $script:Touched++; $null } -GetValues { param($P) $script:Touched++; $null }
            $r.error | Should -Not -BeNullOrEmpty -Because $bad
        }
        $script:Touched | Should -Be 0
        foreach ($bad in 'C:\Windows\System32\config\Sub\..\SAM', '\\?\C:\Windows\System32\config\SAM', 'C:\Users\x\AppData\Local\Microsoft\Sub\..\Credentials\abc') {
            (Get-WtAssistantFileHead -Path $bad).error | Should -Not -BeNullOrEmpty -Because $bad
        }
    }

    It 'read_registry refuses the new secret-bearing keys and redacts secret-looking value names' {
        foreach ($p in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties', 'HKCU:\Software\SimonTatham\PuTTY\Sessions\prod', 'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities')) {
            Test-WtAssistantBlockedRegistryPath -Path $p | Should -BeTrue -Because $p
        }
        Test-WtAssistantBlockedRegistryPath -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Should -BeFalse
        foreach ($n in @('DefaultPassword', 'ProxyPwd', 'ClientSecret', 'AccessToken', 'ApiKey', 'StoredCredential')) { Test-WtAssistantSecretValueName -Name $n | Should -BeTrue -Because $n }
        Test-WtAssistantSecretValueName -Name 'DisplayVersion' | Should -BeFalse
        $bag = [PSCustomObject]@{ PSPath = 'x'; DisplayVersion = '21H2'; DefaultPassword = 'hunter2' }
        $r = Get-WtAssistantRegistryRead -Path 'HKLM:\SOFTWARE\Probe' -GetKey { param($P) [PSCustomObject]@{ SubKeyNames = @(1..150 | ForEach-Object { 'k' + $_ }) } } -GetValues { param($P) $bag }
        @($r.values | Where-Object name -eq 'DefaultPassword')[0].value | Should -Be '<redacted>'
        @($r.values | Where-Object name -eq 'DisplayVersion')[0].value | Should -Be '21H2'
        @($r.subkeys).Count | Should -Be 100
        $r.subkeys_omitted | Should -Be 50
    }

    It 'read_file_head refuses the new secret carriers without opening them' {
        foreach ($p in @('C:\proj\.env', 'C:\keys\server.pem', 'C:\keys\id.key', 'C:\keys\putty.ppk', 'C:\Users\zz\Desktop\work.rdp', 'C:\Users\zz\.git-credentials', 'C:\Users\zz\.npmrc', 'C:\Users\zz\_netrc', 'C:\Windows\Panther\unattend.xml', 'C:\Windows\System32\sysprep\sysprep.inf', 'C:\Users\zz\AppData\Local\Google\Chrome\User Data\Default\Login Data', 'C:\Users\zz\AppData\Local\Google\Chrome\User Data\Default\Cookies', 'C:\Users\zz\AppData\Local\Google\Chrome\User Data\Local State')) {
            Test-WtAssistantBlockedFilePath -Path $p | Should -BeTrue -Because $p
        }
        Test-WtAssistantBlockedFilePath -Path 'C:\Windows\Logs\CBS\CBS.log' | Should -BeFalse
    }

    It 'read_file_head also refuses the dotenv FAMILY, not only the exact ".env" name' {
        foreach ($p in @('C:\proj\.env.local', 'C:\proj\.env.production', 'C:\proj\.env.development', 'C:\proj\prod.env', 'C:\proj\app.env')) {
            Test-WtAssistantBlockedFilePath -Path $p | Should -BeTrue -Because $p
        }
        Test-WtAssistantBlockedFilePath -Path 'C:\proj\environment.txt' | Should -BeFalse
    }

    It 'read_raw routes by kind and refuses anything else' {
        $r = Get-WtAssistantRawRead -Kind 'registry' -Path 'HKLM:\SAM\x'
        [string]$r.error | Should -Match 'registry path refused'
        $f = Get-WtAssistantRawRead -Kind 'file' -Path 'relative\path.txt'
        [string]$f.error | Should -Match 'file path refused'
        (Get-WtAssistantRawRead -Kind 'disk' -Path 'x').error | Should -Be 'kind must be registry or file'
    }

    It 'read_system and read_raw are registered as read tier and their descriptions exist in both languages' {
        foreach ($name in @('read_system', 'read_raw')) {
            $rec = Get-WtAssistantToolRecord -Name $name
            $rec.Tier | Should -Be 'read'
            [string]$script:Translations['EN'][[string]$rec.DescriptionKey] | Should -Not -BeNullOrEmpty
            [string]$script:Translations['TR'][[string]$rec.DescriptionKey] | Should -Not -BeNullOrEmpty
        }
        foreach ($gone in @('read_registry', 'read_file_head', 'list_processes', 'get_wintoolify_status', 'get_system_overview')) { Get-WtAssistantToolRecord -Name $gone | Should -BeNullOrEmpty }
    }
}

Describe 'ConvertTo-WtAssistantToolText, the one serializer' {
    It 'writes scalars as key: value, skips null / empty / false, and puts error and hint first' {
        $value = [ordered]@{ name = 'svc'; enabled = $true; disabled = $false; count = 3; ratio = 1.5; empty = ''; nothing = $null; hint = 'try x'; error = 'boom' }
        $text = ConvertTo-WtAssistantToolText -Value $value
        $lines = @($text -split "`n")
        $lines[0] | Should -Be 'error: boom'
        $lines[1] | Should -Be 'hint: try x'
        $lines | Should -Contain 'name: svc'
        $lines | Should -Contain 'enabled: yes'
        $lines | Should -Contain 'count: 3'
        $lines | Should -Contain 'ratio: 1.5'
        $text | Should -Not -Match 'disabled'
        $text | Should -Not -Match 'empty'
        $text | Should -Not -Match 'nothing'
    }

    It 'joins short scalar arrays inline and lists long ones one per line' {
        (ConvertTo-WtAssistantToolText -Value @{ tags = @('a', 'b', 'c') }) | Should -Be 'tags: a, b, c'
        $long = @{ lines = @('first line of a longer block that is wider than twenty-four characters', 'second') }
        $text = ConvertTo-WtAssistantToolText -Value $long
        @($text -split "`n")[0] | Should -Be 'lines:'
        @($text -split "`n")[1] | Should -Be '  first line of a longer block that is wider than twenty-four characters'
    }

    It 'renders an array of objects as one header line and TSV rows, replacing | inside a value' {
        $rows = @(
            [PSCustomObject]@{ id = 'A:B'; label = 'x | y'; state = 'on' }
            [PSCustomObject]@{ id = 'C:D'; label = 'z'; state = '' }
        )
        $text = ConvertTo-WtAssistantToolText -Value ([ordered]@{ rows = $rows; total = 2 })
        $lines = @($text -split "`n")
        $lines[0] | Should -Be 'rows:'
        $lines[1] | Should -Be '  id | label | state'
        $lines[2] | Should -Be '  A:B | x / y | on'
        $lines[3] | Should -Be '  C:D | z | '
        $lines[4] | Should -Be 'total: 2'
    }

    It 'indents a nested object two spaces and falls back to compact json below depth 2' {
        $value = [ordered]@{ a = [ordered]@{ b = 1; c = [ordered]@{ d = 2 } } }
        $text = ConvertTo-WtAssistantToolText -Value $value
        $lines = @($text -split "`n")
        $lines[0] | Should -Be 'a:'
        $lines[1] | Should -Be '  b: 1'
        $lines[2] | Should -Be '  c: {"d":2}'
    }

    It 'says ok for nothing, and never emits a \u escape' {
        ConvertTo-WtAssistantToolText -Value $null | Should -Be 'ok'
        ConvertTo-WtAssistantToolText -Value @{} | Should -Be 'ok'
        (ConvertTo-WtAssistantToolText -Value @{ path = 'Tools > Fixes'; q = "it's" }) | Should -Not -Match '\\u00'
        $deep = [ordered]@{ a = [ordered]@{ b = [ordered]@{ c = "x > y & it's <z>" } } }
        $deepText = ConvertTo-WtAssistantToolText -Value $deep
        $deepText | Should -Not -Match '\\u00'
        $deepText | Should -Match "x > y & it's <z>"
        $rows = @([PSCustomObject]@{ id = 'r1'; extra = [ordered]@{ note = "ok? > yes & why not <sure> it's fine" } })
        $rowsText = ConvertTo-WtAssistantToolText -Value @{ rows = $rows }
        $rowsText | Should -Not -Match '\\u00'
        $rowsText | Should -Match "why not <sure> it's fine"
    }

    It 'cuts at a line boundary, counts the omitted lines and appends the record hint' {
        $rows = @(1..40 | ForEach-Object { [PSCustomObject]@{ n = $_; text = ('row number ' + $_ + ' with some padding text') } })
        $text = ConvertTo-WtAssistantToolText -Value @{ rows = $rows } -MaxChars 600 -Hint 'narrow with filter='
        $text.Length | Should -BeLessOrEqual 600
        $lines = @($text -split "`n")
        $lines[-1] | Should -Be 'hint: narrow with filter='
        $lines[-2] | Should -Match '^omitted: \d+ lines$'
        foreach ($l in $lines[2..($lines.Count - 3)]) { $l | Should -Match '^  \d+ \| row number \d+ with some padding text$' }
    }

    It 'a top-level array is rows with no key line' {
        $text = ConvertTo-WtAssistantToolText -Value @([PSCustomObject]@{ a = 1 }, [PSCustomObject]@{ a = 2 })
        @($text -split "`n")[0] | Should -Be 'a'
        @($text -split "`n")[1] | Should -Be '1'
    }
}

Describe 'ConvertTo-WtAssistantModelLines and ConvertFrom-WtAssistantFixedTable' {
    It 'drops blanks, rulers, headings ending in a colon and dictionary footnotes; collapses padding; caps with omitted' {
        $lines = @('Heading here:', '', 'Name    State    Command', '----------------', 'chrome  Enabled  C:\x.exe', 'code    Disabled C:\y.exe', '', [string]$script:Translations['EN']['ScheduledTasksFootnote'])
        $out = @(ConvertTo-WtAssistantModelLines -Lines $lines -Columns -DropKeys @('ScheduledTasksFootnote'))
        $out | Should -Be @('Name | State | Command', 'chrome | Enabled | C:\x.exe', 'code | Disabled C:\y.exe')
        $capped = @(ConvertTo-WtAssistantModelLines -Lines @('a', 'b', 'c') -Max 2)
        $capped | Should -Be @('a', 'b', 'omitted: 1 lines')
        @(ConvertTo-WtAssistantModelLines -Lines @('abcdefghij  x') -Columns -MaxCell 5) | Should -Be @('abcd~ | x')
    }

    It 'slices a padded table by its header positions, so a full cell next to another still splits' {
        $lines = @('12 startup entries', '', 'Name         State    Location    Command', '----------------------------------------', 'OneDriveSetup Enabled  HKCU Run    C:\Users\zz\OneDrive.exe', 'chrome~~~~~~~ Disabled Startup dir C:\chrome.exe', '', 'footnote')
        $table = ConvertFrom-WtAssistantFixedTable -Lines $lines
        $table.Columns | Should -Be @('Name', 'State', 'Location', 'Command')
        @($table.Rows).Count | Should -Be 2
        $table.Rows[0] | Should -Be @('OneDriveSetup', 'Enabled', 'HKCU Run', 'C:\Users\zz\OneDrive.exe')
        (ConvertFrom-WtAssistantFixedTable -Lines @('no table here')).Rows | Should -BeNullOrEmpty
    }
}

Describe 'read_system digests' {
    BeforeAll {
        $script:Overview = [PSCustomObject]@{
            windows = [PSCustomObject]@{ caption = 'Microsoft Windows 10 IoT Enterprise LTSC'; display_version = '21H2'; build = '19044'; architecture = '64 bit' }
            hardware = [PSCustomObject]@{ model = 'ROG'; cpu = 'AMD Ryzen 7 5800HS         '; cores = 8; logical_processors = 16; ram_total_gb = 15.4; ram_free_gb = 9.9; gpus = @([PSCustomObject]@{ name = 'AMD Radeon'; driver = '30.0.1' }, [PSCustomObject]@{ name = 'NVIDIA RTX 3050'; driver = '32.0.16' }) }
            volumes = @([PSCustomObject]@{ drive = 'C:'; total_gb = 476.3; free_gb = 317 })
            uptime_hours = 52.5
            power_plan = 'Power Scheme GUID: 4b56727b-66b4-485a-8d8b-a8bef4f7dfb8  (Ultimate Performance (WinToolify))'
            pending_reboot = @(([string]$script:Translations['EN']['PendingRebootHeader'] + ': ' + [string]$script:Translations['EN']['AnswerYes']), ('  - ' + [string]$script:Translations['EN']['PendingRebootReasonCbs']), ('  - ' + ([string]$script:Translations['EN']['PendingRebootReasonComputerName'] -f 'OLDNAME', 'NEWNAME')), '', 'PendingFileRenameOperations: 13')
            top_memory = @('Memory use per program:', 'Process                          Count        Memory', 'chrome                           15        1.8 GB', 'Code                             13      874.8 MB', 'claude                            1      481.8 MB', '', '81 groups, 210 processes')
        }
    }

    It 'overview: one line per fact, power plan name only, pending reboot as reason codes (never the new computer name), top memory as pairs' {
        $d = ConvertTo-WtAssistantOverviewDigest -Overview $Overview
        $d['os'] | Should -Be 'Microsoft Windows 10 IoT Enterprise LTSC 21H2 build 19044 64 bit'
        $d['cpu'] | Should -Be 'AMD Ryzen 7 5800HS (8c/16t)'
        $d['ram_gb'] | Should -Be '15.4 total, 9.9 free'
        $d['gpu'] | Should -Be 'AMD Radeon (30.0.1); NVIDIA RTX 3050 (32.0.16)'
        $d['volumes'] | Should -Be 'C: 476.3 total, 317 free GB'
        $d['power_plan'] | Should -Be 'Ultimate Performance (WinToolify)'
        $d['pending_reboot'] | Should -Be 'yes: cbs, computer_rename'
        $d['top_memory'] | Should -Be 'chrome 1.8 GB (15), Code 874.8 MB (13), claude 481.8 MB'
        (ConvertTo-WtAssistantToolText -Value $d) | Should -Not -Match 'NEWNAME'
        (ConvertTo-WtAssistantToolText -Value $d).Length | Should -BeLessOrEqual 900
        (ConvertTo-WtAssistantPendingRebootText -Lines @(([string]$script:Translations['TR']['PendingRebootHeader'] + ': ' + [string]$script:Translations['TR']['AnswerNo']), '  x')) | Should -Be 'no'
    }

    It 'overview: gpu caps at 4 entries and volumes at 8, both with a "+N more" tail, so an atypical machine cannot blow the size budget' {
        $wide = [PSCustomObject]@{
            windows  = $Overview.windows
            hardware = [PSCustomObject]@{
                model = $Overview.hardware.model; cpu = $Overview.hardware.cpu; cores = $Overview.hardware.cores
                logical_processors = $Overview.hardware.logical_processors; ram_total_gb = $Overview.hardware.ram_total_gb
                ram_free_gb = $Overview.hardware.ram_free_gb
                gpus = @(1..6 | ForEach-Object { [PSCustomObject]@{ name = ('GPU' + $_); driver = ('1.0.' + $_) } })
            }
            volumes  = @(1..10 | ForEach-Object { [PSCustomObject]@{ drive = ('V' + $_ + ':'); total_gb = 100; free_gb = 50 } })
            uptime_hours = $Overview.uptime_hours
            power_plan = $Overview.power_plan
            pending_reboot = $Overview.pending_reboot
            top_memory = $Overview.top_memory
        }
        $d = ConvertTo-WtAssistantOverviewDigest -Overview $wide
        $d['gpu'] | Should -Match '\+2 more$'
        $d['volumes'] | Should -Match '\+2 more$'
        (ConvertTo-WtAssistantToolText -Value $d).Length | Should -BeLessOrEqual 900
    }

    It 'errors: fifteen rows per log, message cut at 120, omitted counted, none when empty, and the ROUTED result actually fits the topic ceiling' {
        $events = @(1..40 | ForEach-Object { [PSCustomObject]@{ time = '2026-09-05 08:0' + ($_ % 10); log = $(if ($_ -le 20) { 'System' } else { 'Application' }); level = 'Error'; id = 1000 + $_; source = 'Src'; message = ('m' * 150) } })
        $d = ConvertTo-WtAssistantErrorsDigest -Errors ([PSCustomObject]@{ hours = 24; events = $events })
        @($d['events']).Count | Should -Be 30
        $d['omitted'] | Should -Be 10
        ([string]$d['events'][0].message).Length | Should -Be 120
        (ConvertTo-WtAssistantErrorsDigest -Errors ([PSCustomObject]@{ hours = 48; events = @() }))['events'] | Should -Be 'none'
        $fakeSources = @{ errors = { param($F) [PSCustomObject]@{ hours = 24; events = $events } } }
        $routed = Get-WtAssistantSystemRead -Topic 'errors' -Filter '24' -Sources $fakeSources
        $routed.Remove('_max_chars')
        $text = ConvertTo-WtAssistantToolText -Value $routed -MaxChars (Get-WtAssistantReadTopicMaxChars -Topic 'errors')
        $text.Length | Should -BeLessOrEqual 1500
        $text | Should -Match 'omitted: \d+ lines$'
    }

    It 'crashes: history rows as columns, analysis reduced to bugcheck / probable cause / stack, cdb cut at 600, note dropped' {
        $history = @('Stop errors and unexpected power loss:', '2026-09-01 10:00  Stop error  The computer has rebooted from a bugcheck 0x133', '', 'Crash dumps still on disk:', '  1 file, 2 MB', '  2026-09-01 10:00  090126-1.dmp')
        $analysis = [PSCustomObject]@{ file = '090126-1.dmp'; time = '2026-09-01 10:00'; build = 19044; bugcheck = [PSCustomObject]@{ code = '0x133'; name = 'DPC_WATCHDOG_VIOLATION'; parameters = @('0x1', '0x0', '0x0', '0x0') }; probable_cause = [PSCustomObject]@{ driver = 'nvlddmkm.sys'; via = 'stack' }; drivers_on_stack = @([PSCustomObject]@{ driver = 'nvlddmkm.sys'; hits = 3 }, [PSCustomObject]@{ driver = 'dxgkrnl.sys'; hits = 1 }); driver_count = 180; note = 'heuristic'; cdb_analysis = ('c' * 900) }
        $d = ConvertTo-WtAssistantCrashDigest -HistoryLines $history -Analysis $analysis
        $d['history'] | Should -Contain '2026-09-01 10:00 | Stop error | The computer has rebooted from a bugcheck 0x133'
        $d['analysis']['bugcheck'] | Should -Be '0x133 DPC_WATCHDOG_VIOLATION params 0x1 0x0 0x0 0x0'
        $d['analysis']['probable_cause'] | Should -Be 'nvlddmkm.sys (stack)'
        $d['analysis']['drivers_on_stack'] | Should -Be 'nvlddmkm.sys x3, dxgkrnl.sys x1'
        ([string]$d['analysis']['cdb']).Length | Should -Be 600
        $d['analysis'].Contains('note') | Should -BeFalse
        (ConvertTo-WtAssistantToolText -Value $d).Length | Should -BeLessOrEqual 1500
        (ConvertTo-WtAssistantCrashDigest -HistoryLines $history -Analysis ([PSCustomObject]@{ error = 'bad header'; file = 'x.dmp' }))['analysis'] | Should -Be 'error: bad header'
    }

    It 'storage: volume/disk/error line blocks reduced through ConvertTo-WtAssistantModelLines, and fit the storage ceiling' {
        $storage = @{
            volumes_lines = @('C: 476.3 GB total, 317 GB free', 'D: 931 GB total, 500 GB free')
            disk_health = @('Name    Type  Health   Status', '----    ----  ------   ------', 'Disk 0  NVMe  Healthy  OK')
            disk_errors = @('Time              Id  Message', '----              --  -------', '2026-09-01 10:00  51  The device had a bad block.')
        }
        $d = ConvertTo-WtAssistantStorageDigest -Storage $storage
        $d['volumes'] | Should -Contain 'C: 476.3 GB total, 317 GB free'
        $d['disks'] | Should -Contain 'Disk 0 | NVMe | Healthy | OK'
        $d['disk_errors'] | Should -Contain '2026-09-01 10:00 | 51 | The device had a bad block.'
        (ConvertTo-WtAssistantToolText -Value $d).Length | Should -BeLessOrEqual 900
    }

    It 'network: one row per adapter from the ip summary, status looked up in the adapter table, tests as plain lines' {
        $network = @{
            adapters = @('Name      Status       LinkSpeed MacAddress        MediaType', '----      ------       --------- ----------        ---------', 'Wi-Fi     Up           866 Mbps  00-11-22-33-44-55 802.11', 'Ethernet  Disconnected 0 bps     66-77-88-99-AA-BB 802.3', '', [string]$script:Translations['EN']['NetAdapterVirtualNote'])
            ip_summary = @('Wi-Fi', '  IPv4    : 192.168.1.20/24', '  Gateway : 192.168.1.1', '  DNS     : 1.1.1.1, 8.8.8.8', '', 'Ethernet', '  IPv4    : -', '  Gateway : -', '  DNS     : -', '')
            tests = @('Internet: 1.1.1.1 reachable (12 ms)', 'DNS: www.microsoft.com -> 3 addresses')
        }
        $d = ConvertTo-WtAssistantNetworkDigest -Network $network
        @($d['adapters']).Count | Should -Be 2
        $d['adapters'][0].name | Should -Be 'Wi-Fi'
        $d['adapters'][0].status | Should -Be 'up'
        $d['adapters'][0].ipv4 | Should -Be '192.168.1.20/24'
        $d['adapters'][0].dns | Should -Be '1.1.1.1, 8.8.8.8'
        $d['adapters'][1].status | Should -Be 'down'
        $d['tests'] | Should -Be @('Internet: 1.1.1.1 reachable (12 ms)', 'DNS: www.microsoft.com -> 3 addresses')
        (ConvertTo-WtAssistantToolText -Value $d) | Should -Not -Match '00-11-22'
        (ConvertTo-WtAssistantToolText -Value (ConvertTo-WtAssistantNetworkDigest -Network @{ adapters = @(); ip_summary = @(); tests = @() })) | Should -Be 'adapters: none'
        (ConvertTo-WtAssistantToolText -Value $d).Length | Should -BeLessOrEqual (Get-WtAssistantReadTopicMaxChars -Topic 'network')
        Get-WtAssistantReadTopicMaxChars -Topic 'network_tests' | Should -Be 1200
    }

    It 'security: RDP members become a count, the net accounts dump becomes three numbers, section headers go' {
        $en = $script:Translations['EN']
        $posture = @(([string]$en['PostureSectionUac']), 'UAC level: Default', ([string]$en['PostureSectionRemote']), 'Remote Desktop: Off', ([string]$en['PostureRdpUsersLabel'] + ': alice, bob@example.com'), 'WinRM service: Stopped', ([string]$en['PostureSectionPasswordPolicy']), 'Force user logoff how long after time expires?: Never', 'Minimum password age (days): 0', 'Maximum password age (days): Unlimited', 'Minimum password length: 7', 'Length of password history maintained: None', 'Lockout threshold: 5', 'Lockout duration (minutes): 30', 'Lockout observation window (minutes): 30', 'Computer role: WORKSTATION', 'The command completed successfully.')
        $d = ConvertTo-WtAssistantSecurityDigest -Security @{ defender = @('Real-time protection: On', 'Signature age: 2 days'); posture = $posture; boot_tpm = @('Firmware: UEFI', 'Secure Boot: Off') }
        $d['posture'] | Should -Contain ([string]$en['PostureRdpUsersLabel'] + ': 2')
        $d['posture'] | Should -Not -Contain 'alice, bob@example.com'
        ($d['posture'] -join "`n") | Should -Not -Match 'alice'
        $d['posture'] | Should -Not -Contain ([string]$en['PostureSectionUac'])
        $d['password_policy'] | Should -Be 'min_len 7, max_age_days n/a, lockout_threshold 5'
        $d['defender'] | Should -Be @('Real-time protection: On', 'Signature age: 2 days')
        (ConvertTo-WtAssistantToolText -Value $d).Length | Should -BeLessOrEqual 700
    }

    It 'startup: padded tables become header + rows with cells cut at 60, footnotes and count lines go, installed matches only when present' {
        $startup = @{
            startup = @('5 entries (4 enabled, 1 disabled)', '', 'Name          State    Location    Command', '-----------------------------------------', ('OneDrive      Enabled  HKCU Run    ' + ('C:\long\path\' * 8)), 'Steam         Disabled Startup dir C:\steam.exe', '', 'footnote text')
            tasks = @('Name        State   Path', '------------------------', 'GoogleUpdate Ready  \GoogleUpdateTaskMachine', '', [string]$script:Translations['EN']['ScheduledTasksFootnote'])
            installed_matches = @()
        }
        $d = ConvertTo-WtAssistantStartupDigest -Startup $startup
        $d['startup'][0].name | Should -Be 'OneDrive'
        ([string]$d['startup'][0].command).Length | Should -Be 60
        ([string]$d['startup'][0].command) | Should -Match '~$'
        $d['startup'][1].state | Should -Be 'Disabled'
        $d['tasks'][0].path | Should -Be '\GoogleUpdateTaskMachine'
        $d.Contains('installed_matches') | Should -BeFalse
        $text = ConvertTo-WtAssistantToolText -Value $d
        $text | Should -Not -Match 'footnote'
        $text | Should -Not -Match '5 entries'
        $text.Length | Should -BeLessOrEqual (Get-WtAssistantReadTopicMaxChars -Topic 'startup')
    }

    It 'services: a named service is one object with its display name; the catalog is rows without it' {
        $rows = @([PSCustomObject]@{ name = 'DiagTrack'; display = 'Connected User Experiences'; status = 'Running'; start_type = 'Automatic' }, [PSCustomObject]@{ name = 'WSearch'; display = 'Windows Search'; status = 'Stopped'; start_type = 'Disabled' })
        $one = ConvertTo-WtAssistantServicesDigest -Services @{ services = @($rows[0]) } -Filter 'DiagTrack'
        $one['display'] | Should -Be 'Connected User Experiences'
        $all = ConvertTo-WtAssistantServicesDigest -Services @{ services = $rows }
        $text = ConvertTo-WtAssistantToolText -Value $all
        $text | Should -Match 'name \| status \| start'
        $text | Should -Not -Match 'Connected User'
        $text | Should -Match 'WSearch \| Stopped \| Disabled'
        $text.Length | Should -BeLessOrEqual (Get-WtAssistantReadTopicMaxChars -Topic 'services')
    }

    It 'processes, changes and status: rows with short column names, changes capped to the newest N with a total' {
        $p = ConvertTo-WtAssistantProcessesDigest -Processes ([PSCustomObject]@{ processes = @([PSCustomObject]@{ name = 'chrome'; pid = 12; ram_mb = 480; cpu_seconds = 12.5 }); count = 210 })
        (ConvertTo-WtAssistantToolText -Value $p) | Should -Match 'name \| pid \| ram_mb \| cpu_s'
        (ConvertTo-WtAssistantToolText -Value $p).Length | Should -BeLessOrEqual (Get-WtAssistantReadTopicMaxChars -Topic 'processes')
        $p['count'] | Should -Be 210
        $changes = @(1..14 | ForEach-Object { [PSCustomObject]@{ id = ('e' + $_); when = '2026-09-0' + ($_ % 9 + 1); action = 'Apply'; scope = 'Machine'; items = 1; restored = ($_ -eq 3) } })
        $c = ConvertTo-WtAssistantChangesDigest -Changes ([PSCustomObject]@{ changes = $changes })
        @($c['changes']).Count | Should -Be 10
        $c['total'] | Should -Be 14
        (ConvertTo-WtAssistantToolText -Value $c).Length | Should -BeLessOrEqual (Get-WtAssistantReadTopicMaxChars -Topic 'wintoolify_changes')
        $c2 = ConvertTo-WtAssistantChangesDigest -Changes ([PSCustomObject]@{ changes = $changes }) -Take 3
        @($c2['changes']).Count | Should -Be 3
        $s = ConvertTo-WtAssistantStatusDigest -Status ([PSCustomObject]@{ sections = @([PSCustomObject]@{ section = 'Services'; title = 'Servisler'; applied = 3; total = 43; not_present = 0 }, [PSCustomObject]@{ section = 'Packages'; title = 'Paketler'; applied = 10; total = 122; not_present = 5 }); applied_total = 13; total = 165 })
        $s['sections'][0].applied | Should -Be '3/43'
        $s['sections'][1].not_present | Should -Be 5
        $s['sections'][0].PSObject.Properties.Name | Should -Not -Contain 'title'
        $s['total'] | Should -Be '13/165'
        (ConvertTo-WtAssistantToolText -Value $s).Length | Should -BeLessOrEqual (Get-WtAssistantReadTopicMaxChars -Topic 'wintoolify_status')
    }

    It 'the router: topics, filters and the unknown-topic error; crashes drops a "no dump" analysis when no file was asked for' {
        (Get-WtAssistantReadTopics).Count | Should -Be 12
        $script:Calls = @()
        $sources = @{
            errors = { param($F) $script:Calls += @('errors:' + $F); [PSCustomObject]@{ hours = 24; events = @() } }
            services = { param($F) $script:Calls += @('services:' + $F); @{ services = @() } }
            crash_history = { param($F) @{ lines = @('x') } }
            crash_analysis = { param($F) $script:Calls += @('dump:' + $F); [PSCustomObject]@{ error = 'no minidump found' } }
            processes = { param($F) $script:Calls += @('top:' + $F); [PSCustomObject]@{ processes = @(); count = 0 } }
            security = { param($F) @{ defender = @(); posture = @(); boot_tpm = @() } }
        }
        $errorsResult = Get-WtAssistantSystemRead -Topic 'errors' -Filter '24' -Sources $sources
        $errorsResult['hours'] | Should -Be 24
        $null = Get-WtAssistantSystemRead -Topic 'services' -Filter 'DiagTrack' -Sources $sources
        $null = Get-WtAssistantSystemRead -Topic 'processes' -Filter 'abc' -Sources $sources
        $Calls | Should -Be @('errors:24', 'services:DiagTrack', 'top:abc')
        $crash = Get-WtAssistantSystemRead -Topic 'crashes' -Sources $sources
        $crash.Contains('analysis') | Should -BeFalse
        $crashNamed = Get-WtAssistantSystemRead -Topic 'crashes' -Filter 'x.dmp' -Sources $sources
        $crashNamed['analysis'] | Should -Be 'error: no minidump found'
        $bad = Get-WtAssistantSystemRead -Topic 'nope'
        $bad['error'] | Should -Be 'unknown topic: nope'
        $bad['hint'] | Should -Match '^topics: overview, errors'

        $errorsResult['_max_chars'] | Should -Be 1500
        $crash['_max_chars'] | Should -Be 1500
        (Get-WtAssistantSystemRead -Topic 'security' -Sources $sources)['_max_chars'] | Should -Be 700
        $bad.Contains('_max_chars') | Should -BeFalse
    }

    It 'Get-WtAssistantReadTopicMaxChars: the per-topic ceiling table, zero for an unknown topic' {
        $expected = @{
            overview = 900; errors = 1500; crashes = 1500; storage = 900
            network = 900; network_tests = 1200; security = 700; startup = 1200
            services = 1200; processes = 900; wintoolify_changes = 900; wintoolify_status = 900
        }
        foreach ($topic in @(Get-WtAssistantReadTopics)) {
            Get-WtAssistantReadTopicMaxChars -Topic $topic | Should -Be $expected[$topic] -Because $topic
        }
        Get-WtAssistantReadTopicMaxChars -Topic 'nope' | Should -Be 0
    }
}
