#Requires -Modules Pester

<#
.SYNOPSIS
    The four rows that absorb seven older ones: the IP configuration
    summary, the listening-port table with owning processes, the
    board/BIOS report, and the release+renew lease row. -GetEnclosure
    runs last in the BIOS report, so an unguarded throw there used to
    lose the whole report rather than just the chassis line.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtIpConfigSummaryLines' {
    It 'prints address, gateway and DNS for each adapter' {
        $fake = {
            @([PSCustomObject]@{
                InterfaceAlias    = 'Ethernet'
                IPv4Address       = @([PSCustomObject]@{ IPAddress = '192.168.1.24'; PrefixLength = 24 })
                IPv4DefaultGateway = @([PSCustomObject]@{ NextHop = '192.168.1.1' })
                DNSServer         = @([PSCustomObject]@{ AddressFamily = 2; ServerAddresses = @('1.1.1.1', '1.0.0.1') })
            })
        }
        $lines = @(Get-WtIpConfigSummaryLines -GetConfiguration $fake)
        $lines[0] | Should -Be 'Ethernet'
        ($lines -join "`n") | Should -Match '192\.168\.1\.24/24'
        ($lines -join "`n") | Should -Match '192\.168\.1\.1'
        ($lines -join "`n") | Should -Match '1\.1\.1\.1, 1\.0\.0\.1'
    }

    It 'says so when the adapter has only IPv6 DNS instead of printing a blank cell' {
        $fake = {
            @([PSCustomObject]@{
                InterfaceAlias    = 'Wi-Fi'
                IPv4Address       = @([PSCustomObject]@{ IPAddress = '10.0.0.5'; PrefixLength = 24 })
                IPv4DefaultGateway = $null
                DNSServer         = @([PSCustomObject]@{ AddressFamily = 23; ServerAddresses = @('fe80::1') })
            })
        }
        $lines = @(Get-WtIpConfigSummaryLines -GetConfiguration $fake)
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'DnsIpv6Only')))
    }

    It 'reports honestly when there is no adapter at all' {
        $lines = @(Get-WtIpConfigSummaryLines -GetConfiguration { @() })
        $lines | Should -Be @((Get-Translation 'NoNetworkAdapterFound'))
    }

    It 'reports honestly, instead of leaking a raw exception, when the source throws' {
        $lines = @(Get-WtIpConfigSummaryLines -GetConfiguration { throw [System.Management.Automation.CommandNotFoundException] 'The term Get-NetIPConfiguration is not recognized' })
        $lines | Should -Be @((Get-Translation 'NoNetworkAdapterFound'))
    }
}

Describe 'Get-WtListeningPortLines' {
    BeforeAll {
        $script:fakeProcs = { @(
            [PSCustomObject]@{ Id = 4;    ProcessName = 'System' }
            [PSCustomObject]@{ Id = 1820; ProcessName = 'svchost' }
        ) }
    }

    It 'joins every listening port to the program that owns it' {
        $listeners = { @(
            [PSCustomObject]@{ LocalPort = 445;  OwningProcess = 4 }
            [PSCustomObject]@{ LocalPort = 135;  OwningProcess = 1820 }
        ) }
        $lines = @(Get-WtListeningPortLines -GetListeners $listeners -GetProcesses $fakeProcs)
        ($lines -join "`n") | Should -Match '135\s+1820\s+svchost'
        ($lines -join "`n") | Should -Match '445\s+4\s+System'
    }

    It 'sorts by port so the table reads in order' {
        $listeners = { @(
            [PSCustomObject]@{ LocalPort = 445;  OwningProcess = 4 }
            [PSCustomObject]@{ LocalPort = 135;  OwningProcess = 1820 }
        ) }
        $lines = @(Get-WtListeningPortLines -GetListeners $listeners -GetProcesses $fakeProcs)
        $lines[1] | Should -Match '^135'
        $lines[2] | Should -Match '^445'
    }

    It 'prints a listener once even though it is reported per address family' {
        $listeners = { @(
            [PSCustomObject]@{ LocalPort = 135; OwningProcess = 1820 }
            [PSCustomObject]@{ LocalPort = 135; OwningProcess = 1820 }
        ) }
        $lines = @(Get-WtListeningPortLines -GetListeners $listeners -GetProcesses $fakeProcs)
        @($lines | Where-Object { $_ -match '^135' }).Count | Should -Be 1
    }

    It 'names the process as unknown rather than blank when the PID has gone' {
        $listeners = { @([PSCustomObject]@{ LocalPort = 9999; OwningProcess = 31337 }) }
        $lines = @(Get-WtListeningPortLines -GetListeners $listeners -GetProcesses $fakeProcs)
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'UnknownProcess')))
    }

    It 'reports honestly when nothing is listening' {
        $lines = @(Get-WtListeningPortLines -GetListeners { @() } -GetProcesses $fakeProcs)
        $lines | Should -Be @((Get-Translation 'NoListeningPort'))
    }

    It 'reports honestly, instead of leaking a raw exception, when the listener source throws' {
        $lines = @(Get-WtListeningPortLines -GetListeners { throw [System.Management.Automation.CommandNotFoundException] 'The term Get-NetTCPConnection is not recognized' } -GetProcesses $fakeProcs)
        $lines | Should -Be @((Get-Translation 'NoListeningPort'))
    }
}

Describe 'Get-WtMotherboardBiosLines' {
    It 'prints board, BIOS and chassis, absorbing the old serial-number row' {
        $board = { [PSCustomObject]@{ Manufacturer = 'ASUSTeK COMPUTER INC. '; Product = 'PRIME B450M-A '; Version = 'Rev X.0x '; SerialNumber = ' 190123456789 ' } }
        $bios  = { [PSCustomObject]@{ Manufacturer = 'American Megatrends Inc.'; SMBIOSBIOSVersion = '3211 '; ReleaseDate = [datetime]'2021-04-16'; SerialNumber = 'SYS-9988 ' } }
        $encl  = { [PSCustomObject]@{ ChassisTypes = @(3) } }
        $text = (@(Get-WtMotherboardBiosLines -GetBoard $board -GetBios $bios -GetEnclosure $encl)) -join "`n"

        $text | Should -Match 'ASUSTeK COMPUTER INC\.'
        $text | Should -Match 'PRIME B450M-A'
        $text | Should -Match '3211'
        $text | Should -Match '2021-04-16'
        $text | Should -Match 'SYS-9988'
        $text | Should -Match 'Desktop'
    }

    It 'trims the space padding SMBIOS leaves on every string' {
        $board = { [PSCustomObject]@{ Manufacturer = 'ACME '; Product = 'B1 '; Version = ' '; SerialNumber = ' ' } }
        $bios  = { [PSCustomObject]@{ Manufacturer = 'ACME'; SMBIOSBIOSVersion = 'F2 '; ReleaseDate = [datetime]'2020-01-02'; SerialNumber = 'X1 ' } }
        $text = (@(Get-WtMotherboardBiosLines -GetBoard $board -GetBios $bios -GetEnclosure { $null })) -join "`n"
        $text | Should -Not -Match 'ACME  '
        $text | Should -Match 'X1'
    }

    It 'prints the raw chassis number when the code is not one it knows' {
        $board = { [PSCustomObject]@{ Manufacturer = 'ACME'; Product = 'B1'; Version = '1'; SerialNumber = 'S' } }
        $bios  = { [PSCustomObject]@{ Manufacturer = 'ACME'; SMBIOSBIOSVersion = 'F2'; ReleaseDate = [datetime]'2020-01-02'; SerialNumber = 'X1' } }
        $text = (@(Get-WtMotherboardBiosLines -GetBoard $board -GetBios $bios -GetEnclosure { [PSCustomObject]@{ ChassisTypes = @(97) } })) -join "`n"
        $text | Should -Match '97'
    }

    It 'skips the release date rather than printing an empty one on a VM' {
        $board = { [PSCustomObject]@{ Manufacturer = 'Microsoft Corporation'; Product = 'Virtual Machine'; Version = '7.0'; SerialNumber = '0000' } }
        $bios  = { [PSCustomObject]@{ Manufacturer = 'Microsoft'; SMBIOSBIOSVersion = 'Hyper-V'; ReleaseDate = $null; SerialNumber = '0000' } }
        $lines = @(Get-WtMotherboardBiosLines -GetBoard $board -GetBios $bios -GetEnclosure { $null })
        @($lines | Where-Object { $_ -match 'BIOS Date' }).Count | Should -Be 0
    }

    It 'reports honestly when SMBIOS gives nothing back' {
        $lines = @(Get-WtMotherboardBiosLines -GetBoard { $null } -GetBios { $null } -GetEnclosure { $null })
        $lines | Should -Be @((Get-Translation 'BiosInfoUnavailable'))
    }

    It 'keeps the board and BIOS lines even when the enclosure source throws AFTER they are built' {
        $board = { [PSCustomObject]@{ Manufacturer = 'ASUSTeK COMPUTER INC.'; Product = 'PRIME B450M-A'; Version = 'Rev X.0x'; SerialNumber = '190123456789' } }
        $bios  = { [PSCustomObject]@{ Manufacturer = 'American Megatrends Inc.'; SMBIOSBIOSVersion = '3211'; ReleaseDate = [datetime]'2021-04-16'; SerialNumber = 'SYS-9988' } }
        $text = (@(Get-WtMotherboardBiosLines -GetBoard $board -GetBios $bios -GetEnclosure { throw [System.Management.Automation.CommandNotFoundException] 'Get-CimInstance is not recognized' })) -join "`n"
        $text | Should -Match 'ASUSTeK COMPUTER INC\.'
        $text | Should -Match 'SYS-9988'
    }

    It 'reports honestly, instead of leaking a raw exception, when both the board and BIOS sources throw' {
        $lines = @(Get-WtMotherboardBiosLines -GetBoard { throw 'WMI repository is inconsistent' } -GetBios { throw 'WMI repository is inconsistent' } -GetEnclosure { $null })
        $lines | Should -Be @((Get-Translation 'BiosInfoUnavailable'))
    }
}
