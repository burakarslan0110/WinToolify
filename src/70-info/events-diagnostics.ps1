# Event levels, recent errors, blue screens, disk errors, top processes.
# Covered by: tests/InfoEventsDiagnostics.Tests.ps1

function Get-WtEventLevelTag {
    <#
    .SYNOPSIS
        PURE: the short, localized word for a Windows event Level number -
        1 Critical, 2 Error, 3 Warning. Anything else (Information,
        Verbose, or a null Level on a record built by hand) yields '', so
        the column keeps its width instead of printing a raw digit.
    #>
    param([AllowNull()][object]$Level)
    $n = 0
    if ($null -ne $Level) { $n = [int]$Level }
    switch ($n) {
        1 { return [string](Get-Translation 'EventLevelCritical') }
        2 { return [string](Get-Translation 'EventLevelError') }
        3 { return [string](Get-Translation 'EventLevelWarning') }
        default { return '' }
    }
}

function Get-WtRecentSystemErrorsLines {
    <#
    .SYNOPSIS
        The last week of Critical and Error records from the System log, one
        readable row each: time, level, event id, provider, and the first
        line of the message. Get-WinEvent raises a TERMINATING error when a
        filter matches nothing - even with -ErrorAction SilentlyContinue on
        some builds - so the call is wrapped in try/catch and an empty
        result prints "no matching events" rather than nothing at all.
        Message is cast to string before being split, since it is $null
        whenever the provider's resource DLL is missing.
    #>
    param(
        [scriptblock]$GetEvents = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 40 -ErrorAction SilentlyContinue
        },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )
    $events = @()
    try { $events = @(& $GetEvents) } catch { $events = @() }
    $events = @($events | Where-Object { $_ })
    if ($events.Count -eq 0) { return [string[]]@([string](Get-Translation 'EventsNoneFound')) }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'RecentSystemErrorsHeading'))
    $msgRoom = [Math]::Max(12, $Width - 57)
    foreach ($e in $events) {
        $when = ''
        if ($e.TimeCreated) {
            $when = ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $level = Get-WtEventLevelTag -Level $e.Level
        $provider = [string]$e.ProviderName
        if ($provider.Length -gt 22) { $provider = $provider.Substring(0, 21) + '~' }
        $parts = @(([string]$e.Message) -csplit "`r`n|`r|`n" | Where-Object { $_.Trim() })
        $msg = if ($parts.Count -gt 0) { $parts[0].Trim() } else { [string](Get-Translation 'EventNoMessage') }
        if ($msg.Length -gt $msgRoom) { $msg = $msg.Substring(0, $msgRoom - 1) + '~' }
        $lines.Add((('{0,-16}  {1,-5}  {2,6}  {3,-22}  {4}' -f $when, $level, ([string]$e.Id), $provider, $msg)).TrimEnd())
    }
    return [string[]]$lines.ToArray()
}

function Get-WtBlueScreenHistoryLines {
    <#
    .SYNOPSIS
        Every stop error, hard power loss, and unexpected shutdown with its
        date, plus the crash dumps still sitting on disk. Three providers,
        not two: WER-SystemErrorReporting 1001 carries the bugcheck,
        Kernel-Power 41 catches a hard hang/power cut with no bugcheck, and
        6008 ("previous shutdown was unexpected") is read here rather than
        by ShutdownHistory, since on a machine with minidumps disabled it
        is often the only trace a crash happened; 6008 gets its own label,
        not the 1001 wording, since it proves only that the shutdown was
        unexpected. Get-WinEvent raises a TERMINATING error when nothing
        matches, so all four sources are wrapped and an empty result
        prints an explicit "none" line.
    #>
    param(
        [scriptblock]$GetBugchecks = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -MaxEvents 20 -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetPowerLoss = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -MaxEvents 20 -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetUnexpectedShutdowns = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6008 } -MaxEvents 20 -ErrorAction SilentlyContinue
        },
        [scriptblock]$GetDumps = {
            Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter '*.dmp' -File -ErrorAction SilentlyContinue
        },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )
    $rows = New-Object System.Collections.Generic.List[object]

    $bugchecks = @()
    try { $bugchecks = @(& $GetBugchecks) } catch { $bugchecks = @() }
    foreach ($e in @($bugchecks | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{ When = $e.TimeCreated; Tag = [string](Get-Translation 'BlueScreenTagBugCheck'); Message = [string]$e.Message })
    }

    $powerLoss = @()
    try { $powerLoss = @(& $GetPowerLoss) } catch { $powerLoss = @() }
    foreach ($e in @($powerLoss | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{ When = $e.TimeCreated; Tag = [string](Get-Translation 'BlueScreenTagPowerLoss'); Message = [string]$e.Message })
    }

    $unexpected = @()
    try { $unexpected = @(& $GetUnexpectedShutdowns) } catch { $unexpected = @() }
    foreach ($e in @($unexpected | Where-Object { $_ })) {
        $rows.Add([PSCustomObject]@{ When = $e.TimeCreated; Tag = [string](Get-Translation 'BlueScreenTagUnexpectedShutdown'); Message = [string]$e.Message })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'BlueScreenHistoryHeading'))
    if ($rows.Count -eq 0) {
        $lines.Add('  ' + [string](Get-Translation 'BlueScreenNoneFound'))
    }
    else {
        foreach ($r in @($rows | Sort-Object -Property When -Descending)) {
            $when = ''
            if ($r.When) { $when = ([datetime]$r.When).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
            $parts = @(([string]$r.Message) -csplit "`r`n|`r|`n" | Where-Object { $_.Trim() })
            $msg = if ($parts.Count -gt 0) { $parts[0].Trim() } else { [string](Get-Translation 'EventNoMessage') }
            $msgRoom = [Math]::Max(12, $Width - 16 - 2 - $r.Tag.Length - 2)
            if ($msg.Length -gt $msgRoom) { $msg = $msg.Substring(0, $msgRoom - 1) + '~' }
            $lines.Add((('{0,-16}  {1}  {2}' -f $when, $r.Tag, $msg)).TrimEnd())
        }
    }

    $lines.Add('')
    $lines.Add([string](Get-Translation 'CrashDumpsHeading'))
    $dumps = @()
    try { $dumps = @((& $GetDumps) | Where-Object { $_ }) } catch { $dumps = @() }
    if ($dumps.Count -eq 0) {
        $lines.Add('  ' + [string](Get-Translation 'CrashDumpsNone'))
    }
    else {
        $total = [long]0
        foreach ($d in $dumps) { $total += [long]$d.Length }
        $lines.Add('  ' + ((Get-Translation 'CrashDumpsSummary') -f $dumps.Count, (Format-WtByteSize -Bytes $total)))
        foreach ($d in @($dumps | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 5)) {
            $stamp = ''
            if ($d.LastWriteTime) { $stamp = ([datetime]$d.LastWriteTime).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
            $lines.Add(('  {0,-16}  {1}' -f $stamp, [string]$d.Name))
        }
    }
    return [string[]]$lines.ToArray()
}

function Get-WtDiskErrorEventsLines {
    <#
    .SYNOPSIS
        Controller and file system faults logged on behalf of the drives -
        the warning that arrives long before SMART turns. Level lives
        inside the FilterHashtable, never a later Where-Object, since
        -MaxEvents 40 is spent before any later filter runs - filtering
        afterwards would fetch 40 volmgr/Ntfs information rows and throw
        the real faults away. A provider that does not exist on this
        machine (stornvme on a SATA-only box) is not fatal; Get-WinEvent's
        TERMINATING "no match" error is caught and reported as "none".
    #>
    param(
        [scriptblock]$GetEvents = {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'volmgr', 'storahci', 'stornvme'; Level = 1, 2, 3 } -MaxEvents 40 -ErrorAction SilentlyContinue
        },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )
    $events = @()
    try { $events = @(& $GetEvents) } catch { $events = @() }
    $events = @($events | Where-Object { $_ })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'DiskErrorEventsHeading'))
    if ($events.Count -eq 0) {
        $lines.Add('  ' + [string](Get-Translation 'DiskErrorEventsNone'))
        return [string[]]$lines.ToArray()
    }

    $msgRoom = [Math]::Max(12, $Width - 57)
    foreach ($e in @($events | Sort-Object -Property TimeCreated -Descending)) {
        $when = ''
        if ($e.TimeCreated) {
            $when = ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $level = Get-WtEventLevelTag -Level $e.Level
        $provider = [string]$e.ProviderName
        if ($provider.Length -gt 22) { $provider = $provider.Substring(0, 21) + '~' }
        $parts = @(([string]$e.Message) -csplit "`r`n|`r|`n" | Where-Object { $_.Trim() })
        $msg = if ($parts.Count -gt 0) { $parts[0].Trim() } else { [string](Get-Translation 'EventNoMessage') }
        if ($msg.Length -gt $msgRoom) { $msg = $msg.Substring(0, $msgRoom - 1) + '~' }
        $lines.Add((('{0,-16}  {1,-5}  {2,6}  {3,-22}  {4}' -f $when, $level, ([string]$e.Id), $provider, $msg)).TrimEnd())
    }
    return [string[]]$lines.ToArray()
}

function Get-WtTopProcessesByMemoryLines {
    <#
    .SYNOPSIS
        The programs holding the most RAM right now, every instance of one
        name added together - so "my memory is full" gets a name.
        Group-Object -AsHashTable hands back PSObject collections on
        PowerShell 5.1, so the name -> total map is built with an explicit
        loop over an OrderedDictionary instead, which conveniently compares
        keys ordinally (what tr-TR's dotless-I rule needs too). No CPU
        column on purpose: Get-Process exposes CPU as lifetime seconds,
        which answers no question a user is asking, and reading it throws
        Access Denied on a protected process, unlike WorkingSet64.
    #>
    param(
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue },
        [int]$Top = 15
    )
    $procs = @()
    try { $procs = @((& $GetProcesses) | Where-Object { $_ }) } catch { $procs = @() }
    if ($procs.Count -eq 0) { return [string[]]@([string](Get-Translation 'TopProcessesNoneFound')) }

    $totals = New-Object System.Collections.Specialized.OrderedDictionary
    $grand = [long]0
    foreach ($p in $procs) {
        $name = [string]$p.ProcessName
        if (-not $name) { $name = '(unknown)' }
        if (-not $totals.Contains($name)) {
            $totals[$name] = [PSCustomObject]@{ Name = $name; Count = 0; Bytes = [long]0 }
        }
        $entry = $totals[$name]
        $entry.Count = $entry.Count + 1
        $entry.Bytes = $entry.Bytes + [long]$p.WorkingSet64
        $grand = $grand + [long]$p.WorkingSet64
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'TopProcessesHeading'))
    $lines.Add((('{0,-28}  {1,5}  {2,12}' -f [string](Get-Translation 'ColumnProcess'), [string](Get-Translation 'ColumnInstances'), [string](Get-Translation 'ColumnMemory'))).TrimEnd())
    foreach ($row in @(@($totals.Values) | Sort-Object -Property Bytes -Descending | Select-Object -First $Top)) {
        $name = [string]$row.Name
        if ($name.Length -gt 28) { $name = $name.Substring(0, 27) + '~' }
        $lines.Add((('{0,-28}  {1,5}  {2,12}' -f $name, $row.Count, (Format-WtByteSize -Bytes ([long]$row.Bytes)))).TrimEnd())
    }
    $lines.Add('')
    $lines.Add([string]((Get-Translation 'TopProcessesTotalLine') -f $procs.Count, $totals.Count, (Format-WtByteSize -Bytes $grand)))
    return [string[]]$lines.ToArray()
}
