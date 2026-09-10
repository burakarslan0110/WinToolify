# IP configuration, listening ports, adapters, Wi-Fi link, profiles, connections, hosts, internet and DNS tests.
# Covered by: tests/InfoNetwork.Tests.ps1

function Get-WtIpConfigSummaryLines {
    <#
    .SYNOPSIS
        One block per live adapter: IPv4 address with prefix, default
        gateway, DNS servers. Replaces the bare ipconfig row - the same
        answer, narrow enough to read in the panel without truncation;
        the verbose ipconfig /all row stays as the fallback. DNSServer
        holds one record per address family, so an IPv6-only resolver
        set is called out rather than shown as an empty cell.
    #>
    param(
        [scriptblock]$GetConfiguration = { Get-NetIPConfiguration -ErrorAction SilentlyContinue }
    )
    $configs = @()
    try { $configs = @(& $GetConfiguration) } catch { $configs = @() }
    if ($configs.Count -eq 0) { return [string[]]@((Get-Translation 'NoNetworkAdapterFound')) }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($config in $configs) {
        $lines.Add([string]$config.InterfaceAlias)

        $v4 = @($config.IPv4Address)
        $address = if ($v4.Count -gt 0) { (@($v4 | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })) -join ', ' } else { '-' }

        $gw = @($config.IPv4DefaultGateway)
        $gateway = if ($gw.Count -gt 0) { (@($gw | ForEach-Object { [string]$_.NextHop })) -join ', ' } else { '-' }

        $v4Dns = @($config.DNSServer | Where-Object { $_.AddressFamily -eq 2 })
        $dns = if ($v4Dns.Count -gt 0 -and @($v4Dns[0].ServerAddresses).Count -gt 0) { (@($v4Dns[0].ServerAddresses)) -join ', ' }
        elseif (@($config.DNSServer).Count -gt 0) { Get-Translation 'DnsIpv6Only' }
        else { '-' }

        $lines.Add(('  IPv4    : {0}' -f $address))
        $lines.Add(('  Gateway : {0}' -f $gateway))
        $lines.Add(('  DNS     : {0}' -f $dns))
        $lines.Add('')
    }
    return [string[]]$lines.ToArray()
}

function Get-WtListeningPortLines {
    <#
    .SYNOPSIS
        Every TCP port this machine listens on, joined to the program that
        owns it. Replaces the netstat -an row outright: netstat prints the
        ports with no owning process, which is the one column that makes
        the output actionable. The PID->name map uses an explicit loop,
        since Group-Object -AsHashTable's PSObject collections only index
        correctly by accident; a listener reported once per address
        family is deduplicated to one row per port+PID.
    #>
    param(
        [scriptblock]$GetListeners = { Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue },
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue }
    )
    $listeners = @()
    try { $listeners = @(& $GetListeners) } catch { $listeners = @() }
    if ($listeners.Count -eq 0) { return [string[]]@((Get-Translation 'NoListeningPort')) }

    $processes = @()
    try { $processes = @(& $GetProcesses) } catch { $processes = @() }
    $names = @{}
    foreach ($process in $processes) { $names[[int]$process.Id] = [string]$process.ProcessName }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0,-7} {1,-8} {2}' -f 'Port', 'PID', 'Process'))
    foreach ($listener in @($listeners | Sort-Object LocalPort)) {
        $key = '{0}|{1}' -f $listener.LocalPort, $listener.OwningProcess
        if (-not $seen.Add($key)) { continue }
        $pidValue = [int]$listener.OwningProcess
        $name = if ($names.ContainsKey($pidValue)) { $names[$pidValue] } else { Get-Translation 'UnknownProcess' }
        $lines.Add(('{0,-7} {1,-8} {2}' -f $listener.LocalPort, $pidValue, $name))
    }
    return [string[]]$lines.ToArray()
}


function Get-WtNetworkAdapterLines {
    <#
    .SYNOPSIS
        One row per network adapter: status, negotiated link speed, MAC and
        media type - the answer to "is this cable running at 1 Gbps, or did
        it fall back to 100". Sorted Up-first (plain Status sort would put
        'Disconnected' first); the compare is -cne, since tr-TR's dotless-I
        rules make a case-insensitive match on 'Up' unreliable. Property
        names stay native English - no localized table headers. A
        Hyper-V virtual switch adapter's made-up 10 Gbps link is called
        out, not shown as a real interface speed.
    #>
    param(
        [scriptblock]$GetAdapters = { Get-NetAdapter -ErrorAction SilentlyContinue }
    )
    $adapters = @()
    try { $adapters = @(@(& $GetAdapters) | Where-Object { $_ }) }
    catch { $adapters = @() }
    if ($adapters.Count -eq 0) { return [string[]]@((Get-Translation 'NetAdapterNoneFound')) }

    $ordered = @($adapters | Sort-Object @{ Expression = { [int]([string]$_.Status -cne 'Up') } }, @{ Expression = { [string]$_.Name } })
    $lines = New-Object System.Collections.Generic.List[string]
    $table = ($ordered | Format-Table -Property Name, Status, LinkSpeed, MacAddress, MediaType -AutoSize | Out-String -Width 110)
    foreach ($row in ($table -split "`r?`n")) {
        if (([string]$row).Trim()) { $lines.Add(([string]$row).TrimEnd()) }
    }

    $hasVirtual = $false
    foreach ($a in $ordered) {
        $name = [string]$a.Name
        if ($name -and $name.IndexOf('vEthernet', [System.StringComparison]::Ordinal) -ge 0) { $hasVirtual = $true }
    }
    if ($hasVirtual) {
        $lines.Add('')
        $lines.Add((Get-Translation 'NetAdapterVirtualNote'))
    }
    return [string[]]$lines.ToArray()
}

function Get-WtWifiLinkLines {
    <#
    .SYNOPSIS
        The connected wireless network with signal percentage, channel,
        radio type and TX/RX rate - "why is Wi-Fi slow" in one screen.
        netsh runs only behind a 'WlanSvc Running' guard (compared -cne,
        since tr-TR's dotless-I makes a case-insensitive match on
        'Running' unreliable), or a desktop with no wireless adapter
        shows a raw, localized netsh error; the report itself is passed
        through verbatim, since parsing Windows' own localized output
        would break on every non-English install.
    #>
    param(
        [scriptblock]$GetWlanServiceStatus = { (Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue).Status },
        [scriptblock]$GetInterfaceOutput = { netsh wlan show interfaces 2>&1 }
    )
    $status = ''
    try { $status = [string](& $GetWlanServiceStatus) }
    catch { $status = '' }
    if ($status -cne 'Running') { return [string[]]@((Get-Translation 'WifiServiceNotRunning')) }

    $raw = @()
    try { $raw = @(& $GetInterfaceOutput) }
    catch { $raw = @() }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $raw) {
        $text = ([string]$item).TrimEnd()
        if ($text.Trim()) { $lines.Add($text) }
    }
    if ($lines.Count -eq 0) { return [string[]]@((Get-Translation 'WifiLinkNoOutput')) }
    return [string[]]$lines.ToArray()
}

function Get-WtFirewallActionText {
    <#
    .SYNOPSIS
        DefaultInboundAction / DefaultOutboundAction in words.
        'NotConfigured' must not reach the panel raw: a factory-default
        machine reports it for both directions, which a home user would
        read as "nothing is blocked" when the effective Windows defaults
        are block inbound / allow outbound. Comparisons are -ceq, since
        tr-TR's dotless-I makes a case-insensitive match on
        'NotConfigured'/'Block' culture-dependent.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction
    )
    if ($Action -ceq 'Allow') { return [string](Get-Translation 'FirewallActionAllow') }
    if ($Action -ceq 'Block') { return [string](Get-Translation 'FirewallActionBlock') }
    if ((-not $Action) -or ($Action -ceq 'NotConfigured')) {
        $effective = if ($Direction -ceq 'Inbound') { Get-Translation 'FirewallActionBlock' } else { Get-Translation 'FirewallActionAllow' }
        return [string]((Get-Translation 'FirewallActionNotConfigured') -f $effective)
    }
    return $Action
}

function Get-WtNetworkProfileLines {
    <#
    .SYNOPSIS
        Is this network Public or Private, does Windows really see the
        internet, and which firewall profiles are on - the connection
        profile and the firewall profile folded into one row.
    #>
    param(
        [scriptblock]$GetConnectionProfiles = { Get-NetConnectionProfile -ErrorAction SilentlyContinue },
        [scriptblock]$GetFirewallProfiles = { Get-NetFirewallProfile -Profile Domain, Private, Public -ErrorAction SilentlyContinue }
    )
    $lines = New-Object System.Collections.Generic.List[string]

    $profiles = @()
    try { $profiles = @(@(& $GetConnectionProfiles) | Where-Object { $_ }) }
    catch { $profiles = @() }
    if ($profiles.Count -eq 0) {
        $lines.Add((Get-Translation 'NetProfileNoneFound'))
    }
    else {
        foreach ($p in $profiles) {
            $lines.Add(('{0}: {1} ({2})' -f (Get-Translation 'NetProfileNameLabel'), [string]$p.Name, [string]$p.InterfaceAlias))
            $lines.Add(('  {0}: {1}' -f (Get-Translation 'NetProfileCategoryLabel'), [string]$p.NetworkCategory))
            $lines.Add(('  {0}: {1}' -f (Get-Translation 'NetProfileIPv4Label'), [string]$p.IPv4Connectivity))
            $lines.Add(('  {0}: {1}' -f (Get-Translation 'NetProfileIPv6Label'), [string]$p.IPv6Connectivity))
        }
    }

    $lines.Add('')
    $lines.Add((Get-Translation 'FirewallProfilesHeader'))
    $firewall = @()
    try { $firewall = @(@(& $GetFirewallProfiles) | Where-Object { $_ }) }
    catch { $firewall = @() }
    if ($firewall.Count -eq 0) {
        $lines.Add(('  ' + (Get-Translation 'FirewallProfilesNotAvailable')))
    }
    else {
        foreach ($f in $firewall) {
            $state = if ([bool]$f.Enabled) { Get-Translation 'FirewallProfileOn' } else { Get-Translation 'FirewallProfileOff' }
            $lines.Add(('  {0}: {1}' -f [string]$f.Name, $state))
            $lines.Add(('    {0}: {1}' -f (Get-Translation 'FirewallInboundLabel'), (Get-WtFirewallActionText -Action ([string]$f.DefaultInboundAction) -Direction 'Inbound')))
            $lines.Add(('    {0}: {1}' -f (Get-Translation 'FirewallOutboundLabel'), (Get-WtFirewallActionText -Action ([string]$f.DefaultOutboundAction) -Direction 'Outbound')))
        }
    }
    return [string[]]$lines.ToArray()
}

function Format-WtRemoteEndpoint {
    <#
    .SYNOPSIS
        "address:port" for the connection table, with a long IPv6 literal
        cut to a fixed width so one row can never push the panel into
        wrapping (the cut is visible, '...', never silent). IndexOf takes
        the Ordinal overload, like every text comparison in this file,
        since tr-TR's dotless-I makes culture-aware comparisons unreliable.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$MaxAddressLength = 24
    )
    $text = $Address
    if ($text.Length -gt $MaxAddressLength) { $text = $text.Substring(0, [Math]::Max(1, $MaxAddressLength - 3)) + '...' }
    if ($Address.IndexOf(':', [System.StringComparison]::Ordinal) -ge 0) { return ('[{0}]:{1}' -f $text, $Port) }
    return ('{0}:{1}' -f $text, $Port)
}

function Get-WtActiveConnectionLines {
    <#
    .SYNOPSIS
        Which programs have an open connection right now, and where to.
        Summary first - connections per program and distinct remote hosts
        - then a capped detail table, since a raw per-connection dump
        runs to 150-300 rows and answers no question. The PID->name map
        uses an explicit loop, since Group-Object -AsHashTable's
        PSObject collections only index correctly by accident, and rows
        are grouped via .ToArray() rather than @($rows): under tr-TR, @()
        around a List[object] of PSCustomObjects throws "Argument types
        do not match". No reverse DNS is performed, to keep this screen
        local and instant.
    #>
    param(
        [scriptblock]$GetConnections = { Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue },
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName },
        [int]$MaxDetailRows = 30
    )
    $connections = @()
    try { $connections = @(@(& $GetConnections) | Where-Object { $_ }) }
    catch { $connections = @() }
    if ($connections.Count -eq 0) { return [string[]]@((Get-Translation 'ActiveConnNone')) }

    $names = @{}
    try {
        foreach ($p in @(& $GetProcesses)) {
            if ($null -eq $p) { continue }
            $key = [string]$p.Id
            if (-not $names.ContainsKey($key)) { $names[$key] = [string]$p.ProcessName }
        }
    }
    catch { $names = @{} }

    $unknown = [string](Get-Translation 'ActiveConnUnknownProcess')
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($c in $connections) {
        $key = [string]$c.OwningProcess
        $owner = if ($names.ContainsKey($key) -and $names[$key]) { [string]$names[$key] } else { $unknown }
        $rows.Add([PSCustomObject]@{
            Owner      = $owner
            ProcessId  = $key
            RemoteHost = [string]$c.RemoteAddress
            Endpoint   = (Format-WtRemoteEndpoint -Address ([string]$c.RemoteAddress) -Port ([int]$c.RemotePort))
        })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'ActiveConnSummaryHeader'))
    $groups = @($rows.ToArray() | Group-Object Owner | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, Name)
    foreach ($g in $groups) {
        $distinct = @(@($g.Group | ForEach-Object { $_.RemoteHost }) | Sort-Object -Unique).Count
        $lines.Add(('  ' + ((Get-Translation 'ActiveConnSummaryLine') -f $g.Name, $g.Count, $distinct)))
    }

    $lines.Add('')
    $shown = @($rows.ToArray() | Select-Object -First $MaxDetailRows)
    $lines.Add(((Get-Translation 'ActiveConnDetailHeader') -f $shown.Count))
    foreach ($r in $shown) {
        $lines.Add(('  {0} ({1}) -> {2}' -f $r.Owner, $r.ProcessId, $r.Endpoint))
    }
    if ($rows.Count -gt $shown.Count) {
        $lines.Add(('  ' + ((Get-Translation 'ActiveConnDetailMore') -f ($rows.Count - $shown.Count))))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'ActiveConnNoReverseDns'))
    return [string[]]$lines.ToArray()
}

function Get-WtHostsFileLines {
    <#
    .SYNOPSIS
        The active hosts entries with their count, the file size and the
        last-changed time - the read-back the blocklist feature never had.
        Read via [System.IO.File]::ReadAllLines(..., UTF8), matching the
        blocklist apply step's own encoding, since Get-Content's PS 5.1
        default (the ANSI code page) would decode the same file
        differently. The missing-file case is checked before .Length is
        touched, since Format-WtByteSize takes a [long] and dies on
        $null. Capped at 150 entries, since a blocklist can add thousands
        of lines.
    #>
    param(
        [string]$Path = (Join-Path $env:WinDir 'System32\drivers\etc\hosts'),
        [scriptblock]$GetFileInfo = { param($P) Get-Item -LiteralPath $P -ErrorAction SilentlyContinue },
        [scriptblock]$ReadLines = { param($P) [System.IO.File]::ReadAllLines($P, [System.Text.Encoding]::UTF8) },
        [int]$MaxEntries = 150
    )
    $info = $null
    try { $info = & $GetFileInfo $Path }
    catch { $info = $null }
    if ($null -eq $info) { return [string[]]@(((Get-Translation 'HostsFileMissing') -f $Path)) }

    $raw = @()
    try { $raw = @(& $ReadLines $Path) }
    catch { return [string[]]@(((Get-Translation 'HostsFileMissing') -f $Path)) }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($line in $raw) {
        $text = ([string]$line).Trim()
        if (-not $text) { continue }
        if ($text.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $entries.Add($text)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'HostsFileHeader') -f $Path))
    $lines.Add(((Get-Translation 'HostsFileStats') -f $entries.Count, (Format-WtByteSize -Bytes ([long]$info.Length)), ([string]$info.LastWriteTime)))
    $lines.Add('')
    if ($entries.Count -eq 0) {
        $lines.Add((Get-Translation 'HostsFileNoEntries'))
        return [string[]]$lines.ToArray()
    }
    $shown = [Math]::Min($entries.Count, $MaxEntries)
    for ($i = 0; $i -lt $shown; $i++) { $lines.Add('  ' + $entries[$i]) }
    if ($entries.Count -gt $shown) {
        $lines.Add(('  ' + ((Get-Translation 'HostsFileTruncated') -f $shown, ($entries.Count - $shown))))
    }
    return [string[]]$lines.ToArray()
}

function Get-WtInternetTestPlanLines {
    <#
    .SYNOPSIS
        The disclosure this row ships on: the complete list of hosts the
        connectivity test is about to contact, written before anything is
        contacted. Deliberately pure and source-free - no data source
        parameter, since taking none is what guarantees this can print
        first. DNS and ICMP only; no HTTP request, no payload about this
        machine, and the ISP name is never looked up (that would need an
        HTTP-based whois service).
    #>
    param(
        [string]$ResolverHost = 'resolver1.opendns.com',
        [string[]]$PingTargets = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'InternetTestDisclosure'))
    $lines.Add('')
    $lines.Add(('  - ' + ((Get-Translation 'InternetTestHostResolver') -f $ResolverHost)))
    foreach ($target in $PingTargets) {
        $lines.Add(('  - ' + ((Get-Translation 'InternetTestHostPing') -f $target)))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'InternetTestNoHttp'))
    $lines.Add('')
    return [string[]]$lines.ToArray()
}

function Get-WtInternetTestResultLines {
    <#
    .SYNOPSIS
        The public IP address and the round-trip latency to three public
        resolvers - is the line up, and how does this machine look from
        outside. The public IP comes from one DNS query (myip.opendns.com
        against resolver1.opendns.com), not an HTTP request, so nothing
        about this machine is uploaded; the ISP name is never attempted
        for the same reason. Every failure is written as a failure, never
        an empty line. Windows PowerShell 5.1 returns Win32_PingStatus
        (StatusCode/ResponseTime); PowerShell 7 returns a wrapper with
        Latency - both shapes are read.
    #>
    param(
        [scriptblock]$GetPublicIp = { Resolve-DnsName -Name 'myip.opendns.com' -Server 'resolver1.opendns.com' -Type A -ErrorAction Stop },
        [scriptblock]$PingTarget = { param($Target) Test-Connection -ComputerName $Target -Count 4 -ErrorAction SilentlyContinue },
        [string[]]$PingTargets = @('1.1.1.1', '8.8.8.8', '9.9.9.9'),
        [int]$PingCount = 4
    )
    $lines = New-Object System.Collections.Generic.List[string]

    $publicIp = ''
    try {
        foreach ($record in @(& $GetPublicIp)) {
            if ($null -eq $record) { continue }
            if (-not ($record.PSObject.Properties.Name -contains 'IPAddress')) { continue }
            if ([string]$record.IPAddress) { $publicIp = [string]$record.IPAddress; break }
        }
    }
    catch { $publicIp = '' }
    if ($publicIp) { $lines.Add(('{0}: {1}' -f (Get-Translation 'InternetTestPublicIpLabel'), $publicIp)) }
    else { $lines.Add((Get-Translation 'InternetTestPublicIpFailed')) }

    $lines.Add('')
    $lines.Add((Get-Translation 'InternetTestLatencyHeader'))
    foreach ($target in $PingTargets) {
        $replies = @()
        try { $replies = @(@(& $PingTarget $target) | Where-Object { $_ }) }
        catch { $replies = @() }
        $times = New-Object System.Collections.Generic.List[double]
        foreach ($reply in $replies) {
            $props = $reply.PSObject.Properties.Name
            if (($props -contains 'StatusCode') -and ($null -ne $reply.StatusCode) -and ([int]$reply.StatusCode -ne 0)) { continue }
            $value = $null
            if (($props -contains 'ResponseTime') -and ($null -ne $reply.ResponseTime)) { $value = [double]$reply.ResponseTime }
            elseif (($props -contains 'Latency') -and ($null -ne $reply.Latency)) { $value = [double]$reply.Latency }
            if ($null -ne $value) { $times.Add($value) }
        }
        if ($times.Count -eq 0) {
            $lines.Add(('  ' + ((Get-Translation 'InternetTestLatencyFailed') -f $target)))
            continue
        }
        $sum = 0.0
        foreach ($t in $times) { $sum += $t }
        $average = [math]::Round($sum / $times.Count)
        $lines.Add(('  ' + ((Get-Translation 'InternetTestLatencyLine') -f $target, $times.Count, $PingCount, $average)))
    }
    return [string[]]$lines.ToArray()
}

function Test-WtHostName {
    <#
    .SYNOPSIS
        Is this text a plausible DNS host name? Labels of letters, digits
        and hyphens (never leading or trailing), 1-63 characters each, 253
        overall, with an optional trailing dot. Uses -cmatch on an
        explicit A-Za-z class, since under tr-TR a case-insensitive
        -match applies the dotless-I rules and would accept or reject the
        wrong names; nothing the user typed reaches a command before this
        returns $true.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not $Name) { return $false }
    if ($Name.Length -gt 253) { return $false }
    return [bool]($Name -cmatch '^[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*\.?$')
}

function Get-WtDnsAnswerAddresses {
    <#
    .SYNOPSIS
        The A-record addresses out of one Resolve-DnsName answer,
        de-duplicated and ordinally sorted so two servers that return the
        same addresses in a different order still compare equal.
    #>
    param([AllowEmptyCollection()][array]$Records = @())
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        if (-not ($record.PSObject.Properties.Name -contains 'IPAddress')) { continue }
        $value = [string]$record.IPAddress
        if (-not $value) { continue }
        if (-not $out.Contains($value)) { $out.Add($value) }
    }
    $sorted = $out.ToArray()
    [array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return [string[]]$sorted
}

function Get-WtDnsTestPlanLines {
    <#
    .SYNOPSIS
        The three servers the name will be asked of, printed BEFORE the
        first query - same disclosure discipline as the connectivity test.
        Pure: no data source parameter, so nothing is queried by printing.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$PublicServers = @('8.8.8.8', '1.1.1.1')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'DnsTestServersHeader') -f $Name))
    $lines.Add(('  - ' + (Get-Translation 'DnsTestServerAdapter')))
    foreach ($server in $PublicServers) {
        $lines.Add(('  - ' + ((Get-Translation 'DnsTestServerLine') -f $server)))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'DnsTestCacheNote'))
    $lines.Add('')
    return [string[]]$lines.ToArray()
}

function Get-WtDnsTestResultLines {
    <#
    .SYNOPSIS
        Resolves one name against the adapter's own DNS server and
        against 8.8.8.8 and 1.1.1.1, puts the three answer sets side by
        side and says plainly when they differ - a hijacked or blocking
        resolver shows up as a different answer. Every query uses
        -Type A -DnsOnly, since without -DnsOnly the local DNS cache
        answers first and hides exactly the difference this row exists
        to expose. A server that fails is written as "no answer", never
        a blank; signatures are built via .ToArray(), never @($answers):
        under tr-TR, @() around a List[object] of PSCustomObjects throws
        "Argument types do not match".
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$PublicServers = @('8.8.8.8', '1.1.1.1'),
        [scriptblock]$ResolveWithAdapter = { param($HostName) Resolve-DnsName -Name $HostName -Type A -DnsOnly -ErrorAction Stop },
        [scriptblock]$ResolveWithServer = { param($HostName, $Server) Resolve-DnsName -Name $HostName -Type A -DnsOnly -Server $Server -ErrorAction Stop }
    )
    $answers = New-Object System.Collections.Generic.List[object]

    $adapter = @()
    try { $adapter = @(Get-WtDnsAnswerAddresses -Records @(& $ResolveWithAdapter $Name)) }
    catch { $adapter = @() }
    $answers.Add([PSCustomObject]@{ Label = [string](Get-Translation 'DnsTestAdapterLabel'); Addresses = $adapter })

    foreach ($server in $PublicServers) {
        $set = @()
        try { $set = @(Get-WtDnsAnswerAddresses -Records @(& $ResolveWithServer $Name $server)) }
        catch { $set = @() }
        $answers.Add([PSCustomObject]@{ Label = [string]$server; Addresses = $set })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($answer in $answers) {
        $text = if (@($answer.Addresses).Count -eq 0) { [string](Get-Translation 'DnsTestNoAnswer') } else { (@($answer.Addresses) -join ', ') }
        $lines.Add(('  {0}: {1}' -f $answer.Label, $text))
    }
    $lines.Add('')
    $signatures = @($answers.ToArray() | ForEach-Object { (@($_.Addresses) -join ',') })
    $distinct = @(@($signatures) | Sort-Object -Unique)
    if ($distinct.Count -le 1) { $lines.Add((Get-Translation 'DnsTestSame')) }
    else { $lines.Add((Get-Translation 'DnsTestDifferent')) }
    return [string[]]$lines.ToArray()
}

function Invoke-WtDnsResolutionTestAction {
    <#
    .SYNOPSIS
        Inline row: the host name is asked for in the panel, validated,
        and only then are the three servers printed and queried.
        Read-WtPanelAnswer runs before Invoke-WtCapturedAction on
        purpose - an interactive prompt inside a captured action would
        deadlock, since output capture blocks the direct keyboard read
        the prompt needs. $Run resolves $target through the scope chain
        rather than via GetNewClosure, which breaks when the bundle runs
        as a script rather than dot-sourced.
    #>
    param(
        [string]$DefaultName = 'www.microsoft.com',
        [scriptblock]$AskName = {
            param($Crumb, $Default)
            Read-WtPanelAnswer -Breadcrumb $Crumb -Lines @() -Prompt ((Get-Translation 'DnsTestPrompt') -f $Default) -Layout 'Compact'
        },
        [scriptblock]$Run = {
            param($HostName, $Crumb)
            $target = $HostName
            Invoke-WtCapturedAction -Title (Get-Translation 'DnsResolutionTest') -Breadcrumb $Crumb -Action {
                foreach ($l in (Get-WtDnsTestPlanLines -Name $target)) { Write-Host $l }
                foreach ($l in (Get-WtDnsTestResultLines -Name $target)) { Write-Host $l }
            }
        },
        [scriptblock]$ShowInvalid = {
            param($Crumb, $Text)
            $null = Read-WtPanelAnswer -Breadcrumb $Crumb -Lines @(((Get-Translation 'DnsTestInvalidHost') -f $Text)) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
        }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { [string](Get-Translation 'DnsResolutionTest') }
    $answer = & $AskName $crumb $DefaultName
    if ($null -eq $answer) { return }
    $entered = ([string]$answer).Trim()
    if (-not $entered) { $entered = $DefaultName }
    if (-not (Test-WtHostName -Name $entered)) {
        & $ShowInvalid $crumb $entered
        return
    }
    & $Run $entered $crumb
}
