# DNS preset catalog, DoH support, adapter capture state.
# Covered by: tests/DnsPreset.Tests.ps1

function Get-WtDnsPresetCatalog {
    <#
    .SYNOPSIS
        The DNS-over-HTTPS preset catalog: 6 providers, with IPv4/IPv6/DoH
        values taken from winutil/config/dns.json. Every preset is CAUTION
        since it rewrites the DNS servers of every adapter.
    #>
    return @(
        [PSCustomObject]@{ Name = 'Cloudflare'; Risk = 'CAUTION'; IPv4Primary = '1.1.1.1'; IPv4Secondary = '1.0.0.1'; IPv6Primary = '2606:4700:4700::1111'; IPv6Secondary = '2606:4700:4700::1001'; DohTemplate = 'https://cloudflare-dns.com/dns-query' }
        [PSCustomObject]@{ Name = 'Cloudflare (Malware Blocking)'; Risk = 'CAUTION'; IPv4Primary = '1.1.1.2'; IPv4Secondary = '1.0.0.2'; IPv6Primary = '2606:4700:4700::1112'; IPv6Secondary = '2606:4700:4700::1002'; DohTemplate = 'https://security.cloudflare-dns.com/dns-query' }
        [PSCustomObject]@{ Name = 'Quad9'; Risk = 'CAUTION'; IPv4Primary = '9.9.9.9'; IPv4Secondary = '149.112.112.112'; IPv6Primary = '2620:fe::fe'; IPv6Secondary = '2620:fe::9'; DohTemplate = 'https://dns.quad9.net/dns-query' }
        [PSCustomObject]@{ Name = 'Google'; Risk = 'CAUTION'; IPv4Primary = '8.8.8.8'; IPv4Secondary = '8.8.4.4'; IPv6Primary = '2001:4860:4860::8888'; IPv6Secondary = '2001:4860:4860::8844'; DohTemplate = 'https://dns.google/dns-query' }
        [PSCustomObject]@{ Name = 'OpenDNS'; Risk = 'CAUTION'; IPv4Primary = '208.67.222.222'; IPv4Secondary = '208.67.220.220'; IPv6Primary = '2620:119:35::35'; IPv6Secondary = '2620:119:53::53'; DohTemplate = 'https://doh.opendns.com/dns-query' }
        [PSCustomObject]@{ Name = 'AdGuard (Ads & Trackers)'; Risk = 'CAUTION'; IPv4Primary = '94.140.14.14'; IPv4Secondary = '94.140.15.15'; IPv6Primary = '2a10:50c0::ad1:ff'; IPv6Secondary = '2a10:50c0::ad2:ff'; DohTemplate = 'https://dns.adguard-dns.com/dns-query' }
    )
}

$script:WtDohSupportedCache = $null

function Test-WtManifestMayExport {
    <#
    .SYNOPSIS
        PURE over one file: $false only when the module manifest at
        ManifestPath exists and does not name CommandName at all - then
        Get-Command cannot find the command either, since command
        discovery reads exactly that export list. A missing or unreadable
        manifest says nothing, so $true: the caller still asks Get-Command.
    #>
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$ManifestPath
    )
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $true }
    try { $text = [System.IO.File]::ReadAllText($ManifestPath) } catch { return $true }
    return ($text.IndexOf($CommandName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-WtDohSupported {
    <#
    .SYNOPSIS
        Feature-detects native DoH client support via cmdlet presence, not
        a build-number gate: no documented minimum build exists (19628, the
        only one Microsoft ever published, is Insider-only). Checks the
        DnsClient manifest first for speed, then caches the answer per session.
    #>
    param(
        [scriptblock]$GetCommandAction = {
            $root = [string]$env:SystemRoot
            if ($root) {
                $manifest = Join-Path $root 'System32\WindowsPowerShell\v1.0\Modules\DnsClient\DnsClient.psd1'
                if (-not (Test-WtManifestMayExport -CommandName 'Add-DnsClientDohServerAddress' -ManifestPath $manifest)) { return $null }
            }
            Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue
        }
    )

    $useMemory = -not $PSBoundParameters.ContainsKey('GetCommandAction')
    if ($useMemory -and $null -ne $script:WtDohSupportedCache) { return [bool]$script:WtDohSupportedCache }
    $supported = [bool](& $GetCommandAction)
    if ($useMemory) { $script:WtDohSupportedCache = $supported }
    return $supported
}

function Get-WtDohServerAddressList {
    <#
    .SYNOPSIS
        The machine's registered DoH server entries, or an empty list on a
        build with no native DoH client: the cmdlet does not exist there,
        and a missing command throws CommandNotFoundException that no
        -ErrorAction can catch, so the presence probe must run first.
    #>
    param(
        [scriptblock]$GetCommandAction = {
            Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetDohAction = {
            Get-DnsClientDohServerAddress
        }
    )

    if (-not (& $GetCommandAction)) { return @() }
    return @(& $GetDohAction)
}

function Get-WtDnsAdapterCaptureState {
    <#
    .SYNOPSIS
        Pre-change capture for every Up adapter: current IPv4/IPv6 server
        addresses (empty array = DHCP) and the full pre-existing DoH entry
        for any touched address, so undo can restore it. The add/modify
        split is computed here, before Apply runs, since Add- fails for an
        address already known.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Preset,

        [bool]$DohSupported = $false,

        [scriptblock]$GetAdaptersAction = {
            Get-NetAdapter | Where-Object Status -eq 'Up'
        },

        [scriptblock]$GetServerAddressAction = {
            param($InterfaceIndex, $AddressFamily)
            (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily $AddressFamily).ServerAddresses
        },

        [scriptblock]$GetDohAction = { Get-WtDohServerAddressList }
    )

    $touchedAddresses = @($Preset.IPv4Primary, $Preset.IPv4Secondary, $Preset.IPv6Primary, $Preset.IPv6Secondary)
    $allDohEntries = @(& $GetDohAction)
    $adapters = @(& $GetAdaptersAction)

    $items = foreach ($adapter in $adapters) {
        $previousIPv4 = @(& $GetServerAddressAction $adapter.InterfaceIndex 'IPv4')
        $previousIPv6 = @(& $GetServerAddressAction $adapter.InterfaceIndex 'IPv6')
        $previousDoh = @($allDohEntries | Where-Object { $touchedAddresses -contains $_.ServerAddress } | ForEach-Object {
            [PSCustomObject]@{
                Address            = $_.ServerAddress
                Template           = $_.DohTemplate
                AllowFallbackToUdp = $_.AllowFallbackToUdp
                AutoUpgrade        = $_.AutoUpgrade
            }
        })

        $previousDohAddresses = @($previousDoh | ForEach-Object { $_.Address })

        [PSCustomObject]@{
            ItemType           = 'DnsConfig'
            InterfaceIndex     = $adapter.InterfaceIndex
            PreviousIPv4       = $previousIPv4
            PreviousIPv6       = $previousIPv6
            PreviousDohEntries = $previousDoh
            AddedDohAddresses    = if ($DohSupported) { @($touchedAddresses | Where-Object { $previousDohAddresses -notcontains $_ }) } else { @() }
            ModifiedDohAddresses = if ($DohSupported) { $previousDohAddresses } else { @() }
        }
    }

    return @($items)
}
