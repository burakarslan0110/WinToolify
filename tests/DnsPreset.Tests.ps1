#Requires -Modules Pester

<#
.SYNOPSIS
    The DNS-over-HTTPS preset catalog, the DoH-support probe, the adapter
    capture step, and the extracted apply logic (Set-WtDnsAdapterConfiguration),
    kept independently testable from the interactive wrapper. No DNS cmdlet
    exists on the macOS dev host, so every test injects a fake action.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtDnsPresetCatalog' {
    BeforeAll {
        $script:DnsCatalog = Get-WtDnsPresetCatalog
    }

    It 'has exactly the 6 defined presets' {
        @($DnsCatalog | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be @(
            'AdGuard (Ads & Trackers)', 'Cloudflare', 'Cloudflare (Malware Blocking)', 'Google', 'OpenDNS', 'Quad9'
        )
    }

    It 'gives Cloudflare the exact IPv4/IPv6/DoH values from winutil' {
        $entry = $DnsCatalog | Where-Object Name -eq 'Cloudflare'
        $entry.IPv4Primary | Should -Be '1.1.1.1'
        $entry.IPv4Secondary | Should -Be '1.0.0.1'
        $entry.IPv6Primary | Should -Be '2606:4700:4700::1111'
        $entry.IPv6Secondary | Should -Be '2606:4700:4700::1001'
        $entry.DohTemplate | Should -Be 'https://cloudflare-dns.com/dns-query'
    }

    It 'gives Quad9 the exact IPv4/IPv6/DoH values from winutil' {
        $entry = $DnsCatalog | Where-Object Name -eq 'Quad9'
        $entry.IPv4Primary | Should -Be '9.9.9.9'
        $entry.IPv4Secondary | Should -Be '149.112.112.112'
        $entry.IPv6Primary | Should -Be '2620:fe::fe'
        $entry.IPv6Secondary | Should -Be '2620:fe::9'
        $entry.DohTemplate | Should -Be 'https://dns.quad9.net/dns-query'
    }
}

Describe 'Test-WtDohSupported' {
    It 'returns $true when the injected Get-Command action finds the cmdlet' {
        $action = { [PSCustomObject]@{ Name = 'Add-DnsClientDohServerAddress' } }
        Test-WtDohSupported -GetCommandAction $action | Should -BeTrue
    }

    It 'returns $false when the injected Get-Command action returns nothing, without calling a real cmdlet' {
        $action = { $null }
        Test-WtDohSupported -GetCommandAction $action | Should -BeFalse
    }

    It 'Test-WtManifestMayExport reads the export list Get-Command discovery reads, and says nothing without a manifest' {
        $manifest = Join-Path $TestDrive 'DnsClient.psd1'
        Set-Content -LiteralPath $manifest -Value "FunctionsToExport = @('Get-DnsClientServerAddress')"
        Test-WtManifestMayExport -CommandName 'Add-DnsClientDohServerAddress' -ManifestPath $manifest | Should -BeFalse
        Set-Content -LiteralPath $manifest -Value "FunctionsToExport = @(`n    'Add-DnsClientDohServerAddress'`n)"
        Test-WtManifestMayExport -CommandName 'Add-DnsClientDohServerAddress' -ManifestPath $manifest | Should -BeTrue
        Test-WtManifestMayExport -CommandName 'Add-DnsClientDohServerAddress' -ManifestPath (Join-Path $TestDrive 'missing.psd1') | Should -BeTrue
    }

    It 'remembers the default probe for the session; an injected action never uses the memory' {
        $old = $script:WtDohSupportedCache
        try {
            $script:WtDohSupportedCache = $true
            Test-WtDohSupported | Should -BeTrue
            $script:WtDohSupportedCache = $false
            Test-WtDohSupported | Should -BeFalse
            Test-WtDohSupported -GetCommandAction { [PSCustomObject]@{ Name = 'Add-DnsClientDohServerAddress' } } | Should -BeTrue
            $script:WtDohSupportedCache | Should -BeFalse
        }
        finally { $script:WtDohSupportedCache = $old }
    }
}

Describe 'Get-WtDohServerAddressList' {
    It 'returns an empty list and never calls the cmdlet on a build that does not have it (regression: the missing command threw out of the apply and closed the window)' {
        $list = Get-WtDohServerAddressList -GetCommandAction { $null } -GetDohAction { throw 'must not be called' }
        @($list).Count | Should -Be 0
    }

    It 'returns the DoH entries when the cmdlet is there' {
        $entries = @([PSCustomObject]@{ ServerAddress = '1.1.1.1' }, [PSCustomObject]@{ ServerAddress = '9.9.9.9' })
        $list = Get-WtDohServerAddressList -GetCommandAction { [PSCustomObject]@{ Name = 'Get-DnsClientDohServerAddress' } } -GetDohAction { $entries }
        @($list | ForEach-Object ServerAddress) | Should -Be @('1.1.1.1', '9.9.9.9')
    }

    It 'is what Get-WtDnsAdapterCaptureState reaches for by default, so no caller has to remember the probe' {
        $parameter = (Get-Command Get-WtDnsAdapterCaptureState).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'GetDohAction' }
        $parameter.DefaultValue.Extent.Text | Should -BeLike '*Get-WtDohServerAddressList*'
    }
}

Describe 'Get-WtDnsAdapterCaptureState' {
    BeforeAll {
        $script:Preset = (Get-WtDnsPresetCatalog) | Where-Object Name -eq 'Cloudflare'
    }

    It 'records an empty PreviousIPv4/PreviousIPv6 for an adapter currently on DHCP' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) @() }
        $getDoh = { @() }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        @($items).Count | Should -Be 1
        $items[0].InterfaceIndex | Should -Be 12
        @($items[0].PreviousIPv4).Count | Should -Be 0
        @($items[0].PreviousIPv6).Count | Should -Be 0
    }

    It 'declares empty AddedDohAddresses and ModifiedDohAddresses when -DohSupported is omitted (default $false)' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) @() }
        $getDoh = { @() }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        $items[0].PSObject.Properties.Name | Should -Contain 'AddedDohAddresses'
        $items[0].PSObject.Properties.Name | Should -Contain 'ModifiedDohAddresses'
        @($items[0].AddedDohAddresses).Count | Should -Be 0
        @($items[0].ModifiedDohAddresses).Count | Should -Be 0
    }

    It 'plans all 4 preset addresses as AddedDohAddresses when DohSupported and the DoH list is empty' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) @() }
        $getDoh = { @() }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -DohSupported $true -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        @($items[0].AddedDohAddresses | Sort-Object) | Should -Be @('1.0.0.1', '1.1.1.1', '2606:4700:4700::1001', '2606:4700:4700::1111' | Sort-Object)
        @($items[0].ModifiedDohAddresses).Count | Should -Be 0
    }

    It 'plans a pre-existing DoH address as ModifiedDohAddresses instead of AddedDohAddresses' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) @() }
        $getDoh = {
            @(
                [PSCustomObject]@{ ServerAddress = '1.1.1.1'; DohTemplate = 'https://custom.example/dns-query'; AllowFallbackToUdp = $true; AutoUpgrade = $false }
            )
        }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -DohSupported $true -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        @($items[0].ModifiedDohAddresses) | Should -Be @('1.1.1.1')
        @($items[0].AddedDohAddresses | Sort-Object) | Should -Be @('1.0.0.1', '2606:4700:4700::1001', '2606:4700:4700::1111' | Sort-Object)
    }

    It 'persists the capture-time AddedDohAddresses plan through Write-WtUndoEntry / Get-WtUndoEntries (regression: undo entry must not rely on Apply mutating the item)' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) @() }
        $getDoh = { @() }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -DohSupported $true -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        $fakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Write-WtUndoEntry -Scope Machine -Action 'dns-preset-roundtrip' -Items $items -TestRootOverride $fakeRoot | Out-Null

        $entries = Get-WtUndoEntries -TestRootOverride $fakeRoot
        $persistedItem = $entries[0].Items[0]

        @($persistedItem.AddedDohAddresses).Count | Should -Be 4
        @($persistedItem.AddedDohAddresses | Sort-Object) | Should -Be @('1.0.0.1', '1.1.1.1', '2606:4700:4700::1001', '2606:4700:4700::1111' | Sort-Object)
    }

    It 'records a non-empty PreviousIPv4 for an adapter with static DNS' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) if ($family -eq 'IPv4') { @('10.0.0.1', '10.0.0.2') } else { @() } }
        $getDoh = { @() }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        @($items[0].PreviousIPv4) | Should -Be @('10.0.0.1', '10.0.0.2')
    }

    It 'records a PreviousDohEntries entry for a pre-existing DoH entry whose address the preset is about to touch' {
        $getAdapters = { @([PSCustomObject]@{ InterfaceIndex = 12 }) }
        $getServerAddress = { param($idx, $family) @() }
        $getDoh = {
            @(
                [PSCustomObject]@{ ServerAddress = '1.1.1.1'; DohTemplate = 'https://custom.example/dns-query'; AllowFallbackToUdp = $true; AutoUpgrade = $false }
                [PSCustomObject]@{ ServerAddress = '9.9.9.9'; DohTemplate = 'https://untouched.example/dns-query'; AllowFallbackToUdp = $true; AutoUpgrade = $false }
            )
        }

        $items = Get-WtDnsAdapterCaptureState -Preset $Preset -GetAdaptersAction $getAdapters -GetServerAddressAction $getServerAddress -GetDohAction $getDoh

        $items[0].PreviousDohEntries.Count | Should -Be 1
        $items[0].PreviousDohEntries[0].Address | Should -Be '1.1.1.1'
        $items[0].PreviousDohEntries[0].Template | Should -Be 'https://custom.example/dns-query'
    }
}

Describe 'Set-WtDnsAdapterConfiguration' {
    BeforeAll {
        $script:Preset = (Get-WtDnsPresetCatalog) | Where-Object Name -eq 'Cloudflare'
        $script:Item = [PSCustomObject]@{ InterfaceIndex = 12 }
    }

    It 'sets IPv4 first, unconditionally, before attempting IPv6 or DoH' {
        $callOrder = New-Object System.Collections.Generic.List[string]
        $setIPv4 = { param($idx, $addrs) $callOrder.Add('IPv4') }.GetNewClosure()
        $setIPv6 = { param($idx, $addrs) $callOrder.Add('IPv6') }.GetNewClosure()
        $addDoh = { param($addr, $template) $callOrder.Add('Doh') }.GetNewClosure()

        Set-WtDnsAdapterConfiguration -Item $Item -Preset $Preset -DohSupported $true -SetIPv4Action $setIPv4 -SetIPv6Action $setIPv6 -AddDohAction $addDoh | Out-Null

        $callOrder[0] | Should -Be 'IPv4'
    }

    It 'still sets the IPv4 servers when the IPv6 call throws' {
        $ipv4Called = New-Object System.Collections.Generic.List[string]
        $setIPv4 = { param($idx, $addrs) $ipv4Called.Add('called') }.GetNewClosure()
        $setIPv6 = { param($idx, $addrs) throw 'simulated: IPv6 disabled on this adapter' }
        $addDoh = { param($addr, $template) }

        { Set-WtDnsAdapterConfiguration -Item $Item -Preset $Preset -DohSupported $true -SetIPv4Action $setIPv4 -SetIPv6Action $setIPv6 -AddDohAction $addDoh } | Should -Not -Throw
        $ipv4Called.Count | Should -Be 1
    }

    It 'still sets IPv4 and IPv6 when every DoH registration (add and modify) throws' {
        $ipv4Called = New-Object System.Collections.Generic.List[string]
        $ipv6Called = New-Object System.Collections.Generic.List[string]
        $setIPv4 = { param($idx, $addrs) $ipv4Called.Add('called') }.GetNewClosure()
        $setIPv6 = { param($idx, $addrs) $ipv6Called.Add('called') }.GetNewClosure()
        $addDoh = { param($addr, $template) throw 'simulated: address already registered' }
        $setDoh = { param($addr, $template) throw 'simulated: modify failed too' }

        $result = Set-WtDnsAdapterConfiguration -Item $Item -Preset $Preset -DohSupported $true -SetIPv4Action $setIPv4 -SetIPv6Action $setIPv6 -AddDohAction $addDoh -SetDohAction $setDoh

        $ipv4Called.Count | Should -Be 1
        $ipv6Called.Count | Should -Be 1
        @($result.AddedDohAddresses).Count | Should -Be 0
        @($result.ModifiedDohAddresses).Count | Should -Be 0
    }

    It 'modifies (Set-) an address the Add call rejects as already registered - the built-in Cloudflare/Google/Quad9 entries ship with AutoUpgrade False - and reports it under ModifiedDohAddresses, not AddedDohAddresses' {
        $modified = New-Object System.Collections.Generic.List[string]
        $setIPv4 = { param($idx, $addrs) }
        $setIPv6 = { param($idx, $addrs) }
        $addDoh = {
            param($addr, $template)
            if ($addr -in @('1.1.1.1', '1.0.0.1')) { throw 'simulated: The object already exists.' }
        }
        $setDoh = { param($addr, $template) if ($template -ne 'https://cloudflare-dns.com/dns-query') { throw 'wrong template' }; $modified.Add($addr) }.GetNewClosure()

        $result = Set-WtDnsAdapterConfiguration -Item $Item -Preset $Preset -DohSupported $true -SetIPv4Action $setIPv4 -SetIPv6Action $setIPv6 -AddDohAction $addDoh -SetDohAction $setDoh

        @($result.AddedDohAddresses | Sort-Object) | Should -Be @('2606:4700:4700::1001', '2606:4700:4700::1111')
        @($result.ModifiedDohAddresses | Sort-Object) | Should -Be @('1.0.0.1', '1.1.1.1')
        @($modified | Sort-Object) | Should -Be @('1.0.0.1', '1.1.1.1')
    }

    It 'skips DoH registration entirely and reports no added addresses when DohSupported is $false' {
        $dohCalled = New-Object System.Collections.Generic.List[string]
        $setIPv4 = { param($idx, $addrs) }
        $setIPv6 = { param($idx, $addrs) }
        $addDoh = { param($addr, $template) $dohCalled.Add('called') }.GetNewClosure()

        $result = Set-WtDnsAdapterConfiguration -Item $Item -Preset $Preset -DohSupported $false -SetIPv4Action $setIPv4 -SetIPv6Action $setIPv6 -AddDohAction $addDoh

        $dohCalled.Count | Should -Be 0
        @($result.AddedDohAddresses).Count | Should -Be 0
    }

    It 'records every successfully-added DoH address when DohSupported is $true' {
        $setIPv4 = { param($idx, $addrs) }
        $setIPv6 = { param($idx, $addrs) }
        $addDoh = { param($addr, $template) }

        $result = Set-WtDnsAdapterConfiguration -Item $Item -Preset $Preset -DohSupported $true -SetIPv4Action $setIPv4 -SetIPv6Action $setIPv6 -AddDohAction $addDoh

        @($result.AddedDohAddresses | Sort-Object) | Should -Be @('1.0.0.1', '1.1.1.1', '2606:4700:4700::1001', '2606:4700:4700::1111' | Sort-Object)
    }
}
