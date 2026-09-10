# Initialize/Restore-WtTui, input batches, frame diff and cache, Write-WtFrame.
# Covered by: tests/Tui.Tests.ps1, tests/CtrlGuard.Tests.ps1 (the Ctrl+C / Ctrl+Break guard)

function Initialize-WtTui {
    <#
    .SYNOPSIS
        One-time console setup: glyphs, input mode, VT detection, the
        alternate screen buffer, admin flag. Disables progress bars via
        $global:, not $script:, ProgressPreference, because Appx cmdlets
        resolve it through their own session state and the stream can't
        be redirected.
    #>
    $script:WtGlyphs = Get-WtGlyphSet -Unicode (Test-WtUnicodeGlyphSupport)
    $script:WtPreviousProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    Reset-WtFrameCache
    $script:WtInputMode = 'Line'
    $script:WtVt = $false
    try {
        if (-not [Console]::IsInputRedirected -and $Host.Name -eq 'ConsoleHost') {
            $null = [Console]::KeyAvailable
            $script:WtInputMode = 'Key'
        }
    }
    catch { $script:WtInputMode = 'Line' }
    if ($script:WtInputMode -eq 'Key') {
        try { $script:WtVt = ([bool]$Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected) } catch { $script:WtVt = $false }
        Enable-WtTuiCtrlCInput
    }
    if ($script:WtVt) {
        $Host.UI.Write($script:WtEsc + '[?1049h' + $script:WtEsc + '[?25l' + $script:WtEsc + '[2J' + $script:WtEsc + '[1;1H')
    }
    else {
        try { [Console]::CursorVisible = ($script:WtInputMode -ne 'Key') } catch { $null = $_ }
        if ($script:WtInputMode -eq 'Key') { Clear-Host }
    }
}

function Enable-WtTuiCtrlCInput {
    <#
    .SYNOPSIS
        Makes Ctrl+C a KEY for the whole session, not PowerShell's break
        signal, so a stray press cannot kill the app mid-action. Set here
        rather than only in the REPL, because a fast third press could
        otherwise slip through as a break signal and end WinToolify.
    #>
    param(
        [scriptblock]$GetConsole = { [Console]::TreatControlCAsInput },
        [scriptblock]$SetConsole = { param($Value) [Console]::TreatControlCAsInput = [bool]$Value }
    )
    try {
        $script:WtTuiSavedCtrlC = [bool](& $GetConsole)
        & $SetConsole $true
        $script:WtTuiCtrlCOwned = $true
    }
    catch { $script:WtTuiSavedCtrlC = $null; $script:WtTuiCtrlCOwned = $false }
}

function Restore-WtTuiCtrlCInput {
    param([scriptblock]$SetConsole = { param($Value) [Console]::TreatControlCAsInput = [bool]$Value })
    $script:WtTuiCtrlCOwned = $false
    if ($null -eq $script:WtTuiSavedCtrlC) { return }
    try { & $SetConsole ([bool]$script:WtTuiSavedCtrlC) } catch { $null = $_ }
    $script:WtTuiSavedCtrlC = $null
}

function Assert-WtTuiCtrlCInput {
    <#
    .SYNOPSIS
        Puts Ctrl+C back to being a KEY after a captured native command
        (sfc, DISM, winget, a child PowerShell) flips the shared
        console-mode bit back on. Called before every blocking key read
        and on the native runner's tick; returns $true when it changed it.
    #>
    param(
        [scriptblock]$GetConsole = { [Console]::TreatControlCAsInput },
        [scriptblock]$SetConsole = { param($Value) [Console]::TreatControlCAsInput = [bool]$Value }
    )
    if (-not $script:WtTuiCtrlCOwned) { return $false }
    try {
        if ([bool](& $GetConsole)) { return $false }
        & $SetConsole $true
        return $true
    }
    catch { return $false }
}

$script:WtCtrlGuardSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class WtCtrlGuard
{
    public delegate bool HandlerRoutine(uint dwCtrlType);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
    private static HandlerRoutine _handler;
    private static int _swallowed;
    public static bool IsInstalled { get { return _handler != null; } }
    public static int Swallowed { get { return _swallowed; } }
    private static bool OnCtrl(uint dwCtrlType)
    {
        // CTRL_C_EVENT = 0, CTRL_BREAK_EVENT = 1: handled here, the chain stops
        if (dwCtrlType == 0 || dwCtrlType == 1) { Interlocked.Increment(ref _swallowed); return true; }
        return false;
    }
    public static bool Install()
    {
        if (_handler != null) return true;
        HandlerRoutine handler = new HandlerRoutine(OnCtrl);
        if (!SetConsoleCtrlHandler(handler, true)) return false;
        _handler = handler;
        return true;
    }
    public static bool Remove()
    {
        if (_handler == null) return true;
        bool removed = SetConsoleCtrlHandler(_handler, false);
        _handler = null;
        return removed;
    }
}
'@

function Enable-WtCtrlGuard {
    <#
    .SYNOPSIS
        Registers the process-wide Ctrl+C / Ctrl+Break handler for the whole
        run (the main flow's first statement). Runs before the host's own
        handler (LIFO) so its true return hides the event from the host,
        though a child process still gets it. Returns $true when set up.
    #>
    param([scriptblock]$Apply = {
        if (-not ('WtCtrlGuard' -as [type])) { Add-Type -TypeDefinition $script:WtCtrlGuardSource -ErrorAction Stop }
        [bool][WtCtrlGuard]::Install()
    })
    $script:WtCtrlGuard = $false
    try { $script:WtCtrlGuard = [bool](& $Apply) } catch { $script:WtCtrlGuard = $false }
    return $script:WtCtrlGuard
}

function Disable-WtCtrlGuard {
    <#
    .SYNOPSIS
        Unregisters the handler in the main flow's finally, so a console the
        user opened themselves gets its Ctrl+C back at the prompt. No-op when
        Enable-WtCtrlGuard never took; never throws.
    #>
    param([scriptblock]$Apply = { $null = [WtCtrlGuard]::Remove() })
    if (-not $script:WtCtrlGuard) { return }
    $script:WtCtrlGuard = $false
    try { $null = & $Apply } catch { $null = $_ }
}

function Restore-WtTui {
    <#
    .SYNOPSIS
        Leaves the alternate buffer and shows the cursor again - the
        user's previous console content comes back. Safe to call when
        Initialize-WtTui never ran.
    #>
    if ($script:WtPreviousProgressPreference) { $global:ProgressPreference = $script:WtPreviousProgressPreference }
    Restore-WtTuiCtrlCInput
    if ($script:WtVt) {
        try { $Host.UI.Write($script:WtEsc + '[?1049l' + $script:WtEsc + '[?25h') } catch { $null = $_ }
    }
    else {
        try { [Console]::CursorVisible = $true } catch { $null = $_ }
    }
}

function Get-WtFrameChromeHeight {
    <#
    .SYNOPSIS
        Rows the frame spends outside the content viewport: header
        (banner rows + 4) plus 6 for a default box (borders, path,
        separators, footer) or 4 in banner mode (no path row). The
        layout (Full / Compact) does not change the count.
    #>
    param(
        [Parameter(Mandatory)][int]$Width,
        [bool]$ShowBanner = $false,
        [bool]$Searchable = $false,
        [int]$DescriptionRows = 0
    )
    $header = @(Get-WtBannerLines -Width $Width).Count + 4
    $search = $(if ($Searchable) { 2 } else { 0 })
    $desc = $(if ($DescriptionRows -gt 0) { $DescriptionRows + 1 } else { 0 })
    if ($ShowBanner) { return $header + 4 + $search + $desc }
    return $header + 6 + $search + $desc
}

function Read-WtInputBatch {
    <#
    .SYNOPSIS
        One blocking ReadKey, then drains any auto-repeat queued after a
        navigation key. Never mixes RawUI.ReadKey / FlushInputBuffer -
        separate caches, phantom keys. Converter: (Key, KeyChar) -> token;
        no GetNewClosure, it breaks in the built (non-dot-sourced) script.
        Exhausted redirected stdin returns 'Eof' and sets
        $script:WtInputExhausted, which is how the main menu tells this
        Back from an Esc: Esc stays, this leaves.
    #>
    param([scriptblock]$Converter)

    if ($script:WtInputMode -eq 'Key') {
        $null = Assert-WtTuiCtrlCInput
        $null = Assert-WtWindowMaximized
        try {
            $ki = [Console]::ReadKey($true)
            $first = if ($Converter) { [string](& $Converter ([string]$ki.Key) ([string]$ki.KeyChar)) }
                     else { ConvertTo-WtKeyToken -Key ([string]$ki.Key) -KeyChar ([string]$ki.KeyChar) }
            $tokens = New-Object System.Collections.Generic.List[string]
            $tokens.Add($first)
            if (Test-WtNavToken -Token $first) {
                while ($tokens.Count -lt 64 -and [Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    $t = if ($Converter) { [string](& $Converter ([string]$k.Key) ([string]$k.KeyChar)) }
                         else { ConvertTo-WtKeyToken -Key ([string]$k.Key) -KeyChar ([string]$k.KeyChar) }
                    $tokens.Add($t)
                    if (-not (Test-WtNavToken -Token $t)) { break }
                }
            }
            return [string[]]$tokens.ToArray()
        }
        catch {
            $null = Write-WtErrorLog -ErrorRecord $_ -Context 'Read-WtInputBatch: key input failed, falling back to line mode'
            $script:WtInputMode = 'Line'
            Reset-WtFrameCache
        }
    }
    $line = Read-Host (Get-Translation 'InputPrompt')
    if ($null -eq $line) {
        $script:WtInputExhausted = $true
        return [string[]]@('Eof')
    }
    return [string[]]@((ConvertTo-WtLineToken -Line $line))
}

function Clear-WtPendingInput {
    <#
    .SYNOPSIS
        Throws away every key sitting in the console queue and returns how
        many there were. Called after a long action ends and again when
        the nav screen regains control, so a key queued during the action
        (or its auto-repeat) cannot silently replay and repeat the row.
    #>
    param(
        [scriptblock]$KeyAvailable = { [Console]::KeyAvailable },
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) },
        [int]$Cap = 1024
    )
    if ($script:WtInputMode -ne 'Key') { return 0 }
    $drained = 0
    try {
        while ($drained -lt $Cap -and [bool](& $KeyAvailable)) {
            $null = & $ReadKey
            $drained++
        }
    }
    catch { $null = $_ }
    return $drained
}

function Get-WtFrameDiff {
    <#
    .SYNOPSIS
        Indexes of the rows that differ from the previous frame (or every
        index when forced / the previous frame is shorter). Case-sensitive
        ordinal compare: the rows carry SGR payloads.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rows,
        [AllowEmptyCollection()][string[]]$PrevRows = @(),
        [bool]$Force = $false
    )
    $changed = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($Force -or $i -ge $PrevRows.Count -or -not [string]::Equals($Rows[$i], $PrevRows[$i], [System.StringComparison]::Ordinal)) { $changed.Add($i) }
    }
    return [int[]]$changed.ToArray()
}

function Reset-WtFrameCache {
    <#
    .SYNOPSIS
        Forget the previous frame so the next Write-WtFrame repaints every
        row. Called after anything that wrote to the console outside the
        painter (console-output mode, Read-Host prompts, native commands).
    #>
    $script:WtPrevRows = @()
    $script:WtPrevWidth = 0
    $script:WtPrevHeight = 0
}

function Get-WtConsoleSize {
    <#
    .SYNOPSIS
        Current window size as @{ Width; Height }, 100x40 when no console
        exists (redirected host, tests).
    #>
    $w = 100
    $h = 40
    try {
        $s = $Host.UI.RawUI.WindowSize
        if ($s.Width -gt 0 -and $s.Height -gt 0) { $w = [int]$s.Width; $h = [int]$s.Height }
    }
    catch { $null = $_ }
    return @{ Width = $w; Height = $h }
}

function Get-WtFrameWidth {
    <#
    .SYNOPSIS
        PURE: how many columns a framed screen may draw into. Rows stop
        one column short of the console by default: filling the last cell
        of a row leaves the console in its pending-wrap state and the next
        character written would push the frame down a line. With VT on
        every row Write-WtFrame paints is preceded by an absolute cursor
        move, which clears that state before anything else is written, so
        there the frame can have the whole width. VT is only ever set in
        Key mode, so this is also what keeps the Line-mode path - where
        each row is written with its own newline - one column short.
    #>
    param(
        [Parameter(Mandatory)][int]$Width,
        [bool]$Vt = $script:WtVt
    )
    return [Math]::Max(20, $(if ($Vt) { $Width } else { $Width - 1 }))
}

function Write-WtFrame {
    <#
    .SYNOPSIS
        Paints a frame: key mode + VT emits one SGR string per changed row
        via CUP in a single host write (DECSET 2026) without touching the
        last column; key mode without VT does the same diff via
        SetCursorPosition + Write; line mode is Clear-Host plus plain rows.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$FrameLines,
        [int]$Width = 0,
        [int]$Height = 0
    )
    if ($Width -le 0 -or $Height -le 0) {
        $size = Get-WtConsoleSize
        if ($Width -le 0) { $Width = $size.Width }
        if ($Height -le 0) { $Height = $size.Height }
    }
    $w = Get-WtFrameWidth -Width $Width
    $lines = @($FrameLines)
    if ($lines.Count -gt $Height) { $lines = @($lines[0..($Height - 1)]) }

    if ($script:WtInputMode -eq 'Line') {
        Clear-Host
        foreach ($line in $lines) { Write-Host (ConvertTo-WtRowString -Segments @($line) -Width $w -Vt $false) }
        return
    }

    $force = ($Width -ne $script:WtPrevWidth -or $Height -ne $script:WtPrevHeight -or @($script:WtPrevRows).Count -eq 0)
    $rows = New-Object string[] $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) { $rows[$i] = ConvertTo-WtRowString -Segments @($lines[$i]) -Width $w -Vt $script:WtVt }
    $changed = Get-WtFrameDiff -Rows $rows -PrevRows ([string[]]@($script:WtPrevRows)) -Force $force

    if ($script:WtVt) {
        $e = $script:WtEsc
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($e + '[?2026h')
        if ($force) { [void]$sb.Append($e + '[2J') }
        foreach ($i in $changed) { [void]$sb.Append($e + '[' + ($i + 1) + ';1H').Append($rows[$i]) }
        [void]$sb.Append($e + '[1;1H' + $e + '[?2026l')
        $Host.UI.Write($sb.ToString())
    }
    else {
        if ($force) { Clear-Host }
        $defaultBg = $Host.UI.RawUI.BackgroundColor
        foreach ($i in $changed) {
            try { [Console]::SetCursorPosition(0, $i) } catch { continue }
            $used = 0
            foreach ($seg in @($lines[$i])) {
                $text = [string]$seg.T
                if (($used + $text.Length) -gt $w) { $text = $text.Substring(0, [Math]::Max(0, $w - $used)) }
                if ($text.Length -eq 0) { continue }
                $fg = if ($seg.F -and $script:WtSgrMap.ContainsKey([string]$seg.F)) { [ConsoleColor]$seg.F } else { [ConsoleColor]'Gray' }
                $bg = if ($seg.B -and $script:WtSgrMap.ContainsKey([string]$seg.B)) { [ConsoleColor]$seg.B } else { $defaultBg }
                $Host.UI.Write($fg, $bg, $text)
                $used += $text.Length
            }
            if ($used -lt $w) { $Host.UI.Write([ConsoleColor]'Gray', $defaultBg, (' ' * ($w - $used))) }
        }
        try { [Console]::SetCursorPosition(0, 0) } catch { $null = $_ }
    }
    $script:WtPrevRows = $rows
    $script:WtPrevWidth = $Width
    $script:WtPrevHeight = $Height
}
