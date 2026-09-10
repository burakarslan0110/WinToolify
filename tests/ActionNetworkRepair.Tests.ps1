#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    $script:CaptureLines = {
        param([scriptblock]$Action)
        @(& $Action 6>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
    }
}

Describe 'Invoke-WtRestartNetworkAdaptersAction' {
    It 'refuses outright inside a remote desktop session and never touches an adapter' {
        $lines = & $script:CaptureLines {
            Invoke-WtRestartNetworkAdaptersAction -GetSessionName { 'RDP-Tcp#7' } -GetAdapters { throw 'must not enumerate adapters' }
        }
        $lines | Should -Contain ((Get-Translation 'NetAdaptersRdpBlocked') -f 'RDP-Tcp#7')
    }

    It 'says so when no adapter is up' {
        $lines = & $script:CaptureLines {
            Invoke-WtRestartNetworkAdaptersAction -GetSessionName { 'Console' } -GetAdapters { @() } -RestartAdapter { throw 'must not restart' }
        }
        $lines | Should -Be @((Get-Translation 'NetAdaptersNone'))
    }

    It 'restarts every adapter that is up and polls each one back to Up' {
        $script:restarted = New-Object System.Collections.Generic.List[string]
        $script:polls = 0
        $lines = & $script:CaptureLines {
            Invoke-WtRestartNetworkAdaptersAction `
                -GetSessionName { 'Console' } `
                -GetAdapters { @([PSCustomObject]@{ Name = 'Ethernet' }, [PSCustomObject]@{ Name = 'Wi-Fi' }) } `
                -RestartAdapter { param($Name) $script:restarted.Add([string]$Name) } `
                -GetAdapterStatus { param($Name) $script:polls++; if ($script:polls % 2 -eq 0) { 'Up' } else { 'Disconnected' } } `
                -WaitOneSecond { } `
                -TimeoutSeconds 30
        }
        @($script:restarted) | Should -Be @('Ethernet', 'Wi-Fi')
        $lines | Should -Contain ((Get-Translation 'NetAdapterUp') -f 'Ethernet', 2)
        $lines | Should -Contain ((Get-Translation 'NetAdapterUp') -f 'Wi-Fi', 2)
    }

    It 'reports a failing adapter and keeps going with the next one' {
        $script:restarted = New-Object System.Collections.Generic.List[string]
        $lines = & $script:CaptureLines {
            Invoke-WtRestartNetworkAdaptersAction `
                -GetSessionName { 'Console' } `
                -GetAdapters { @([PSCustomObject]@{ Name = 'Broken' }, [PSCustomObject]@{ Name = 'Wi-Fi' }) } `
                -RestartAdapter { param($Name) if ($Name -ceq 'Broken') { throw 'driver refused' }; $script:restarted.Add([string]$Name) } `
                -GetAdapterStatus { param($Name) 'Up' } `
                -WaitOneSecond { } `
                -TimeoutSeconds 5
        }
        $lines | Should -Contain ((Get-Translation 'NetAdapterFailed') -f 'Broken', 'driver refused')
        @($script:restarted) | Should -Be @('Wi-Fi')
    }

    It 'says the adapter is still not up instead of claiming success' {
        $lines = & $script:CaptureLines {
            Invoke-WtRestartNetworkAdaptersAction `
                -GetSessionName { 'Console' } `
                -GetAdapters { @([PSCustomObject]@{ Name = 'Wi-Fi' }) } `
                -RestartAdapter { param($Name) } `
                -GetAdapterStatus { param($Name) 'Disconnected' } `
                -WaitOneSecond { } `
                -TimeoutSeconds 3
        }
        $lines | Should -Contain ((Get-Translation 'NetAdapterNotUp') -f 'Wi-Fi', 'Disconnected', 3)
    }
}

Describe 'Get-WtWifiProfileNames' {
    It 'splits on the FIRST colon so an SSID that contains a colon survives' {
        $out = @(
            ''
            'Profiles on interface Wi-Fi:'
            ''
            'Group policy profiles (read only)'
            '---------------------------------'
            '    <None>'
            ''
            'User profiles'
            '-------------'
            '    All User Profile     : HomeNet'
            '    All User Profile     : Cafe: Free WiFi'
        )
        @(Get-WtWifiProfileNames -Output $out) | Should -Be @('HomeNet', 'Cafe: Free WiFi')
    }

    It 'reads a Turkish listing, where only the label before the colon is translated' {
        $out = @('Wi-Fi arabirimindeki profiller:', '', 'Kullanici profilleri', '--------------------', '    Tum Kullanici Profili     : EvAgi')
        @(Get-WtWifiProfileNames -Output $out) | Should -Be @('EvAgi')
    }

    It 'returns nothing when netsh listed no profile at all' {
        @(Get-WtWifiProfileNames -Output @('', 'Profiles on interface Wi-Fi:', '', 'User profiles', '-------------')).Count | Should -Be 0
        @(Get-WtWifiProfileNames -Output @()).Count | Should -Be 0
    }
}

Describe 'Invoke-WtForgetWifiProfileAction' {
    BeforeEach {
        $script:shown = $null
        $script:deleted = $null
        $script:asked = $null
    }

    It 'says so and asks nothing when there is no saved profile' {
        Invoke-WtForgetWifiProfileAction `
            -ListProfiles { @('Profiles on interface Wi-Fi:') } `
            -AskChoice { throw 'must not ask' } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not delete' }
        @($script:shown) | Should -Be @((Get-Translation 'WifiProfilesNone'))
    }

    It 'numbers the profiles and deletes the one the user picked' {
        Invoke-WtForgetWifiProfileAction `
            -ListProfiles { @('    All User Profile     : HomeNet', '    All User Profile     : Cafe: Free WiFi') } `
            -AskChoice { param($Lines) $script:asked = @($Lines); '2' } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { param($ProfileName, $Crumb) $script:deleted = [string]$ProfileName }
        $script:asked | Should -Contain '  [1] HomeNet'
        $script:asked | Should -Contain '  [2] Cafe: Free WiFi'
        $script:deleted | Should -Be 'Cafe: Free WiFi'
    }

    It 'refuses a number that is not on the list and deletes nothing' {
        Invoke-WtForgetWifiProfileAction `
            -ListProfiles { @('    All User Profile     : HomeNet') } `
            -AskChoice { param($Lines) '9' } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not delete' }
        @($script:shown) | Should -Be @((Get-Translation 'WifiProfileInvalidChoice'))
    }

    It 'refuses text that is not a number at all and deletes nothing' {
        Invoke-WtForgetWifiProfileAction `
            -ListProfiles { @('    All User Profile     : HomeNet') } `
            -AskChoice { param($Lines) 'HomeNet' } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not delete' }
        @($script:shown) | Should -Be @((Get-Translation 'WifiProfileInvalidChoice'))
    }

    It 'an empty answer just returns - nothing is shown and nothing is deleted' {
        Invoke-WtForgetWifiProfileAction `
            -ListProfiles { @('    All User Profile     : HomeNet') } `
            -AskChoice { param($Lines) '   ' } `
            -ShowMessage { throw 'must not draw' } `
            -Run { throw 'must not delete' }
        $script:deleted | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-WtResetWinsockAction' {
    It 'prints the restart notice even when netsh printed nothing at all' {
        $lines = & $script:CaptureLines { Invoke-WtResetWinsockAction -RunReset { @() } }
        $lines[0] | Should -Be (Get-Translation 'WinsockResetRunning')
        $lines | Should -Contain (Get-Translation 'NetworkRestartRequired')
    }

    It 'streams the netsh output and adds the third-party LSP note' {
        $lines = & $script:CaptureLines { Invoke-WtResetWinsockAction -RunReset { 'Winsock Catalog reset ok' } }
        $lines | Should -Contain 'Winsock Catalog reset ok'
        $lines | Should -Contain (Get-Translation 'WinsockResetLspNote')
        $lines | Should -Contain (Get-Translation 'NetworkRestartRequired')
    }
}

Describe 'Get-WtNetworkResetPreviewLines' {
    It 'lists the static addresses and the current DNS servers' {
        $lines = @(Get-WtNetworkResetPreviewLines `
            -GetAddresses {
                @(
                    [PSCustomObject]@{ InterfaceAlias = 'Ethernet'; IPAddress = '192.168.1.50'; PrefixLength = 24; PrefixOrigin = 'Manual' }
                    [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; IPAddress = '192.168.1.77'; PrefixLength = 24; PrefixOrigin = 'Dhcp' }
                )
            } `
            -GetDnsServers {
                @(
                    [PSCustomObject]@{ InterfaceAlias = 'Ethernet'; ServerAddresses = @('1.1.1.1', '1.0.0.1') }
                    [PSCustomObject]@{ InterfaceAlias = 'Wi-Fi'; ServerAddresses = @() }
                )
            })
        $lines[0] | Should -Be (Get-Translation 'NetResetStaticHeader')
        $lines | Should -Contain '  Ethernet: 192.168.1.50/24'
        $lines | Should -Not -Contain '  Wi-Fi: 192.168.1.77/24'
        $lines | Should -Contain '  Ethernet: 1.1.1.1, 1.0.0.1'
    }

    It 'says there is none rather than printing nothing when the data is missing or throws' {
        $lines = @(Get-WtNetworkResetPreviewLines -GetAddresses { throw 'Generic failure' } -GetDnsServers { @() })
        $lines | Should -Contain ('  ' + (Get-Translation 'NetResetNoStatic'))
        $lines | Should -Contain ('  ' + (Get-Translation 'NetResetNoDns'))
    }
}

Describe 'Invoke-WtResetTcpIpStackCommands' {
    It 'explains a non-zero netsh exit code instead of leaving the raw line alone' {
        $lines = & $script:CaptureLines {
            Invoke-WtResetTcpIpStackCommands `
                -RunIpv4 { 'Resetting Interface, OK!' } `
                -RunIpv6 { 'Access is denied.' } `
                -GetExitCode { 1 } `
                -RetireDnsRecords { 0 }
        }
        $lines | Should -Contain 'Resetting Interface, OK!'
        $lines | Should -Contain ((Get-Translation 'ResetTcpIpExitCode') -f 1)
        $lines | Should -Contain (Get-Translation 'ResetTcpIpAccessDeniedNote')
    }

    It 'retires the DNS preset undo records and prints how many' {
        $script:retireCalled = $false
        $lines = & $script:CaptureLines {
            Invoke-WtResetTcpIpStackCommands `
                -RunIpv4 { @() } `
                -RunIpv6 { @() } `
                -GetExitCode { 0 } `
                -RetireDnsRecords { $script:retireCalled = $true; 2 }
        }
        $script:retireCalled | Should -BeTrue
        $lines | Should -Contain ((Get-Translation 'UndoRetiredDnsPreset') -f 2)
        $lines | Should -Contain (Get-Translation 'NetworkRestartRequired')
        $lines | Should -Not -Contain (Get-Translation 'ResetTcpIpAccessDeniedNote')
    }

    It 'prints a line before the first netsh call so the panel is never silent' {
        $lines = & $script:CaptureLines {
            Invoke-WtResetTcpIpStackCommands -RunIpv4 { @() } -RunIpv6 { @() } -GetExitCode { 0 } -RetireDnsRecords { 0 }
        }
        $lines[0] | Should -Be (Get-Translation 'ResetTcpIpStackRunning')
    }
}

Describe 'Invoke-WtResetTcpIpStackAction' {
    It 'shows the preview inside the gate and runs the reset once the gate is passed' {
        $script:gateLines = $null
        $script:ran = $false
        Invoke-WtResetTcpIpStackAction `
            -GetPreviewLines { @('Static IPv4 addresses:', '  Ethernet: 192.168.1.50/24') } `
            -Confirm { param($Lines) $script:gateLines = @($Lines); $true } `
            -ShowMessage { throw 'must not cancel' } `
            -Run { param($Crumb) $script:ran = $true }
        $script:gateLines | Should -Contain '  Ethernet: 192.168.1.50/24'
        $script:ran | Should -BeTrue
    }

    It 'runs nothing and says it was cancelled when the gate is refused' {
        $script:shown = $null
        Invoke-WtResetTcpIpStackAction `
            -GetPreviewLines { @('preview') } `
            -Confirm { param($Lines) $false } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not reset the stack' }
        @($script:shown) | Should -Be @((Get-Translation 'ActionCancelled'))
    }
}

Describe 'Test-WtWinHttpProxyConfigured' {
    It 'sees a configured proxy by its host:port shape, not by the English words' {
        Test-WtWinHttpProxyConfigured -Lines @(
            'Current WinHTTP proxy settings:'
            ''
            '    Proxy Server(s) :  proxy.corp.local:8080'
            '    Bypass List     :  (none)'
        ) | Should -BeTrue
    }

    It 'sees an IPv4 proxy too' {
        Test-WtWinHttpProxyConfigured -Lines @('    Proxy Server(s) :  10.0.0.9:3128') | Should -BeTrue
    }

    It 'reads the English direct-access line as no proxy' {
        Test-WtWinHttpProxyConfigured -Lines @('Current WinHTTP proxy settings:', '', '    Direct access (no proxy server).') | Should -BeFalse
    }

    It 'reads the Turkish direct-access line as no proxy' {
        Test-WtWinHttpProxyConfigured -Lines @('Gecerli WinHTTP proxy ayarlari:', '', '    Dogrudan erisim (proxy sunucusu yok).') | Should -BeFalse
    }

    It 'treats empty output as no proxy instead of throwing' {
        Test-WtWinHttpProxyConfigured -Lines @() | Should -BeFalse
    }
}

Describe 'Invoke-WtResetWinHttpProxyCommands' {
    It 'runs both reset subcommands and shows the state afterwards' {
        $script:calls = New-Object System.Collections.Generic.List[string]
        $lines = & $script:CaptureLines {
            Invoke-WtResetWinHttpProxyCommands -ProxyWasConfigured $true `
                -RunResetProxy { $script:calls.Add('proxy'); 'Current WinHTTP proxy settings: Direct access (no proxy server).' } `
                -RunResetAutoProxy { $script:calls.Add('autoproxy'); @() } `
                -ShowProxy { 'Direct access (no proxy server).' }
        }
        @($script:calls) | Should -Be @('proxy', 'autoproxy')
        $lines[0] | Should -Be (Get-Translation 'WinHttpProxyResetting')
        $lines | Should -Contain (Get-Translation 'WinHttpProxyAfter')
        $lines | Should -Contain 'Direct access (no proxy server).'
    }

    It 'says so up front when there was no proxy to clear' {
        $lines = & $script:CaptureLines {
            Invoke-WtResetWinHttpProxyCommands -ProxyWasConfigured $false -RunResetProxy { @() } -RunResetAutoProxy { @() } -ShowProxy { @() }
        }
        $lines | Should -Contain (Get-Translation 'WinHttpProxyNotSet')
    }
}

Describe 'Invoke-WtResetWinHttpProxyAction' {
    It 'does not ask the gate at all when no proxy is configured' {
        $script:ran = $false
        Invoke-WtResetWinHttpProxyAction `
            -ShowProxy { @('    Direct access (no proxy server).') } `
            -Confirm { throw 'must not gate a harmless reset' } `
            -ShowMessage { throw 'must not cancel' } `
            -Run { param($Crumb, $Configured) $script:ran = $true; $script:configured = [bool]$Configured }
        $script:ran | Should -BeTrue
        $script:configured | Should -BeFalse
    }

    It 'gates the reset when a proxy IS set and shows the current setting inside the gate' {
        $script:gateLines = $null
        $script:ran = $false
        Invoke-WtResetWinHttpProxyAction `
            -ShowProxy { @('    Proxy Server(s) :  proxy.corp.local:8080') } `
            -Confirm { param($Lines) $script:gateLines = @($Lines); $true } `
            -ShowMessage { throw 'must not cancel' } `
            -Run { param($Crumb, $Configured) $script:ran = $true; $script:configured = [bool]$Configured }
        $script:gateLines | Should -Contain (Get-Translation 'WinHttpProxyCurrent')
        $script:gateLines | Should -Contain '    Proxy Server(s) :  proxy.corp.local:8080'
        $script:ran | Should -BeTrue
        $script:configured | Should -BeTrue
    }

    It 'runs nothing when the gate is refused' {
        $script:shown = $null
        Invoke-WtResetWinHttpProxyAction `
            -ShowProxy { @('    Proxy Server(s) :  proxy.corp.local:8080') } `
            -Confirm { param($Lines) $false } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not reset the proxy' }
        @($script:shown) | Should -Be @((Get-Translation 'ActionCancelled'))
    }
}

Describe 'Get-WtHostsFileSummary / Get-WtHostsResetPreviewLines / Get-WtDefaultHostsContent' {
    It 'counts active entries and the WinToolify-marked ones, ignoring comments and blanks' {
        $content = @(
            '# Copyright (c) 1993-2009 Microsoft Corp.'
            ''
            '127.0.0.1 localhost'
            "0.0.0.0 ads.example.com`t# WinToolify (Telemetry)"
            "0.0.0.0 tracker.example.net`t# WinToolify (Ads)"
            '   # an indented comment'
        ) -join "`r`n"
        $summary = Get-WtHostsFileSummary -Content $content
        $summary.Active | Should -Be 3
        $summary.Marked | Should -Be 2
    }

    It 'reports zeroes for an empty or unreadable file instead of throwing' {
        (Get-WtHostsFileSummary -Content '').Active | Should -Be 0
        (Get-WtHostsFileSummary -Content '').Marked | Should -Be 0
    }

    It 'turns the counts into the two preview lines the gate shows' {
        $lines = @(Get-WtHostsResetPreviewLines -Content "127.0.0.1 localhost`r`n")
        $lines | Should -Be @(
            ((Get-Translation 'HostsActiveEntries') -f 1)
            ((Get-Translation 'HostsWinToolifyEntries') -f 0)
        )
    }

    It 'returns the Windows default text: pure ASCII, CRLF, no active entry left' {
        $text = Get-WtDefaultHostsContent
        $text | Should -Match 'localhost'
        $text.EndsWith("`r`n") | Should -BeTrue
        ([regex]::Matches($text, '[^\x00-\x7F]')).Count | Should -Be 0
        (Get-WtHostsFileSummary -Content $text).Active | Should -Be 0
    }
}

Describe 'Invoke-WtResetHostsFileWrite' {
    It 'backs the file up, writes the default text and flushes the DNS cache' {
        $script:hostsPath = Join-Path $TestDrive 'hosts'
        Set-Content -LiteralPath $script:hostsPath -Value '0.0.0.0 ads.example.com' -Encoding UTF8
        $script:backedUp = $null
        $script:written = $null
        $lines = & $script:CaptureLines {
            Invoke-WtResetHostsFileWrite -MarkedCount 2 `
                -GetHostsPath { $script:hostsPath } `
                -BackupHosts { param($Path) $script:backedUp = [string]$Path; 'D:\WinToolify\backup\hosts-20260823-101500.bak' } `
                -WriteHosts { param($Path, $Text) $script:written = [string]$Text } `
                -FlushDns { 'Successfully flushed the DNS Resolver Cache.' } `
                -RetireRecords { 3 }
        }
        $script:backedUp | Should -Be $script:hostsPath
        $script:written | Should -Be (Get-WtDefaultHostsContent)
        $lines | Should -Contain ((Get-Translation 'HostsBackupWritten') -f 'D:\WinToolify\backup\hosts-20260823-101500.bak')
        $lines | Should -Contain (Get-Translation 'HostsFileRewritten')
        $lines | Should -Contain 'Successfully flushed the DNS Resolver Cache.'
        $lines | Should -Contain ((Get-Translation 'UndoRetiredBlocklistHosts') -f 3)
    }

    It 'retires no undo record when the file carried none of this tool s lines' {
        $script:hostsPath = Join-Path $TestDrive 'hosts2'
        $lines = & $script:CaptureLines {
            Invoke-WtResetHostsFileWrite -MarkedCount 0 `
                -GetHostsPath { $script:hostsPath } `
                -BackupHosts { param($Path) 'D:\WinToolify\backup\hosts.bak' } `
                -WriteHosts { param($Path, $Text) } `
                -FlushDns { @() } `
                -RetireRecords { throw 'must not retire a record this row did not invalidate' }
        }
        $lines | Should -Contain (Get-Translation 'HostsFileRewritten')
    }
}

Describe 'Invoke-WtResetHostsFileAction' {
    It 'shows the counts in the gate and passes the marked count to the writer' {
        $script:gateLines = $null
        $script:markedSeen = -1
        Invoke-WtResetHostsFileAction `
            -ReadHosts { "127.0.0.1 localhost`r`n0.0.0.0 ads.example.com`t# WinToolify (Ads)`r`n" } `
            -Confirm { param($Lines) $script:gateLines = @($Lines); $true } `
            -ShowMessage { throw 'must not cancel' } `
            -Run { param($Crumb, $Marked) $script:markedSeen = [int]$Marked }
        $script:gateLines | Should -Contain ((Get-Translation 'HostsActiveEntries') -f 2)
        $script:gateLines | Should -Contain ((Get-Translation 'HostsWinToolifyEntries') -f 1)
        $script:markedSeen | Should -Be 1
    }

    It 'writes nothing when the gate is refused' {
        $script:shown = $null
        Invoke-WtResetHostsFileAction `
            -ReadHosts { '127.0.0.1 localhost' } `
            -Confirm { param($Lines) $false } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not rewrite the hosts file' }
        @($script:shown) | Should -Be @((Get-Translation 'ActionCancelled'))
    }

    It 'still asks the gate when the hosts file cannot be read at all' {
        $script:gateLines = $null
        Invoke-WtResetHostsFileAction `
            -ReadHosts { throw 'Access to the path is denied.' } `
            -Confirm { param($Lines) $script:gateLines = @($Lines); $false } `
            -ShowMessage { param($Lines) } `
            -Run { throw 'must not rewrite the hosts file' }
        $script:gateLines | Should -Contain ((Get-Translation 'HostsActiveEntries') -f 0)
    }
}

Describe 'Get-WtFirewallRuleCounts' {
    It 'counts this tool s blocklist rules and the group-less custom rules apart' {
        $counts = Get-WtFirewallRuleCounts -GetRules {
            @(
                [PSCustomObject]@{ DisplayName = 'WinToolify-Block-Telemetry-0'; Group = 'WinToolify' }
                [PSCustomObject]@{ DisplayName = 'WinToolify-Block-Telemetry-1'; Group = 'WinToolify' }
                [PSCustomObject]@{ DisplayName = 'My game server'; Group = '' }
                [PSCustomObject]@{ DisplayName = 'No group at all'; Group = $null }
                [PSCustomObject]@{ DisplayName = 'Core Networking'; Group = '@FirewallAPI.dll,-25000' }
            )
        }
        $counts.WinToolify | Should -Be 2
        $counts.Custom | Should -Be 2
    }

    It 'returns zeroes when the firewall cannot be queried at all' {
        $counts = Get-WtFirewallRuleCounts -GetRules { throw 'The service cannot be started' }
        $counts.WinToolify | Should -Be 0
        $counts.Custom | Should -Be 0
    }
}

Describe 'Invoke-WtResetFirewallRulesCommands' {
    It 'runs the reset, retires the blocklist undo records and prints how many' {
        $script:retireCalled = $false
        $lines = & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands `
                -RunReset { 'Ok.' } `
                -RetireRecords { $script:retireCalled = $true; 4 } `
                -GetProfileState { @() } `
                -SetProfileState { throw 'must not set anything - nothing changed' }
        }
        $lines[0] | Should -Be (Get-Translation 'FirewallResetRunning')
        $lines | Should -Contain 'Ok.'
        $script:retireCalled | Should -BeTrue
        $lines | Should -Contain ((Get-Translation 'UndoRetiredBlocklistFirewall') -f 4)
    }

    It 'captures the on/off state before the reset and restores any profile the reset changed, in order' {
        $script:calls = New-Object System.Collections.Generic.List[string]
        $script:readCount = 0
        $script:beforeState = @(
            [PSCustomObject]@{ Name = 'Domain'; Enabled = $false }
            [PSCustomObject]@{ Name = 'Private'; Enabled = $true }
            [PSCustomObject]@{ Name = 'Public'; Enabled = $false }
        )
        $script:afterState = @(
            [PSCustomObject]@{ Name = 'Domain'; Enabled = $true }
            [PSCustomObject]@{ Name = 'Private'; Enabled = $true }
            [PSCustomObject]@{ Name = 'Public'; Enabled = $true }
        )
        $lines = & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands `
                -RunReset { $script:calls.Add('reset') } `
                -RetireRecords { 0 } `
                -GetProfileState {
                    $script:readCount++
                    $script:calls.Add('read' + $script:readCount)
                    if ($script:readCount -eq 1) { $script:beforeState } else { $script:afterState }
                } `
                -SetProfileState { param($Name, $Enabled) $script:calls.Add("set:$Name=$Enabled") }
        }
        @($script:calls) | Should -Be @('read1', 'reset', 'read2', 'set:Domain=False', 'set:Public=False')
        $lines | Should -Contain ((Get-Translation 'FirewallStateRestored') -f 'Domain, Public')
    }

    It 'does not write a profile whose state did not change' {
        $script:setCalls = New-Object System.Collections.Generic.List[string]
        $script:sameState = @([PSCustomObject]@{ Name = 'Domain'; Enabled = $true })
        & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands `
                -RunReset { @() } `
                -RetireRecords { 0 } `
                -GetProfileState { $script:sameState } `
                -SetProfileState { param($Name, $Enabled) $script:setCalls.Add([string]$Name) }
        } | Out-Null
        @($script:setCalls).Count | Should -Be 0
    }

    It 'a failed read still lets the reset proceed and says so, restoring nothing' {
        $script:resetCalled = $false
        $script:setCalled = $false
        $lines = & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands `
                -RunReset { $script:resetCalled = $true } `
                -RetireRecords { 0 } `
                -GetProfileState { throw 'Access is denied.' } `
                -SetProfileState { $script:setCalled = $true }
        }
        $script:resetCalled | Should -BeTrue
        $script:setCalled | Should -BeFalse
        $lines | Should -Contain (Get-Translation 'FirewallStateReadFailed')
    }

    It 'a failed restore names the profile and does not abort the remaining profiles' {
        $script:beforeState = @(
            [PSCustomObject]@{ Name = 'Domain'; Enabled = $false }
            [PSCustomObject]@{ Name = 'Public'; Enabled = $false }
        )
        $script:afterState = @(
            [PSCustomObject]@{ Name = 'Domain'; Enabled = $true }
            [PSCustomObject]@{ Name = 'Public'; Enabled = $true }
        )
        $script:readCount = 0
        $script:setCalls = New-Object System.Collections.Generic.List[string]
        $lines = & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands `
                -RunReset { @() } `
                -RetireRecords { 0 } `
                -GetProfileState { $script:readCount++; if ($script:readCount -eq 1) { $script:beforeState } else { $script:afterState } } `
                -SetProfileState {
                    param($Name, $Enabled)
                    if ($Name -ceq 'Domain') { throw 'Access is denied.' }
                    $script:setCalls.Add([string]$Name)
                }
        }
        $lines | Should -Contain ((Get-Translation 'FirewallStateRestoreFailed') -f 'Domain')
        @($script:setCalls) | Should -Be @('Public')
        $lines | Should -Contain ((Get-Translation 'FirewallStateRestored') -f 'Public')
        ($lines -join "`n").Contains('Domain, Public') | Should -BeFalse
    }

    It 'names no profile at all when every restore attempt fails' {
        $script:beforeState = @([PSCustomObject]@{ Name = 'Domain'; Enabled = $false })
        $script:afterState = @([PSCustomObject]@{ Name = 'Domain'; Enabled = $true })
        $script:readCount = 0
        $lines = & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands `
                -RunReset { @() } `
                -RetireRecords { 0 } `
                -GetProfileState { $script:readCount++; if ($script:readCount -eq 1) { $script:beforeState } else { $script:afterState } } `
                -SetProfileState { param($Name, $Enabled) throw 'Access is denied.' }
        }
        $lines | Should -Contain ((Get-Translation 'FirewallStateRestoreFailed') -f 'Domain')
        $template = Get-Translation 'FirewallStateRestored'
        $prefix = $template.Substring(0, $template.IndexOf('{0}'))
        ($lines | Where-Object { $_.StartsWith($prefix) }).Count | Should -Be 0
    }

    It 'the real default writer binds the bool through ConvertTo-WtGpoBoolean, matching the guarded-toggle writer' {
        $ast = (Get-Command Invoke-WtResetFirewallRulesCommands).ScriptBlock.Ast
        $defaultAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'SetProfileState' }, $true)
        $defaultAst | Should -Not -BeNullOrEmpty
        $src = $defaultAst.DefaultValue.Extent.Text
        $src | Should -Match 'ConvertTo-WtGpoBoolean'
        $src | Should -Not -Match 'Set-NetFirewallProfile[^\r\n]*-Enabled \$Enabled\b'
    }
}

Describe 'Invoke-WtResetFirewallRulesAction' {
    It 'prints both rule counts inside the gate and then runs the reset' {
        $script:gateLines = $null
        $script:ran = $false
        Invoke-WtResetFirewallRulesAction `
            -GetCounts { [PSCustomObject]@{ WinToolify = 6; Custom = 3 } } `
            -Confirm { param($Lines) $script:gateLines = @($Lines); $true } `
            -ShowMessage { throw 'must not cancel' } `
            -Run { param($Crumb) $script:ran = $true }
        $script:gateLines | Should -Contain ((Get-Translation 'FirewallRuleCountWinToolify') -f 6)
        $script:gateLines | Should -Contain ((Get-Translation 'FirewallRuleCountCustom') -f 3)
        $script:ran | Should -BeTrue
    }

    It 'runs nothing when the gate is refused' {
        $script:shown = $null
        Invoke-WtResetFirewallRulesAction `
            -GetCounts { [PSCustomObject]@{ WinToolify = 6; Custom = 3 } } `
            -Confirm { param($Lines) $false } `
            -ShowMessage { param($Lines) $script:shown = @($Lines) } `
            -Run { throw 'must not reset the firewall' }
        @($script:shown) | Should -Be @((Get-Translation 'ActionCancelled'))
    }
}

Describe 'Row item filters retire only their own layer of a mixed Apply Blocklist entry' {
    <#
    .SYNOPSIS
        Exercises the REAL default -RetireRecords scriptblock of each row
        (not the stub every other test in this file uses), since that is
        the only way the literal 'HostsBlock' / 'FirewallBlock' ItemFilter
        ever runs. Redirects $env:ProgramData / $env:LOCALAPPDATA for the
        width of this block, since the row's own default never accepts a
        -TestRootOverride.
    #>
    BeforeEach {
        $script:pinRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wt-row-retire-' + [guid]::NewGuid().ToString('N'))
        $script:pinProgramData = Join-Path $script:pinRoot 'ProgramData'
        $script:pinLocalAppData = Join-Path $script:pinRoot 'LocalAppData'
        New-Item -ItemType Directory -Path $script:pinProgramData -Force | Out-Null
        New-Item -ItemType Directory -Path $script:pinLocalAppData -Force | Out-Null
        $script:savedProgramData = $env:ProgramData
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $env:ProgramData = $script:pinProgramData
        $env:LOCALAPPDATA = $script:pinLocalAppData
        Write-WtUndoEntry -Scope Machine -Action 'Apply Blocklist' -Items @(
            [PSCustomObject]@{ ItemType = 'HostsBlock'; Tier = 'spy' }
            [PSCustomObject]@{ ItemType = 'FirewallBlock'; Tier = 'spy' }
        ) | Out-Null
    }
    AfterEach {
        $env:ProgramData = $script:savedProgramData
        $env:LOCALAPPDATA = $script:savedLocalAppData
        if (Test-Path -LiteralPath $script:pinRoot) { Remove-Item -LiteralPath $script:pinRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Invoke-WtResetHostsFileWrite retires only the HostsBlock layer and leaves FirewallBlock restorable' {
        & $script:CaptureLines {
            Invoke-WtResetHostsFileWrite -MarkedCount 1 `
                -GetHostsPath { Join-Path $TestDrive 'hosts' } `
                -BackupHosts { param($Path) 'backup.bak' } `
                -WriteHosts { param($Path, $Text) } `
                -FlushDns { @() }
        } | Out-Null

        $entry = @(Get-WtUndoEntries)[0]
        $hosts = @($entry.Items | Where-Object { $_.ItemType -eq 'HostsBlock' })[0]
        $firewall = @($entry.Items | Where-Object { $_.ItemType -eq 'FirewallBlock' })[0]
        Test-WtUndoItemClosed -Item $hosts | Should -BeTrue
        Test-WtUndoItemClosed -Item $firewall | Should -BeFalse
    }

    It 'Invoke-WtResetFirewallRulesCommands retires only the FirewallBlock layer and leaves HostsBlock restorable' {
        & $script:CaptureLines {
            Invoke-WtResetFirewallRulesCommands -RunReset { @() } -GetProfileState { @() } -SetProfileState { throw 'must not set anything' }
        } | Out-Null

        $entry = @(Get-WtUndoEntries)[0]
        $hosts = @($entry.Items | Where-Object { $_.ItemType -eq 'HostsBlock' })[0]
        $firewall = @($entry.Items | Where-Object { $_.ItemType -eq 'FirewallBlock' })[0]
        Test-WtUndoItemClosed -Item $firewall | Should -BeTrue
        Test-WtUndoItemClosed -Item $hosts | Should -BeFalse
    }
}

Describe 'Ag Onarimi group wiring' {
    BeforeAll {
        $script:NetworkGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupNetworkRepair' } | Select-Object -First 1
        $script:NetworkRows = @(& $script:NetworkGroup.GetRows)
        $script:NewNames = @('RestartNetworkAdapters', 'ForgetWifiProfile', 'ResetWinsock', 'ResetTcpIpStack', 'ResetWinHttpProxy', 'ResetHostsFile', 'ResetFirewallRules')
    }

    It 'ends with the seven new rows, in catalogue order, after the rows that were already there' {
        $names = @($script:NetworkRows | ForEach-Object { [string]$_.Name })
        @($names[-7..-1]) | Should -Be $script:NewNames
    }

    It 'marks the two adapter/winsock rows captured and the five panel rows not' {
        $byName = @{}
        foreach ($row in $script:NetworkRows) { $byName[[string]$row.Name] = $row }
        [bool]$byName['RestartNetworkAdapters'].Data.Captured | Should -BeTrue
        [bool]$byName['ResetWinsock'].Data.Captured | Should -BeTrue
        foreach ($name in @('ForgetWifiProfile', 'ResetTcpIpStack', 'ResetWinHttpProxy', 'ResetHostsFile', 'ResetFirewallRules')) {
            [bool]$byName[$name].Data.Captured | Should -BeFalse -Because "$name asks the user something before it runs"
        }
    }

    It 'carries the catalogue risk badges' {
        $byName = @{}
        foreach ($row in $script:NetworkRows) { $byName[[string]$row.Name] = $row }
        foreach ($name in @('RestartNetworkAdapters', 'ForgetWifiProfile', 'ResetWinsock', 'ResetWinHttpProxy', 'ResetHostsFile')) {
            [string]$byName[$name].Risk | Should -Be 'CAUTION'
        }
        [string]$byName['ResetTcpIpStack'].Risk | Should -Be 'ADVANCED'
        [string]$byName['ResetFirewallRules'].Risk | Should -Be 'ADVANCED'
    }

    It 'never puts a Read-Host inside a captured row - it would deadlock behind the panel' {
        foreach ($row in $script:NetworkRows) {
            if ([bool]$row.Data.Captured) {
                [string]$row.Data.Action | Should -Not -Match 'Read-Host'
            }
        }
    }

    It 'resolves every new label in both dictionaries, ASCII only and at most 45 characters' {
        foreach ($name in $script:NewNames) {
            foreach ($language in @('EN', 'TR')) {
                $script:Translations[$language].ContainsKey($name) | Should -BeTrue -Because "$language needs '$name'"
                $value = [string]$script:Translations[$language][$name]
                $value | Should -Not -BeNullOrEmpty
                $value.Length | Should -BeLessOrEqual 45 -Because "'$name' is a row label in $language"
                ([regex]::Matches($value, '[^\x00-\x7F]')).Count | Should -Be 0 -Because "'$name' must be pure ASCII in $language"
            }
        }
    }
}
