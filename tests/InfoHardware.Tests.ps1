#Requires -Modules Pester

<#
.SYNOPSIS
    The Information screen's Hardware group: memory modules, GPU/driver
    details, battery health and problem devices. Every Windows data
    source is injected, so no test here touches CIM, the registry or
    powercfg. Fixtures use $script: scope throughout: an &-invoked
    scriptblock resolves free variables from its invocation site, so a
    same-named local in a function under test would otherwise be read
    instead of the fixture.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtMemoryModuleLines' {
    BeforeAll {
        $script:TwoSticks = @(
            [PSCustomObject]@{ BankLabel = 'BANK 0'; DeviceLocator = 'DIMM 0'; Capacity = 8GB; Speed = 3200; SMBIOSMemoryType = 26; PartNumber = 'CMK16GX4M2B3200C16  ' }
            [PSCustomObject]@{ BankLabel = 'BANK 1'; DeviceLocator = 'DIMM 0'; Capacity = 8GB; Speed = 3200; SMBIOSMemoryType = 26; PartNumber = 'CMK16GX4M2B3200C16  ' }
        )
        $script:FourSlotArray = @([PSCustomObject]@{ MemoryDevices = 4; MaxCapacityEx = 134217728 })
    }

    It 'lists one line per stick, then the installed total, the free slot count and the ceiling' {
        $lines = @(Get-WtMemoryModuleLines -GetModules { $script:TwoSticks } -GetArrays { $script:FourSlotArray })
        $lines[0] | Should -Be (Get-Translation 'MemoryModuleHeader')
        $lines[1] | Should -Be '  BANK 0: 8.0 GB DDR4 3200 MHz (CMK16GX4M2B3200C16)'
        $lines[2] | Should -Be '  BANK 1: 8.0 GB DDR4 3200 MHz (CMK16GX4M2B3200C16)'
        $lines[3] | Should -Be ((Get-Translation 'MemoryModuleTotalLine') -f '16.0 GB', 2)
        $lines[4] | Should -Be ((Get-Translation 'MemoryModuleSlotsLine') -f 4, 2)
        $lines[5] | Should -Be ((Get-Translation 'MemoryModuleMaxLine') -f '128.0 GB')
    }

    It 'falls back to DeviceLocator when the board leaves BankLabel empty' {
        $lines = @(Get-WtMemoryModuleLines -GetModules { @([PSCustomObject]@{ BankLabel = ''; DeviceLocator = 'ChannelA-DIMM1'; Capacity = 16GB; Speed = 2667; SMBIOSMemoryType = 26; PartNumber = 'M471A2K43CB1-CTD' }) } -GetArrays { @() })
        $lines[1] | Should -Match 'ChannelA-DIMM1'
    }

    It 'says so when the memory class throws' {
        $lines = @(Get-WtMemoryModuleLines -GetModules { throw 'Generic failure' } -GetArrays { @() })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'MemoryModuleNotAvailable')
    }

    It 'says so when the memory class returns nothing' {
        $lines = @(Get-WtMemoryModuleLines -GetModules { @() } -GetArrays { $script:FourSlotArray })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'MemoryModuleNotAvailable')
    }

    It 'falls back to MemoryType and prints an unrecognised type code raw' {
        $lines = @(Get-WtMemoryModuleLines -GetModules { @(
                    [PSCustomObject]@{ BankLabel = 'BANK 0'; Capacity = 4GB; Speed = 1600; SMBIOSMemoryType = 0; MemoryType = 24; PartNumber = 'HMT351' }
                    [PSCustomObject]@{ BankLabel = 'BANK 1'; Capacity = 4GB; Speed = 1600; SMBIOSMemoryType = 99; MemoryType = 0; PartNumber = 'HMT351' }
                ) } -GetArrays { @() })
        $lines[1] | Should -Match 'DDR3'
        $lines[2] | Should -Match ([regex]::Escape(((Get-Translation 'MemoryModuleTypeUnknown') -f 99)))
    }

    It 'still lists the sticks when the memory array class throws' {
        $lines = @(Get-WtMemoryModuleLines -GetModules { $script:TwoSticks } -GetArrays { throw 'Generic failure' })
        $lines[1] | Should -Match 'BANK 0'
        $lines[-1] | Should -Be (Get-Translation 'MemoryModuleSlotsUnknown')
    }

    It 'renders every slot full differently from the free-slot case' {
        $script:TwoSlotFullArray = @([PSCustomObject]@{ MemoryDevices = 2; MaxCapacityEx = 134217728 })
        $lines = @(Get-WtMemoryModuleLines -GetModules { $script:TwoSticks } -GetArrays { $script:TwoSlotFullArray })
        $lines | Should -Contain ((Get-Translation 'MemoryModuleSlotsLine') -f 2, 0)
        $lines | Should -Not -Contain ((Get-Translation 'MemoryModuleSlotsLine') -f 4, 2)
    }

    It 'clamps the free slot count to 0 when the firmware reports fewer slots than installed modules' {
        $script:UnderReportedArray = @([PSCustomObject]@{ MemoryDevices = 1; MaxCapacityEx = 134217728 })
        $lines = @(Get-WtMemoryModuleLines -GetModules { $script:TwoSticks } -GetArrays { $script:UnderReportedArray })
        $lines | Should -Contain ((Get-Translation 'MemoryModuleSlotsLine') -f 1, 0)
        $lines | Should -Not -Contain ((Get-Translation 'MemoryModuleSlotsLine') -f 1, -1)
        $lines | Should -Not -Match '-1 '
    }
}

Describe 'ConvertTo-WtVramByteCount' {
    It 'takes the REG_QWORD Int64 form as it stands' {
        ConvertTo-WtVramByteCount -Value ([long]8589934592) | Should -Be 8589934592
    }

    It 'decodes the REG_BINARY form Intel and older WDDM drivers write' {
        ConvertTo-WtVramByteCount -Value ([byte[]]@(0, 0, 0, 0, 2, 0, 0, 0)) | Should -Be 8589934592
    }

    It 'decodes a short byte array without reading past its end' {
        ConvertTo-WtVramByteCount -Value ([byte[]]@(0, 0, 0, 64)) | Should -Be 1073741824
    }

    It 'returns 0 for a missing or unparsable value instead of throwing' {
        ConvertTo-WtVramByteCount -Value $null | Should -Be 0
        ConvertTo-WtVramByteCount -Value 'n/a' | Should -Be 0
    }
}

Describe 'Get-WtGpuDriverLines' {
    BeforeAll {
        $script:Adapters = @(
            [PSCustomObject]@{ Name = 'NVIDIA GeForce RTX 3060'; DriverVersion = '31.0.15.3623'; DriverDate = [datetime]'2023-05-11'; CurrentHorizontalResolution = 2560; CurrentVerticalResolution = 1440; CurrentRefreshRate = 144 }
            [PSCustomObject]@{ Name = 'Intel(R) UHD Graphics 630'; DriverVersion = '27.20.100.9316'; DriverDate = [datetime]'2021-02-02'; CurrentHorizontalResolution = $null; CurrentVerticalResolution = $null; CurrentRefreshRate = $null }
        )
        $script:VramEntries = @(
            [PSCustomObject]@{ DriverDesc = 'NVIDIA GeForce RTX 3060'; Bytes = 12884901888 }
            [PSCustomObject]@{ DriverDesc = 'Intel(R) UHD Graphics 630'; Bytes = 1073741824 }
        )
    }

    It 'prints VRAM, driver version, driver date and the active mode for each adapter' {
        $lines = @(Get-WtGpuDriverLines -GetControllers { $script:Adapters } -GetVramEntries { $script:VramEntries })
        $lines[0] | Should -Be ((Get-Translation 'GpuDriverNameLine') -f 'NVIDIA GeForce RTX 3060')
        $lines[1] | Should -Be ((Get-Translation 'GpuDriverVramLine') -f '12.0 GB')
        $lines[2] | Should -Be ((Get-Translation 'GpuDriverVersionLine') -f '31.0.15.3623', '2023-05-11')
        $lines[3] | Should -Be ((Get-Translation 'GpuDriverModeLine') -f 2560, 1440, 144)
    }

    It 'says the display mode is not active when the adapter reports no resolution' {
        $lines = @(Get-WtGpuDriverLines -GetControllers { $script:Adapters } -GetVramEntries { $script:VramEntries })
        $lines[-1] | Should -Be (Get-Translation 'GpuDriverModeInactive')
    }

    It 'falls back to the adapter position when DriverDesc does not match the CIM name' {
        $lines = @(Get-WtGpuDriverLines -GetControllers { @($script:Adapters[0]) } -GetVramEntries { @([PSCustomObject]@{ DriverDesc = 'NVIDIA GeForce RTX 3060 Laptop GPU'; Bytes = 6442450944 }) })
        $lines[1] | Should -Be ((Get-Translation 'GpuDriverVramLine') -f '6.0 GB')
    }

    It 'says so when no display adapter can be read' {
        $lines = @(Get-WtGpuDriverLines -GetControllers { throw 'Generic failure' } -GetVramEntries { @() })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'GpuDriverNotAvailable')
    }

    It 'still prints the adapter when the display class key is unreadable' {
        $lines = @(Get-WtGpuDriverLines -GetControllers { @($script:Adapters[0]) } -GetVramEntries { throw 'access denied' })
        $lines[1] | Should -Be ((Get-Translation 'GpuDriverVramLine') -f (Get-Translation 'GpuDriverVramUnknown'))
    }
}

Describe 'Get-WtBatteryHealthLines' {
    BeforeAll {
        $script:OneBattery = @([PSCustomObject]@{ Name = 'NVT-45N1'; EstimatedChargeRemaining = 87 })
        $script:Report = [xml]@'
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <Batteries>
    <Battery>
      <Id>NVT-45N1</Id>
      <DesignCapacity>45000</DesignCapacity>
      <FullChargeCapacity>39150</FullChargeCapacity>
      <CycleCount>128</CycleCount>
    </Battery>
  </Batteries>
</BatteryReport>
'@
        $script:TwoPackReport = [xml]@'
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <Batteries>
    <Battery><Id>PACK-1</Id><DesignCapacity>24000</DesignCapacity><FullChargeCapacity>21000</FullChargeCapacity><CycleCount>44</CycleCount></Battery>
    <Battery><Id>PACK-2</Id><DesignCapacity>24000</DesignCapacity><FullChargeCapacity>19200</FullChargeCapacity><CycleCount>61</CycleCount></Battery>
  </Batteries>
</BatteryReport>
'@
    }

    It 'reports charge, design and full-charge capacity, wear and cycle count' {
        $lines = @(Get-WtBatteryHealthLines -GetBatteries { $script:OneBattery } -GetBatteryReport { $script:Report })
        $lines[0] | Should -Be ((Get-Translation 'BatteryChargeLine') -f 87)
        $lines[1] | Should -Be ((Get-Translation 'BatteryNameLine') -f 'NVT-45N1')
        $lines[2] | Should -Be ((Get-Translation 'BatteryDesignLine') -f 45000)
        $lines[3] | Should -Be ((Get-Translation 'BatteryFullChargeLine') -f 39150)
        $lines[4] | Should -Be ((Get-Translation 'BatteryWearLine') -f '13.0')
        $lines[5] | Should -Be ((Get-Translation 'BatteryCycleLine') -f 128)
    }

    It 'says there is no battery when the source throws Generic failure - the desktop case' {
        $lines = @(Get-WtBatteryHealthLines -GetBatteries { throw 'Generic failure' } -GetBatteryReport { $script:Report })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'BatteryNotFound')
    }

    It 'says there is no battery when the class returns no instance' {
        $lines = @(Get-WtBatteryHealthLines -GetBatteries { @() } -GetBatteryReport { $script:Report })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'BatteryNotFound')
    }

    It 'never divides when the design capacity is 0' {
        $script:ZeroDesignReport = [xml]'<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012"><Batteries><Battery><Id>X</Id><DesignCapacity>0</DesignCapacity><FullChargeCapacity>39150</FullChargeCapacity></Battery></Batteries></BatteryReport>'
        $lines = @(Get-WtBatteryHealthLines -GetBatteries { $script:OneBattery } -GetBatteryReport { $script:ZeroDesignReport })
        $lines | Should -Contain (Get-Translation 'BatteryWearUnknown')
        $lines | Should -Contain (Get-Translation 'BatteryCycleUnknown')
    }

    It 'says the report is unreadable when powercfg produced nothing' {
        $lines = @(Get-WtBatteryHealthLines -GetBatteries { $script:OneBattery } -GetBatteryReport { $null })
        $lines[-1] | Should -Be (Get-Translation 'BatteryReportUnavailable')
        $failed = @(Get-WtBatteryHealthLines -GetBatteries { $script:OneBattery } -GetBatteryReport { throw 'powercfg exploded' })
        $failed[-1] | Should -Be (Get-Translation 'BatteryReportUnavailable')
    }

    It 'writes one block per battery pack instead of dividing an array' {
        $lines = @(Get-WtBatteryHealthLines -GetBatteries { $script:OneBattery } -GetBatteryReport { $script:TwoPackReport })
        @($lines | Where-Object { $_ -clike ((Get-Translation 'BatteryNameLine') -f '*') }).Count | Should -Be 2
        $lines | Should -Contain ((Get-Translation 'BatteryWearLine') -f '12.5')
        $lines | Should -Contain ((Get-Translation 'BatteryWearLine') -f '20.0')
    }
}

Describe 'Get-WtProblemDeviceLines' {
    BeforeAll {
        $script:BadDevices = @(
            [PSCustomObject]@{ Name = 'PCI Simple Communications Controller'; ConfigManagerErrorCode = 28; DeviceID = 'PCI\VEN_8086&DEV_A360&SUBSYS_86941043&REV_00\3&11583659&0&B0' }
            [PSCustomObject]@{ Name = 'Realtek USB Card Reader'; ConfigManagerErrorCode = 22; DeviceID = 'USB\VID_0BDA&PID_0129\20100201396000000' }
        )
    }

    It 'lists each flagged device, lowest error code first, with the code in plain language' {
        $lines = @(Get-WtProblemDeviceLines -GetDevices { $script:BadDevices })
        $lines[0] | Should -Be ((Get-Translation 'ProblemDeviceCountLine') -f 2)
        $lines[1] | Should -Be ('  22 - ' + (Get-Translation 'ProblemDeviceCode22'))
        $lines[2] | Should -Be '    Realtek USB Card Reader'
        $lines[3] | Should -Be '    USB\VID_0BDA&PID_0129\20100201396000000'
        $lines[4] | Should -Be ('  28 - ' + (Get-Translation 'ProblemDeviceCode28'))
        $lines[5] | Should -Be '    PCI Simple Communications Controller'
    }

    It 'says nothing is wrong when the query returns no device' {
        $lines = @(Get-WtProblemDeviceLines -GetDevices { @() })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'ProblemDeviceNone')
    }

    It 'says so when the query itself cannot run' {
        $lines = @(Get-WtProblemDeviceLines -GetDevices { throw 'Generic failure' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'ProblemDeviceNotAvailable')
    }

    It 'prints an error code it has no wording for with the number itself' {
        $lines = @(Get-WtProblemDeviceLines -GetDevices { @([PSCustomObject]@{ Name = 'Mystery device'; ConfigManagerErrorCode = 99; DeviceID = 'ROOT\UNKNOWN\0000' }) })
        $lines[1] | Should -Be ('  99 - ' + ((Get-Translation 'ProblemDeviceCodeUnknown') -f 99))
    }

    It 'trims a long DeviceID so no line passes 95 columns' {
        $longId = 'PCI\VEN_10DE&DEV_1F08&SUBSYS_86A31043&REV_A1\4&2F1E3B5C&0&0008' + ('X' * 90)
        $lines = @(Get-WtProblemDeviceLines -GetDevices { @([PSCustomObject]@{ Name = 'Device with a very long instance path'; ConfigManagerErrorCode = 43; DeviceID = $longId }) })
        (@($lines | ForEach-Object { $_.Length }) | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 95
        $lines[-1] | Should -Match '~$'
    }

    It 'queries with the WQL <> operator, never the PowerShell -ne' {
        $definition = (Get-Command Get-WtProblemDeviceLines).Definition
        $definition | Should -Match ([regex]::Escape('ConfigManagerErrorCode <> 0'))
        $definition | Should -Not -Match ([regex]::Escape('ConfigManagerErrorCode -ne'))
    }
}

Describe 'The Hardware group carries the four new rows' {
    BeforeAll {
        $script:HardwareRows = @(& (@(Get-WtInfoToolGroups) | Where-Object { $_.HeaderKey -eq 'InfoGroupHardware' }).GetRows)
        $script:NewNames = @('MemoryModuleReport', 'GpuDriverDetails', 'BatteryHealthReport', 'ProblemDeviceReport')
    }

    It 'places them in catalogue order inside the group' {
        $names = @($script:HardwareRows | ForEach-Object Name)
        $names.IndexOf('MemoryModuleReport') | Should -BeGreaterThan ($names.IndexOf('ShowRAMUsage'))
        $names.IndexOf('GpuDriverDetails') | Should -BeGreaterThan ($names.IndexOf('ShowCPUInfo'))
        $names.IndexOf('BatteryHealthReport') | Should -Be (($names.IndexOf('GpuDriverDetails')) + 1)
        $names.IndexOf('ProblemDeviceReport') | Should -Be (($names.IndexOf('BatteryHealthReport')) + 1)
        $names.IndexOf('ProblemDeviceReport') | Should -BeLessThan ($names.IndexOf('ShowPrinterStatus'))
    }

    It 'declares each as a captured row whose label resolves in both dictionaries' {
        foreach ($name in $script:NewNames) {
            $row = @($script:HardwareRows | Where-Object { $_.Name -ceq $name })[0]
            $row | Should -Not -BeNullOrEmpty -Because "$name must be on the Hardware group"
            $row.Kind | Should -Be 'Action'
            $row.Data.Captured | Should -BeTrue
            $script:Translations['EN'].ContainsKey($name) | Should -BeTrue -Because "EN needs '$name'"
            $script:Translations['TR'].ContainsKey($name) | Should -BeTrue -Because "TR needs '$name'"
            $script:Translations['EN'][$name] | Should -Not -Be $script:Translations['TR'][$name]
            ([string]$script:Translations['EN'][$name]).Length | Should -BeLessOrEqual 45
            ([string]$script:Translations['TR'][$name]).Length | Should -BeLessOrEqual 45
        }
    }

    It 'keeps the four row scriptblocks free of write verbs and of Read-Host' {
        $denylist = @('Set-', 'Remove-', 'Stop-', 'Start-', 'Restart-', 'New-', 'Clear-', 'Disable-', 'Enable-', 'Read-Host')
        foreach ($name in $script:NewNames) {
            $text = [string](@($script:HardwareRows | Where-Object { $_.Name -ceq $name })[0].Data.Action)
            foreach ($verb in $denylist) {
                $text | Should -Not -BeLike ('*' + $verb + '*') -Because "$name is an information row and must not change state"
            }
        }
    }

    It 'reads hardware through CIM, never Get-WmiObject and never Win32_Product' {
        foreach ($fn in @('Get-WtMemoryModuleLines', 'Get-WtGpuDriverLines', 'Get-WtGpuVramEntries', 'Get-WtBatteryHealthLines', 'Get-WtBatteryReportXml', 'Get-WtProblemDeviceLines')) {
            $definition = (Get-Command $fn).Definition
            $definition | Should -Not -Match 'Get-WmiObject' -Because "$fn must work under PowerShell 7 too"
            $definition | Should -Not -Match 'Win32_Product' -Because "$fn must never trigger an MSI reconfiguration"
        }
    }

    It 'shows the four rows exactly once on the flattened Information screen' {
        $items = @(Get-WtInfoToolsItems)
        foreach ($name in $script:NewNames) {
            @($items | Where-Object { $_.Name -ceq $name }).Count | Should -Be 1
        }
    }
}
