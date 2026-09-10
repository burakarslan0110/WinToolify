# The console side of the assistant's plain-console REPL: mode entry/exit,
# the alt-buffer hop, the append-only printers, and the ReadKey line reader.
# Covered by: tests/ReplConsole.Tests.ps1

function Get-WtReplDefaultWriter {
    <#
    .SYNOPSIS
        The one place a REPL line reaches the host: Write-Host with a
        colour, optionally without the newline (streaming). Works in
        conhost, Windows Terminal, ISE and a redirected host alike.
    #>
    return { param($Text, $Fg, $NoNewline)
        $color = $(if ($Fg) { [ConsoleColor]$Fg } else { [ConsoleColor]'Gray' })
        if ($NoNewline) { Write-Host -NoNewline -ForegroundColor $color ([string]$Text) }
        else { Write-Host -ForegroundColor $color ([string]$Text) }
    }
}

function Get-WtReplRawWriter {
    <#
    .SYNOPSIS
        VT sequences and the edit line go straight to the host: no colour,
        no newline.
    #>
    return { param($Text) $Host.UI.Write([string]$Text) }
}

function Hide-WtReplLive {
    <#
    .SYNOPSIS
        Erases the live region: carriage return, up to the region's
        first row (relative - never an absolute cursor position), erase
        to the end of the screen, cursor back on. No-op when nothing is
        painted, so every transcript writer can call it unconditionally.
    #>
    param([scriptblock]$Write = (Get-WtReplRawWriter))
    if ($null -eq $script:WtReplLive -or [int]$script:WtReplLive.Rows -le 0) { return }
    $text = "`r"
    if ([int]$script:WtReplLive.CaretRow -gt 0) { $text += $script:WtEsc + '[' + [int]$script:WtReplLive.CaretRow + 'A' }
    $text += $script:WtEsc + '[J' + $script:WtEsc + '[?25h'
    & $Write $text
    $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
}

function Show-WtReplLive {
    <#
    .SYNOPSIS
        Paints the live region below the committed transcript in ONE
        console write: cursor off, back to the region's first row, rows
        joined by LF (no trailing newline - Hide relies on the caret
        being INSIDE the region), erase-to-end after the last row, caret
        parked on CaretRow/CaretCol (-1 hides it). Rows overwrite the
        old region in place rather than erase-then-redraw, which
        flickered on every keystroke. A region taller than the window is
        cut from the FRONT, since the relative ESC[nA can no longer
        reach rows that scrolled out of the viewport.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [int]$CaretRow = -1,
        [int]$CaretCol = 0,
        [int]$Width = 0,
        [int]$Height = 0,
        [scriptblock]$Write = (Get-WtReplRawWriter)
    )
    if (-not $script:WtReplLiveEnabled) { return }
    $rows = @($Rows)
    if ($rows.Count -eq 0) { Hide-WtReplLive -Write $Write; return }
    if (-not $script:WtReplLastBlank -and -not $script:WtReplToolBoxOpen) {
        $rows = @(, @(, (New-WtSeg -Text '' -Fg 'Gray'))) + $rows
        if ($CaretRow -ge 0) { $CaretRow++ }
    }
    if ($Width -le 0 -or ($Height -le 0 -and $rows.Count -gt 1)) {
        $size = Get-WtConsoleSize
        if ($Width -le 0) { $Width = [int]$size.Width }
        if ($Height -le 0) { $Height = [int]$size.Height }
    }
    $max = [Math]::Max(1, $Height - 1)
    if ($Height -gt 0 -and $rows.Count -gt $max) {
        $dropped = $rows.Count - $max
        $rows = @($rows[$dropped..($rows.Count - 1)])
        if ($CaretRow -ge 0) {
            $CaretRow = $CaretRow - $dropped
            if ($CaretRow -lt 0) { $CaretRow = -1 }
        }
    }
    $w = [Math]::Max(20, $Width - 1)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($script:WtEsc + '[?25l' + "`r")
    $previous = $script:WtReplLive
    if ($null -ne $previous -and [int]$previous.Rows -gt 0 -and [int]$previous.CaretRow -gt 0) {
        [void]$sb.Append($script:WtEsc + '[' + [int]$previous.CaretRow + 'A')
    }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append("`n") }
        [void]$sb.Append((ConvertTo-WtRowString -Segments @($rows[$i]) -Width $w -Vt $script:WtVt))
    }
    [void]$sb.Append($script:WtEsc + '[J')
    $caret = $(if ($CaretRow -ge 0 -and $CaretRow -lt $rows.Count) { $CaretRow } else { $rows.Count - 1 })
    $up = $rows.Count - 1 - $caret
    if ($up -gt 0) { [void]$sb.Append($script:WtEsc + '[' + $up + 'A') }
    [void]$sb.Append("`r" + $script:WtEsc + '[' + ([Math]::Max(0, $CaretCol) + 1) + 'G')
    [void]$sb.Append($script:WtEsc + $(if ($CaretRow -ge 0) { '[?25h' } else { '[?25l' }))
    & $Write $sb.ToString()
    $script:WtReplLive = @{ Rows = $rows.Count; CaretRow = $caret }
}

function Write-WtReplRows {
    <#
    .SYNOPSIS
        Commits segment rows (a box, the banner) to the transcript: each
        row rendered Width-1 wide, coloured when VT is on, one console
        line each, through the line writer so tests see plain lines.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [int]$Width = 0,
        [scriptblock]$Write = (Get-WtReplDefaultWriter)
    )
    Hide-WtReplLive
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    $w = [Math]::Max(20, $Width - 1)
    foreach ($row in @($Rows)) { & $Write (ConvertTo-WtRowString -Segments @($row) -Width $w -Vt $script:WtVt) 'Gray' $false }
}

$script:WtReplLastBlank = $true
$script:WtReplLastGroup = ''

$script:WtReplPageWidth = 0

$script:WtReplToolBoxOpen = $false
$script:WtReplToolBoxWidth = 0

$script:WtReplResizePoll = $false
$script:WtReplResizeChecked = [datetime]::MinValue

function Get-WtReplMargin {
    <#
    .SYNOPSIS
        PURE: the transcript's side margin in columns - where you, the
        answer and the info lines start, and how far short of the right
        edge they wrap. Two columns is exactly where the text sits inside
        the input box ("| > "), so a committed line stays in the column it
        was typed in.
    #>
    return [int]$script:WtReplMargin
}

function Get-WtReplTextWidth {
    <#
    .SYNOPSIS
        PURE: the width the transcript's text is wrapped at - the console
        width less the right margin. The rows themselves still render
        Width-1 wide (padding), so the frames around them do not change.
    #>
    param([int]$Width = 80)
    return [Math]::Max(12, $Width - (Get-WtReplMargin))
}

function Reset-WtReplBlockState {
    $script:WtReplLastBlank = $true
    $script:WtReplLastGroup = ''
    $script:WtReplToolBoxOpen = $false
}

function Get-WtReplToolBoxRow {
    <#
    .SYNOPSIS
        PURE: one row of the tool box - its top border, its bottom
        border, or one content row ("| " + segments + padding + " |",
        cut with '~' past the inner width) - Width-1 wide, DarkGray so
        the box sits behind the answer rather than in front of it.
    #>
    param(
        [ValidateSet('Top', 'Bottom', 'Row')][string]$Part = 'Row',
        [AllowEmptyCollection()][array]$Segments = @(),
        [int]$Width = 80,
        [PSCustomObject]$Glyphs = $script:WtGlyphs,
        [string]$Fg = 'DarkGray'
    )
    $box = @(Get-WtReplBoxRows -Title '' -Rows @(, @($Segments)) -Width $Width -Glyphs $Glyphs -Fg $Fg)
    switch ($Part) {
        'Top' { return , $box[0] }
        'Bottom' { return , $box[2] }
        default { return , $box[1] }
    }
}

function Close-WtReplToolBox {
    <#
    .SYNOPSIS
        Prints the bottom border of the open tool box, if one is open.
        Every transcript writer calls it before printing anything that
        is not a tool row, so the box always closes exactly once.
    #>
    param([int]$Width = 0, [scriptblock]$Write = (Get-WtReplDefaultWriter))
    if (-not $script:WtReplToolBoxOpen) { return }
    $script:WtReplToolBoxOpen = $false
    if ($Width -le 0) { $Width = [int]$script:WtReplToolBoxWidth }
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    Write-WtReplBlock -Rows @(, (Get-WtReplToolBoxRow -Part 'Bottom' -Width $Width)) -Width $Width -Write $Write -ToolBox
}

function Get-WtReplEntryGroup {
    <#
    .SYNOPSIS
        PURE: which of the three speakers an entry kind belongs to. Tool,
        Info and Error are one group - the app talking - so a tool call,
        its results, a permission decision and the turn summary stay one
        block, while you -> tool, answer -> tool and answer -> summary
        each get their own blank line.
    #>
    param([AllowEmptyString()][string]$Kind = '')
    if ($Kind -eq 'User') { return 'User' }
    if ($Kind -eq 'Assistant') { return 'Assistant' }
    return 'System'
}

function Write-WtReplBlock {
    <#
    .SYNOPSIS
        The ONE door into the transcript. Hides the live region, closes
        an open tool box unless these rows belong to it (-ToolBox), then
        writes segment rows. -Separate asks for a blank line before the
        block (only when the speaker changed); two blanks in a row are
        never printed, here or across calls, so no caller has to track
        what the previous one left behind.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][array]$Rows = @(),
        [switch]$Separate,
        [int]$Width = 0,
        [scriptblock]$Write = (Get-WtReplDefaultWriter),
        [scriptblock]$HideWrite = $null,
        [switch]$ToolBox
    )
    if ($null -ne $HideWrite) { Hide-WtReplLive -Write $HideWrite } else { Hide-WtReplLive }
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    if (-not $ToolBox) { Close-WtReplToolBox -Width $Width -Write $Write }
    $w = [Math]::Max(20, $Width - 1)
    if ($Separate -and -not $script:WtReplLastBlank) {
        & $Write '' 'Gray' $false
        $script:WtReplLastBlank = $true
    }
    foreach ($row in @($Rows)) {
        $plain = (@($row) | ForEach-Object { [string]$_.T }) -join ''
        $isBlank = ($plain.Trim().Length -eq 0)
        if ($isBlank -and $script:WtReplLastBlank) { continue }
        & $Write (ConvertTo-WtRowString -Segments @($row) -Width $w -Vt $script:WtVt) 'Gray' $false
        $script:WtReplLastBlank = $isBlank
    }
}

function Sync-WtReplResize {
    <#
    .SYNOPSIS
        The mid-turn resize: while the model works nothing is reading a
        line, so the prompt's own resize path cannot fire and the banner
        would sit off-centre until the turn ended. Called from the cancel
        poll and the status-row tick, at most once per 250 ms; when the
        console width differs from the one the page was painted at, the
        whole page is repainted - banner, transcript so far, and the
        streamed answer re-run through the stream so its wrap and state
        match the new width. Returns $true when it repainted.
    #>
    param([scriptblock]$Write = (Get-WtReplRawWriter), [switch]$Force)
    if (-not $script:WtReplMode -or -not $script:WtReplLiveEnabled) { return $false }
    $now = [datetime]::UtcNow
    if (-not $Force -and ($now - [datetime]$script:WtReplResizeChecked).TotalMilliseconds -lt 250) { return $false }
    $script:WtReplResizeChecked = $now
    $pageWidth = [int]$script:WtReplPageWidth
    if ($pageWidth -le 0) { return $false }
    $width = [int](Get-WtConsoleSize).Width
    if ($width -eq $pageWidth) { return $false }
    Hide-WtReplLive -Write $Write
    Clear-WtReplScreen
    Write-WtReplHeader -Width $width
    Write-WtReplWelcome -Width $width
    $chat = $script:WtAssistantChat
    if ($null -ne $chat) { Write-WtReplTranscriptTail -Session $chat -Count 400 -Width $width }
    if ($null -ne $script:WtReplStream) {
        $content = $script:WtReplStream.Content.ToString()
        $reasoning = $script:WtReplStream.Reasoning.ToString()
        Reset-WtReplStream
        $script:WtReplStream.Width = $width
        [void]$script:WtReplStream.Reasoning.Append($reasoning)
        if ($content) { Write-WtReplStream -Piece $content -Width $width }
    }
    return $true
}

function Show-WtReplSpinner {
    param(
        [AllowEmptyString()][string]$Label = '',
        [scriptblock]$Now = { Get-Date },
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [int]$Width = 0
    )
    $started = [datetime](& $Now)
    $script:WtReplSpinner = @{ Started = $started; LastPaint = [datetime]::MinValue; LastSig = ''; Label = $Label; Chars = 0; Active = $true; Tail = @() }
    Update-WtReplSpinner -Force -Now $Now -Write $Write -Width $Width
}

function Update-WtReplSpinner {
    <#
    .SYNOPSIS
        One tick: add streamed chars, and at most every 120 ms repaint the
        spinner line in the live region. Called from the client's
        ShouldCancel poll and from every reasoning delta, so a thinking
        model keeps the seconds moving without printing a word of it. Box
        rows are built into a List, not an array literal: @( (row) (row) )
        would flatten the two row-arrays into four rows instead of two.
    #>
    param(
        [int]$AddChars = 0,
        [switch]$Force,
        [scriptblock]$Now = { Get-Date },
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [int]$Width = 0,
        [AllowNull()][AllowEmptyCollection()][string[]]$Tail = $null
    )
    $s = $script:WtReplSpinner
    if ($null -eq $s -or -not $s.Active) { return }
    $s.Chars = [int]$s.Chars + $AddChars
    if ($null -ne $Tail) { $s.Tail = @($Tail | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().Length -gt 0 }) }
    $t = [datetime](& $Now)
    if (-not $Force -and ($t - [datetime]$s.LastPaint).TotalMilliseconds -lt 120) { return }
    $s.LastPaint = $t
    if (-not $script:WtReplLiveEnabled) { return }
    $resized = [bool](Sync-WtReplResize -Write $Write)
    $line = Format-WtReplSpinnerLine -Label ([string]$s.Label) -Seconds ($t - [datetime]$s.Started).TotalSeconds -Chars ([int]$s.Chars)
    $tail = @($(if ($s.ContainsKey('Tail')) { $s.Tail } else { @() }))
    $sig = $line + "`n" + ($tail -join "`n") + "`n" + [string]$script:WtReplToolBoxOpen
    if (-not $Force -and -not $resized -and [string]::Equals([string]$s.LastSig, $sig, [System.StringComparison]::Ordinal)) { return }
    $s.LastSig = $sig
    $seg = New-WtSeg -Text $line -Fg 'DarkYellow'
    if ($script:WtReplToolBoxOpen -or $tail.Count -gt 0) {
        $boxWidth = [int]$script:WtReplToolBoxWidth
        if (-not $script:WtReplToolBoxOpen -or $boxWidth -le 0) { $boxWidth = $(if ($Width -gt 0) { $Width } else { (Get-WtConsoleSize).Width }) }
        $rows = New-Object System.Collections.Generic.List[object]
        if (-not $script:WtReplToolBoxOpen) { $rows.Add((Get-WtReplToolBoxRow -Part 'Top' -Width $boxWidth)) }
        $rows.Add((Get-WtReplToolBoxRow -Part 'Row' -Segments @(, $seg) -Width $boxWidth))
        foreach ($outLine in $tail) { $rows.Add((Get-WtReplToolBoxRow -Part 'Row' -Segments @(, (New-WtSeg -Text ('      ' + $outLine) -Fg 'Gray')) -Width $boxWidth)) }
        $rows.Add((Get-WtReplToolBoxRow -Part 'Bottom' -Width $boxWidth))
        Show-WtReplLive -Rows $rows.ToArray() -CaretRow -1 -Width $Width -Write $Write
        return
    }
    $marginSeg = New-WtSeg -Text ((' ' * (Get-WtReplMargin)) + $line) -Fg 'DarkYellow'
    Show-WtReplLive -Rows @(, @(, $marginSeg)) -CaretRow -1 -Width $Width -Write $Write
}

function Hide-WtReplSpinner {
    param([scriptblock]$Write = (Get-WtReplRawWriter))
    if ($null -ne $script:WtReplSpinner) { $script:WtReplSpinner.Active = $false }
    Hide-WtReplLive -Write $Write
}

$script:WtReplConsoleModeSource = @'
using System;
using System.Runtime.InteropServices;
public static class WtConsoleMode
{
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@

function Enable-WtReplQuickEdit {
    <#
    .SYNOPSIS
        Mouse selection in conhost while the REPL runs (Windows Terminal
        handles selection itself and ignores this). Returns the mode to
        restore, $null when the console API is not available - every
        failure is swallowed, the REPL works without it. The P/Invoke
        source (compiled once per process) needs ENABLE_QUICK_EDIT_MODE
        (0x40) and ENABLE_EXTENDED_FLAGS (0x80) set together in the same
        call, and is C# 5 only, since that is what PS 5.1's compiler
        accepts.
    #>
    param([scriptblock]$Apply = {
        if (-not ('WtConsoleMode' -as [type])) { Add-Type -TypeDefinition $script:WtReplConsoleModeSource -ErrorAction Stop }
        $handle = [WtConsoleMode]::GetStdHandle(-10)
        $mode = [uint32]0
        if (-not [WtConsoleMode]::GetConsoleMode($handle, [ref]$mode)) { return $null }
        $null = [WtConsoleMode]::SetConsoleMode($handle, ($mode -bor [uint32]0x40 -bor [uint32]0x80))
        return $mode
    })
    try { return (& $Apply) } catch { return $null }
}

function Restore-WtReplQuickEdit {
    param(
        [AllowNull()]$Mode,
        [scriptblock]$Apply = { param($M)
            $handle = [WtConsoleMode]::GetStdHandle(-10)
            $null = [WtConsoleMode]::SetConsoleMode($handle, [uint32]$M)
        }
    )
    if ($null -eq $Mode) { return }
    try { & $Apply $Mode } catch { $null = $_ }
}

function Clear-WtReplScreen {
    <#
    .SYNOPSIS
        A fresh page: viewport AND scrollback wiped (ESC[3J - a conhost
        that ignores it just keeps the old scrollback), cursor homed.
        Without VT, Clear-Host through a seam. Clear-Host runs FIRST on
        every host: conhost's ESC[2J does not erase the buffer, it
        scrolls the viewport INTO the scrollback, leaving a window-high
        gap above the banner; Clear-Host wipes conhost's whole buffer,
        while in Windows Terminal it clears only the viewport, leaving
        the ESC[3J that follows to drop the scrollback there.
    #>
    param(
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [scriptblock]$ClearHost = { Clear-Host }
    )
    Hide-WtReplLive -Write $Write
    try { & $ClearHost } catch { $null = $_ }
    if ($script:WtVt) { & $Write ($script:WtEsc + '[3J' + $script:WtEsc + '[1;1H') }
    Reset-WtFrameCache
    Reset-WtReplBlockState
}

function Write-WtReplHeader {
    <#
    .SYNOPSIS
        The top of the assistant page: the same banner every framed screen
        shows (centered, cyan), the credit lines, then the breadcrumb -
        "Main Menu > WinToolify Assistant" - as the path row of a
        full-width box (cyan border, white text), exactly the row every
        framed screen opens its frame with, and one blank row under it.
        The model and what the assistant remembers live in the status line
        under the input box instead, so the page opens with six fewer
        rows. Sets $script:WtReplPageWidth, the resize baseline every
        later check compares against. Uses Write-WtReplLine, never
        Write-WtReplRows, since only the line/block writers keep
        $script:WtReplLastBlank and the speaker group current.
    #>
    param(
        [int]$Width = 0,
        [scriptblock]$Write = (Get-WtReplDefaultWriter)
    )
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    $script:WtReplPageWidth = [int]$Width
    $w = [Math]::Max(20, $Width - 1)
    $center = { param([string]$Text) $pad = [Math]::Max(0, [Math]::Floor(($w - $Text.Length) / 2)); (' ' * $pad) + $Text }
    foreach ($b in @(Get-WtBannerLines -Width $Width)) { Write-WtReplLine -Text (& $center $b) -Fg 'Cyan' -Write $Write -NoMargin }
    Write-WtReplLine -Text '' -Write $Write
    $credit = @(Get-WtBannerCreditLines)
    Write-WtReplLine -Text (& $center ([string]$credit[0])) -Fg 'Gray' -Write $Write -NoMargin
    Write-WtReplLine -Text (& $center ([string]$credit[1])) -Fg 'DarkGray' -Write $Write -NoMargin
    Write-WtReplLine -Text '' -Write $Write
    $crumbRow = @(, (New-WtSeg -Text ([string](Get-WtBreadcrumb -Keys 'MainMenu', 'Assistant')) -Fg 'White'))
    $crumb = @(Get-WtReplBoxRows -Title '' -Rows @(, $crumbRow) -Width $Width -Glyphs $script:WtGlyphs -Fg 'Cyan')
    foreach ($row in $crumb) { Write-WtReplLine -Text (ConvertTo-WtRowString -Segments $row -Width $w -Vt $script:WtVt) -Fg 'Cyan' -Write $Write -NoMargin }
    Write-WtReplLine -Text '' -Write $Write
}

function Write-WtReplWelcome {
    <#
    .SYNOPSIS
        The introduction under the breadcrumb: who the assistant is, what it
        does, five example questions and the key hints. A PERMANENT part of
        the page, printed on every paint (menu entry, /yeni, a pushed-screen
        return, any resize) with the transcript piling up under it - it
        used to print only on an empty page, so the first repaint after the
        first message wiped it. Lives next to Write-WtReplHeader since the
        mid-turn resize repaints the page from this layer.
    #>
    param([int]$Width = 0, [scriptblock]$Write = (Get-WtReplDefaultWriter))
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    $margin = Get-WtReplMargin
    $textWidth = Get-WtReplTextWidth -Width $Width
    $rows = New-Object System.Collections.Generic.List[object]
    $paragraph = { param([string]$Text, [string]$Fg)
        $block = @{ Kind = 'Paragraph'; Level = 0; Marker = ''; Text = $Text; State = @{ InFence = $false } }
        $colors = @{ Normal = $Fg; Strong = 'White'; Code = 'DarkCyan'; Link = $Fg; Url = $Fg }
        foreach ($r in (Split-WtWrappedSegments -Parts (Split-WtRichInline -Text ([string]$block.Text)) -Width $textWidth -Indent $margin -Colors $colors)) { $rows.Add($r) }
    }
    & $paragraph ([string](Get-Translation 'AsWelcome1')) 'Gray'
    $rows.Add(@(, (New-WtSeg -Text '' -Fg 'Gray')))
    & $paragraph ([string](Get-Translation 'AsWelcome2')) 'Gray'
    foreach ($key in 'AsWelcomeEx1', 'AsWelcomeEx2', 'AsWelcomeEx3', 'AsWelcomeEx4', 'AsWelcomeEx5') {
        $block = @{ Kind = 'Bullet'; Level = 0; Marker = ''; Text = [string](Get-Translation $key); State = @{ InFence = $false } }
        foreach ($r in (Get-WtRichBlockRows -Block $block -Width $textWidth -Indent $margin)) { $rows.Add($r) }
    }
    $rows.Add(@(, (New-WtSeg -Text '' -Fg 'Gray')))
    & $paragraph ([string](Get-Translation 'AsWelcome3')) 'DarkGray'
    Write-WtReplBlock -Rows $rows.ToArray() -Width $Width -Write $Write
    $script:WtReplLastGroup = 'System'
}

function Enter-WtReplMode {
    <#
    .SYNOPSIS
        Framed TUI -> plain console: leave the alternate buffer and show
        the cursor (VT), unpin the buffer height so the console has
        scrollback, take Ctrl+C as input. Idempotent. WtInputMode stays
        'Key' on purpose: the 'Line' paths Clear-Host.
    #>
    param(
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [scriptblock]$SetConsole = { param($Name, $Value)
            switch ($Name) {
                'BufferHeight' { [Console]::BufferHeight = [int]$Value }
                'CtrlC' { [Console]::TreatControlCAsInput = [bool]$Value }
                'Cursor' { [Console]::CursorVisible = [bool]$Value }
                'Repin' { $Host.UI.RawUI.BufferSize = $Host.UI.RawUI.WindowSize }
            }
        },
        [scriptblock]$GetConsole = { param($Name)
            switch ($Name) {
                'BufferHeight' { [Console]::BufferHeight }
                'CtrlC' { [Console]::TreatControlCAsInput }
                'WindowHeight' { [Console]::WindowHeight }
            }
        }
    )
    if ($script:WtReplMode) { return }
    $saved = @{ BufferHeight = 0; CtrlC = $false }
    if ($script:WtInputMode -eq 'Key') {
        try { $saved.BufferHeight = [int](& $GetConsole 'BufferHeight') } catch { $null = $_ }
        try { $saved.CtrlC = [bool](& $GetConsole 'CtrlC') } catch { $null = $_ }
    }
    $script:WtReplSaved = $saved
    if ($script:WtVt) { & $Write ($script:WtEsc + '[?1049l' + $script:WtEsc + '[?25h') }
    else { try { & $SetConsole 'Cursor' $true } catch { $null = $_ } }
    if ($script:WtInputMode -eq 'Key') {
        $script:WtReplConsoleModeSaved = Enable-WtReplQuickEdit
        $windowHeight = 50
        try { $windowHeight = [int](& $GetConsole 'WindowHeight') } catch { $null = $_ }
        try { & $SetConsole 'BufferHeight' ([Math]::Max(3000, $windowHeight)) } catch { $null = $_ }
        try { & $SetConsole 'CtrlC' $true } catch { $null = $_ }
    }
    $script:WtReplLiveEnabled = [bool]($script:WtVt -and $script:WtInputMode -eq 'Key')
    $script:WtReplResizePoll = [bool]($script:WtInputMode -eq 'Key')
    $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
    $script:WtReplMode = $true
    Reset-WtFrameCache
}

function Exit-WtReplMode {
    <#
    .SYNOPSIS
        Plain console -> framed TUI: give Ctrl+C back, repin the buffer
        to the window (destroys the REPL scrollback - the transcript lives
        in the session, not the console), re-enter the alternate buffer
        with a cleared screen. Idempotent; safe in a finally.
    #>
    param(
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [scriptblock]$SetConsole = { param($Name, $Value)
            switch ($Name) {
                'CtrlC' { [Console]::TreatControlCAsInput = [bool]$Value }
                'Cursor' { [Console]::CursorVisible = [bool]$Value }
                'Repin' { $Host.UI.RawUI.BufferSize = $Host.UI.RawUI.WindowSize }
            }
        }
    )
    if (-not $script:WtReplMode) { return }
    Hide-WtReplLive -Write $Write
    $saved = $script:WtReplSaved
    if ($script:WtInputMode -eq 'Key') {
        try { & $SetConsole 'CtrlC' ([bool]$(if ($null -ne $saved) { $saved.CtrlC } else { $false })) } catch { $null = $_ }
        try { & $SetConsole 'Repin' $true } catch { $null = $_ }
        Restore-WtReplQuickEdit -Mode $script:WtReplConsoleModeSaved
        $script:WtReplConsoleModeSaved = $null
    }
    if ($script:WtVt) { & $Write ($script:WtEsc + '[?1049h' + $script:WtEsc + '[?25l' + $script:WtEsc + '[2J' + $script:WtEsc + '[1;1H') }
    else { try { & $SetConsole 'Cursor' ($script:WtInputMode -ne 'Key') } catch { $null = $_ } }
    $script:WtReplMode = $false
    $script:WtReplLiveEnabled = $false
    $script:WtReplResizePoll = $false
    Reset-WtFrameCache
}

function Invoke-WtReplHop {
    <#
    .SYNOPSIS
        Runs something that paints a frame (a panel gate, a captured
        action, a screen) from inside the REPL: hop into the alternate
        buffer, run it, hop back, keeping the scrollback intact. Outside
        the REPL it just runs the action. A host without VT has no
        alternate buffer to hop into, so the framed action's own
        Clear-Host wipes the transcript off the console; when the REPL is
        active there, the transcript tail is reprinted afterward so the
        conversation is not lost from view.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [scriptblock]$Write = (Get-WtReplRawWriter)
    )
    if (-not $script:WtVt) {
        Hide-WtReplLive -Write $Write
        $result = & $Action
        if ($script:WtReplMode) {
            Reset-WtFrameCache
            Write-WtReplLine -Text ''
            if ($null -ne $script:WtAssistantChat) { Write-WtReplTranscriptTail -Session $script:WtAssistantChat -Count 40 }
        }
        return $result
    }
    if (-not $script:WtReplMode) { return (& $Action) }
    Hide-WtReplLive -Write $Write
    & $Write ($script:WtEsc + '[?1049h' + $script:WtEsc + '[?25l' + $script:WtEsc + '[2J' + $script:WtEsc + '[1;1H')
    Reset-WtFrameCache
    try { return (& $Action) }
    finally {
        & $Write ($script:WtEsc + '[?1049l' + $script:WtEsc + '[?25h')
        Reset-WtFrameCache
    }
}

function Write-WtReplLine {
    <#
    .SYNOPSIS
        One plain row onto the transcript. It keeps the same two flags
        Write-WtReplBlock keeps: these ~60 call sites (every slash
        command, the header, the low-mode question branches) commit real
        rows, so a block that follows must know whether the last row was
        blank and that the app - not you, not the answer - spoke last.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [string]$Fg = 'Gray',
        [scriptblock]$Write = (Get-WtReplDefaultWriter),
        [switch]$NoMargin
    )
    Hide-WtReplLive
    Close-WtReplToolBox -Write $Write
    $plain = [string]$Text
    $shown = $(if ($NoMargin -or $plain.Trim().Length -eq 0) { $plain } else { (' ' * (Get-WtReplMargin)) + $plain })
    & $Write $shown $Fg $false
    $script:WtReplLastBlank = ($plain.Trim().Length -eq 0)
    $script:WtReplLastGroup = 'System'
}

function Reset-WtReplStream {
    $script:WtReplStream = @{
        Content   = (New-Object System.Text.StringBuilder)
        Reasoning = (New-Object System.Text.StringBuilder)
        Open      = $false
        LastKind  = ''
        Buffer    = (New-Object System.Text.StringBuilder)
        Rich      = @{ InFence = $false }
        Width     = 0
    }
}

function Write-WtReplLineBuffered {
    <#
    .SYNOPSIS
        One COMPLETED source line out of the stream buffer and onto the
        screen, through the rich layer and the one transcript door.
        Rich.Continuation marks a chunk the overflow cut broke off a
        paragraph: it is rendered AS a paragraph rather than classified
        again, so a tail that happens to start "- " or "# " is never
        re-read as a bullet or a heading in the middle of a sentence.
    #>
    param([AllowEmptyString()][string]$Line = '', [int]$Width = 80, [scriptblock]$Write)
    $rich = $script:WtReplStream.Rich
    $continuing = [bool]($rich.Continuation -and -not $rich.InFence)
    $margin = Get-WtReplMargin
    $indent = $(if ($continuing) { [int]$rich.ContinuationIndent } else { $margin })
    if ($continuing) {
        $block = @{ Kind = 'Paragraph'; Level = 0; Marker = ''; Text = ([string]$Line).Trim(); State = @{ InFence = $false } }
    }
    else {
        $block = Get-WtRichBlock -Line $Line -State $rich
    }
    $state = $block.State
    $state.ContinuationIndent = $(if ($continuing) { $indent } else { [int](Get-WtRichBlockIndents -Block $block -Indent $margin).Continuation })
    $script:WtReplStream.Rich = $state
    $rows = (Get-WtRichBlockRows -Block $block -Width (Get-WtReplTextWidth -Width $Width) -Indent $indent)
    if ($rows.Count -eq 0) { return }
    Write-WtReplBlock -Rows $rows -Separate:(-not $script:WtReplStream.Open) -Width $Width -Write $Write
    $script:WtReplStream.Open = $true
    $script:WtReplLastGroup = 'Assistant'
}

function Test-WtReplCutSafe {
    <#
    .SYNOPSIS
        PURE: may the overflow cut take this chunk on its own? A ** or a
        backtick that opens inside it and closes after the cut would be
        printed literally, putting raw markdown on the screen - so the
        chunk waits instead. Nothing is lost: the newline path or
        Complete flushes it.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text = '')
    foreach ($part in @(Split-WtRichInline -Text ([string]$Text))) {
        if ([string]$part.Style -ne 'Normal') { continue }
        $plain = [string]$part.Text
        if ($plain.IndexOf([char]96) -ge 0) { return $false }
        if ($plain.IndexOf('**', [System.StringComparison]::Ordinal) -ge 0) { return $false }
        if ($plain.IndexOf('__', [System.StringComparison]::Ordinal) -ge 0) { return $false }
    }
    return $true
}

function Write-WtReplStream {
    <#
    .SYNOPSIS
        One streamed piece. Reasoning is COLLECTED AND NEVER PRINTED.
        Content is appended raw to Content - that is what the transcript
        records and /kopyala copies - and also to a line buffer: a
        completed line goes through the rich layer, a half line waits. A
        buffer that outgrows the wrap width without ever seeing a newline
        is broken at its last space, so a model that streams one huge
        paragraph still shows progress. Width is settled once per turn,
        since a console query per delta would cost a syscall per token
        and can corrupt a paste mid-drain. The cut reserves the RENDERED
        row's extra columns (a bullet's "  * " vs its "- " source, or a
        continuation's own indent), not the source text's own width, so a
        word is never stranded above its continuation.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Piece = '',
        [ValidateSet('Content', 'Reasoning')][string]$Kind = 'Content',
        [int]$Width = 0,
        [scriptblock]$Write = (Get-WtReplDefaultWriter)
    )
    if ($null -eq $script:WtReplStream) { Reset-WtReplStream }
    if (-not $Piece) { return }
    [void]$script:WtReplStream[$Kind].Append([string]$Piece)
    if ($Kind -eq 'Reasoning') { $script:WtReplStream.LastKind = 'Reasoning'; return }
    $script:WtReplStream.LastKind = 'Content'
    if ($Width -le 0) { $Width = [int]$script:WtReplStream.Width }
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width; $script:WtReplStream.Width = $Width }
    [void]$script:WtReplStream.Buffer.Append([string]$Piece)

    $margin = Get-WtReplMargin
    $limit = Get-WtRichWrapWidth -Width (Get-WtReplTextWidth -Width $Width)
    while ($true) {
        $buf = $script:WtReplStream.Buffer.ToString()
        $nl = $buf.IndexOf([char]10)
        if ($nl -ge 0) {
            $line = $buf.Substring(0, $nl).TrimEnd([char]13)
            [void]$script:WtReplStream.Buffer.Remove(0, $nl + 1)
            Write-WtReplLineBuffered -Line $line -Width $Width -Write $Write
            continue
        }
        $rich = $script:WtReplStream.Rich
        $reserve = 0
        if ($rich.Continuation -and -not $rich.InFence) { $reserve = [int]$rich.ContinuationIndent }
        else { $reserve = $margin + [int](Get-WtRichBlockIndents -Block (Get-WtRichBlock -Line $buf -State $rich)).First }
        $cutLimit = [Math]::Max(10, $limit - $reserve)
        if ($buf.Length -le $cutLimit) { break }
        $cut = $buf.LastIndexOf([char]' ', $cutLimit - 1)
        if ($cut -le 0) { break }
        if (-not (Test-WtReplCutSafe -Text ($buf.Substring(0, $cut)))) { break }
        [void]$script:WtReplStream.Buffer.Remove(0, $cut + 1)
        Write-WtReplLineBuffered -Line ($buf.Substring(0, $cut)) -Width $Width -Write $Write
        $script:WtReplStream.Rich.Continuation = $true
    }
}

function Complete-WtReplStream {
    <#
    .SYNOPSIS
        End of turn (or of a stream broken by a tool call): flush what is
        left in the buffer and forget an unterminated fence, so the next
        answer does not start inside a code block.
    #>
    param([int]$Width = 0, [scriptblock]$Write = (Get-WtReplDefaultWriter))
    if ($null -eq $script:WtReplStream) { return }
    if ($Width -le 0) { $Width = [int]$script:WtReplStream.Width }
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    $rest = $script:WtReplStream.Buffer.ToString()
    [void]$script:WtReplStream.Buffer.Clear()
    if ($rest.Trim().Length -gt 0) { Write-WtReplLineBuffered -Line $rest -Width $Width -Write $Write }
    $script:WtReplStream.Rich = @{ InFence = $false }
    $script:WtReplStream.Open = $false
}

function Get-WtReplStreamText {
    param([ValidateSet('All', 'Content', 'Reasoning')][string]$Kind = 'All')
    if ($null -eq $script:WtReplStream) { return '' }
    switch ($Kind) {
        'Content' { return $script:WtReplStream.Content.ToString() }
        'Reasoning' { return $script:WtReplStream.Reasoning.ToString() }
    }
    $reasoning = $script:WtReplStream.Reasoning.ToString()
    $content = $script:WtReplStream.Content.ToString()
    if ($reasoning -and $content) { return ($reasoning + "`n" + $content) }
    return ($reasoning + $content)
}

function Get-WtReplEntryLines {
    <#
    .SYNOPSIS
        PURE: a transcript entry as printable segment rows. The user's
        own text sits behind "> " in cyan; the answer goes through the
        rich layer (markdown off the screen, wrapped at the window);
        a tool line carries its own indent and is printed as it was
        formatted, its name white up to the arguments; info and error
        lines are marked two columns in.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('User', 'Assistant', 'Tool', 'Error', 'Info')][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [int]$Width = 80,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $margin = Get-WtReplMargin
    $textWidth = Get-WtReplTextWidth -Width $Width
    switch ($Kind) {
        'Assistant' {
            foreach ($r in (Get-WtRichLines -Text ([string]$Text) -Width $textWidth -Indent $margin -Glyphs $Glyphs)) { $rows.Add($r) }
        }
        'User' {
            $colors = @{ Normal = 'Cyan'; Strong = 'Cyan'; Code = 'Cyan'; Link = 'Cyan'; Url = 'Cyan' }
            foreach ($line in (([string]$Text).Split([char]10))) {
                $parts = @(@{ Text = ([string]$line).TrimEnd([char]13); Style = 'Normal' })
                foreach ($r in (Split-WtWrappedSegments -Parts $parts -Width $textWidth -Indent $margin -Hanging 2 -Prefix '> ' -PrefixFg 'Cyan' -Colors $colors)) { $rows.Add($r) }
            }
        }
        'Tool' {
            $limit = Get-WtRichWrapWidth -Width $Width
            foreach ($line in (([string]$Text).Split([char]10))) {
                $t = ([string]$line).TrimEnd([char]13)
                if ($t.Length -gt $limit) { $t = $t.Substring(0, $limit - 1) + [string][char]0x2026 }
                $bullet = [string]$Glyphs.Bullet
                $isCall = $t.TrimStart().StartsWith($bullet, [System.StringComparison]::Ordinal)
                $cut = $(if ($isCall) { $t.IndexOf('(') } else { -1 })
                if ($cut -gt 0) {
                    $rows.Add(@((New-WtSeg -Text $t.Substring(0, $cut) -Fg 'White'), (New-WtSeg -Text $t.Substring($cut) -Fg 'DarkGray')))
                }
                elseif ($isCall) { $rows.Add(@(, (New-WtSeg -Text $t -Fg 'White'))) }
                else { $rows.Add(@(, (New-WtSeg -Text $t -Fg 'DarkGray'))) }
            }
        }
        default {
            $fg = $(if ($Kind -eq 'Error') { 'Red' } else { 'DarkYellow' })
            $mark = $(if ($Kind -eq 'Error') { '! ' } else { 'i ' })
            $colors = @{ Normal = $fg; Strong = $fg; Code = $fg; Link = $fg; Url = $fg }
            foreach ($line in (([string]$Text).Split([char]10))) {
                $parts = @(@{ Text = ([string]$line).TrimEnd([char]13); Style = 'Normal' })
                foreach ($r in (Split-WtWrappedSegments -Parts $parts -Width $textWidth -Indent $margin -Hanging $mark.Length -Prefix $mark -PrefixFg $fg -Colors $colors)) { $rows.Add($r) }
            }
        }
    }
    return , $rows.ToArray()
}

function Write-WtReplEntry {
    <#
    .SYNOPSIS
        Commits one transcript entry (User/Assistant/Tool/Info/Error),
        opening or continuing the shared tool box for consecutive Tool
        entries. The speaker GROUP decides whether a blank line goes in
        before it, not the raw Kind: two Tool entries (a call and its
        result) stay glued, but a Tool entry after the answer opens a
        new block.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [int]$Width = 0,
        [scriptblock]$Write = (Get-WtReplDefaultWriter)
    )
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    $group = Get-WtReplEntryGroup -Kind $Kind
    $separate = ($group -ne $script:WtReplLastGroup)
    if ($Kind -eq 'Tool') {
        $rows = New-Object System.Collections.Generic.List[object]
        if (-not $script:WtReplToolBoxOpen) { $rows.Add((Get-WtReplToolBoxRow -Part 'Top' -Width $Width)) }
        foreach ($line in (Get-WtReplEntryLines -Kind 'Tool' -Text $Text -Width ($Width - 4))) { $rows.Add((Get-WtReplToolBoxRow -Part 'Row' -Segments @($line) -Width $Width)) }
        Write-WtReplBlock -Rows $rows.ToArray() -Separate:$separate -Width $Width -Write $Write -ToolBox
        $script:WtReplToolBoxOpen = $true
        $script:WtReplToolBoxWidth = [int]$Width
        $script:WtReplLastGroup = $group
        return
    }
    Write-WtReplBlock -Rows (Get-WtReplEntryLines -Kind $Kind -Text $Text -Width $Width) -Separate:$separate -Width $Width -Write $Write
    $script:WtReplLastGroup = $group
}

function Get-WtReplSuggestionLines {
    <#
    .SYNOPSIS
        PURE: the suggestion block as plain lines. -Suggestions can be a
        hashtable (Chat.Suggestions) or a PSCustomObject (unit tests), so
        membership is checked both ways rather than by dot-notation alone.
    #>
    param([AllowEmptyCollection()][array]$Suggestions = @())
    $rows = @($Suggestions)
    if ($rows.Count -eq 0) { return [string[]]@() }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('  ' + [string](Get-Translation 'AsSuggestionsHeading'))
    $n = 0
    foreach ($s in $rows) {
        $n++
        if ($n -gt 1) { $lines.Add('') }
        $line = '  [' + $n + '] ' + [string]$s.Label
        if ($s.Risk) { $line += '  [' + [string](Get-Translation ('Risk' + [string]$s.Risk)) + ']' }
        if ($s.Path) { $line += ' - ' + [string]$s.Path }
        $lines.Add($line)
        $hasWhat = $(if ($s -is [System.Collections.IDictionary]) { $s.ContainsKey('What') } else { $s.PSObject.Properties.Name -contains 'What' })
        if ($hasWhat -and [string]$s.What) { $lines.Add('      ' + [string]$s.What) }
    }
    return [string[]]$lines.ToArray()
}

function Write-WtReplSuggestions {
    param([AllowEmptyCollection()][array]$Suggestions = @(), [int]$Width = 0, [scriptblock]$Write = (Get-WtReplDefaultWriter))
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in @(Get-WtReplSuggestionLines -Suggestions $Suggestions)) { $rows.Add(@(, (New-WtSeg -Text ([string]$line) -Fg 'Yellow'))) }
    if ($rows.Count -eq 0) { return }
    Write-WtReplBlock -Rows $rows.ToArray() -Separate -Width $Width -Write $Write
    $script:WtReplLastGroup = 'System'
}

function Get-WtReplTranscriptTail {
    <#
    .SYNOPSIS
        What is reprinted when the REPL is re-entered from the menu: the
        last Count printed lines of the transcript, then the current
        suggestions. The console buffer is never the record - the session
        is - so this rebuilds the view from it. Get-WtReplEntryLines is
        called in plain parentheses, not wrapped in @(): its own
        "return ,$rows.ToArray()" already hands back one array as a single
        output object, and @() around that would nest it one level deeper.
    #>
    param([Parameter(Mandatory)][hashtable]$Session, [int]$Count = 400, [int]$Width = 80)
    $all = New-Object System.Collections.Generic.List[object]
    $previous = ''
    $boxOpen = $false
    foreach ($entry in @($Session.Entries.ToArray())) {
        $kind = [string]$entry.Kind
        $group = Get-WtReplEntryGroup -Kind $kind
        $lines = (Get-WtReplEntryLines -Kind $kind -Text ([string]$entry.Text) -Width $(if ($kind -eq 'Tool') { $Width - 4 } else { $Width }))
        if (@($lines).Count -eq 0) { continue }
        if ($kind -ne 'Tool' -and $boxOpen) { $all.Add((Get-WtReplToolBoxRow -Part 'Bottom' -Width $Width)); $boxOpen = $false }
        if ($previous -and $group -ne $previous) { $all.Add(@(, (New-WtSeg -Text '' -Fg 'Gray'))) }
        if ($kind -eq 'Tool') {
            if (-not $boxOpen) { $all.Add((Get-WtReplToolBoxRow -Part 'Top' -Width $Width)); $boxOpen = $true }
            foreach ($row in $lines) { $all.Add((Get-WtReplToolBoxRow -Part 'Row' -Segments @($row) -Width $Width)) }
        }
        else { foreach ($row in $lines) { $all.Add($row) } }
        $previous = $group
    }
    if ($boxOpen) { $all.Add((Get-WtReplToolBoxRow -Part 'Bottom' -Width $Width)) }
    $rows = $all.ToArray()
    if ($rows.Count -gt $Count) { $rows = @($rows[($rows.Count - $Count)..($rows.Count - 1)]) }
    $tail = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) { $tail.Add($r) }
    $suggestions = @(Get-WtReplSuggestionLines -Suggestions @($Session.Suggestions))
    if ($suggestions.Count -gt 0 -and $tail.Count -gt 0) { $tail.Add(@(, (New-WtSeg -Text '' -Fg 'Gray'))) }
    foreach ($s in $suggestions) {
        $tail.Add(@(, (New-WtSeg -Text ([string]$s) -Fg 'Yellow')))
    }
    return , $tail.ToArray()
}

function Write-WtReplTranscriptTail {
    <#
    .SYNOPSIS
        Commits the transcript tail (and current suggestions) to the
        screen. Resets the tool-box-open and last-speaker-group flags
        first, since a box or a group left over from the page this
        replaces does not describe what is on screen now.
    #>
    param([Parameter(Mandatory)][hashtable]$Session, [int]$Count = 400, [int]$Width = 0, [scriptblock]$Write = (Get-WtReplDefaultWriter))
    if ($Width -le 0) { $Width = (Get-WtConsoleSize).Width }
    $script:WtReplToolBoxOpen = $false
    Write-WtReplBlock -Rows (Get-WtReplTranscriptTail -Session $Session -Count $Count -Width $Width) -Separate -Width $Width -Write $Write
    $script:WtReplLastGroup = ''
}

function Read-WtReplLine {
    <#
    .SYNOPSIS
        The REPL's line reader, returning
        @{ Kind = 'Submit'|'Cancel'|'CtrlC'|'Eof'|'Resize'; Text }.
        Key mode runs a ReadKey loop over the pure editor and paints the
        box, slash popup and caret through Show-WtReplLive; keys already
        queued behind one another are a paste burst, applied as one edit.
        Line mode (ISE, redirected stdin) falls back to Read-Host with no
        editing. Two traps hold it together: the console size is queried
        only between keys, since querying it while a paste drains corrupts
        the input (dotnet/runtime #88343), and the wait-for-a-key
        scriptblock is bound to $awaitKey rather than $waitKey, which
        would shadow the -WaitKey parameter and recurse until the stack
        overflowed.
    #>
    param(
        [string]$Prompt = '> ',
        [AllowEmptyCollection()][string[]]$History = @(),
        [switch]$Secret,
        [AllowEmptyString()][string]$Placeholder = '',
        [AllowEmptyCollection()][array]$StatusRows = @(),
        [scriptblock]$GetClipboard = { try { [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { '' } },
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) },
        [scriptblock]$KeyAvailable = { [Console]::KeyAvailable },
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [int]$Width = 0,
        [AllowEmptyCollection()][string[]]$QuestionLines = @(),
        [AllowEmptyString()][string]$QuestionTitle = '',
        [AllowEmptyString()][string]$QuestionRisk = '',
        [switch]$EchoAsUser,
        [switch]$AllowResize,
        [AllowNull()][AllowEmptyString()][string]$InitialText = '',
        [scriptblock]$WaitKey = $null
    )
    if ($script:WtInputMode -ne 'Key') {
        $line = $null
        if ($Secret) {
            $secure = Read-Host -AsSecureString $Prompt
            if ($null -ne $secure) { $line = ([System.Net.NetworkCredential]::new('', $secure)).Password }
        }
        else { $line = Read-Host $Prompt }
        if ($null -eq $line) { return @{ Kind = 'Eof'; Text = '' } }
        return @{ Kind = 'Submit'; Text = [string]$line }
    }
    $widthFixed = ($Width -gt 0)
    $size = Get-WtConsoleSize
    if (-not $widthFixed) { $Width = [int]$size.Width }
    $boxHeight = [int]$size.Height
    $live = [bool]$script:WtReplLiveEnabled
    $askEntry = (@($QuestionLines).Count -gt 0)
    if ($AllowResize -and -not $widthFixed -and -not $askEntry -and [int]$script:WtReplPageWidth -gt 0 -and $Width -ne [int]$script:WtReplPageWidth) {
        if ($live) { Hide-WtReplLive -Write $Write }
        return @{ Kind = 'Resize'; Text = '' }
    }
    $state = New-WtReplLineState -History $History
    if ($InitialText) { $state.Text = [string]$InitialText; $state.Cursor = ([string]$InitialText).Length }
    $shownText = { if ($Secret) { ('*' * ([string]$state.Text).Length) } else { [string]$state.Text } }
    $awaitKey = {
        if ($null -ne $WaitKey) { return [string](& $WaitKey) }
        if ($widthFixed -or -not $script:WtReplResizePoll -or -not $script:WtReplMode) { return 'Key' }
        while ($true) {
            $ready = $false
            try { $ready = [bool](& $KeyAvailable) } catch { return 'Key' }
            if ($ready) { return 'Key' }
            $polled = Get-WtConsoleSize
            if ([int]$polled.Width -ne $Width -or [int]$polled.Height -ne $boxHeight) { return 'Resize' }
            Start-Sleep -Milliseconds 50
        }
    }
    $paint = {
        $shown = & $shownText
        if ($live) {
            $box = Get-WtReplInputLines -Prompt $Prompt -Text $shown -Cursor ([int]$state.Cursor) -Width $Width -Placeholder $Placeholder
            $below = @()
            if (@($state.Popup).Count -gt 0) { $below = @(Get-WtReplPopupRows -Popup @($state.Popup) -Index ([int]$state.PopupIndex) -Width $Width) }
            else { $below = @($StatusRows) }
            $above = @()
            if (@($QuestionLines).Count -gt 0) {
                $fg = switch ($QuestionRisk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'Cyan' } }
                $qRows = @(Get-WtReplQuestionRows -Lines $QuestionLines -Width $Width -Fg $fg)
                $above = @(Get-WtReplBoxRows -Title $QuestionTitle -Rows $qRows -Width $Width -Fg $fg)
            }
            $rows = @($above) + @($box.Rows) + @($below)
            Show-WtReplLive -Rows $rows -CaretRow ([int]$box.CaretRow + @($above).Count) -CaretCol ([int]$box.CaretCol) -Width $Width -Height $boxHeight -Write $Write
        }
        else {
            $render = Get-WtReplLineRender -Prompt $Prompt -Text $shown -Cursor ([int]$state.Cursor) -Width $Width
            & $Write ("`r" + $script:WtEsc + '[2K' + [string]$render.Line + "`r" + $script:WtEsc + '[' + ([int]$render.CursorCol + 1) + 'G')
        }
    }
    $finish = { param([string]$Kind)
        if ($live) {
            Hide-WtReplLive -Write $Write
            if ($Kind -eq 'Submit') {
                $shown = [string](& $shownText)
                if ($EchoAsUser) { if ($shown.Trim().Length -gt 0) { Write-WtReplEntry -Kind 'User' -Text $shown -Width $Width } }
                else { Write-WtReplLine -Text ($Prompt + $shown) -Fg 'Cyan' }
            }
        }
        else { & $Write "`n" }
        return @{ Kind = $Kind; Text = [string]$state.Text }
    }
    & $paint
    while ($true) {
        $null = Assert-WtTuiCtrlCInput
        $null = Assert-WtWindowMaximized
        if ((& $awaitKey) -eq 'Resize') {
            $size = Get-WtConsoleSize
            $Width = [int]$size.Width
            $boxHeight = [int]$size.Height
            if ($AllowResize -and @($QuestionLines).Count -eq 0) { return (& $finish 'Resize') }
            Sync-WtReplResize -Force -Write $Write | Out-Null
            & $paint
            continue
        }
        $key = $null
        try { $key = & $ReadKey } catch { $null = Write-WtErrorLog -ErrorRecord $_ -Context 'Read-WtReplLine: ReadKey failed'; $key = $null }
        if ($null -eq $key) { return (& $finish 'Eof') }
        $emit = 'None'
        while ($true) {
            $burst = $false
            try { $burst = [bool](& $KeyAvailable) } catch { $burst = $false }
            $token = ConvertTo-WtReplKeyToken -Key ([string]$key.Key) -KeyChar ([string]$key.KeyChar) -Modifiers ([string]$key.Modifiers) -Burst $burst
            if ($token.Ctrl -and [string]$token.Key -eq 'V') {
                $clip = ''
                try { $clip = [string](& $GetClipboard) } catch { $clip = '' }
                $token = @{ Key = 'Paste'; Text = $clip; Char = ''; Ctrl = $false; Burst = $burst }
            }
            $r = Update-WtReplLine -State $state -Token $token
            $state = $r.State
            $emit = [string]$r.Emit
            if (-not $live -and $emit -eq 'None') { & $paint }
            if ($emit -ne 'None' -and $emit -ne 'Clear') { break }
            if (-not $burst) { break }
            $key = $null
            try { $key = & $ReadKey } catch { $key = $null }
            if ($null -eq $key) { break }
        }
        switch ($emit) {
            'Submit' { return (& $finish 'Submit') }
            'Cancel' { return (& $finish 'Cancel') }
            'CtrlC' { return (& $finish 'CtrlC') }
        }
        if (-not $burst -and -not $widthFixed) {
            $size = Get-WtConsoleSize
            $wasWidth = $Width
            $Width = [int]$size.Width
            $boxHeight = [int]$size.Height
            $askingSomething = (@($QuestionLines).Count -gt 0)
            $pageWidth = [int]$script:WtReplPageWidth
            $stale = ($Width -ne $wasWidth) -or ($pageWidth -gt 0 -and $Width -ne $pageWidth)
            if ($AllowResize -and -not $askingSomething -and $stale) { return (& $finish 'Resize') }
            if ($askingSomething -and $Width -ne $wasWidth) { Sync-WtReplResize -Force -Write $Write | Out-Null }
        }
        & $paint
    }
}

function Read-WtReplPick {
    <#
    .SYNOPSIS
        The one selector every REPL choice uses: arrows + Enter, digits,
        hotkey letters, Esc. Live mode paints the box in the live region;
        plain mode prints a numbered list and reads a number (or free
        text when a text option exists) through -ReadLine. The text
        option hands over to the line reader. A question taller than the
        window is committed to the scrollable transcript first, wrapped,
        since the live region would otherwise cut it from the TOP - the
        part that says where the data goes. Returns
        @{ Index = 1..N (0 = cancelled or free text); Text = label / typed text }.
    #>
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Options,
        [AllowEmptyString()][string]$TextOption = '',
        [AllowEmptyString()][string]$Risk = '',
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) },
        [scriptblock]$ReadLine = { param($P) Read-WtReplLine -Prompt $P },
        [scriptblock]$Write = (Get-WtReplRawWriter),
        [int]$Width = 0
    )
    $state = New-WtReplPickState -Options $Options -TextOption $TextOption
    $rows = @($state.Rows)
    if (-not $script:WtReplLiveEnabled) {
        $fg = switch ($Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'White' } }
        if ($Title) { Write-WtReplLine -Text $Title -Fg 'White' }
        foreach ($l in @($Lines)) { Write-WtReplLine -Text ([string]$l) -Fg $fg }
        $listed = @($rows | Where-Object { -not $_.IsText })
        for ($i = 0; $i -lt $listed.Count; $i++) { Write-WtReplLine -Text ('  ' + ($i + 1) + ') ' + [string]$listed[$i].Label) }
        $r = & $ReadLine ([string](Get-Translation 'AsPickPrompt') + ': ')
        if ([string]$r.Kind -ne 'Submit') { return @{ Index = 0; Text = '' } }
        $text = ([string]$r.Text).Trim()
        $index = 0
        if ([int]::TryParse($text, [ref]$index) -and $index -ge 1 -and $index -le $listed.Count) { return @{ Index = $index; Text = [string]$listed[$index - 1].Label } }
        if ($TextOption -and $text) { return @{ Index = 0; Text = $text } }
        return @{ Index = 0; Text = '' }
    }
    $pickSize = Get-WtConsoleSize
    if ($Width -le 0) { $Width = [int]$pickSize.Width }
    $pickHeight = [int]$pickSize.Height
    $probe = @(Get-WtReplPickLines -Title $Title -Lines $Lines -State $state -Width $Width -Glyphs $script:WtGlyphs -Risk $Risk)
    if (@($Lines).Count -gt 0 -and $probe.Count -gt [Math]::Max(1, $pickHeight - 1)) {
        $textFg = switch ($Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'White' } }
        Hide-WtReplLive -Write $Write
        Write-WtReplBlock -Rows @(Get-WtReplQuestionRows -Lines $Lines -Width $Width -Fg $textFg) -Separate -Width $Width
        $Lines = @()
    }
    while ($true) {
        Show-WtReplLive -Rows @(Get-WtReplPickLines -Title $Title -Lines $Lines -State $state -Width $Width -Risk $Risk) -CaretRow -1 -Width $Width -Height $pickHeight -Write $Write
        $null = Assert-WtTuiCtrlCInput
        $null = Assert-WtWindowMaximized
        $key = $null
        try { $key = & $ReadKey } catch { $key = $null }
        if ($null -eq $key) { Hide-WtReplLive -Write $Write; return @{ Index = 0; Text = '' } }
        $token = ConvertTo-WtReplKeyToken -Key ([string]$key.Key) -KeyChar ([string]$key.KeyChar) -Modifiers ([string]$key.Modifiers) -Burst $false
        $r = Update-WtReplPickState -State $state -Token $token
        $state = $r.State
        if ([string]$r.Emit -eq 'Cancel') { Hide-WtReplLive -Write $Write; return @{ Index = 0; Text = '' } }
        if ([string]$r.Emit -eq 'Pick') {
            Hide-WtReplLive -Write $Write
            $picked = $rows[[int]$state.Index]
            if ($picked.IsText) {
                $line = & $ReadLine ([string]$picked.Label + ': ')
                if ([string]$line.Kind -ne 'Submit') { return @{ Index = 0; Text = '' } }
                return @{ Index = 0; Text = ([string]$line.Text).Trim() }
            }
            return @{ Index = ([int]$state.Index + 1); Text = [string]$picked.Label }
        }
    }
}

function Read-WtReplAnswer {
    <#
    .SYNOPSIS
        The REPL's stand-in for Read-WtPanelAnswer. With -Choices (the
        privacy gate) it is a selector and hands back the chosen LETTER,
        so every existing letter parser keeps working; without, the
        lines are printed (risk-coloured) and a line of text is read.
        $null = cancelled, which every gate treats as no.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prompt,
        [AllowEmptyString()][string]$Risk = '',
        [AllowNull()][array]$Choices = $null,
        [scriptblock]$ReadLine = { param($P, $QLines, $QTitle, $QRisk) Read-WtReplLine -Prompt $P -QuestionLines ([string[]]@($QLines)) -QuestionTitle ([string]$QTitle) -QuestionRisk ([string]$QRisk) },
        [scriptblock]$ReadPick = { param($T, $L, $O, $R) Read-WtReplPick -Title $T -Lines $L -Options $O -Risk $R },
        [scriptblock]$Write = (Get-WtReplDefaultWriter)
    )
    $fg = switch ($Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'White' } }
    if ($null -ne $Choices -and @($Choices).Count -gt 0 -and $script:WtReplLiveEnabled) {
        $options = @(foreach ($c in @($Choices)) { @{ Label = [string]$c.Label; Hotkey = [string]$c.Letter } })
        $title = [string]$Prompt
        $yesNo = ' ' + [string](Format-WtYesNoHint)
        if ($title.EndsWith($yesNo, [System.StringComparison]::Ordinal)) { $title = $title.Substring(0, $title.Length - $yesNo.Length) }
        $r = & $ReadPick $title ([string[]]@($Lines)) $options $Risk
        if ([int]$r.Index -lt 1) { return $null }
        return [string]@($Choices)[[int]$r.Index - 1].Letter
    }
    if (-not $script:WtReplLiveEnabled) {
        foreach ($line in @($Lines)) { & $Write ([string]$line) $fg $false }
        & $Write $Prompt $fg $false
        $r = & $ReadLine ([string](Get-Translation 'AsReplAnswerPrompt')) ([string[]]@()) '' ''
        if ([string]$r.Kind -ne 'Submit') { return $null }
        return [string]$r.Text
    }
    $r = & $ReadLine ([string](Get-Translation 'AsReplAnswerPrompt')) ([string[]]@($Lines)) $Prompt $Risk
    if ([string]$r.Kind -ne 'Submit') { return $null }
    return [string]$r.Text
}

function Test-WtReplCancelRequested {
    <#
    .SYNOPSIS
        The ShouldCancel poll while the model generates: drain whatever
        keys are queued; Esc or Ctrl+C (Char 3 with TreatControlCAsInput)
        means stop. Other keys are discarded - typing during a stream
        must not land in the next prompt.
    #>
    param(
        [scriptblock]$KeyAvailable = { $script:WtInputMode -eq 'Key' -and [Console]::KeyAvailable },
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) }
    )
    $cancel = $false
    $guard = 0
    $null = Assert-WtTuiCtrlCInput
    $null = Assert-WtWindowMaximized
    while ($guard -lt 64) {
        $available = $false
        try { $available = [bool](& $KeyAvailable) } catch { $available = $false }
        if (-not $available) { break }
        $guard++
        $key = $null
        try { $key = & $ReadKey } catch { $key = $null }
        if ($null -eq $key) { break }
        if ([string]$key.Key -eq 'Escape') { $cancel = $true }
        if ([string]$key.KeyChar -eq ([string][char]3)) { $cancel = $true }
        if ([string]$key.Key -eq 'C' -and (([string]$key.Modifiers).IndexOf('Control', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) { $cancel = $true }
    }
    return $cancel
}

function Set-WtReplTitle {
    param([AllowEmptyString()][string]$Text)
    try { $Host.UI.RawUI.WindowTitle = [string]$Text } catch { $null = $_ }
}
