#Requires -Modules Pester

<#
.SYNOPSIS
    The blocklist tier catalog, the downloader/parser (tested against
    fake responses shaped like the real WindowsSpyBlocker files -
    0.0.0.0 <domain> for hosts, bare IPv4 for firewall), the idempotent
    hosts-diff computation, and the firewall IP validation/chunking/
    naming plan.

    CaptureState must never perform the actual hosts-file write or
    firewall-rule creation: Invoke-WtGuardedChange writes the undo entry
    after CaptureState returns and before Apply runs, so a write inside
    CaptureState would happen before any undo record exists.
    Get-WtHostsLinesToAdd and Get-WtFirewallRulePlan are therefore
    pure/read-only; the actual write/rule-creation happens in
    Invoke-WtApplyBlocklistSelection's Apply delegate.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtBlocklistTierCatalog' {
    BeforeAll {
        $script:TierCatalog = Get-WtBlocklistTierCatalog
    }

    It 'has exactly 3 tiers: Spy, Update, Extra' {
        @($TierCatalog | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be @('Extra', 'Spy', 'Update')
    }

    It 'tags Spy=SAFE, Update=CAUTION, Extra=ADVANCED, per upstream''s own warnings' {
        (($TierCatalog | Where-Object Name -eq 'Spy').Risk) | Should -Be 'SAFE'
        (($TierCatalog | Where-Object Name -eq 'Update').Risk) | Should -Be 'CAUTION'
        (($TierCatalog | Where-Object Name -eq 'Extra').Risk) | Should -Be 'ADVANCED'
    }

    It 'gives every tier a HostsUrl and FirewallUrl pointing at the confirmed WindowsSpyBlocker raw paths' {
        foreach ($tier in $TierCatalog) {
            $tier.HostsUrl | Should -Match "raw\.githubusercontent\.com/crazy-max/WindowsSpyBlocker/master/data/hosts/$($tier.Name.ToLower()).txt"
            $tier.FirewallUrl | Should -Match "raw\.githubusercontent\.com/crazy-max/WindowsSpyBlocker/master/data/firewall/$($tier.Name.ToLower()).txt"
        }
    }

    It 'labels each tier beyond its bare name through a translation key' {
        foreach ($tier in $TierCatalog) {
            $tier.DisplayLabel | Should -Match ('^' + $tier.Name + ' - .+') -Because $tier.Name
            $tier.LabelKey | Should -Be ('CatBlocklistTier' + $tier.Name + 'Label')
        }
    }
}

Describe 'Invoke-WtDownloadBlocklistTier' {
    It 'strips header comment lines and blank lines, returning hosts-format content lines verbatim (no re-parsing)' {
        $fakeContent = @"
### WindowsSpyBlocker - Hosts spy rules
### License: MIT
### More info: https://github.com/crazy-max/WindowsSpyBlocker

0.0.0.0 a.ads1.msn.com
0.0.0.0 a.ads2.msads.net
"@
        $action = { param($url) [PSCustomObject]@{ Content = $fakeContent } }
        $lines = @(Invoke-WtDownloadBlocklistTier -Url 'https://example/spy.txt' -GetWebRequestAction $action)

        $lines.Count | Should -Be 2
        $lines[0] | Should -Be '0.0.0.0 a.ads1.msn.com'
        $lines[1] | Should -Be '0.0.0.0 a.ads2.msads.net'
    }

    It 'returns bare-IP firewall lines verbatim' {
        $fakeContent = @"
### WindowsSpyBlocker - Firewall spy rules
### License: MIT

13.64.90.137
13.68.31.193
"@
        $action = { param($url) [PSCustomObject]@{ Content = $fakeContent } }
        $lines = @(Invoke-WtDownloadBlocklistTier -Url 'https://example/spy.txt' -GetWebRequestAction $action)

        $lines.Count | Should -Be 2
        $lines[0] | Should -Be '13.64.90.137'
    }

    It 'propagates the exception on a download failure rather than returning a partial or empty list' {
        $action = { param($url) throw 'simulated network failure' }
        { Invoke-WtDownloadBlocklistTier -Url 'https://example/spy.txt' -GetWebRequestAction $action } | Should -Throw
    }
}

Describe 'Get-WtHostsLinesToAdd' {
    It 'computes the marker-suffixed form and includes only lines not already present' {
        $upstream = @('0.0.0.0 a.ads1.msn.com', '0.0.0.0 a.ads2.msads.net')
        $currentHosts = "127.0.0.1 localhost`n0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)`n"
        $action = { $currentHosts }.GetNewClosure()

        $toAdd = @(Get-WtHostsLinesToAdd -Lines $upstream -Tier 'Spy' -ReadHostsAction $action)

        $toAdd.Count | Should -Be 1
        $toAdd[0] | Should -Be "0.0.0.0 a.ads2.msads.net`t# WinToolify (Spy)"
    }

    It 'returns an empty list on a second application (fully idempotent)' {
        $upstream = @('0.0.0.0 a.ads1.msn.com')
        $currentHosts = "0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)`n"
        $action = { $currentHosts }.GetNewClosure()

        @(Get-WtHostsLinesToAdd -Lines $upstream -Tier 'Spy' -ReadHostsAction $action).Count | Should -Be 0
    }

    It 'never re-parses the upstream line - the marker-suffixed form is the verbatim upstream line plus the marker, nothing extracted or recomposed' {
        $upstream = @('0.0.0.0 a.ads1.msn.com')
        $action = { '' }
        $toAdd = @(Get-WtHostsLinesToAdd -Lines $upstream -Tier 'Spy' -ReadHostsAction $action)
        $toAdd[0] | Should -Be "0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)"
    }
}

Describe 'Remove-WtHostsBlocklistLines' {
    It 'removes only its own exact recorded lines, leaving a pre-existing unrelated line intact' {
        $content = "127.0.0.1 localhost`n0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)`n192.168.1.1 my-own-entry`n"
        $linesToRemove = @("0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)")

        $result = Remove-WtHostsBlocklistLines -Content $content -Lines $linesToRemove

        $result | Should -Match 'my-own-entry'
        $result | Should -Match 'localhost'
        $result | Should -Not -Match 'a\.ads1\.msn\.com'
    }

    It 'is a no-op when none of the recorded lines are present' {
        $content = "127.0.0.1 localhost`n"
        $result = Remove-WtHostsBlocklistLines -Content $content -Lines @("0.0.0.0 a.ads1.msn.com`t# WinToolify (Spy)")
        $result | Should -Match 'localhost'
    }
}

Describe 'Get-WtFirewallRulePlan' {
    It 'drops an unparseable IP and counts it, without passing it to any rule' {
        $ips = @('13.64.90.137', 'not-an-ip', '13.68.31.193')
        $plan = Get-WtFirewallRulePlan -IPs $ips -Tier 'Spy' -ChunkSize 500

        $plan.DroppedCount | Should -Be 1
        $allAddresses = $plan.Chunks | ForEach-Object { $_.Addresses } | Sort-Object
        $allAddresses | Should -Not -Contain 'not-an-ip'
        @($allAddresses).Count | Should -Be 2
    }

    It 'chunks at the given ChunkSize and names each chunk WinToolify-Block-<Tier>-<Index>' {
        $ips = 1..1001 | ForEach-Object { "10.0.$([Math]::Floor($_ / 256)).$($_ % 256)" }
        $plan = Get-WtFirewallRulePlan -IPs $ips -Tier 'Extra' -ChunkSize 500

        $plan.Chunks.Count | Should -Be 3
        $plan.Chunks[0].RuleName | Should -Be 'WinToolify-Block-Extra-0'
        $plan.Chunks[1].RuleName | Should -Be 'WinToolify-Block-Extra-1'
        $plan.Chunks[2].RuleName | Should -Be 'WinToolify-Block-Extra-2'
        $plan.Chunks[0].Addresses.Count | Should -Be 500
        $plan.Chunks[2].Addresses.Count | Should -Be 1
    }

    It 'produces zero chunks for an empty (all-invalid) input, not an error' {
        $plan = Get-WtFirewallRulePlan -IPs @('not-an-ip') -Tier 'Spy' -ChunkSize 500
        $plan.Chunks.Count | Should -Be 0
        $plan.DroppedCount | Should -Be 1
    }

    It 'keeps a start-end IPv4 range verbatim (WindowsSpyBlocker update/extra ship 8 such lines; New-NetFirewallRule -RemoteAddress documents "IPv4 Range: 1.2.3.4-1.2.3.7") and still drops a range whose end is not an address' {
        $ips = @('65.55.138.0-65.55.138.255', '13.64.90.137', '1.2.3.4-not-an-ip', '1.2.3.4-1.2.3.7-1.2.3.9')
        $plan = Get-WtFirewallRulePlan -IPs $ips -Tier 'Update' -ChunkSize 500

        $allAddresses = @($plan.Chunks | ForEach-Object { $_.Addresses })
        $allAddresses | Should -Contain '65.55.138.0-65.55.138.255'
        $allAddresses | Should -Contain '13.64.90.137'
        @($allAddresses).Count | Should -Be 2
        $plan.DroppedCount | Should -Be 2
    }
}
