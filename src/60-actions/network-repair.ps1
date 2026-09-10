# Wi-Fi password, ping, adapters, Winsock/TCP-IP/WinHTTP reset, hosts reset, firewall rule reset.
# Covered by: tests/ActionNetworkRepair.Tests.ps1

function Get-WtWifiPasswordLines {
    <#
    .SYNOPSIS
        PURE formatter: the lines a looked-up Wi-Fi profile should show.
        Separated from the panel flow so the wording is testable without
        a console or a real wireless profile.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result
    )
    if (-not $Result.Found) { return @((Get-Translation 'WiFiProfileNotFound')) }
    $lines = @(
        ('{0}: {1}' -f (Get-Translation 'WiFiName'), $Result.Name)
        ('{0}: {1}' -f (Get-Translation 'WiFiAuthentication'), $Result.Authentication)
    )
    if ($Result.Key) { $lines += ('{0}: {1}' -f (Get-Translation 'WiFiPassword'), $Result.Key) }
    else { $lines += (Get-Translation 'NoPasswordFound') }
    return $lines
}

function Invoke-WtPingTestAction {
    <#
    .SYNOPSIS
        Asks for the address in the panel, then pings it with the replies
        streaming into the box. The address is captured by the closure
        and passed to ping as ONE argument, so nothing the user types is
        ever re-parsed as script.
    #>
    param(
        [scriptblock]$AskTarget = { Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @() -Prompt (Get-Translation 'Pinging') },
        [scriptblock]$Run = {
            param($Address, $Crumb)
            $target = $Address
            Invoke-WtCapturedAction -Title (Get-Translation 'PingTest') -Breadcrumb $Crumb -Action { ping $target }
        }
    )
    $entered = ([string](& $AskTarget)).Trim()
    if (-not $entered) { return }
    & $Run $entered $script:WtPanelBreadcrumb
}

function Invoke-WtRestartNetworkAdaptersAction {
    <#
    .SYNOPSIS
        Disables and re-enables every adapter that is Up, then POLLS each
        one back to Up for up to 30 seconds. A fixed 5-second wait reports
        a healthy Wi-Fi as Disconnected - the adapter is back long before
        the association finishes. Refused outright inside an RDP session:
        the first adapter that goes down takes the session with it.
    #>
    param(
        [scriptblock]$GetSessionName = { [string]$env:SESSIONNAME },
        [scriptblock]$GetAdapters = { Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property Name },
        [scriptblock]$RestartAdapter = { param($Name) Restart-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop },
        [scriptblock]$GetAdapterStatus = { param($Name) [string](Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue).Status },
        [scriptblock]$WaitOneSecond = { Start-Sleep -Seconds 1 },
        [int]$TimeoutSeconds = 30
    )
    $session = [string](& $GetSessionName)
    if ($session.StartsWith('RDP-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ((Get-Translation 'NetAdaptersRdpBlocked') -f $session) -ForegroundColor Red
        return
    }
    $adapters = @()
    try { $adapters = @(& $GetAdapters) }
    catch { $adapters = @() }
    if ($adapters.Count -eq 0) {
        Write-Host (Get-Translation 'NetAdaptersNone') -ForegroundColor Yellow
        return
    }
    Write-Host ((Get-Translation 'NetAdaptersRestarting') -f $adapters.Count, $TimeoutSeconds)
    foreach ($adapter in $adapters) {
        $name = [string]$adapter.Name
        Write-Host ((Get-Translation 'NetAdapterRestarting') -f $name)
        try {
            & $RestartAdapter $name
        }
        catch {
            Write-Host ((Get-Translation 'NetAdapterFailed') -f $name, $_.Exception.Message) -ForegroundColor Red
            continue
        }
        $status = ''
        $waited = 0
        while ($waited -lt $TimeoutSeconds) {
            & $WaitOneSecond
            $waited++
            $status = [string](& $GetAdapterStatus $name)
            if ($status -ceq 'Up') { break }
        }
        if ($status -ceq 'Up') { Write-Host ((Get-Translation 'NetAdapterUp') -f $name, $waited) -ForegroundColor Green }
        else { Write-Host ((Get-Translation 'NetAdapterNotUp') -f $name, $status, $waited) -ForegroundColor Yellow }
    }
}

function Get-WtWifiProfileNames {
    <#
    .SYNOPSIS
        PURE: the saved profile names out of "netsh wlan show profiles".
        Splits on the first colon only, since an SSID may itself contain
        one, and never matches the line's label text, which is translated
        on a Turkish Windows.
    #>
    param([AllowEmptyCollection()][string[]]$Output = @())
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Output)) {
        $line = [string]$raw
        if (-not $line) { continue }
        if ($line -cnotmatch '^\s') { continue }
        $colon = $line.IndexOf(':', [System.StringComparison]::Ordinal)
        if ($colon -lt 0) { continue }
        $name = $line.Substring($colon + 1).Trim()
        if (-not $name) { continue }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    return [string[]]$names.ToArray()
}

function Invoke-WtForgetWifiProfileAction {
    <#
    .SYNOPSIS
        Panel flow: list the saved wireless profiles, ask for a number in
        the panel, then delete exactly that one profile with netsh. The
        chosen SSID is passed as ONE quoted argument ("name=<ssid>"), so
        an SSID with spaces is not re-split by the native command line and
        nothing the user typed is ever re-parsed as script.
    #>
    param(
        [scriptblock]$ListProfiles = { netsh wlan show profiles },
        [scriptblock]$AskChoice = { param($Lines) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt (Get-Translation 'WifiProfilePickPrompt') -Risk 'CAUTION' },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = {
            param($ProfileName, $Crumb)
            $target = $ProfileName
            Invoke-WtCapturedAction -Title (Get-Translation 'ForgetWifiProfile') -Breadcrumb $Crumb -Action {
                Write-Host ((Get-Translation 'WifiProfileDeleting') -f $target)
                netsh wlan delete profile "name=$target"
            }
        }
    )
    $names = @(Get-WtWifiProfileNames -Output @(& $ListProfiles | ForEach-Object { [string]$_ }))
    if ($names.Count -eq 0) {
        & $ShowMessage @((Get-Translation 'WifiProfilesNone'))
        return
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'WifiProfilePickHeader'))
    for ($i = 0; $i -lt $names.Count; $i++) { $lines.Add(('  [{0}] {1}' -f ($i + 1), $names[$i])) }
    $answer = ([string](& $AskChoice $lines.ToArray())).Trim()
    if (-not $answer) { return }
    $index = 0
    if (-not [int]::TryParse($answer, [ref]$index) -or $index -lt 1 -or $index -gt $names.Count) {
        & $ShowMessage @((Get-Translation 'WifiProfileInvalidChoice'))
        return
    }
    & $Run $names[$index - 1] $script:WtPanelBreadcrumb
}

function Invoke-WtResetWinsockAction {
    <#
    .SYNOPSIS
        netsh winsock reset - rebuilds the Winsock catalog and removes
        third-party LSP layers dead VPN/AV software leaves behind. The
        restart notice prints unconditionally, since netsh never throws
        and gating it on output would leave the stack half-applied with no
        warning.
    #>
    param([scriptblock]$RunReset = { netsh winsock reset })
    Write-Host (Get-Translation 'WinsockResetRunning')
    foreach ($line in @(& $RunReset)) { Write-Host ([string]$line) }
    Write-Host (Get-Translation 'WinsockResetLspNote')
    Write-Host (Get-Translation 'NetworkRestartRequired') -ForegroundColor Yellow
}

function Get-WtNetworkResetPreviewLines {
    <#
    .SYNOPSIS
        PURE: what the TCP/IP reset is about to erase - the static IPv4
        addresses and the DNS servers configured right now, shown before
        the confirmation gate. When a source is missing or throws, the
        "there is none" line is printed rather than an empty section.
    #>
    param(
        [scriptblock]$GetAddresses = { Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue },
        [scriptblock]$GetDnsServers = { Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'NetResetStaticHeader'))
    $statics = @()
    try { $statics = @(& $GetAddresses | Where-Object { [string]$_.PrefixOrigin -ceq 'Manual' }) }
    catch { $statics = @() }
    if ($statics.Count -eq 0) { $lines.Add('  ' + (Get-Translation 'NetResetNoStatic')) }
    else {
        foreach ($address in $statics) { $lines.Add(('  {0}: {1}/{2}' -f $address.InterfaceAlias, $address.IPAddress, $address.PrefixLength)) }
    }
    $lines.Add((Get-Translation 'NetResetDnsHeader'))
    $servers = @()
    try { $servers = @(& $GetDnsServers | Where-Object { @($_.ServerAddresses).Count -gt 0 }) }
    catch { $servers = @() }
    if ($servers.Count -eq 0) { $lines.Add('  ' + (Get-Translation 'NetResetNoDns')) }
    else {
        foreach ($entry in $servers) { $lines.Add(('  {0}: {1}' -f $entry.InterfaceAlias, (@($entry.ServerAddresses) -join ', '))) }
    }
    return [string[]]$lines.ToArray()
}

function Invoke-WtResetTcpIpStackCommands {
    <#
    .SYNOPSIS
        The captured half of the TCP/IP reset: netsh int ip reset, then
        netsh int ipv6 reset, each exit code read and reported. A non-zero
        code here is usually the expected "access is denied" on a handful
        of system-owned registry keys, not a failure. Also retires the
        DnsPreset undo records this reset just erased.
    #>
    param(
        [scriptblock]$RunIpv4 = { netsh int ip reset },
        [scriptblock]$RunIpv6 = { netsh int ipv6 reset },
        [scriptblock]$GetExitCode = { $LASTEXITCODE },
        [scriptblock]$RetireDnsRecords = { Set-WtUndoEntryRetired -ActionNames @('Apply DNS Preset') -RetiredBy 'ResetTcpIpStack' }
    )
    Write-Host (Get-Translation 'ResetTcpIpStackRunning')
    $sawNonZero = $false
    foreach ($step in @($RunIpv4, $RunIpv6)) {
        foreach ($line in @(& $step)) { Write-Host ([string]$line) }
        $code = 0
        $raw = & $GetExitCode
        if ($null -ne $raw) { $code = [int]$raw }
        Write-Host ((Get-Translation 'ResetTcpIpExitCode') -f $code)
        if ($code -ne 0) { $sawNonZero = $true }
    }
    if ($sawNonZero) { Write-Host (Get-Translation 'ResetTcpIpAccessDeniedNote') -ForegroundColor Yellow }
    $retired = [int](& $RetireDnsRecords)
    Write-Host ((Get-Translation 'UndoRetiredDnsPreset') -f $retired)
    Write-Host (Get-Translation 'NetworkRestartRequired') -ForegroundColor Yellow
}

function Invoke-WtResetTcpIpStackAction {
    <#
    .SYNOPSIS
        Inline, not captured: the static addresses and current DNS are
        shown first, then Confirm-WtDestructiveAction names the DoH DNS
        preset this tool wrote as what will be erased. The gate reads the
        keyboard, so only the netsh commands run inside
        Invoke-WtCapturedAction.
    #>
    param(
        [scriptblock]$GetPreviewLines = { Get-WtNetworkResetPreviewLines },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'ResetTcpIpConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = { param($Crumb) Invoke-WtCapturedAction -Title (Get-Translation 'ResetTcpIpStack') -Breadcrumb $Crumb -Action { Invoke-WtResetTcpIpStackCommands } }
    )
    $preview = @(& $GetPreviewLines)
    if (-not (& $Confirm $preview)) {
        & $ShowMessage @((Get-Translation 'ActionCancelled'))
        return
    }
    & $Run $script:WtPanelBreadcrumb
}

function Test-WtWinHttpProxyConfigured {
    <#
    .SYNOPSIS
        PURE: true when "netsh winhttp show proxy" output names a proxy
        server. Matches on the shape of a proxy value (host:port), never
        on the surrounding text, since both the labels and the "no proxy"
        sentence are localized.
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())
    foreach ($raw in @($Lines)) {
        $line = [string]$raw
        if (-not $line) { continue }
        if ($line -cmatch '[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}(\s|;|$)') { return $true }
    }
    return $false
}

function Invoke-WtResetWinHttpProxyCommands {
    <#
    .SYNOPSIS
        The captured half: reset proxy + reset autoproxy, then the state
        afterwards so the user sees the result. Both subcommands ship with
        every supported Windows (Windows 8 and later), so neither is
        probed with a "netsh winhttp" help call first.
    #>
    param(
        [bool]$ProxyWasConfigured = $true,
        [scriptblock]$RunResetProxy = { netsh winhttp reset proxy },
        [scriptblock]$RunResetAutoProxy = { netsh winhttp reset autoproxy },
        [scriptblock]$ShowProxy = { netsh winhttp show proxy }
    )
    Write-Host (Get-Translation 'WinHttpProxyResetting')
    if (-not $ProxyWasConfigured) { Write-Host (Get-Translation 'WinHttpProxyNotSet') }
    foreach ($line in @(& $RunResetProxy)) { Write-Host ([string]$line) }
    foreach ($line in @(& $RunResetAutoProxy)) { Write-Host ([string]$line) }
    Write-Host (Get-Translation 'WinHttpProxyAfter')
    foreach ($line in @(& $ShowProxy)) { Write-Host ([string]$line) }
}

function Invoke-WtResetWinHttpProxyAction {
    <#
    .SYNOPSIS
        Inline, not captured, even though the catalogue lists this row as
        captured: the gate is asked only when a proxy is really set, since
        Confirm-WtDestructiveAction reads the keyboard and would deadlock
        inside Invoke-WtCapturedAction. Only the reset commands run
        captured.
    #>
    param(
        [scriptblock]$ShowProxy = { netsh winhttp show proxy },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'WinHttpProxyConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = {
            param($Crumb, $Configured)
            $wasConfigured = [bool]$Configured
            Invoke-WtCapturedAction -Title (Get-Translation 'ResetWinHttpProxy') -Breadcrumb $Crumb -Action { Invoke-WtResetWinHttpProxyCommands -ProxyWasConfigured $wasConfigured }
        }
    )
    $current = @(& $ShowProxy | ForEach-Object { [string]$_ })
    $configured = Test-WtWinHttpProxyConfigured -Lines $current
    if ($configured) {
        $lines = @((Get-Translation 'WinHttpProxyCurrent')) + @($current | Where-Object { $_.Trim() })
        if (-not (& $Confirm $lines)) {
            & $ShowMessage @((Get-Translation 'ActionCancelled'))
            return
        }
    }
    & $Run $script:WtPanelBreadcrumb $configured
}

function Get-WtHostsFileSummary {
    <#
    .SYNOPSIS
        PURE: how many active entries the Hosts file holds (a non-empty
        line that does not start with '#') and how many of those carry
        this tool's blocklist marker, appended by Get-WtHostsLinesToAdd as
        "<line><tab># WinToolify (<tier>)".
    #>
    param([AllowEmptyString()][string]$Content = '')
    $active = 0
    $marked = 0
    foreach ($raw in ([string]$Content -split "`r?`n")) {
        $line = [string]$raw
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $active++
        if ($line.Contains('# WinToolify (')) { $marked++ }
    }
    return [PSCustomObject]@{ Active = $active; Marked = $marked }
}

function Get-WtHostsResetPreviewLines {
    <#
    .SYNOPSIS
        PURE: the two lines the confirmation gate shows before the Hosts
        file is rewritten - what is in there now, and how much of it this
        tool put there.
    #>
    param([AllowEmptyString()][string]$Content = '')
    $summary = Get-WtHostsFileSummary -Content $Content
    return [string[]]@(
        ((Get-Translation 'HostsActiveEntries') -f $summary.Active)
        ((Get-Translation 'HostsWinToolifyEntries') -f $summary.Marked)
    )
}

function Get-WtDefaultHostsContent {
    <#
    .SYNOPSIS
        PURE: the Hosts file Windows ships, verbatim, with CRLF endings
        and a trailing newline. Not a translation key on purpose - this
        is file content Windows itself writes in English, not UI text.
    #>
    $lines = @(
        '# Copyright (c) 1993-2009 Microsoft Corp.'
        '#'
        '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.'
        '#'
        '# This file contains the mappings of IP addresses to host names. Each'
        '# entry should be kept on an individual line. The IP address should'
        '# be placed in the first column followed by the corresponding host name.'
        '# The IP address and the host name should be separated by at least one'
        '# space.'
        '#'
        '# Additionally, comments (such as these) may be inserted on individual'
        '# lines or following the machine name denoted by a ''#'' symbol.'
        '#'
        '# For example:'
        '#'
        '#      102.54.94.97     rhino.acme.com          # source server'
        '#       38.25.63.10     x.acme.com              # x client host'
        ''
        '# localhost name resolution is handled within DNS itself.'
        "#`t127.0.0.1       localhost"
        "#`t::1             localhost"
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Invoke-WtResetHostsFileWrite {
    <#
    .SYNOPSIS
        The captured half of the Hosts reset: back the file up, write the
        Windows default text over it and flush the DNS cache. Uses
        [System.IO.File]::WriteAllText, since Set-Content fails on hosts
        with "Stream was not readable". Retires the Blocklist undo records
        only past zero MarkedCount, since firewall-based blocklist rules
        stay live after a Hosts reset.
    #>
    param(
        [Parameter(Mandatory)][int]$MarkedCount,
        [scriptblock]$GetHostsPath = { Join-Path $env:WinDir 'System32\drivers\etc\hosts' },
        [scriptblock]$BackupHosts = {
            param($Path)
            $backupDir = Get-WtDataPath -Scope 'Machine' -SubPath 'backup'
            $target = Join-Path $backupDir ('hosts-{0}.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item -LiteralPath $Path -Destination $target -Force
            $target
        },
        [scriptblock]$WriteHosts = {
            param($Path, $Text)
            [System.IO.File]::WriteAllText($Path, $Text, [System.Text.Encoding]::UTF8)
        },
        [scriptblock]$FlushDns = { ipconfig /flushdns },
        [scriptblock]$RetireRecords = { Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetHostsFile' -ItemFilter { param($Item) $Item.ItemType -eq 'HostsBlock' } }
    )
    $path = [string](& $GetHostsPath)
    $backup = [string](& $BackupHosts $path)
    Write-Host ((Get-Translation 'HostsBackupWritten') -f $backup)
    & $WriteHosts $path (Get-WtDefaultHostsContent)
    Write-Host (Get-Translation 'HostsFileRewritten') -ForegroundColor Green
    Write-Host (Get-Translation 'HostsFlushingDns')
    foreach ($line in @(& $FlushDns)) { Write-Host ([string]$line) }
    if ($MarkedCount -gt 0) {
        $retired = [int](& $RetireRecords)
        Write-Host ((Get-Translation 'UndoRetiredBlocklistHosts') -f $retired)
    }
}

function Invoke-WtResetHostsFileAction {
    <#
    .SYNOPSIS
        Inline: the file is read and counted first, the gate names what
        disappears (including the user's own entries) and only then does
        the captured writer run. An unreadable file is not a crash - the
        counts come back as zero and the gate is still asked.
    #>
    param(
        [scriptblock]$ReadHosts = { [System.IO.File]::ReadAllText((Join-Path $env:WinDir 'System32\drivers\etc\hosts'), [System.Text.Encoding]::UTF8) },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'HostsResetConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = {
            param($Crumb, $Marked)
            $markedCount = [int]$Marked
            Invoke-WtCapturedAction -Title (Get-Translation 'ResetHostsFile') -Breadcrumb $Crumb -Action { Invoke-WtResetHostsFileWrite -MarkedCount $markedCount }
        }
    )
    $content = ''
    try { $content = [string](& $ReadHosts) }
    catch { $content = '' }
    $summary = Get-WtHostsFileSummary -Content $content
    if (-not (& $Confirm (Get-WtHostsResetPreviewLines -Content $content))) {
        & $ShowMessage @((Get-Translation 'ActionCancelled'))
        return
    }
    & $Run $script:WtPanelBreadcrumb $summary.Marked
}

function Get-WtFirewallRuleCounts {
    <#
    .SYNOPSIS
        How many rules "netsh advfirewall reset" is about to drop: this
        tool's own blocklist rules (Group 'WinToolify') and the custom
        rules that belong to no group at all. Windows' built-in rules
        carry their own resource group and are counted in neither, since
        they come back with the default set regardless. Returns zeroes,
        not nothing, when the firewall service cannot be queried.
    #>
    param([scriptblock]$GetRules = { Get-NetFirewallRule -ErrorAction SilentlyContinue })
    $rules = @()
    try { $rules = @(& $GetRules) }
    catch { $rules = @() }
    $ownCount = 0
    $customCount = 0
    foreach ($rule in $rules) {
        $group = [string]$rule.Group
        if ([string]::Equals($group, 'WinToolify', [System.StringComparison]::Ordinal)) { $ownCount++ }
        elseif (-not $group.Trim()) { $customCount++ }
    }
    return [PSCustomObject]@{ WinToolify = $ownCount; Custom = $customCount }
}

function Invoke-WtResetFirewallRulesCommands {
    <#
    .SYNOPSIS
        The captured half: "netsh advfirewall reset", which also silently
        restores Windows' out-of-box policy and turns every profile's
        firewall back on. The per-profile enabled state is captured first
        and any changed profile is put back afterward, one Set- call each
        so one refusal does not abandon the rest. Also retires the
        Blocklist undo records this reset invalidates.
    #>
    param(
        [scriptblock]$RunReset = { netsh advfirewall reset },
        [scriptblock]$RetireRecords = { Set-WtUndoEntryRetired -ActionNames @('Apply Blocklist') -RetiredBy 'ResetFirewallRules' -ItemFilter { param($Item) $Item.ItemType -eq 'FirewallBlock' } },
        [scriptblock]$GetProfileState = { Get-NetFirewallProfile -All -ErrorAction Stop | Select-Object Name, Enabled },
        [scriptblock]$SetProfileState = { param($Name, $Enabled) Set-NetFirewallProfile -Name $Name -Enabled (ConvertTo-WtGpoBoolean -Enabled ([bool]$Enabled)) -ErrorAction Stop }
    )
    Write-Host (Get-Translation 'FirewallResetRunning')
    $before = $null
    try { $before = @(& $GetProfileState) }
    catch { $before = $null }

    foreach ($line in @(& $RunReset)) { Write-Host ([string]$line) }

    $retired = [int](& $RetireRecords)
    Write-Host ((Get-Translation 'UndoRetiredBlocklistFirewall') -f $retired)

    if ($null -eq $before) {
        Write-Host (Get-Translation 'FirewallStateReadFailed') -ForegroundColor Yellow
        return
    }
    $after = $null
    try { $after = @(& $GetProfileState) }
    catch { $after = $null }
    if ($null -eq $after) {
        Write-Host (Get-Translation 'FirewallStateReadFailed') -ForegroundColor Yellow
        return
    }
    $afterByName = @{}
    foreach ($profile in $after) { $afterByName[[string]$profile.Name] = [bool]$profile.Enabled }
    $restoredNames = New-Object System.Collections.Generic.List[string]
    foreach ($profile in $before) {
        $name = [string]$profile.Name
        $wanted = [bool]$profile.Enabled
        if (-not $afterByName.ContainsKey($name)) { continue }
        if ($afterByName[$name] -eq $wanted) { continue }
        try {
            & $SetProfileState $name $wanted
            $restoredNames.Add($name)
        }
        catch { Write-Host ((Get-Translation 'FirewallStateRestoreFailed') -f $name) -ForegroundColor Red }
    }
    if ($restoredNames.Count -gt 0) {
        $summary = ($restoredNames -join ', ')
        Write-Host ((Get-Translation 'FirewallStateRestored') -f $summary)
    }
}

function Invoke-WtResetFirewallRulesAction {
    <#
    .SYNOPSIS
        Inline, not captured, even though the catalogue lists this row as
        captured: the counts are read and printed first, then
        Confirm-WtDestructiveAction gates the reset, since that gate reads
        the keyboard and would deadlock inside Invoke-WtCapturedAction.
    #>
    param(
        [scriptblock]$GetCounts = { Get-WtFirewallRuleCounts },
        [scriptblock]$Confirm = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'FirewallResetConsequence') -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$Run = { param($Crumb) Invoke-WtCapturedAction -Title (Get-Translation 'ResetFirewallRules') -Breadcrumb $Crumb -Action { Invoke-WtResetFirewallRulesCommands } }
    )
    $counts = & $GetCounts
    $lines = @(
        ((Get-Translation 'FirewallRuleCountWinToolify') -f $counts.WinToolify)
        ((Get-Translation 'FirewallRuleCountCustom') -f $counts.Custom)
    )
    if (-not (& $Confirm $lines)) {
        & $ShowMessage @((Get-Translation 'ActionCancelled'))
        return
    }
    & $Run $script:WtPanelBreadcrumb
}

function Invoke-WtWifiPasswordAction {
    <#
    .SYNOPSIS
        Asks for the profile name in the panel, then shows the answer in
        the box. The prompt happens here rather than inside a captured
        action, so there is no Read-Host for Invoke-WtCapturedAction to
        deadlock on.
    #>
    param(
        [scriptblock]$AskName = { Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @() -Prompt (Get-Translation 'WiFiName') },
        [scriptblock]$LookUp = { param($Name) Get-WtWifiProfileKey -ProfileName $Name },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines }
    )
    $name = [string](& $AskName)
    if (-not $name.Trim()) { return }
    & $ShowResult @(Get-WtWifiPasswordLines -Result (& $LookUp $name.Trim())) | Out-Null
}
