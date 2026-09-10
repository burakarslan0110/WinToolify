# winget table parsing, queries, argument builders and the batch runner.
# Covered by: tests/WingetStoreParse.Tests.ps1, tests/WingetStoreArgs.Tests.ps1

function Get-WtWingetColumnStarts {
    <#
    .SYNOPSIS
        Column start offsets read off a winget header row: the index of
        every non-space that follows at least two spaces (plus index 0).
        Positional, so it works whatever language winget printed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Header)
    $starts = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Header.Length; $i++) {
        if ($Header[$i] -eq ' ') { continue }
        if ($i -eq 0) { $starts.Add(0); continue }
        if ($i -ge 2 -and $Header[$i - 1] -eq ' ' -and $Header[$i - 2] -eq ' ') { $starts.Add($i) }
    }
    return [int[]]$starts.ToArray()
}

function ConvertFrom-WtWingetTable {
    <#
    .SYNOPSIS
        winget's fixed-width table as objects. Columns are found by POSITION
        (ordinal 0=Name, 1=Id, 2=Version), never by header text, since
        winget localises headers. The Source column is found by VALUE
        (winget / msstore), which disambiguates the slot before it:
        Available on 'winget list' (only with -WithAvailable), the
        discarded Match column on 'winget search'. Blank lines are
        skipped, never terminating; a row that fails the one-space-per-
        boundary alignment gate, or has an empty Id, is skipped (continue)
        rather than ending the scan - both guard against silently dropping
        real rows. Returns @{ Name; Id; Version; Available; Source }.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [switch]$WithAvailable
    )

    $sourceValues = @('winget', 'msstore')
    $sep = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (([string]$Lines[$i]).TrimEnd() -match '^-{10,}$') { $sep = $i; break }
    }
    if ($sep -lt 1) { return @() }

    $starts = Get-WtWingetColumnStarts -Header ([string]$Lines[$sep - 1])
    if ($starts.Count -lt 2) { return @() }

    $cell = {
        param([string]$Line, [int]$Index)
        if ($Index -ge $starts.Count) { return '' }
        $from = $starts[$Index]
        if ($from -ge $Line.Length) { return '' }
        $to = if (($Index + 1) -lt $starts.Count) { [Math]::Min($starts[$Index + 1], $Line.Length) } else { $Line.Length }
        return $Line.Substring($from, [Math]::Max(0, $to - $from)).Trim()
    }

    $out = New-Object System.Collections.Generic.List[object]
    for ($i = $sep + 1; $i -lt $Lines.Count; $i++) {
        $line = [string]$Lines[$i]

        if ($line.Trim() -eq '') { continue }

        $id = & $cell $line 1
        if ($id -eq '') { continue }

        $aligned = $true
        for ($c = 1; $c -lt $starts.Count; $c++) {
            $boundary = $starts[$c]
            if ($line.Length -gt $boundary -and $line[$boundary - 1] -ne ' ') {
                $aligned = $false
                break
            }
        }
        if (-not $aligned) { continue }

        $source = ''
        $sourceIndex = -1
        for ($c = $starts.Count - 1; $c -ge 3; $c--) {
            $value = & $cell $line $c
            if ($value -ne '' -and ($sourceValues -contains $value.ToLowerInvariant())) {
                $source = $value
                $sourceIndex = $c
                break
            }
        }
        $available = ''
        if ($WithAvailable -and $sourceIndex -eq 4) { $available = & $cell $line 3 }

        $out.Add(@{
            Name      = & $cell $line 0
            Id        = $id
            Version   = & $cell $line 2
            Available = $available
            Source    = $source
        })
    }
    return $out.ToArray()
}

$script:WtWingetInstalledCache = $null

function Clear-WtWingetCache {
    <#
    .SYNOPSIS
        Forget the cached 'winget list'. Called by the store screen's R key
        and after any install / upgrade / uninstall run.
    #>
    $script:WtWingetInstalledCache = $null
}

function ConvertTo-WtNativeArgumentLine {
    <#
    .SYNOPSIS
        An argument array as one command line, quoted the way the Windows C
        runtime parses it back (needed since ProcessStartInfo.ArgumentList
        does not exist on .NET Framework 4.8 / PS 5.1). Quoting triggers on
        any [char]::IsWhiteSpace, not just a literal space - CommandLineToArgvW
        also splits on tab/CR/LF, and checking only ' ' let an unquoted value
        smuggle in as two argv elements. Backslashes are doubled only when
        they immediately precede a quote (the value's own or the closing
        one); doubling them everywhere corrupts an unrelated backslash.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) {
        $value = [string]$a
        if ($value -eq '') { $parts.Add('""'); continue }

        $needsQuoting = $false
        foreach ($ch in $value.ToCharArray()) {
            if ([char]::IsWhiteSpace($ch) -or $ch -eq '"') { $needsQuoting = $true; break }
        }
        if (-not $needsQuoting) { $parts.Add($value); continue }

        $sb = New-Object System.Text.StringBuilder
        $null = $sb.Append('"')
        $backslashes = 0
        foreach ($ch in $value.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            if ($ch -eq '"') {
                if ($backslashes -gt 0) { $null = $sb.Append('\', $backslashes * 2) }
                $backslashes = 0
                $null = $sb.Append('\"')
                continue
            }
            if ($backslashes -gt 0) { $null = $sb.Append('\', $backslashes) }
            $backslashes = 0
            $null = $sb.Append($ch)
        }
        if ($backslashes -gt 0) { $null = $sb.Append('\', $backslashes * 2) }
        $null = $sb.Append('"')
        $parts.Add($sb.ToString())
    }
    return ($parts -join ' ')
}

function Invoke-WtWingetCapture {
    <#
    .SYNOPSIS
        Runs winget with the given argument ARRAY and returns its stdout as
        lines. Arguments are passed as an array, never as one string, so a
        package name the user typed is never re-parsed as script. Decoding
        is settled by StandardOutputEncoding (UTF-8) on the child process,
        never [Console]::OutputEncoding, since changing the code page under
        a painted frame corrupts the box-drawing glyphs. Both pipes are
        drained CONCURRENTLY (two ReadToEndAsync tasks): reading stdout to
        EOF before touching stderr deadlocks forever the moment winget's
        stderr output - a failed source update, an unaccepted agreement -
        exceeds the 4 KB pipe buffer with nobody reading it.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [scriptblock]$RunWinget,
        [string]$FilePath = 'winget.exe'
    )
    if ($RunWinget) { return , [string[]]@(& $RunWinget $Arguments) }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ConvertTo-WtNativeArgumentLine -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = $null
    $text = ''
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $text = [string]$outTask.Result
        $null = $errTask.Result
        $process.WaitForExit()
    }
    catch { return , [string[]]@() }
    finally { if ($null -ne $process) { $process.Dispose() } }
    return [string[]]@($text -split "`r?`n")
}

function Get-WtWingetSearchResults {
    <#
    .SYNOPSIS
        'winget search' against the winget source only. msstore is
        deliberately not queried: a Store package installs through a
        licence the elevated session may not hold, and it fails silently.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Query = '',
        [scriptblock]$RunWinget
    )
    $q = ([string]$Query).Trim()
    if ($q -eq '') { return @() }
    $arguments = [string[]]@(
        'search', $q
        '--source', 'winget'
        '--disable-interactivity'
        '--accept-source-agreements'
    )
    $lines = Invoke-WtWingetCapture -Arguments $arguments -RunWinget $RunWinget
    return @(ConvertFrom-WtWingetTable -Lines $lines)
}

function Get-WtWingetInstalledPackages {
    <#
    .SYNOPSIS
        'winget list' - one call gives both the installed version and the
        version an upgrade would bring, so the installed tab needs no second
        'winget upgrade' round trip. Cached for the session (the list takes
        seconds and the cursor moves constantly); Clear-WtWingetCache after
        any install/upgrade/uninstall and on the screen's R key.
    #>
    param([scriptblock]$RunWinget)
    if ($null -ne $script:WtWingetInstalledCache) { return @($script:WtWingetInstalledCache) }
    $arguments = [string[]]@(
        'list'
        '--disable-interactivity'
        '--accept-source-agreements'
    )
    $lines = Invoke-WtWingetCapture -Arguments $arguments -RunWinget $RunWinget
    $script:WtWingetInstalledCache = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
    return @($script:WtWingetInstalledCache)
}

function Get-WtWingetInstallArguments {
    <#
    .SYNOPSIS
        The winget argument list for ONE install, built as an array so
        nothing the catalog or the user supplied is re-parsed as script.
        --silent and --disable-interactivity are not optional: the output
        panel has no cancel key, so an installer UI or an unaccepted
        agreement would block forever; --accept-* turns that into a hard
        failure instead of a prompt.
    #>
    param([Parameter(Mandatory)][string]$Id)
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add('install')
    $list.Add('--id'); $list.Add($Id); $list.Add('--exact')
    $list.Add('--source'); $list.Add('winget')
    $list.Add('--silent')
    $list.Add('--disable-interactivity')
    $list.Add('--accept-source-agreements')
    $list.Add('--accept-package-agreements')
    return , [string[]]$list.ToArray()
}

function Get-WtWingetUninstallArguments {
    <#
    .SYNOPSIS
        The winget argument list for ONE uninstall. No --source: an app on
        the installed tab may be an ARP entry winget did not install, and
        pinning the source would make it unfindable.
    #>
    param([Parameter(Mandatory)][string]$Id)
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add('uninstall')
    $list.Add('--id'); $list.Add($Id); $list.Add('--exact')
    $list.Add('--silent')
    $list.Add('--disable-interactivity')
    $list.Add('--accept-source-agreements')
    return , [string[]]$list.ToArray()
}

function Test-WtWingetAdminContextProhibited {
    <#
    .SYNOPSIS
        Whether winget refused (0x8A15007D,
        APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED) because the
        package lives in the USER scope while this process is elevated.
        WinToolify always relaunches itself elevated, so this is not an
        edge case: every per-user install (Antigravity, VS Code user setup,
        anything shipped through Squirrel) hits it, and winget has no flag
        that overrides it - the only fix is running the same command back
        in the user's own non-elevated session (Invoke-WtWingetBatch
        -RunOneAsUser).
    #>
    param([AllowNull()][object]$ExitCode)
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) { return $false }
    return ($code -eq [Convert]::ToUInt32('8A15007D', 16))
}

function Get-WtWingetResultKind {
    <#
    .SYNOPSIS
        One winget exit code as a verdict word: 'Ok' | 'AlreadyInstalled' |
        'NoUpgrade' | 'NotFound' | 'RebootRequired' | 'RebootToRetry' |
        'Failed'. Uses ConvertTo-WtWingetExitCode since $LASTEXITCODE is
        signed while winget's codes are unsigned, and a literal like
        [uint32]0x8A150014 overflows on PS 5.1. 0x8A150049 is deliberately
        NOT mapped to RebootRequired - it is actually
        APPINSTALLER_CLI_ERROR_MSI_INSTALL_FAILED, and reporting an install
        failure as success-needing-restart is the exact false-success bug
        this function exists to prevent. 0x8A15010A's own text says the
        install failed too, so it gets RebootToRetry (a failure), not
        RebootRequired like the other two reboot codes.
    #>
    param([AllowNull()][object]$ExitCode)
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) { return 'Failed' }
    if ($code -eq [uint32]0) { return 'Ok' }
    if ($code -eq [Convert]::ToUInt32('8A15007D', 16)) { return 'AdminContext' }
    if ($code -eq [Convert]::ToUInt32('8A150014', 16)) { return 'NotFound' }
    if ($code -eq [Convert]::ToUInt32('8A15002B', 16)) { return 'NoUpgrade' }
    if ($code -eq [Convert]::ToUInt32('8A150061', 16)) { return 'AlreadyInstalled' }
    if ($code -eq [Convert]::ToUInt32('8A150109', 16)) { return 'RebootRequired' }
    if ($code -eq [Convert]::ToUInt32('8A15010B', 16)) { return 'RebootRequired' }
    if ($code -eq [Convert]::ToUInt32('8A15010A', 16)) { return 'RebootToRetry' }
    return 'Failed'
}

function Get-WtWingetResultKey {
    <#
    .SYNOPSIS
        The translation key one verdict earns for one OPERATION - a fix for
        uninstalls that used to print install-worded results ("2 kuruldu"
        for 2 removals). Only wording that actually differs gets its own
        key (a restart or a not-found is the same regardless of operation).
        AlreadyInstalled / NoUpgrade cannot happen on an uninstall, so if
        winget ever returns one anyway this says WsResultUnchanged - the
        honest "nothing changed" - instead of inventing a reason.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [ValidateSet('Install', 'Upgrade', 'Uninstall')][string]$Operation = 'Install'
    )
    if ($Kind -eq 'Ok') {
        switch ($Operation) {
            'Upgrade'   { return 'WsResultOkUpgrade' }
            'Uninstall' { return 'WsResultOkUninstall' }
        }
        return 'WsResultOk'
    }
    if ($Kind -eq 'AlreadyInstalled' -or $Kind -eq 'NoUpgrade') {
        if ($Operation -eq 'Uninstall') { return 'WsResultUnchanged' }
        return $(if ($Kind -eq 'AlreadyInstalled') { 'WsResultAlready' } else { 'WsResultNoUpgrade' })
    }
    switch ($Kind) {
        'AdminContext'   { return 'WsResultAdminContext' }
        'NotFound'       { return 'WsResultNotFound' }
        'RebootRequired' { return 'WsResultReboot' }
        'RebootToRetry'  { return 'WsResultRebootRetry' }
    }
    return 'WsResultFailed'
}

function Get-WtWingetResultLine {
    <#
    .SYNOPSIS
        The one-line verdict for a single package, ready for the output
        panel. An unrecognised code is printed as UNSIGNED hex: a negative
        decimal cannot be looked up in Microsoft's table.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()][object]$ExitCode,
        [ValidateSet('Install', 'Upgrade', 'Uninstall')][string]$Operation = 'Install'
    )
    $key = Get-WtWingetResultKey -Kind $Kind -Operation $Operation
    if ($key -ne 'WsResultFailed') { return ((Get-Translation $key) -f $Id) }
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    $hex = if ($null -eq $code) { '????????' } else { '{0:X8}' -f $code }
    return ((Get-Translation 'WsResultFailed') -f $Id, $hex)
}

function Get-WtWingetBatchArguments {
    <#
    .SYNOPSIS
        The argument array for one package and one operation. Upgrade
        reuses Get-WtWingetUpgradeArguments - the single-package upgrade
        builder that already exists in src/60-actions/software.ps1 - so
        there is one place where upgrade flags live.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Upgrade', 'Uninstall')][string]$Operation,
        [Parameter(Mandatory)][string]$Id
    )
    switch ($Operation) {
        'Install'   { return Get-WtWingetInstallArguments -Id $Id }
        'Uninstall' { return Get-WtWingetUninstallArguments -Id $Id }
        'Upgrade'   { return , [string[]]@(Get-WtWingetUpgradeArguments -Package $Id) }
    }
}

function Invoke-WtWingetBatch {
    <#
    .SYNOPSIS
        Runs one operation over a set of package ids, IN ORDER (winget
        accepts one package per command), and returns a verdict per package.
        A failing package never stops the run. The cached 'winget list' is
        dropped at the end, since an install or uninstall changes the
        machine it describes. RunOneAsUser retries only the one failure
        de-elevation can fix (0x8A15007D); if it cannot run at all, the
        elevated verdict stands, reported honestly as 'AdminContext' rather
        than a bare hex code.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids,
        [Parameter(Mandatory)][ValidateSet('Install', 'Upgrade', 'Uninstall')][string]$Operation,
        [Parameter(Mandatory)][scriptblock]$RunOne,
        [scriptblock]$RunOneAsUser
    )
    $ids = @($Ids)
    if ($ids.Count -eq 0) { return @() }
    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $id = [string]$ids[$i]
        $arguments = Get-WtWingetBatchArguments -Operation $Operation -Id $id
        $code = & $RunOne $id $arguments ($i + 1) $ids.Count
        if ($RunOneAsUser -and (Test-WtWingetAdminContextProhibited -ExitCode $code)) {
            $retryCode = & $RunOneAsUser $id $arguments ($i + 1) $ids.Count
            if ($null -ne $retryCode) { $code = $retryCode }
        }
        $results.Add(@{ Id = $id; Kind = (Get-WtWingetResultKind -ExitCode $code); ExitCode = $code })
    }
    Clear-WtWingetCache
    return @($results.ToArray())
}

function Get-WtWingetSummaryLines {
    <#
    .SYNOPSIS
        The closing block of a batch run: a count per verdict, then every
        package that did not simply succeed, named. Counts are worded per
        OPERATION (an uninstall printing install wording was a real bug).
        Uninstall gets THREE numbers, not four: its middle two buckets
        (already installed / already current) are verdicts an uninstall
        cannot produce, so they are summed into one "unchanged" number
        instead of printing a contradictory zero. NotFound, RebootToRetry
        and AdminContext all roll into the Failed count (each still gets
        its own detail line); RebootRequired rolls into Ok, since winget
        already succeeded and only wants a restart.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Results,
        [ValidateSet('Install', 'Upgrade', 'Uninstall')][string]$Operation = 'Install'
    )
    $results = @($Results)
    if ($results.Count -eq 0) { return [string[]]@() }
    $count = { param([string]$Kind) @($results | Where-Object { [string]$_.Kind -eq $Kind }).Count }
    $countFailed = (& $count 'Failed') + (& $count 'NotFound') + (& $count 'RebootToRetry') + (& $count 'AdminContext')
    $countOk = (& $count 'Ok') + (& $count 'RebootRequired')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add((Get-Translation 'WsSummaryTitle'))
    if ($Operation -eq 'Uninstall') {
        $countUnchanged = (& $count 'AlreadyInstalled') + (& $count 'NoUpgrade')
        $lines.Add(((Get-Translation 'WsSummaryCountsUninstall') -f $countOk, $countUnchanged, $countFailed))
    }
    else {
        $key = if ($Operation -eq 'Upgrade') { 'WsSummaryCountsUpgrade' } else { 'WsSummaryCounts' }
        $lines.Add(((Get-Translation $key) -f $countOk, (& $count 'AlreadyInstalled'), (& $count 'NoUpgrade'), $countFailed))
    }
    foreach ($r in $results) {
        if ([string]$r.Kind -eq 'Ok') { continue }
        $lines.Add('  ' + (Get-WtWingetResultLine -Id ([string]$r.Id) -Kind ([string]$r.Kind) `
            -ExitCode $r.ExitCode -Operation $Operation))
    }
    return [string[]]$lines.ToArray()
}
