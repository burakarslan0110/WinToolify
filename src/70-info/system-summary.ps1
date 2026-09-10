# System identity, Windows version/build, upgrade history, pending reboot, time sync, shutdown history.
# Covered by: tests/InfoSystemSummary.Tests.ps1

function Get-WtSystemIdentityLines {
    <#
    .SYNOPSIS
        The merged "System Identity" leaf: computer + user name, BIOS
        serial, and the Windows license summary (cscript slmgr, no GUI)
        - one list of console lines. Sources are injected so the shape
        is unit-tested without CIM.
    #>
    param(
        [scriptblock]$GetSerial = { (Get-CimInstance -ClassName Win32_BIOS).SerialNumber },
        [scriptblock]$GetLicenseLines = { Get-WtLicenseInfoLines },
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$UserName = $env:USERNAME
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'ComputerName'), $ComputerName))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'ActiveUser'), $UserName))
    $serial = try { [string](& $GetSerial) } catch { $null }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'SerialNumber'), $(if ($serial) { $serial } else { 'n/a' })))
    $lines.Add('')
    $lines.Add(((Get-Translation 'LicenseInfo') + ':'))
    foreach ($l in @(& $GetLicenseLines)) { $lines.Add('  ' + [string]$l) }
    return [string[]]$lines.ToArray()
}


function Get-WtWindowsVersionLines {
    <#
    .SYNOPSIS
        V1's "Show Windows Version", now with a console summary before
        winver opens: caption, DisplayVersion + build, architecture.
    #>
    param(
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem },
        [scriptblock]$GetDisplayVersion = { (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion }
    )
    $os = & $GetOs
    $display = [string](& $GetDisplayVersion)
    $version = if ($display) { '{0} (Build {1})' -f $display, $os.BuildNumber } else { 'Build {0}' -f $os.BuildNumber }
    return [string[]]@(
        ('{0}: {1}' -f (Get-Translation 'WindowsEdition'), $os.Caption)
        ('{0}: {1}' -f (Get-Translation 'WindowsVersionLabel'), $version)
        ('{0}: {1}' -f (Get-Translation 'Architecture'), $os.OSArchitecture)
    )
}

function Format-WtUnixDate {
    <#
    .SYNOPSIS
        A registry Unix-seconds stamp as local wall-clock text, or the
        localized "date not recorded" line when missing or zero.
        InstallDate is a REG_DWORD ([int]) and must be widened before
        FromUnixTimeSeconds (which takes [long]) accepts it. Rendered with
        InvariantCulture so the '-' and ':' separators stay the same under
        tr-TR.
    #>
    param([AllowNull()]$UnixSeconds)
    $seconds = [long]0
    if ($null -ne $UnixSeconds -and [long]::TryParse([string]$UnixSeconds, [ref]$seconds) -and $seconds -gt 0) {
        return ([datetimeoffset]::FromUnixTimeSeconds($seconds)).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return (Get-Translation 'UpgradeHistoryDateUnknown')
}

function Get-WtWindowsBuildText {
    <#
    .SYNOPSIS
        "Windows 10 Pro - 21H2 - Build 19044.4291" from a
        CurrentVersion-shaped property bag. Older keys carry ReleaseId
        instead of DisplayVersion, CurrentBuildNumber instead of
        CurrentBuild, and a 'Source OS' key can carry neither; an entry
        with nothing usable returns '' so the caller can print the key
        name instead of a row of dashes.
    #>
    param([AllowNull()]$Entry)
    if ($null -eq $Entry) { return '' }
    $name = [string]$Entry.ProductName
    $display = [string]$Entry.DisplayVersion
    if (-not $display) { $display = [string]$Entry.ReleaseId }
    $build = [string]$Entry.CurrentBuild
    if (-not $build) { $build = [string]$Entry.CurrentBuildNumber }
    $ubr = [string]$Entry.UBR
    if ($build -and $ubr) { $build = '{0}.{1}' -f $build, $ubr }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($name) { $parts.Add($name) }
    if ($display) { $parts.Add($display) }
    if ($build) { $parts.Add(('{0} {1}' -f (Get-Translation 'BuildLabel'), $build)) }
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join ' - ')
}

function Get-WtWindowsUpgradeHistoryLines {
    <#
    .SYNOPSIS
        When this Windows was installed, what it is running now, and every
        build it was upgraded through - the honest answer to the question
        systeminfo's single "Original Install Date" muddles, since a feature
        upgrade rewrites that date. Rows come from HKLM:\SYSTEM\Setup
        subkeys named 'Source OS*', matched Ordinal (tr-TR folds I/i
        differently). No such keys is the common case, not a failure, so
        the row prints one flat sentence instead of an empty block.
    #>
    param(
        [scriptblock]$GetCurrentVersion = { Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue },
        [scriptblock]$GetSourceOsEntries = {
            Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName.StartsWith('Source OS', [System.StringComparison]::OrdinalIgnoreCase) } |
                ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue }
        }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $cv = try { & $GetCurrentVersion } catch { $null }
    if ($null -eq $cv) {
        $lines.Add((Get-Translation 'UpgradeHistoryNotAvailable'))
        return [string[]]$lines.ToArray()
    }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'UpgradeHistoryInstalledOn'), (Format-WtUnixDate -UnixSeconds $cv.InstallDate)))
    $current = Get-WtWindowsBuildText -Entry $cv
    if (-not $current) { $current = (Get-Translation 'UpgradeHistoryDateUnknown') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'UpgradeHistoryCurrent'), $current))

    $entries = @()
    try { $entries = @(& $GetSourceOsEntries | Where-Object { $null -ne $_ }) } catch { $entries = @() }
    if ($entries.Count -eq 0) {
        $lines.Add((Get-Translation 'UpgradeHistoryNone'))
        return [string[]]$lines.ToArray()
    }
    $lines.Add('')
    $lines.Add(((Get-Translation 'UpgradeHistoryPrevious') + ':'))
    $sorted = @($entries | Sort-Object -Property @{ Expression = { if ($null -eq $_.InstallDate) { [long]0 } else { [long]$_.InstallDate } } })
    foreach ($e in $sorted) {
        $text = Get-WtWindowsBuildText -Entry $e
        if (-not $text) { $text = [string]$e.PSChildName }
        $lines.Add(('  {0}  {1}' -f (Format-WtUnixDate -UnixSeconds $e.InstallDate), $text))
    }
    return [string[]]$lines.ToArray()
}

function Get-WtPendingRebootLines {
    <#
    .SYNOPSIS
        Whether Windows is waiting for a restart, and WHICH component is
        asking for it - also explains why sfc and DISM keep failing on a
        machine that never got restarted. Three flags decide:
        CBS\RebootPending, Windows Update's RebootRequired, and an
        ActiveComputerName that no longer matches ComputerName (compared
        Ordinal-ignore-case, since tr-TR folds 'I' differently).
        PendingFileRenameOperations is REPORTED as a count but never
        decides: it is populated on almost every machine, so letting it
        decide would make the row cry wolf.
    #>
    param(
        [scriptblock]$GetCbsRebootPending = { Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' },
        [scriptblock]$GetWindowsUpdateRebootRequired = { Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' },
        [scriptblock]$GetActiveComputerName = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName },
        [scriptblock]$GetPendingComputerName = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName },
        [scriptblock]$GetPendingFileRenames = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations }
    )
    $reasons = New-Object System.Collections.Generic.List[string]

    $cbs = try { [bool](& $GetCbsRebootPending) } catch { $false }
    if ($cbs) { $reasons.Add((Get-Translation 'PendingRebootReasonCbs')) }

    $wu = try { [bool](& $GetWindowsUpdateRebootRequired) } catch { $false }
    if ($wu) { $reasons.Add((Get-Translation 'PendingRebootReasonWindowsUpdate')) }

    $activeName = try { [string](& $GetActiveComputerName) } catch { '' }
    $pendingName = try { [string](& $GetPendingComputerName) } catch { '' }
    if ($activeName -and $pendingName -and -not [string]::Equals($activeName, $pendingName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add(((Get-Translation 'PendingRebootReasonComputerName') -f $activeName, $pendingName))
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $answer = if ($reasons.Count -gt 0) { Get-Translation 'AnswerYes' } else { Get-Translation 'AnswerNo' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), $answer))
    if ($reasons.Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'PendingRebootNoFlags'))
    }
    else {
        foreach ($r in $reasons) { $lines.Add('  - ' + $r) }
    }

    $lines.Add('')
    try {
        $renames = @(& $GetPendingFileRenames)
        $renameCount = @($renames | Where-Object { $_ -is [string] -and $_.Trim().Length -gt 0 }).Count
        $lines.Add(((Get-Translation 'PendingRebootFileRenameLine') -f $renameCount))
    }
    catch {
        $lines.Add((Get-Translation 'PendingRebootFileRenameUnavailable'))
    }
    return [string[]]$lines.ToArray()
}

function Get-WtTimeSyncLines {
    <#
    .SYNOPSIS
        The clock, the time zone, the sync source, the last successful sync
        and the current offset - a drifted clock breaks HTTPS everywhere at
        once. w32tm /query calls run ONLY while W32Time is running, since a
        stopped service fails both with 0x80070426 and localized noise. The
        w32tm output is printed verbatim, never parsed, since its field
        names are localized and would silently match nothing in another
        language. /resync is an action, not information, and stays off this
        screen.
    #>
    param(
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$GetTimeZoneName = { [System.TimeZoneInfo]::Local.DisplayName },
        [scriptblock]$GetTimeService = { Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue },
        [scriptblock]$GetTimeSource = { & w32tm /query /source 2>&1 },
        [scriptblock]$GetTimeStatus = { & w32tm /query /status 2>&1 }
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $lines = New-Object System.Collections.Generic.List[string]

    $now = try { [datetime](& $GetNow) } catch { [datetime]::Now }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncLocalTime'), $now.ToString('yyyy-MM-dd HH:mm:ss', $invariant)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncUtcTime'), $now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', $invariant)))
    $zone = try { [string](& $GetTimeZoneName) } catch { '' }
    if (-not $zone) { $zone = Get-Translation 'TimeSyncZoneUnknown' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncTimeZone'), $zone))

    $service = try { & $GetTimeService } catch { $null }
    if ($null -eq $service) {
        $lines.Add('')
        $lines.Add((Get-Translation 'TimeSyncServiceMissing'))
        return [string[]]$lines.ToArray()
    }
    if (-not [string]::Equals([string]$service.Status, 'Running', [System.StringComparison]::OrdinalIgnoreCase)) {
        $lines.Add('')
        $lines.Add((Get-Translation 'TimeSyncServiceStopped'))
        return [string[]]$lines.ToArray()
    }

    $lines.Add('')
    $source = try { @(& $GetTimeSource) } catch { @() }
    $sourceText = (@($source | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' ')
    if (-not $sourceText) { $sourceText = Get-Translation 'TimeSyncNotAvailable' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TimeSyncSourceHeader'), $sourceText))

    $lines.Add('')
    $lines.Add(((Get-Translation 'TimeSyncStatusHeader') + ':'))
    $status = try { @(& $GetTimeStatus) } catch { @() }
    $statusLines = @($status | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_.Trim() })
    if ($statusLines.Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'TimeSyncNotAvailable'))
    }
    else {
        foreach ($l in $statusLines) { $lines.Add('  ' + $l) }
    }
    return [string[]]$lines.ToArray()
}

function Get-WtShutdownEventText {
    <#
    .SYNOPSIS
        One history row for a 1074 / 6005 / 6006 System event. 1074 carries
        the process, user and reason in the FIRST LINE of Message, never by
        property order (it differs between shutdown initiators). The first
        line is taken by splitting on LF and trimming a trailing CR, not a
        "`r`n" regex anchor - a PS 5.1 trap this project has already paid
        for once. A missing message resource says so instead of printing a
        blank.
    #>
    param([Parameter(Mandatory)][AllowNull()]$EventRecord)
    if ($null -eq $EventRecord) { return (Get-Translation 'ShutdownMessageUnavailable') }
    $id = 0
    if ($null -ne $EventRecord.Id) { $id = [int]$EventRecord.Id }
    $label = switch ($id) {
        1074 { Get-Translation 'ShutdownEventRequested' }
        6005 { Get-Translation 'ShutdownEventLogStarted' }
        6006 { Get-Translation 'ShutdownEventLogStopped' }
        default { (Get-Translation 'ShutdownEventOther') -f $id }
    }
    if ($id -ne 1074) { return $label }
    $message = [string]$EventRecord.Message
    if (-not $message.Trim()) { return ('{0} - {1}' -f $label, (Get-Translation 'ShutdownMessageUnavailable')) }
    $first = $message.Split([char]10)[0].TrimEnd([char]13).Trim()
    if (-not $first) { return ('{0} - {1}' -f $label, (Get-Translation 'ShutdownMessageUnavailable')) }
    return ('{0} - {1}' -f $label, $first)
}

function Get-WtShutdownHistoryLines {
    <#
    .SYNOPSIS
        How long the machine has been up, and when and why it was last shut
        down or restarted. The header is LastBootUpTime with a Fast Startup
        footnote: with Fast Startup on, a shutdown hibernates the kernel
        session, so that value does not move and can be far older than the
        last power-off. Reads 1074/6005/6006 only - 6008 and 41 belong to
        the blue screen history row instead, noted so the omission never
        reads as a gap. Get-WinEvent throws on no match, which is exactly a
        trimmed/cleared log, so the catch prints "no record left".
    #>
    param(
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem },
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$GetEvents = { Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074, 6005, 6006 } -MaxEvents 40 -ErrorAction Stop },
        [int]$MaxRows = 8
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $lines = New-Object System.Collections.Generic.List[string]

    $os = try { & $GetOs } catch { $null }
    $boot = $null
    if ($null -ne $os -and $null -ne $os.LastBootUpTime) {
        $boot = try { [datetime]$os.LastBootUpTime } catch { $null }
    }
    if ($null -eq $boot) {
        $lines.Add((Get-Translation 'ShutdownBootTimeUnavailable'))
    }
    else {
        $now = try { [datetime](& $GetNow) } catch { [datetime]::Now }
        $span = $now - $boot
        if ($span.Ticks -lt 0) { $span = [timespan]::Zero }
        $lines.Add(('{0}: {1}' -f (Get-Translation 'ShutdownLastBoot'), $boot.ToString('yyyy-MM-dd HH:mm:ss', $invariant)))
        $lines.Add(('{0}: {1}' -f (Get-Translation 'ShutdownUptime'), ((Get-Translation 'ShutdownUptimeValue') -f $span.Days, $span.Hours, $span.Minutes)))
        $lines.Add((Get-Translation 'ShutdownFastStartupNote'))
    }

    $lines.Add('')
    $lines.Add(((Get-Translation 'ShutdownHistoryHeader') + ':'))
    $events = @()
    try { $events = @(& $GetEvents | Where-Object { $null -ne $_ }) } catch { $events = @() }
    if ($events.Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'ShutdownHistoryNone'))
    }
    else {
        $ordered = @($events | Sort-Object -Property @{ Expression = { [datetime]$_.TimeCreated }; Descending = $true })
        foreach ($e in @($ordered | Select-Object -First $MaxRows)) {
            $stamp = try { ([datetime]$e.TimeCreated).ToString('yyyy-MM-dd HH:mm:ss', $invariant) } catch { '' }
            $lines.Add(('  {0}  {1}' -f $stamp, (Get-WtShutdownEventText -EventRecord $e)))
        }
    }

    $lines.Add('')
    $lines.Add((Get-Translation 'ShutdownBugcheckElsewhere'))
    return [string[]]$lines.ToArray()
}
