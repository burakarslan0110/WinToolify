# Panel breadcrumb, output lines, wrapped text, panel messages and answers, Wait-WtEnter.
# Covered by: tests/Tui.Tests.ps1, tests/ApplyFlow.Tests.ps1

$script:WtPanelBreadcrumb = ''

function Get-WtPanelItems {
    <#
    .SYNOPSIS
        Plain text lines as non-focusable Info rows (one per line), with
        an optional risk so notices render red/yellow. Only the first
        line carries the risk tag, since a message wrapped over several
        rows is one message, not one per row.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$Risk = ''
    )
    $items = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($l in @($Lines)) {
        $n++
        $items.Add((New-WtListItem -Kind 'Info' -Name ('Line:' + $n) -Label ([string]$l) -Risk $Risk -RiskTag ($n -eq 1)))
    }
    return $items.ToArray()
}

function ConvertTo-WtOutputLines {
    <#
    .SYNOPSIS
        One captured pipeline object -> the text lines a panel should
        show: errors and warnings become their message, not a stack
        trace, and other objects go through Out-String. A lone carriage
        return overwrites the current row instead of starting a new one,
        since tools like sfc write their whole progress as one
        CR-separated line.
    #>
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return @() }

    $text = $null
    if ($InputObject -is [string]) { $text = $InputObject }
    elseif ($InputObject -is [System.Management.Automation.InformationRecord]) {
        $data = $InputObject.MessageData
        $text = if ($null -ne $data -and $data.PSObject.Properties.Name -contains 'Message') { [string]$data.Message } else { [string]$data }
    }
    elseif ($InputObject -is [System.Management.Automation.ErrorRecord]) { $text = [string]$InputObject.Exception.Message }
    elseif ($InputObject -is [System.Management.Automation.WarningRecord]) { $text = [string]$InputObject.Message }
    elseif ($InputObject -is [System.Management.Automation.VerboseRecord] -or $InputObject -is [System.Management.Automation.DebugRecord]) { $text = [string]$InputObject.Message }
    else {
        $text = ($InputObject | Out-String).TrimEnd("`r", "`n")
        $text = $text -replace '^(\r?\n)+', ''
    }

    if ($null -eq $text) { return @() }
    $lines = @($text -split '\r?\n')
    if ($lines.Count -eq 1 -and -not $lines[0]) { return @('') }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line.IndexOf("`r") -lt 0) { $rows.Add($line); continue }
        $segments = @($line -split "`r" | Where-Object { $_ -ne '' })
        $rows.Add($(if ($segments.Count -gt 0) { [string]$segments[-1] } else { '' }))
    }
    return $rows.ToArray()
}

function New-WtNativeOutputState {
    <#
    .SYNOPSIS
        The state Add-WtNativeOutputChunk carries across chunks:
        @{ Lines; Current; Column }. Lines lives inside the hashtable, not
        as its own parameter, since a typed List[string] parameter lets
        PowerShell's binder silently unwrap and reject it without
        [CmdletBinding()], dropping every chunk with the panel left blank.
    #>
    return @{ Lines = (New-Object System.Collections.Generic.List[string]); Current = ''; Column = 0 }
}

function Add-WtNativeOutputChunk {
    <#
    .SYNOPSIS
        Applies one raw chunk of a native tool's stdout to the line state
        the panel renders, the way a terminal would: LF commits the row,
        CR returns to column 1, BS steps back one, anything else
        overwrites and advances. PadRight covers a CR followed by a
        shorter write, so the previous row's tail does not linger.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowEmptyString()][string]$Chunk = ''
    )
    $committed = $State.Lines
    foreach ($char in $Chunk.ToCharArray()) {
        if ($char -eq "`n") { $committed.Add([string]$State.Current); $State.Current = ''; $State.Column = 0; continue }
        if ($char -eq "`r") { $State.Column = 0; continue }
        if ($char -eq "`b") { if ([int]$State.Column -gt 0) { $State.Column = [int]$State.Column - 1 }; continue }
        $text = [string]$State.Current
        $column = [int]$State.Column
        if ($column -ge $text.Length) { $State.Current = $text.PadRight($column) + $char }
        else { $State.Current = $text.Remove($column, 1).Insert($column, $char) }
        $State.Column = $column + 1
    }
}

function Format-WtElapsed {
    <#
    .SYNOPSIS
        PURE: seconds -> "mm:ss" for the "still running" footer. Minutes
        keep counting past 60 instead of rolling into hours, so a
        90-minute run reads "90:12" rather than "1:30:12".
    #>
    param([Parameter(Mandatory)][int]$Seconds)
    $s = [Math]::Max(0, $Seconds)
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($s / 60), ($s % 60))
}

function Split-WtWrappedLines {
    <#
    .SYNOPSIS
        PURE: word-wraps one long message into panel-width lines. Runs of
        whitespace collapse to single spaces, a word longer than Width is
        hard-broken, and blank input yields no lines at all.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    $w = [Math]::Max(8, $Width)
    $words = @(([string]$Text) -split '\s+' | Where-Object { $_ })
    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in $words) {
        $piece = [string]$word
        while ($piece.Length -gt $w) {
            if ($current) { $lines.Add($current); $current = '' }
            $lines.Add($piece.Substring(0, $w))
            $piece = $piece.Substring($w)
        }
        if (-not $current) { $current = $piece }
        elseif (($current.Length + 1 + $piece.Length) -le $w) { $current += ' ' + $piece }
        else { $lines.Add($current); $current = $piece }
    }
    if ($current) { $lines.Add($current) }
    return $lines.ToArray()
}

function Get-WtPanelInnerWidth {
    <#
    .SYNOPSIS
        PURE: the widest inner area a box can offer on this console. A
        Compact box is never wider, so wrapping to this fits both
        layouts.
    #>
    param([Parameter(Mandatory)][int]$Width)
    return [Math]::Max(20, (Get-WtFrameWidth -Width $Width) - 4)
}

function Show-WtPanelMessage {
    <#
    .SYNOPSIS
        Paints a frame whose content is a list of text lines (summaries,
        progress, results). No input. Returns the console size used.
        Long lines are wrapped to the box, never cut with '~'.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$FooterText = '',
        [string]$Risk = '',
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full'
    )
    $size = Get-WtConsoleSize
    $items = @(Get-WtPanelItems -Lines (ConvertTo-WtPanelLines -Lines $Lines -Width (Get-WtPanelInnerWidth -Width $size.Width) -Risk $Risk) -Risk $Risk)
    $state = @{ CursorIndex = -1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
    $frame = Get-WtFrameRows -Breadcrumb $Breadcrumb -Items $items -State $state -Width $size.Width -Height $size.Height `
        -Glyphs $script:WtGlyphs -FooterText $FooterText -LineMode ($script:WtInputMode -eq 'Line') `
        -Layout $Layout
    Write-WtFrame -FrameLines $frame -Width $size.Width -Height $size.Height
    $geo = Get-WtFrameFooterCell -FrameLines $frame -Glyphs $script:WtGlyphs
    return @{ Width = $size.Width; Height = $size.Height; FooterRow = $geo.Row; FooterCol = $geo.Col }
}

function Show-WtListLoading {
    <#
    .SYNOPSIS
        The one-line "Yukleniyor..." panel a catalog screen paints before
        it builds its rows: the screen's own breadcrumb, no footer,
        nothing to answer. Key mode only, since in line mode a frame is a
        full Clear-Host repaint not worth doing for a screen replaced a
        moment later.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb)
    if ($script:WtInputMode -ne 'Key') { return }
    $null = Show-WtPanelMessage -Breadcrumb $Breadcrumb -Lines @((Get-Translation 'ListLoading')) -FooterText ''
}

function Get-WtFrameFooterCell {
    <#
    .SYNOPSIS
        PURE: the footer row of a painted frame - the last box row before
        the bottom border - and the column just inside its left border.
        Full layout: (Height-2, 2); Compact: wherever the box ends.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$FrameLines,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs
    )
    $row = [Math]::Max(0, $FrameLines.Count - 2)
    $col = 2
    for ($i = $FrameLines.Count - 1; $i -ge 0; $i--) {
        $text = (@($FrameLines[$i]) | ForEach-Object T) -join ''
        $lead = $text.Length - $text.TrimStart().Length
        if ($text.TrimStart().StartsWith($Glyphs.V)) { $row = $i; $col = $lead + 2; break }
    }
    return @{ Row = $row; Col = $col }
}

function Read-WtPanelAnswer {
    <#
    .SYNOPSIS
        The in-panel modal: paints the lines, parks the cursor on the
        footer row inside the box, and reads one line there; $null when
        input is exhausted. Content taller than the viewport is shown
        first in the scrollable output screen, since Read-Host blocks and
        cannot be scrolled while the prompt is up. -Secret reads through
        Read-Host -AsSecureString and hands back plain text, so a typed
        secret echoes as '*' instead of in the clear. Resets the frame
        cache afterwards, since Read-Host's echo dirties the row.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Risk = '',
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full',
        [switch]$Secret,
        [scriptblock]$ShowScrollable = { param($Crumb, $Rows) Show-WtOutputScreen -Breadcrumb $Crumb -Lines $Rows -FooterText (Get-Translation 'OutputFooterThenAsk') | Out-Null }
    )
    $readAnswerLine = {
        if ($Secret) {
            $secure = Read-Host -AsSecureString $Prompt
            if ($null -eq $secure) { return $null }
            return ([System.Net.NetworkCredential]::new('', $secure)).Password
        }
        return (Read-Host $Prompt)
    }
    if ($script:WtInputMode -eq 'Line') {
        Clear-Host
        foreach ($l in @($Lines)) { Write-Host $l }
        $answer = & $readAnswerLine
        Reset-WtFrameCache
        return $answer
    }
    $size0 = Get-WtConsoleSize
    $Prompt = [string](Get-WtPanelPromptFit -Prompt $Prompt -Width ([int]$size0.Width))
    $wrapped = @(ConvertTo-WtPanelLines -Lines $Lines -Width (Get-WtPanelInnerWidth -Width $size0.Width) -Risk $Risk)
    $viewHeight = [Math]::Max(1, $size0.Height - (Get-WtFrameChromeHeight -Width $size0.Width))
    if ($wrapped.Count -gt $viewHeight) {
        & $ShowScrollable $Breadcrumb $wrapped
        $Lines = @()
        Reset-WtFrameCache
    }
    $footerText = if ($Layout -eq 'Compact') { $Prompt + ': ' } else { '' }
    $size = Show-WtPanelMessage -Breadcrumb $Breadcrumb -Lines $Lines -FooterText $footerText -Risk $Risk -Layout $Layout
    $footerRow = [int]$size.FooterRow
    $footerCol = [int]$size.FooterCol
    try {
        if ($script:WtVt) { $Host.UI.Write($script:WtEsc + '[' + ($footerRow + 1) + ';' + ($footerCol + 1) + 'H' + $script:WtEsc + '[?25h') }
        else { [Console]::SetCursorPosition($footerCol, $footerRow); [Console]::CursorVisible = $true }
    }
    catch { $null = $_ }
    $null = Assert-WtTuiCtrlCInput
    $null = Assert-WtWindowMaximized
    $answer = & $readAnswerLine
    try {
        if ($script:WtVt) { $Host.UI.Write($script:WtEsc + '[?25l') } else { [Console]::CursorVisible = $false }
    }
    catch { $null = $_ }
    Reset-WtFrameCache
    return $answer
}

function Wait-WtEnter {
    <#
    .SYNOPSIS
        The pause used by every transient flow, shown IN THE PANEL: the
        optional lines, then the translated prompt on the footer. The
        next TUI frame is drawn from scratch afterwards.
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $null = Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @($Lines) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
    Reset-WtFrameCache
}

function Get-WtPanelPromptFit {
    <#
    .SYNOPSIS
        PURE: cuts a Read-Host prompt so prompt + ': ' still fits between
        the panel's footer column and the right border. Read-Host retypes
        the prompt at the footer column; an unfit prompt once wrapped onto
        the bottom border and the answering Enter scrolled the alt buffer.
        Budget: Width minus the footer column, border/pad, and the ': '
        Read-Host appends, floored at 10; overflow is cut and marked '~'.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prompt,
        [Parameter(Mandatory)][int]$Width
    )
    $budget = [Math]::Max(10, $Width - 8)
    if ($Prompt.Length -le $budget) { return $Prompt }
    return ($Prompt.Substring(0, $budget - 1) + '~')
}
