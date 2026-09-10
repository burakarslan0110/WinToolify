#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the seven Information Tools > Network rows and the pure
    Get-Wt*Lines functions behind them. Every Windows data source is
    injected as a scriptblock - no test here touches the real network, the
    real registry or the real hosts file.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtNetworkAdapterLines' {
    BeforeAll {
        $script:AdapterFixture = {
            @(
                [PSCustomObject]@{ Name = 'Wi-Fi'; Status = 'Disconnected'; LinkSpeed = '0 bps'; MacAddress = '90-E8-68-42-92-73'; MediaType = 'Native 802.11' }
                [PSCustomObject]@{ Name = 'Ethernet'; Status = 'Up'; LinkSpeed = '100 Mbps'; MacAddress = '00-11-22-33-44-55'; MediaType = '802.3' }
            )
        }
    }

    It 'lists every adapter with its status, link speed, MAC and media type' {
        $lines = @(Get-WtNetworkAdapterLines -GetAdapters $AdapterFixture)
        ($lines -join "`n") | Should -Match 'Ethernet'
        ($lines -join "`n") | Should -Match '100 Mbps'
        ($lines -join "`n") | Should -Match '00-11-22-33-44-55'
        ($lines -join "`n") | Should -Match '802\.3'
    }

    It 'puts connected adapters first - a plain Sort-Object Status would put Disconnected before Up' {
        $lines = @(Get-WtNetworkAdapterLines -GetAdapters $AdapterFixture)
        $upIndex = ($lines | Select-String -SimpleMatch 'Ethernet' | Select-Object -First 1).LineNumber
        $downIndex = ($lines | Select-String -SimpleMatch 'Wi-Fi' | Select-Object -First 1).LineNumber
        $upIndex | Should -BeLessThan $downIndex
    }

    It 'adds the synthetic-speed note only when a Hyper-V vEthernet adapter is present' {
        $withVirtual = { @([PSCustomObject]@{ Name = 'vEthernet (Wi-Fi)'; Status = 'Up'; LinkSpeed = '10 Gbps'; MacAddress = '00-15-5D-05-9E-D3'; MediaType = '802.3' }) }
        @(Get-WtNetworkAdapterLines -GetAdapters $withVirtual) | Should -Contain (Get-Translation 'NetAdapterVirtualNote')
        @(Get-WtNetworkAdapterLines -GetAdapters $AdapterFixture) | Should -Not -Contain (Get-Translation 'NetAdapterVirtualNote')
    }

    It 'says so when there is no adapter at all' {
        @(Get-WtNetworkAdapterLines -GetAdapters { @() }) | Should -Be @((Get-Translation 'NetAdapterNoneFound'))
    }

    It 'says so when the adapter source throws' {
        @(Get-WtNetworkAdapterLines -GetAdapters { throw 'Generic failure' }) | Should -Be @((Get-Translation 'NetAdapterNoneFound'))
    }
}

Describe 'Get-WtWifiLinkLines' {
    It 'prints a translated line and never calls netsh when WlanSvc is not running' {
        $script:NetshCalled = $false
        $lines = @(Get-WtWifiLinkLines -GetWlanServiceStatus { 'Stopped' } -GetInterfaceOutput { $script:NetshCalled = $true; @('should not happen') })
        $lines | Should -Be @((Get-Translation 'WifiServiceNotRunning'))
        $script:NetshCalled | Should -BeFalse
    }

    It 'treats a missing service (null status) as "no wireless adapter"' {
        @(Get-WtWifiLinkLines -GetWlanServiceStatus { $null } -GetInterfaceOutput { @('x') }) | Should -Be @((Get-Translation 'WifiServiceNotRunning'))
    }

    It 'passes the netsh interface report through when the service is running' {
        $netsh = {
            @(
                ''
                'There is 1 interface on the system: '
                ''
                '    Name                   : Wi-Fi'
                '    State                  : connected'
                '    SSID                   : 2042'
                '    Radio type             : 802.11ax'
                '    Channel                : 9'
                '    Receive rate (Mbps)    : 286.8'
                '    Transmit rate (Mbps)   : 286.8'
                '    Signal                 : 79% '
                ''
            )
        }
        $lines = @(Get-WtWifiLinkLines -GetWlanServiceStatus { 'Running' } -GetInterfaceOutput $netsh)
        ($lines -join "`n") | Should -Match 'SSID'
        ($lines -join "`n") | Should -Match '802\.11ax'
        ($lines -join "`n") | Should -Match '79%'
        $lines | Should -Not -Contain ''
    }

    It 'says so when the service runs but netsh returns nothing' {
        @(Get-WtWifiLinkLines -GetWlanServiceStatus { 'Running' } -GetInterfaceOutput { @() }) | Should -Be @((Get-Translation 'WifiLinkNoOutput'))
    }

    It 'says so when netsh throws' {
        @(Get-WtWifiLinkLines -GetWlanServiceStatus { 'Running' } -GetInterfaceOutput { throw 'netsh exploded' }) | Should -Be @((Get-Translation 'WifiLinkNoOutput'))
    }
}

Describe 'Get-WtFirewallActionText' {
    It 'translates Allow and Block' {
        Get-WtFirewallActionText -Action 'Allow' -Direction 'Outbound' | Should -Be (Get-Translation 'FirewallActionAllow')
        Get-WtFirewallActionText -Action 'Block' -Direction 'Inbound' | Should -Be (Get-Translation 'FirewallActionBlock')
    }

    It 'never prints a bare NotConfigured - it spells out the effective Windows default' {
        $inbound = Get-WtFirewallActionText -Action 'NotConfigured' -Direction 'Inbound'
        $outbound = Get-WtFirewallActionText -Action 'NotConfigured' -Direction 'Outbound'
        $inbound | Should -Not -Be 'NotConfigured'
        $inbound | Should -Match ([regex]::Escape((Get-Translation 'FirewallActionBlock')))
        $outbound | Should -Match ([regex]::Escape((Get-Translation 'FirewallActionAllow')))
    }

    It 'treats an empty action the same way as NotConfigured' {
        Get-WtFirewallActionText -Action '' -Direction 'Inbound' | Should -Be (Get-WtFirewallActionText -Action 'NotConfigured' -Direction 'Inbound')
    }
}

Describe 'Get-WtNetworkProfileLines' {
    BeforeAll {
        $script:ProfileFixture = {
            @([PSCustomObject]@{ Name = '2042'; InterfaceAlias = 'Wi-Fi'; NetworkCategory = 'Public'; IPv4Connectivity = 'Internet'; IPv6Connectivity = 'NoTraffic' })
        }
        $script:FirewallFixture = {
            @(
                [PSCustomObject]@{ Name = 'Domain'; Enabled = $true; DefaultInboundAction = 'NotConfigured'; DefaultOutboundAction = 'NotConfigured' }
                [PSCustomObject]@{ Name = 'Private'; Enabled = $true; DefaultInboundAction = 'Block'; DefaultOutboundAction = 'Allow' }
                [PSCustomObject]@{ Name = 'Public'; Enabled = $false; DefaultInboundAction = 'Block'; DefaultOutboundAction = 'Allow' }
            )
        }
    }

    It 'shows whether the network is Public or Private and whether Windows really sees the internet' {
        $text = @(Get-WtNetworkProfileLines -GetConnectionProfiles $ProfileFixture -GetFirewallProfiles $FirewallFixture) -join "`n"
        $text | Should -Match '2042'
        $text | Should -Match 'Public'
        $text | Should -Match 'Internet'
        $text | Should -Match 'NoTraffic'
    }

    It 'shows each firewall profile as on or off' {
        $text = @(Get-WtNetworkProfileLines -GetConnectionProfiles $ProfileFixture -GetFirewallProfiles $FirewallFixture) -join "`n"
        $text | Should -Match ('Domain: ' + [regex]::Escape((Get-Translation 'FirewallProfileOn')))
        $text | Should -Match ('Public: ' + [regex]::Escape((Get-Translation 'FirewallProfileOff')))
    }

    It 'never leaks the raw word NotConfigured into the panel' {
        $text = @(Get-WtNetworkProfileLines -GetConnectionProfiles $ProfileFixture -GetFirewallProfiles $FirewallFixture) -join "`n"
        $text | Should -Not -Match 'NotConfigured'
    }

    It 'says so when there is no active profile and no readable firewall state' {
        $lines = @(Get-WtNetworkProfileLines -GetConnectionProfiles { @() } -GetFirewallProfiles { @() })
        $lines | Should -Contain (Get-Translation 'NetProfileNoneFound')
        $lines | Should -Contain ('  ' + (Get-Translation 'FirewallProfilesNotAvailable'))
    }

    It 'degrades to the same lines when both sources throw' {
        $lines = @(Get-WtNetworkProfileLines -GetConnectionProfiles { throw 'no profile' } -GetFirewallProfiles { throw 'no firewall' })
        $lines | Should -Contain (Get-Translation 'NetProfileNoneFound')
        $lines | Should -Contain ('  ' + (Get-Translation 'FirewallProfilesNotAvailable'))
    }

    It 'renders the firewall defaults in Turkish when the language is TR' {
        $previous = $script:Language
        try {
            $script:Language = 'TR'
            $text = @(Get-WtNetworkProfileLines -GetConnectionProfiles $ProfileFixture -GetFirewallProfiles $FirewallFixture) -join "`n"
            $text | Should -Match ([regex]::Escape((Get-Translation 'FirewallProfilesHeader')))
            $text | Should -Not -Match 'NotConfigured'
        }
        finally { $script:Language = $previous }
    }
}

Describe 'Format-WtRemoteEndpoint' {
    It 'renders an IPv4 endpoint as address:port' {
        Format-WtRemoteEndpoint -Address '160.79.104.10' -Port 443 | Should -Be '160.79.104.10:443'
    }

    It 'brackets an IPv6 endpoint and trims it visibly instead of silently' {
        $text = Format-WtRemoteEndpoint -Address '2a00:1450:4001:0828:0000:0000:0000:200e' -Port 443 -MaxAddressLength 24
        $text | Should -Match '^\['
        $text | Should -Match '\]:443$'
        $text | Should -Match '\.\.\.'
        $text.Length | Should -BeLessThan 34
    }

    It 'leaves a short IPv6 address whole' {
        Format-WtRemoteEndpoint -Address '::1' -Port 5357 | Should -Be '[::1]:5357'
    }
}

Describe 'Get-WtActiveConnectionLines' {
    BeforeAll {
        $script:ConnFixture = {
            @(
                [PSCustomObject]@{ LocalAddress = '192.168.1.188'; LocalPort = 52577; RemoteAddress = '160.79.104.10'; RemotePort = 443; OwningProcess = 10440 }
                [PSCustomObject]@{ LocalAddress = '192.168.1.188'; LocalPort = 52576; RemoteAddress = '160.79.104.10'; RemotePort = 443; OwningProcess = 10440 }
                [PSCustomObject]@{ LocalAddress = '192.168.1.188'; LocalPort = 52580; RemoteAddress = '20.42.65.92'; RemotePort = 443; OwningProcess = 10440 }
                [PSCustomObject]@{ LocalAddress = '127.0.0.1'; LocalPort = 55927; RemoteAddress = '127.0.0.1'; RemotePort = 52026; OwningProcess = 1848 }
                [PSCustomObject]@{ LocalAddress = '192.168.1.188'; LocalPort = 52590; RemoteAddress = '13.107.42.14'; RemotePort = 443; OwningProcess = 99999 }
            )
        }
        $script:ProcFixture = {
            @(
                [PSCustomObject]@{ Id = 10440; ProcessName = 'msedge' }
                [PSCustomObject]@{ Id = 1848; ProcessName = 'svchost' }
            )
        }
    }

    It 'summarises per program: connection count and distinct remote hosts' {
        $lines = @(Get-WtActiveConnectionLines -GetConnections $ConnFixture -GetProcesses $ProcFixture)
        $lines | Should -Contain (Get-Translation 'ActiveConnSummaryHeader')
        $lines | Should -Contain ('  ' + ((Get-Translation 'ActiveConnSummaryLine') -f 'msedge', 3, 2))
        $lines | Should -Contain ('  ' + ((Get-Translation 'ActiveConnSummaryLine') -f 'svchost', 1, 1))
    }

    It 'names an unmapped PID rather than printing an empty owner' {
        $text = @(Get-WtActiveConnectionLines -GetConnections $ConnFixture -GetProcesses $ProcFixture) -join "`n"
        $text | Should -Match ([regex]::Escape((Get-Translation 'ActiveConnUnknownProcess')))
    }

    It 'lists the detail rows with the owning app and the remote endpoint' {
        $text = @(Get-WtActiveConnectionLines -GetConnections $ConnFixture -GetProcesses $ProcFixture) -join "`n"
        $text | Should -Match 'msedge \(10440\) -> 160\.79\.104\.10:443'
    }

    It 'caps the detail table and says how many rows it left out' {
        $many = {
            @(1..35 | ForEach-Object {
                [PSCustomObject]@{ LocalAddress = '10.0.0.1'; LocalPort = (50000 + $_); RemoteAddress = ('10.1.1.' + $_); RemotePort = 443; OwningProcess = 4242 }
            })
        }
        $lines = @(Get-WtActiveConnectionLines -GetConnections $many -GetProcesses { @([PSCustomObject]@{ Id = 4242; ProcessName = 'app' }) } -MaxDetailRows 30)
        $lines | Should -Contain ((Get-Translation 'ActiveConnDetailHeader') -f 30)
        $lines | Should -Contain ('  ' + ((Get-Translation 'ActiveConnDetailMore') -f 5))
    }

    It 'states that no reverse DNS lookup is performed' {
        @(Get-WtActiveConnectionLines -GetConnections $ConnFixture -GetProcesses $ProcFixture) | Should -Contain (Get-Translation 'ActiveConnNoReverseDns')
    }

    It 'says so when nothing is connected' {
        @(Get-WtActiveConnectionLines -GetConnections { @() } -GetProcesses $ProcFixture) | Should -Be @((Get-Translation 'ActiveConnNone'))
    }

    It 'says so when the connection source throws' {
        @(Get-WtActiveConnectionLines -GetConnections { throw 'access denied' } -GetProcesses $ProcFixture) | Should -Be @((Get-Translation 'ActiveConnNone'))
    }

    It 'still lists connections when the process source throws' {
        $lines = @(Get-WtActiveConnectionLines -GetConnections $ConnFixture -GetProcesses { throw 'no processes' })
        $lines.Count | Should -BeGreaterThan 1
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'ActiveConnUnknownProcess')))
    }
}

Describe 'Get-WtHostsFileLines' {
    BeforeEach {
        $script:HostsPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.hosts')
    }

    It 'counts only the active entries and prints size and last-changed time' {
        $content = @(
            '# Copyright (c) 1993-2009 Microsoft Corp.'
            '#'
            '#	102.54.94.97     rhino.acme.com'
            ''
            '127.0.0.1 telemetry.example.com'
            '0.0.0.0 ads.example.com'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($HostsPath, $content, [System.Text.Encoding]::UTF8)
        $lines = @(Get-WtHostsFileLines -Path $HostsPath)
        $lines[0] | Should -Be ((Get-Translation 'HostsFileHeader') -f $HostsPath)
        ($lines -join "`n") | Should -Match '127\.0\.0\.1 telemetry\.example\.com'
        ($lines -join "`n") | Should -Match '0\.0\.0\.0 ads\.example\.com'
        ($lines -join "`n") | Should -Not -Match 'rhino\.acme\.com'
        $lines[1] | Should -Match '^2 '
    }

    It 'says so when the file holds only comments' {
        [System.IO.File]::WriteAllText($HostsPath, "# nothing here`r`n#`r`n", [System.Text.Encoding]::UTF8)
        @(Get-WtHostsFileLines -Path $HostsPath) | Should -Contain (Get-Translation 'HostsFileNoEntries')
    }

    It 'caps the listing - a blocklist can add thousands of lines' {
        $rows = @(1..200 | ForEach-Object { "0.0.0.0 host$_.example.com" })
        [System.IO.File]::WriteAllText($HostsPath, ($rows -join "`r`n"), [System.Text.Encoding]::UTF8)
        $lines = @(Get-WtHostsFileLines -Path $HostsPath -MaxEntries 150)
        $lines | Should -Contain ('  ' + ((Get-Translation 'HostsFileTruncated') -f 150, 50))
        ($lines -join "`n") | Should -Not -Match 'host151\.example\.com'
    }

    It 'guards the missing file before .Length is touched (Format-WtByteSize takes [long] and dies on null)' {
        $missing = Join-Path $TestDrive 'no-such-hosts-file'
        @(Get-WtHostsFileLines -Path $missing) | Should -Be @((Get-Translation 'HostsFileMissing') -f $missing)
    }

    It 'says so when the file exists but cannot be read' {
        [System.IO.File]::WriteAllText($HostsPath, '0.0.0.0 x.example.com', [System.Text.Encoding]::UTF8)
        $lines = @(Get-WtHostsFileLines -Path $HostsPath -ReadLines { param($P) throw 'locked' })
        $lines | Should -Be @((Get-Translation 'HostsFileMissing') -f $HostsPath)
    }
}

Describe 'Get-WtInternetTestPlanLines' {
    It 'names every host the test is about to contact' {
        $lines = @(Get-WtInternetTestPlanLines)
        $text = $lines -join "`n"
        $text | Should -Match 'resolver1\.opendns\.com'
        $text | Should -Match '1\.1\.1\.1'
        $text | Should -Match '8\.8\.8\.8'
        $text | Should -Match '9\.9\.9\.9'
        $lines[0] | Should -Be (Get-Translation 'InternetTestDisclosure')
    }

    It 'states that no HTTP request is sent and no ISP name is looked up' {
        @(Get-WtInternetTestPlanLines) | Should -Contain (Get-Translation 'InternetTestNoHttp')
    }

    It 'is pure - it takes no network data source at all, so printing it contacts nothing' {
        $params = (Get-Command Get-WtInternetTestPlanLines).Parameters.Keys
        $params | Should -Not -Contain 'GetPublicIp'
        $params | Should -Not -Contain 'PingTarget'
    }
}

Describe 'Get-WtInternetTestResultLines' {
    It 'reports the public IP address from the single DNS query' {
        $lines = @(Get-WtInternetTestResultLines `
                -GetPublicIp { @([PSCustomObject]@{ IPAddress = '203.0.113.7'; Type = 'A' }) } `
                -PingTarget { param($Target) @() } `
                -PingTargets @('1.1.1.1'))
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'InternetTestPublicIpLabel'), '203.0.113.7')
    }

    It 'writes a failure as a failure, never as an empty line' {
        $lines = @(Get-WtInternetTestResultLines `
                -GetPublicIp { throw 'no resolver' } `
                -PingTarget { param($Target) @() } `
                -PingTargets @('1.1.1.1'))
        $lines | Should -Contain (Get-Translation 'InternetTestPublicIpFailed')
        $lines | Should -Contain ('  ' + ((Get-Translation 'InternetTestLatencyFailed') -f '1.1.1.1'))
    }

    It 'averages the replies of a Windows PowerShell 5.1 ping (Win32_PingStatus ResponseTime)' {
        $ping = { param($Target) @(
                [PSCustomObject]@{ StatusCode = 0; ResponseTime = 10 }
                [PSCustomObject]@{ StatusCode = 0; ResponseTime = 20 }
                [PSCustomObject]@{ StatusCode = 0; ResponseTime = 30 }
                [PSCustomObject]@{ StatusCode = 0; ResponseTime = 40 }
            ) }
        $lines = @(Get-WtInternetTestResultLines -GetPublicIp { @() } -PingTarget $ping -PingTargets @('8.8.8.8') -PingCount 4)
        $lines | Should -Contain ('  ' + ((Get-Translation 'InternetTestLatencyLine') -f '8.8.8.8', 4, 4, 25))
    }

    It 'also reads the PowerShell 7 ping shape (Latency) and skips non-zero status replies' {
        $ping = { param($Target) @(
                [PSCustomObject]@{ Status = 'Success'; Latency = 12 }
                [PSCustomObject]@{ Status = 'TimedOut'; StatusCode = 11010; Latency = 0 }
                [PSCustomObject]@{ Status = 'Success'; Latency = 14 }
            ) }
        $lines = @(Get-WtInternetTestResultLines -GetPublicIp { @() } -PingTarget $ping -PingTargets @('9.9.9.9') -PingCount 4)
        $lines | Should -Contain ('  ' + ((Get-Translation 'InternetTestLatencyLine') -f '9.9.9.9', 2, 4, 13))
    }

    It 'degrades to "no reply" when the ping source throws' {
        $lines = @(Get-WtInternetTestResultLines -GetPublicIp { @() } -PingTarget { param($Target) throw 'network unreachable' } -PingTargets @('1.1.1.1'))
        $lines | Should -Contain ('  ' + ((Get-Translation 'InternetTestLatencyFailed') -f '1.1.1.1'))
    }
}

Describe 'Test-WtHostName' {
    It 'accepts ordinary host names' {
        Test-WtHostName -Name 'www.microsoft.com' | Should -BeTrue
        Test-WtHostName -Name 'localhost' | Should -BeTrue
        Test-WtHostName -Name 'Istanbul.example.com' | Should -BeTrue
        Test-WtHostName -Name '1.1.1.1' | Should -BeTrue
        Test-WtHostName -Name 'www.microsoft.com.' | Should -BeTrue
    }

    It 'rejects anything that is not a host name' {
        Test-WtHostName -Name '' | Should -BeFalse
        Test-WtHostName -Name 'has space' | Should -BeFalse
        Test-WtHostName -Name '-leading.example.com' | Should -BeFalse
        Test-WtHostName -Name 'double..dot' | Should -BeFalse
        Test-WtHostName -Name 'http://www.microsoft.com' | Should -BeFalse
        Test-WtHostName -Name '; Stop-Computer' | Should -BeFalse
    }

    It 'rejects a name longer than 253 characters' {
        Test-WtHostName -Name (('a' * 60 + '.') * 5) | Should -BeFalse
    }
}

Describe 'Get-WtDnsAnswerAddresses' {
    It 'takes the A records, de-duplicates and sorts them ordinally' {
        $records = @(
            [PSCustomObject]@{ IPAddress = '10.0.0.2' }
            [PSCustomObject]@{ IPAddress = '10.0.0.1' }
            [PSCustomObject]@{ IPAddress = '10.0.0.2' }
            [PSCustomObject]@{ NameHost = 'cdn.example.com' }
        )
        @(Get-WtDnsAnswerAddresses -Records $records) | Should -Be @('10.0.0.1', '10.0.0.2')
    }

    It 'returns an empty set for no records' {
        @(Get-WtDnsAnswerAddresses -Records @()).Count | Should -Be 0
    }
}

Describe 'Get-WtDnsTestPlanLines' {
    It 'names the three servers before any query is made' {
        $lines = @(Get-WtDnsTestPlanLines -Name 'www.microsoft.com')
        $text = $lines -join "`n"
        $text | Should -Match 'www\.microsoft\.com'
        $text | Should -Match '8\.8\.8\.8'
        $text | Should -Match '1\.1\.1\.1'
        $lines | Should -Contain ('  - ' + (Get-Translation 'DnsTestServerAdapter'))
    }

    It 'states that -DnsOnly keeps the local cache out of the comparison' {
        @(Get-WtDnsTestPlanLines -Name 'www.microsoft.com') | Should -Contain (Get-Translation 'DnsTestCacheNote')
    }
}

Describe 'Get-WtDnsTestResultLines' {
    It 'puts the three answer sets side by side and says they agree' {
        $same = { param($HostName, $Server) @([PSCustomObject]@{ IPAddress = '23.45.67.89' }) }
        $lines = @(Get-WtDnsTestResultLines -Name 'www.microsoft.com' `
                -ResolveWithAdapter { param($HostName) @([PSCustomObject]@{ IPAddress = '23.45.67.89' }) } `
                -ResolveWithServer $same)
        $lines | Should -Contain ('  {0}: {1}' -f (Get-Translation 'DnsTestAdapterLabel'), '23.45.67.89')
        $lines | Should -Contain '  8.8.8.8: 23.45.67.89'
        $lines | Should -Contain '  1.1.1.1: 23.45.67.89'
        $lines | Should -Contain (Get-Translation 'DnsTestSame')
    }

    It 'says the answers DIFFER when the adapter resolver returns something else' {
        $lines = @(Get-WtDnsTestResultLines -Name 'blocked.example.com' `
                -ResolveWithAdapter { param($HostName) @([PSCustomObject]@{ IPAddress = '0.0.0.0' }) } `
                -ResolveWithServer { param($HostName, $Server) @([PSCustomObject]@{ IPAddress = '93.184.216.34' }) })
        $lines | Should -Contain (Get-Translation 'DnsTestDifferent')
        $lines | Should -Not -Contain (Get-Translation 'DnsTestSame')
    }

    It 'ignores answer ORDER - the same addresses in a different order still agree' {
        $lines = @(Get-WtDnsTestResultLines -Name 'www.example.com' `
                -ResolveWithAdapter { param($HostName) @([PSCustomObject]@{ IPAddress = '10.0.0.2' }, [PSCustomObject]@{ IPAddress = '10.0.0.1' }) } `
                -ResolveWithServer { param($HostName, $Server) @([PSCustomObject]@{ IPAddress = '10.0.0.1' }, [PSCustomObject]@{ IPAddress = '10.0.0.2' }) })
        $lines | Should -Contain (Get-Translation 'DnsTestSame')
    }

    It 'writes "no answer" for a server that fails, never an empty line' {
        $lines = @(Get-WtDnsTestResultLines -Name 'www.example.com' `
                -ResolveWithAdapter { param($HostName) throw 'SERVFAIL' } `
                -ResolveWithServer { param($HostName, $Server) throw 'timeout' })
        $lines | Should -Contain ('  {0}: {1}' -f (Get-Translation 'DnsTestAdapterLabel'), (Get-Translation 'DnsTestNoAnswer'))
        $lines | Should -Contain ('  8.8.8.8: ' + (Get-Translation 'DnsTestNoAnswer'))
        $lines | Should -Contain (Get-Translation 'DnsTestSame')
    }
}

Describe 'Invoke-WtDnsResolutionTestAction' {
    It 'offers www.microsoft.com as the default and uses it on an empty answer' {
        $script:AskedPrompt = ''
        $script:RanWith = ''
        Invoke-WtDnsResolutionTestAction `
            -AskName { param($Crumb, $Default) $script:AskedPrompt = ((Get-Translation 'DnsTestPrompt') -f $Default); '' } `
            -Run { param($HostName, $Crumb) $script:RanWith = $HostName } `
            -ShowInvalid { param($Crumb, $Text) throw 'must not be reached' }
        $script:AskedPrompt | Should -Match 'www\.microsoft\.com'
        $script:RanWith | Should -Be 'www.microsoft.com'
    }

    It 'trims and uses what the user typed' {
        $script:RanWith = ''
        Invoke-WtDnsResolutionTestAction `
            -AskName { param($Crumb, $Default) '  example.org  ' } `
            -Run { param($HostName, $Crumb) $script:RanWith = $HostName } `
            -ShowInvalid { param($Crumb, $Text) throw 'must not be reached' }
        $script:RanWith | Should -Be 'example.org'
    }

    It 'validates before it queries - an invalid name never reaches the run step' {
        $script:RanWith = ''
        $script:Rejected = ''
        Invoke-WtDnsResolutionTestAction `
            -AskName { param($Crumb, $Default) '; Stop-Computer' } `
            -Run { param($HostName, $Crumb) $script:RanWith = $HostName } `
            -ShowInvalid { param($Crumb, $Text) $script:Rejected = $Text }
        $script:RanWith | Should -Be ''
        $script:Rejected | Should -Be '; Stop-Computer'
    }

    It 'does nothing when input is exhausted (Read-WtPanelAnswer returned $null)' {
        $script:RanWith = ''
        Invoke-WtDnsResolutionTestAction `
            -AskName { param($Crumb, $Default) $null } `
            -Run { param($HostName, $Crumb) $script:RanWith = $HostName } `
            -ShowInvalid { param($Crumb, $Text) throw 'must not be reached' }
        $script:RanWith | Should -Be ''
    }

    It 'asks in the panel, never with Read-Host' {
        (Get-Command Invoke-WtDnsResolutionTestAction).Definition | Should -Not -Match 'Read-Host'
        (Get-Command Invoke-WtDnsResolutionTestAction).Definition | Should -Match 'Read-WtPanelAnswer'
    }
}

Describe 'Information Tools > Network group wiring' {
    BeforeAll {
        $group = @(Get-WtInfoToolGroups) | Where-Object { $_.HeaderKey -eq 'InfoGroupNetwork' } | Select-Object -First 1
        $script:NetworkRows = @(& $group.GetRows)
        $script:NetworkNames = @($script:NetworkRows | ForEach-Object { $_.Name })
    }

    It 'carries all seven new rows' {
        foreach ($name in @('ShowNetworkAdapters', 'ShowWifiLinkDetails', 'ShowNetworkProfileState', 'ShowActiveConnections', 'ShowHostsFile', 'InternetConnectivityTest', 'DnsResolutionTest')) {
            $NetworkNames | Should -Contain $name
        }
    }

    It 'resolves every new label in both dictionaries' {
        foreach ($name in @('ShowNetworkAdapters', 'ShowWifiLinkDetails', 'ShowNetworkProfileState', 'ShowActiveConnections', 'ShowHostsFile', 'InternetConnectivityTest', 'DnsResolutionTest')) {
            $script:Translations['EN'].ContainsKey($name) | Should -BeTrue -Because "EN needs '$name'"
            $script:Translations['TR'].ContainsKey($name) | Should -BeTrue -Because "TR needs '$name'"
        }
    }

    It 'keeps six rows captured and only the DNS test inline (it has to ask first)' {
        foreach ($name in @('ShowNetworkAdapters', 'ShowWifiLinkDetails', 'ShowNetworkProfileState', 'ShowActiveConnections', 'ShowHostsFile', 'InternetConnectivityTest')) {
            $row = @($NetworkRows) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            $row.Data.Captured | Should -BeTrue -Because $name
        }
        $dns = @($NetworkRows) | Where-Object { $_.Name -eq 'DnsResolutionTest' } | Select-Object -First 1
        $dns.Data.Captured | Should -BeNullOrEmpty
        $dns.Data.Action | Should -Not -BeNullOrEmpty
    }

    It 'flags the hosts file row CAUTION' {
        (@($NetworkRows) | Where-Object { $_.Name -eq 'ShowHostsFile' } | Select-Object -First 1).Risk | Should -Be 'CAUTION'
    }

    It 'no captured row calls Read-Host - it would deadlock behind the capture' {
        foreach ($row in @($NetworkRows | Where-Object { $_.Data.Captured })) {
            [string]$row.Data.Action | Should -Not -Match 'Read-Host' -Because $row.Name
        }
    }

    It 'no new row changes state - the information screen is read-only' {
        $denied = @('Set-', 'Remove-', 'Stop-', 'Start-', 'Restart-', 'New-', 'Clear-', 'Disable-', 'Enable-', 'vssadmin delete')
        foreach ($row in @($NetworkRows)) {
            foreach ($verb in $denied) {
                [string]$row.Data.Action | Should -Not -Match ([regex]::Escape($verb)) -Because "$($row.Name) / $verb"
            }
        }
    }

    It 'the internet row prints its disclosure BEFORE it contacts anything' {
        $body = [string]((@($NetworkRows) | Where-Object { $_.Name -eq 'InternetConnectivityTest' } | Select-Object -First 1).Data.Action)
        $planIndex = $body.IndexOf('Get-WtInternetTestPlanLines', [System.StringComparison]::Ordinal)
        $resultIndex = $body.IndexOf('Get-WtInternetTestResultLines', [System.StringComparison]::Ordinal)
        $planIndex | Should -BeGreaterOrEqual 0
        $resultIndex | Should -BeGreaterThan $planIndex
    }
}
