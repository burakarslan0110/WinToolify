# Power action, shutdown timer, advanced startup, firmware settings.
# Covered by: tests/ActionPowerSession.Tests.ps1

function Invoke-WtPowerAction {
    <#
    .SYNOPSIS
        One YES-gated power action; the gate text is the existing
        Consequence* key. Safe-boot flags keep '{default}' quoted
        (Guard.Tests AST rule).
    #>
    param(
        [Parameter(Mandatory)][string]$ConsequenceKey,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Breadcrumb = ''
    )
    if (Confirm-WtDestructiveAction -Consequence (Get-Translation $ConsequenceKey) -Breadcrumb $Breadcrumb) {
        Invoke-WtCapturedAction -Title (Get-Translation $ConsequenceKey) -Breadcrumb $Breadcrumb -Action $Action
    }
    else {
        $null = Read-WtPanelAnswer -Breadcrumb $Breadcrumb -Lines @((Get-Translation 'ActionCancelled')) -Prompt (Get-Translation 'PressEnterContinue')
    }
}

# --- Power & session rows (shutdown timer, advanced startup, firmware setup) ----

function Get-WtShutdownTimerPlan {
    <#
    .SYNOPSIS
        PURE: turns the panel answer into a plan. Mode is 'Cancel' (empty
        or zero), 'Schedule' (a whole number of minutes) or 'Invalid'
        (anything else); Invalid is refused in the panel and NEVER
        handed to shutdown.exe. The ceiling is two days - a bigger
        number is clamped, and the clamp is REPORTED by the caller,
        never applied silently. Matched with -cnotmatch against
        '^\d+\z', not -notmatch/'$': under tr-TR a case-insensitive
        match is culture-sensitive (dotless I), and .NET's '$' also
        matches before a trailing newline.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Answer,
        [datetime]$Now = (Get-Date)
    )
    $maxMinutes = 2880
    $text = ([string]$Answer).Trim()
    if (-not $text) { return [PSCustomObject]@{ Mode = 'Cancel'; Minutes = 0; Seconds = 0; Capped = $false; At = $Now } }
    if ($text -cnotmatch '^\d+\z') { return [PSCustomObject]@{ Mode = 'Invalid'; Minutes = 0; Seconds = 0; Capped = $false; At = $Now } }
    $parsed = [long]0
    if (-not [long]::TryParse($text, [ref]$parsed)) { $parsed = [long]::MaxValue }
    if ($parsed -le 0) { return [PSCustomObject]@{ Mode = 'Cancel'; Minutes = 0; Seconds = 0; Capped = $false; At = $Now } }
    $capped = ($parsed -gt [long]$maxMinutes)
    $minutes = [int][Math]::Min($parsed, [long]$maxMinutes)
    return [PSCustomObject]@{
        Mode    = 'Schedule'
        Minutes = $minutes
        Seconds = ($minutes * 60)
        Capped  = $capped
        At      = $Now.AddMinutes($minutes)
    }
}

function Get-WtShutdownCancelLines {
    <#
    .SYNOPSIS
        PURE: what "shutdown /a" actually answered, in the user's
        language. 1116 is ERROR_NO_SHUTDOWN_IN_PROGRESS - shutdown.exe
        writes that to stderr in the OS language ("Unable to abort the
        system shutdown because no shutdown was in progress.(1116)"),
        which is not an error here at all, just "there was nothing to
        cancel". The raw text never reaches the panel; this line does.
    #>
    param([Parameter(Mandatory)][int]$ExitCode)
    if ($ExitCode -eq 0) { return [string[]]@((Get-Translation 'ShutdownTimerCancelled')) }
    if ($ExitCode -eq 1116) { return [string[]]@((Get-Translation 'ShutdownTimerNonePending')) }
    return [string[]]@(((Get-Translation 'ShutdownTimerCancelFailed') -f $ExitCode))
}

function Get-WtShutdownScheduleLines {
    <#
    .SYNOPSIS
        PURE: what "shutdown /s /t <seconds>" answered. The wall-clock
        echo is the whole point of the row - the user has to be able to
        verify WHEN the machine goes down - so it is formatted with
        InvariantCulture: a culture-formatted date renders differently
        per host and the row would stop being checkable.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Plan,
        [Parameter(Mandatory)][int]$ExitCode
    )
    $rows = New-Object System.Collections.Generic.List[string]
    if ($Plan.Capped) { $rows.Add((Get-Translation 'ShutdownTimerCapped')) }
    if ($ExitCode -ne 0) {
        $rows.Add(((Get-Translation 'ShutdownTimerScheduleFailed') -f $ExitCode))
        return [string[]]$rows.ToArray()
    }
    $stamp = ([datetime]$Plan.At).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    $rows.Add(((Get-Translation 'ShutdownTimerScheduled') -f $Plan.Minutes, $stamp))
    $rows.Add((Get-Translation 'ShutdownTimerCancelHint'))
    return [string[]]$rows.ToArray()
}

function Invoke-WtShutdownCommand {
    <#
    .SYNOPSIS
        The ONLY place shutdown.exe is started, with stderr merged
        INSIDE cmd.exe rather than by PowerShell: on 5.1 a native
        stderr line crossing the PowerShell boundary is wrapped in a
        NativeCommandError ErrorRecord and would paint as a red stack
        trace under Invoke-WtCapturedAction. Returns the exit code and
        plain-string output without letting raw text reach the panel;
        $Arguments comes from the caller's already-validated values
        only. The local variable is $commandLine, not $line, to avoid
        the same collector-name call-stack shadowing documented on
        Show-WtShutdownTimerResult.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [scriptblock]$RunLine = {
            param($CommandLine)
            $out = @(cmd.exe /c $CommandLine)
            return [PSCustomObject]@{ ExitCode = [int]$LASTEXITCODE; Output = [string[]]$out }
        }
    )
    $commandLine = 'shutdown.exe ' + ($Arguments -join ' ') + ' 2>&1'
    return & $RunLine $commandLine
}

function Show-WtShutdownTimerResult {
    <#
    .SYNOPSIS
        Prints the timer's result rows inside the panel. The delegate
        deliberately reads $wtTimerRows and NOT $Lines:
        Invoke-WtCapturedAction keeps its collected output in a variable
        called $lines, PowerShell variable lookup is case-insensitive,
        and a plain script block resolves its captured variables through
        the CALL STACK - so a variable named $Lines here would be
        shadowed by the collector the moment the action runs inside the
        capture, and the panel would echo its own buffer.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyCollection()][string[]]$ResultLines = @(),
        [string]$Breadcrumb = ''
    )
    $wtTimerRows = @($ResultLines)
    Invoke-WtCapturedAction -Title $Title -Breadcrumb $Breadcrumb -Action { foreach ($row in $wtTimerRows) { Write-Host $row } }
}

function Invoke-WtShutdownTimerAction {
    <#
    .SYNOPSIS
        One row, both jobs: arm a shutdown timer or cancel a pending one.
        The minutes are asked IN THE PANEL first - a Read-Host inside
        Invoke-WtCapturedAction deadlocks behind the capture - and the
        answer only picks a branch. An empty answer (including the $null
        Read-WtPanelAnswer returns when input is exhausted) means cancel,
        which is both the documented answer and the safe direction.
    #>
    param(
        [scriptblock]$AskMinutes = {
            Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @((Get-Translation 'ShutdownTimerHint')) -Prompt (Get-Translation 'ShutdownTimerPrompt') -Risk 'CAUTION' -Layout 'Compact'
        },
        [scriptblock]$ShowInvalid = {
            $null = Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @((Get-Translation 'ShutdownTimerInvalid')) -Prompt (Get-Translation 'PressEnterContinue') -Risk 'CAUTION'
        },
        [scriptblock]$RunCancel = { Invoke-WtShutdownCommand -Arguments @('/a') },
        [scriptblock]$RunSchedule = { param($Seconds) Invoke-WtShutdownCommand -Arguments @('/s', '/t', ([string]$Seconds)) },
        [scriptblock]$ShowResult = {
            param($Rows)
            Show-WtShutdownTimerResult -Title (Get-Translation 'ShutdownTimer') -ResultLines $Rows -Breadcrumb $script:WtPanelBreadcrumb
        }
    )
    $answer = [string](& $AskMinutes)
    $plan = Get-WtShutdownTimerPlan -Answer $answer
    if ($plan.Mode -eq 'Invalid') {
        & $ShowInvalid
        return
    }
    if ($plan.Mode -eq 'Cancel') {
        $cancelResult = & $RunCancel
        & $ShowResult (Get-WtShutdownCancelLines -ExitCode ([int]$cancelResult.ExitCode))
        return
    }
    $armResult = & $RunSchedule $plan.Seconds
    & $ShowResult (Get-WtShutdownScheduleLines -Plan $plan -ExitCode ([int]$armResult.ExitCode))
}

function Test-WtWinReAvailable {
    <#
    .SYNOPSIS
        True when reagentc /info reports a recovery image location. Only
        the \\?\GLOBALROOT PATH substring is checked (labels are
        localized, the device path never is), matched Ordinal since
        tr-TR breaks case-insensitive I/i comparison. Streams merge
        through cmd.exe for the same NativeCommandError reason as
        Invoke-WtShutdownCommand; $wtReagentcDump avoids the same
        collector-shadowing trap as Show-WtShutdownTimerResult.
    #>
    param([scriptblock]$GetInfo = { @(cmd.exe /c 'reagentc.exe /info 2>&1') })
    $wtReagentcDump = @()
    try { $wtReagentcDump = @(& $GetInfo) }
    catch { return $false }
    foreach ($row in $wtReagentcDump) {
        if ([string]$row -and ([string]$row).IndexOf('\\?\GLOBALROOT', [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

function Invoke-WtRestartToAdvancedStartup {
    <#
    .SYNOPSIS
        Restarts into the recovery menu (advanced startup) with
        "shutdown /r /o /t 0", but only after reagentc /info has proved
        WinRE actually exists - otherwise the box would restart straight
        back to the desktop with no explanation. The first Write-Host
        happens before the reagentc call itself, since
        Invoke-WtCapturedAction only repaints on output and a silent
        check would leave a frozen-looking panel.
    #>
    param(
        [scriptblock]$GetWinReInfo = { @(cmd.exe /c 'reagentc.exe /info 2>&1') },
        [scriptblock]$Restart = { Invoke-WtShutdownCommand -Arguments @('/r', '/o', '/t', '0') }
    )
    Write-Host (Get-Translation 'WinReChecking') -ForegroundColor Cyan
    if (-not (Test-WtWinReAvailable -GetInfo $GetWinReInfo)) {
        Write-Host (Get-Translation 'WinReUnavailable') -ForegroundColor Red
        Write-Host (Get-Translation 'WinReUnavailableHint') -ForegroundColor Yellow
        return
    }
    Write-Host (Get-Translation 'RestartingToAdvancedStartup') -ForegroundColor Cyan
    $powerResult = & $Restart
    if ([int]$powerResult.ExitCode -ne 0) {
        Write-Host ((Get-Translation 'PowerCommandFailed') -f [int]$powerResult.ExitCode) -ForegroundColor Red
    }
}

function Test-WtUefiFirmware {
    <#
    .SYNOPSIS
        True on a UEFI machine, false on legacy BIOS or when neither
        source can answer - refusing on doubt, since a wrong restart
        strands the user on the desktop with no explanation. Reads
        $env:firmware_type first ('UEFI' on PowerShell 5.1); falls back
        to Confirm-SecureBootUEFI, resolved via Get-Command since the
        module is not on every SKU, whose PlatformNotSupportedException
        means "not UEFI". Compared with [string]::Equals Ordinal, never
        -eq/ToUpper: tr-TR's dotless I makes 'UEFI' a documented trap.
    #>
    param(
        [scriptblock]$GetFirmwareType = { $env:firmware_type },
        [scriptblock]$GetSecureBootState = {
            $secureBootCmd = Get-Command -Name 'Confirm-SecureBootUEFI' -ErrorAction SilentlyContinue
            if (-not $secureBootCmd) { throw [System.PlatformNotSupportedException]::new('Confirm-SecureBootUEFI is not available') }
            & $secureBootCmd
        }
    )
    $firmware = [string](& $GetFirmwareType)
    if ($firmware) {
        if ([string]::Equals($firmware, 'UEFI', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($firmware, 'Legacy', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    try {
        $null = & $GetSecureBootState
        return $true
    }
    catch { return $false }
}

function Invoke-WtRestartToFirmwareSettings {
    <#
    .SYNOPSIS
        Restarts straight into the UEFI firmware setup with
        "shutdown /r /fw /t 0". On a legacy BIOS the row REFUSES: /fw is
        a UEFI-only request, and a machine that cannot honour it would
        just restart to the desktop, leaving the user to wonder what
        happened. Fast Boot is precisely why this row exists - reaching
        the firmware by keyboard is otherwise close to impossible.
    #>
    param(
        [scriptblock]$IsUefi = { Test-WtUefiFirmware },
        [scriptblock]$Restart = { Invoke-WtShutdownCommand -Arguments @('/r', '/fw', '/t', '0') }
    )
    if (-not (& $IsUefi)) {
        Write-Host (Get-Translation 'FirmwareNotUefi') -ForegroundColor Red
        Write-Host (Get-Translation 'FirmwareNotUefiHint') -ForegroundColor Yellow
        return
    }
    Write-Host (Get-Translation 'RestartingToFirmwareSettings') -ForegroundColor Cyan
    $powerResult = & $Restart
    if ([int]$powerResult.ExitCode -ne 0) {
        Write-Host ((Get-Translation 'PowerCommandFailed') -f [int]$powerResult.ExitCode) -ForegroundColor Red
    }
}

# --- builders (pure) -----------------------------------------------------------
