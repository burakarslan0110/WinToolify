#Requires -Modules Pester

<#
.SYNOPSIS
    Disk & System Health bundle: the disk health report (Get-PhysicalDisk +
    Get-StorageReliabilityCounter joined by DeviceId, flag rules, alarm
    temperatures), the sensor snapshot (CIM classes, GPU aggregation,
    memory-pressure flag), both line renderers, Format-WtByteSize, and
    Save-WtReport. Every Windows-only source is behind an injectable
    action - none exist on the macOS dev host - so tests feed fixture
    objects shaped like the real classes. A mandatory [string[]] rejects
    an empty string element unless AllowEmptyString is declared, so
    Save-WtReport's tests include blank lines to guard against it.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function script:New-FakeDisk {
        param($DeviceId, $FriendlyName = 'Disk', $MediaType = 'SSD', $HealthStatus = 'Healthy', $Size = 512GB)
        [PSCustomObject]@{
            DeviceId          = $DeviceId
            FriendlyName      = $FriendlyName
            SerialNumber      = "SN$DeviceId"
            MediaType         = $MediaType
            BusType           = 'NVMe'
            Size              = $Size
            HealthStatus      = $HealthStatus
            OperationalStatus = 'OK'
        }
    }

    function script:New-FakeCounter {
        param($DeviceId, $Temperature = 41, $TemperatureMax = 55, $Wear = 3, $PowerOnHours = 1200, $ReadErrorsUncorrected = 0, $WriteErrorsUncorrected = 0)
        [PSCustomObject]@{
            DeviceId               = $DeviceId
            Temperature            = $Temperature
            TemperatureMax         = $TemperatureMax
            Wear                   = $Wear
            PowerOnHours           = $PowerOnHours
            ReadErrorsUncorrected  = $ReadErrorsUncorrected
            WriteErrorsUncorrected = $WriteErrorsUncorrected
        }
    }

    function script:New-FlagInput {
        param($MediaType = 'SSD', $HealthStatus = 'Healthy', $TemperatureC = $null, $WearPercent = $null, $ReadErrorsUncorrected = 0, $WriteErrorsUncorrected = 0)
        [PSCustomObject]@{
            MediaType              = $MediaType
            HealthStatus           = $HealthStatus
            TemperatureC           = $TemperatureC
            WearPercent            = $WearPercent
            ReadErrorsUncorrected  = $ReadErrorsUncorrected
            WriteErrorsUncorrected = $WriteErrorsUncorrected
        }
    }
}

Describe 'Format-WtByteSize' {
    It 'renders 1024-based units with one decimal and invariant culture' {
        Format-WtByteSize -Bytes 0 | Should -Be '0 B'
        Format-WtByteSize -Bytes 512 | Should -Be '512 B'
        Format-WtByteSize -Bytes 1536 | Should -Be '1.5 KB'
        Format-WtByteSize -Bytes 257238630 | Should -Be '245.3 MB'
        Format-WtByteSize -Bytes 1288490189 | Should -Be '1.2 GB'
        Format-WtByteSize -Bytes 2199023255552 | Should -Be '2.0 TB'
    }
}

Describe 'Get-WtDiskAlarmTemperature' {
    It 'is 50 for HDD and 60 for everything else' {
        Get-WtDiskAlarmTemperature -MediaType 'HDD' | Should -Be 50
        Get-WtDiskAlarmTemperature -MediaType 'SSD' | Should -Be 60
        Get-WtDiskAlarmTemperature -MediaType 'Unspecified' | Should -Be 60
    }
}

Describe 'Get-WtDiskHealthReport' {
    It 'joins counters by DeviceId and reports n/a fields for a disk without a counter' {
        $disks = @((New-FakeDisk -DeviceId '0' -FriendlyName 'NVMe A'), (New-FakeDisk -DeviceId '1' -FriendlyName 'USB Stick' -MediaType 'Unspecified'))
        $counters = @((New-FakeCounter -DeviceId '0'))

        $report = @(Get-WtDiskHealthReport -GetPhysicalDisksAction { $disks } -GetReliabilityCountersAction { param($Disks) $counters })

        $report.Count | Should -Be 2
        $first = $report | Where-Object DeviceId -eq '0'
        $first.TemperatureC | Should -Be 41
        $first.TemperatureMaxC | Should -Be 55
        $first.WearPercent | Should -Be 3
        $first.PowerOnHours | Should -Be 1200
        $first.SizeBytes | Should -Be 512GB
        $first.Severity | Should -Be 'OK'

        $second = $report | Where-Object DeviceId -eq '1'
        $second.TemperatureC | Should -BeNullOrEmpty
        $second.WearPercent | Should -BeNullOrEmpty
        $second.ReadErrorsUncorrected | Should -BeNullOrEmpty
        $second.Severity | Should -Be 'OK'
    }

    It 'treats Temperature 0 and Wear 0 on an HDD as not reported' {
        $disks = @((New-FakeDisk -DeviceId '0' -MediaType 'HDD'))
        $counters = @((New-FakeCounter -DeviceId '0' -Temperature 0 -TemperatureMax 0 -Wear 0))

        $entry = @(Get-WtDiskHealthReport -GetPhysicalDisksAction { $disks } -GetReliabilityCountersAction { param($Disks) $counters })[0]

        $entry.TemperatureC | Should -BeNullOrEmpty
        $entry.WearPercent | Should -BeNullOrEmpty
        $entry.Severity | Should -Be 'OK'
    }

    It 'still reports every disk when the reliability-counter action throws' {
        $disks = @((New-FakeDisk -DeviceId '0'), (New-FakeDisk -DeviceId '1'))

        $report = @(Get-WtDiskHealthReport -GetPhysicalDisksAction { $disks } -GetReliabilityCountersAction { throw 'no counters' })

        $report.Count | Should -Be 2
        foreach ($entry in $report) {
            $entry.TemperatureC | Should -BeNullOrEmpty
            $entry.WearPercent | Should -BeNullOrEmpty
            $entry.Severity | Should -Be 'OK'
        }
    }
}

Describe 'Get-WtDiskHealthFlags' {
    It 'is CRITICAL for an unhealthy disk' {
        $result = Get-WtDiskHealthFlags -Disk (New-FlagInput -HealthStatus 'Unhealthy')
        $result.Severity | Should -Be 'CRITICAL'
        @($result.Flags).Count | Should -Be 1
    }

    It 'is WARNING at the wear, error, and temperature thresholds' {
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -WearPercent 90)).Severity | Should -Be 'WARNING'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -ReadErrorsUncorrected 1)).Severity | Should -Be 'WARNING'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -WriteErrorsUncorrected 1)).Severity | Should -Be 'WARNING'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -MediaType 'HDD' -TemperatureC 50)).Severity | Should -Be 'WARNING'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -MediaType 'SSD' -TemperatureC 60)).Severity | Should -Be 'WARNING'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -HealthStatus 'Warning')).Severity | Should -Be 'WARNING'
    }

    It 'is OK just below every threshold and for unreported values' {
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -MediaType 'HDD' -TemperatureC 49)).Severity | Should -Be 'OK'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -MediaType 'SSD' -TemperatureC 59)).Severity | Should -Be 'OK'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -WearPercent 89)).Severity | Should -Be 'OK'
        (Get-WtDiskHealthFlags -Disk (New-FlagInput -TemperatureC $null -WearPercent $null)).Severity | Should -Be 'OK'
    }

    It 'emits one flag per triggered rule and reports the worst severity' {
        $result = Get-WtDiskHealthFlags -Disk (New-FlagInput -HealthStatus 'Unhealthy' -WearPercent 95 -MediaType 'SSD' -TemperatureC 70)
        $result.Severity | Should -Be 'CRITICAL'
        @($result.Flags).Count | Should -Be 3
        @($result.Flags | Where-Object Severity -eq 'CRITICAL').Count | Should -Be 1
        @($result.Flags | Where-Object Severity -eq 'WARNING').Count | Should -Be 2
    }
}

Describe 'Format-WtDiskHealthLines' {
    It 'prefixes the heading with the severity and renders n/a for missing values' {
        $disks = @((New-FakeDisk -DeviceId '0' -FriendlyName 'Bad Disk' -HealthStatus 'Unhealthy'))
        $report = @(Get-WtDiskHealthReport -GetPhysicalDisksAction { $disks } -GetReliabilityCountersAction { param($Disks) @() })

        $lines = @(Format-WtDiskHealthLines -Report $report)

        @($lines | Where-Object { $_ -like '`[CRITICAL`] Bad Disk*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'Temperature: n/a' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'Wear: n/a' }).Count | Should -Be 1
    }

    It 'renders the no-disks line for an empty report' {
        $lines = @(Format-WtDiskHealthLines -Report @())
        @($lines | Where-Object { $_ -eq 'No physical disks reported.' }).Count | Should -Be 1
    }
}

Describe 'Save-WtReport' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'writes the lines to User\reports\<name>-<timestamp>.txt and returns the path' {
        $stamp = Get-Date -Year 2026 -Month 8 -Day 18 -Hour 21 -Minute 5 -Second 9
        $path = Save-WtReport -Name 'health' -Lines @('a', 'b') -TestRootOverride $FakeRoot -Timestamp $stamp

        $path | Should -Be (Join-Path (Join-Path (Join-Path $FakeRoot 'User') 'reports') 'health-20260818-210509.txt')
        Test-Path -LiteralPath $path | Should -BeTrue
        @(Get-Content -LiteralPath $path) | Should -Be @('a', 'b')
    }

    It 'keeps blank lines - a chat transcript has paragraph breaks - instead of refusing the whole report, so /kaydet does not crash on them' {
        $path = Save-WtReport -Name 'blank' -Lines ([string[]]@('a', '', 'b')) -TestRootOverride $FakeRoot
        @(Get-Content -LiteralPath $path) | Should -Be @('a', '', 'b')
    }
}

Describe 'Get-WtGpuUtilizationFromEngines' {
    It 'returns the max over engine types of the per-type sums, not the grand total' {
        $engines = @(
            [PSCustomObject]@{ Name = 'pid_100_luid_0x0_0xA_phys_0_eng_0_engtype_3D'; UtilizationPercentage = 20 }
            [PSCustomObject]@{ Name = 'pid_200_luid_0x0_0xA_phys_0_eng_0_engtype_3D'; UtilizationPercentage = 10 }
            [PSCustomObject]@{ Name = 'pid_100_luid_0x0_0xA_phys_0_eng_1_engtype_Copy'; UtilizationPercentage = 25 }
        )
        Get-WtGpuUtilizationFromEngines -Engines $engines | Should -Be 30
    }

    It 'returns $null for an empty list' {
        Get-WtGpuUtilizationFromEngines -Engines @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtNvidiaSmiTemperature' {
    It 'parses the first line as an integer' {
        Get-WtNvidiaSmiTemperature -ResolveAction { 'C:\fake\nvidia-smi.exe' } -QueryAction { param($Path) @('52') } | Should -Be 52
    }

    It 'returns $null and never queries when the tool cannot be resolved' {
        $script:QueryCalls = 0
        Get-WtNvidiaSmiTemperature -ResolveAction { $null } -QueryAction { param($Path) $script:QueryCalls++; @('52') } | Should -BeNullOrEmpty
        $script:QueryCalls | Should -Be 0
    }

    It 'returns $null for non-integer output' {
        Get-WtNvidiaSmiTemperature -ResolveAction { 'C:\fake\nvidia-smi.exe' } -QueryAction { param($Path) @('N/A') } | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtSensorSnapshot' {
    BeforeAll {
        function script:New-FixtureCimAction {
            param([long]$FreeKB = 1677721, [switch]$ThrowThermal, [switch]$ThrowAll)
            $free = $FreeKB
            $throwThermal = [bool]$ThrowThermal
            $throwAll = [bool]$ThrowAll
            return {
                param($Namespace, $ClassName)
                if ($throwAll) { throw "no class $ClassName" }
                switch ($ClassName) {
                    'Win32_Processor' {
                        @(
                            [PSCustomObject]@{ Name = 'Fake CPU'; LoadPercentage = 10; CurrentClockSpeed = 3400; NumberOfCores = 4; NumberOfLogicalProcessors = 8 }
                            [PSCustomObject]@{ Name = 'Fake CPU'; LoadPercentage = 30; CurrentClockSpeed = 3400; NumberOfCores = 4; NumberOfLogicalProcessors = 8 }
                        )
                    }
                    'MSAcpi_ThermalZoneTemperature' {
                        if ($throwThermal) { throw 'Not supported' }
                        @([PSCustomObject]@{ InstanceName = 'ACPI\ThermalZone\TZ00_0'; CurrentTemperature = 3182 })
                    }
                    'Win32_OperatingSystem' {
                        @([PSCustomObject]@{ TotalVisibleMemorySize = 16777216; FreePhysicalMemory = $free })
                    }
                    'Win32_VideoController' {
                        @([PSCustomObject]@{ Name = 'Fake GPU'; DriverVersion = '1.2.3' })
                    }
                    'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine' {
                        @(
                            [PSCustomObject]@{ Name = 'pid_1_luid_0x0_0xA_phys_0_eng_0_engtype_3D'; UtilizationPercentage = 7 }
                            [PSCustomObject]@{ Name = 'pid_1_luid_0x0_0xA_phys_0_eng_1_engtype_Copy'; UtilizationPercentage = 2 }
                        )
                    }
                    'Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory' {
                        @([PSCustomObject]@{ Name = 'luid_0x0_0xA_phys_0'; DedicatedUsage = 1073741824; SharedUsage = 0 })
                    }
                    default { throw "unexpected class $ClassName" }
                }
            }.GetNewClosure()
        }
    }

    It 'aggregates every section, leaves a throwing thermal zone n/a, and flags 90 % memory use' {
        $snapshot = Get-WtSensorSnapshot -CimQueryAction (New-FixtureCimAction -ThrowThermal) -GpuTemperatureAction { 52 }

        $snapshot.Cpu.Name | Should -Be 'Fake CPU'
        $snapshot.Cpu.LoadPercent | Should -Be 20
        $snapshot.Cpu.ClockMHz | Should -Be 3400
        $snapshot.Cpu.Cores | Should -Be 8
        $snapshot.Cpu.LogicalProcessors | Should -Be 16
        $snapshot.Cpu.TemperatureC | Should -BeNullOrEmpty
        $snapshot.Memory.TotalMB | Should -Be 16384
        $snapshot.Memory.AvailableMB | Should -Be 1638
        $snapshot.Memory.UsedPercent | Should -Be 90
        $snapshot.Gpu.Name | Should -Be 'Fake GPU'
        $snapshot.Gpu.DriverVersion | Should -Be '1.2.3'
        $snapshot.Gpu.UtilizationPercent | Should -Be 7
        $snapshot.Gpu.DedicatedVramUsedMB | Should -Be 1024
        $snapshot.Gpu.TemperatureC | Should -Be 52
        $snapshot.Severity | Should -Be 'WARNING'
        @($snapshot.Flags | Where-Object { $_.Message -like 'High memory pressure*' }).Count | Should -Be 1
    }

    It 'reports the hottest thermal zone in Celsius and OK at 89 % memory use' {
        $snapshot = Get-WtSensorSnapshot -CimQueryAction (New-FixtureCimAction -FreeKB 1845494) -GpuTemperatureAction { $null }

        $snapshot.Cpu.TemperatureC | Should -Be 45
        $snapshot.Memory.UsedPercent | Should -Be 89
        $snapshot.Gpu.TemperatureC | Should -BeNullOrEmpty
        $snapshot.Severity | Should -Be 'OK'
        @($snapshot.Flags).Count | Should -Be 0
    }

    It 'degrades every field to $null when every CIM query throws, and still renders' {
        $snapshot = Get-WtSensorSnapshot -CimQueryAction (New-FixtureCimAction -ThrowAll) -GpuTemperatureAction { throw 'no smi' }

        $snapshot.Cpu.Name | Should -BeNullOrEmpty
        $snapshot.Cpu.LoadPercent | Should -BeNullOrEmpty
        $snapshot.Memory.UsedPercent | Should -BeNullOrEmpty
        $snapshot.Gpu.Name | Should -BeNullOrEmpty
        $snapshot.Gpu.UtilizationPercent | Should -BeNullOrEmpty
        $snapshot.Gpu.TemperatureC | Should -BeNullOrEmpty
        $snapshot.Severity | Should -Be 'OK'

        $lines = @(Format-WtSensorLines -Snapshot $snapshot)
        @($lines | Where-Object { $_ -match 'n/a' }).Count | Should -BeGreaterThan 3
        @($lines | Where-Object { $_ -eq '' }).Count | Should -Be 0
    }
}

Describe 'Format-WtSensorLines' {
    It 'renders load, n/a temperature, and the WARNING prefix for the fixture snapshot' {
        $snapshot = Get-WtSensorSnapshot -CimQueryAction (New-FixtureCimAction -ThrowThermal) -GpuTemperatureAction { $null }
        $lines = @(Format-WtSensorLines -Snapshot $snapshot)

        @($lines | Where-Object { $_ -match 'Load: 20 %' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'Temperature: n/a' }).Count | Should -Be 2
        @($lines | Where-Object { $_ -like '`[WARNING`]*' }).Count | Should -BeGreaterOrEqual 1
        @($lines | Where-Object { $_ -match 'VRAM in use: 1024 MB' }).Count | Should -Be 1
    }
}
