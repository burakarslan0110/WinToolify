# Rich text for the assistant transcript: markdown-ish source text into
# printable, coloured segment rows. PURE - no console, no translation.

function Get-WtRichWrapWidth {
    <#
    .SYNOPSIS
        PURE: the one wrap width formula - the console width less the
        last column (a character written there wraps by itself). No cap:
        the text fills the window it is printed in, however wide that is.
    #>
    param([int]$Width = 80)
    return [Math]::Max(10, $Width - 1)
}

function Get-WtRichBlockIndents {
    <#
    .SYNOPSIS
        PURE: how many columns a block's rows take beyond its source
        text, for the streaming overflow cut. First = the extra columns
        of the FIRST rendered row over the raw line (a bullet renders
        "  * text" for "- text": two more); Continuation = the column
        every later row starts at, which is also where the tail of a cut
        block must be printed so it stays under the block's own text.
    #>
    param([Parameter(Mandatory)][hashtable]$Block, [int]$Indent = 0)
    switch ([string]$Block.Kind) {
        'Bullet'   { return @{ First = 2; Continuation = $Indent + 4 } }
        'Numbered' { return @{ First = 2; Continuation = $Indent + 2 + ([string]$Block.Marker).Length + 1 } }
        'Quote'    { return @{ First = 0; Continuation = $Indent + 2 } }
        default    { return @{ First = 0; Continuation = $Indent } }
    }
}

function Get-WtRichBlock {
    <#
    .SYNOPSIS
        PURE: one raw line plus the streaming state into the block it
        forms - @{ Kind; Level; Marker; Text; State }. A fence line
        toggles State.InFence and prints nothing; while the fence is
        open EVERY line is Code, so a '# comment' inside a code block
        is never mistaken for a heading. A rule is three or more of the
        same -, * or _ and nothing else, tested BEFORE the bullet so
        '---' does not read as a '-' item.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Line = '',
        [AllowNull()][hashtable]$State = $null
    )
    $inFence = $(if ($null -ne $State) { [bool]$State.InFence } else { $false })
    $raw = [string]$Line
    $lead = $raw.Trim()
    $next = @{ InFence = $inFence }
    $fence = ([string][char]96) * 3

    if ($lead.StartsWith($fence, [System.StringComparison]::Ordinal)) {
        $next.InFence = (-not $inFence)
        return @{ Kind = 'Fence'; Level = 0; Marker = ''; Text = ''; State = $next }
    }
    if ($inFence) { return @{ Kind = 'Code'; Level = 0; Marker = ''; Text = $raw; State = $next } }
    if ($lead.Length -eq 0) { return @{ Kind = 'Blank'; Level = 0; Marker = ''; Text = ''; State = $next } }

    if ($lead.Length -ge 3) {
        $c0 = $lead[0]
        if ($c0 -eq '-' -or $c0 -eq '*' -or $c0 -eq '_') {
            $same = $true
            foreach ($ch in $lead.ToCharArray()) { if ($ch -ne $c0) { $same = $false; break } }
            if ($same) { return @{ Kind = 'Rule'; Level = 0; Marker = ''; Text = ''; State = $next } }
        }
    }

    if ($lead[0] -eq '#') {
        $h = 0
        while ($h -lt $lead.Length -and $lead[$h] -eq '#') { $h++ }
        if ($h -ge 1 -and $h -le 6 -and $h -lt $lead.Length -and $lead[$h] -eq ' ') {
            return @{ Kind = 'Heading'; Level = $h; Marker = ''; Text = $lead.Substring($h + 1).Trim(); State = $next }
        }
        return @{ Kind = 'Paragraph'; Level = 0; Marker = ''; Text = $lead; State = $next }
    }

    if ($lead.Length -ge 2 -and $lead[1] -eq ' ' -and ($lead[0] -eq '-' -or $lead[0] -eq '*' -or $lead[0] -eq '+')) {
        return @{ Kind = 'Bullet'; Level = 0; Marker = ''; Text = $lead.Substring(2).Trim(); State = $next }
    }

    $d = 0
    while ($d -lt $lead.Length -and [char]::IsDigit($lead[$d])) { $d++ }
    if ($d -gt 0 -and ($d + 1) -lt $lead.Length -and ($lead[$d] -eq '.' -or $lead[$d] -eq ')') -and $lead[$d + 1] -eq ' ') {
        return @{ Kind = 'Numbered'; Level = 0; Marker = $lead.Substring(0, $d + 1); Text = $lead.Substring($d + 2).Trim(); State = $next }
    }

    if ($lead[0] -eq '>') {
        return @{ Kind = 'Quote'; Level = 0; Marker = ''; Text = $lead.Substring(1).Trim(); State = $next }
    }

    if ($lead[0] -eq '|' -and $lead[$lead.Length - 1] -eq '|') {
        return @{ Kind = 'Table'; Level = 0; Marker = ''; Text = $lead; State = $next }
    }

    return @{ Kind = 'Paragraph'; Level = 0; Marker = ''; Text = $lead; State = $next }
}

function Split-WtRichInline {
    <#
    .SYNOPSIS
        PURE: one line of text into styled parts - @(@{ Text; Style }),
        Style in Normal/Strong/Code/Link/Url. Backticked code wins over
        every other mark (a ** inside code stays literal), and a mark
        that never closes stays literal text since the stream hands us
        half-written lines.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text = '')
    $s = [string]$Text
    $parts = New-Object System.Collections.Generic.List[object]
    $buf = New-Object System.Text.StringBuilder
    $tick = [char]96
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        $taken = $false

        if ($c -eq $tick) {
            $close = $s.IndexOf($tick, $i + 1)
            if ($close -gt $i) {
                if ($buf.Length -gt 0) { $parts.Add(@{ Text = $buf.ToString(); Style = 'Normal' }); [void]$buf.Clear() }
                $parts.Add(@{ Text = $s.Substring($i + 1, $close - $i - 1); Style = 'Code' })
                $i = $close + 1
                $taken = $true
            }
        }
        elseif (($c -eq '*' -or $c -eq '_') -and ($i + 1) -lt $s.Length -and $s[$i + 1] -eq $c) {
            $mark = [string]$c + [string]$c
            $close = $s.IndexOf($mark, $i + 2, [System.StringComparison]::Ordinal)
            if ($close -gt ($i + 1)) {
                if ($buf.Length -gt 0) { $parts.Add(@{ Text = $buf.ToString(); Style = 'Normal' }); [void]$buf.Clear() }
                $parts.Add(@{ Text = $s.Substring($i + 2, $close - $i - 2); Style = 'Strong' })
                $i = $close + 2
                $taken = $true
            }
        }
        elseif ($c -eq '[') {
            $rb = $s.IndexOf(']', $i + 1)
            if ($rb -gt $i -and ($rb + 1) -lt $s.Length -and $s[$rb + 1] -eq '(') {
                $rp = $s.IndexOf(')', $rb + 2)
                if ($rp -gt ($rb + 1)) {
                    if ($buf.Length -gt 0) { $parts.Add(@{ Text = $buf.ToString(); Style = 'Normal' }); [void]$buf.Clear() }
                    $parts.Add(@{ Text = $s.Substring($i + 1, $rb - $i - 1); Style = 'Link' })
                    $parts.Add(@{ Text = ' (' + $s.Substring($rb + 2, $rp - $rb - 2) + ')'; Style = 'Url' })
                    $i = $rp + 1
                    $taken = $true
                }
            }
        }

        if (-not $taken) {
            [void]$buf.Append($c)
            $i++
        }
    }
    if ($buf.Length -gt 0) { $parts.Add(@{ Text = $buf.ToString(); Style = 'Normal' }) }
    return , $parts.ToArray()
}

function Get-WtRichDefaultColors {
    return @{ Normal = 'Gray'; Strong = 'White'; Code = 'DarkCyan'; Link = 'Gray'; Url = 'DarkGray' }
}

function Split-WtWrappedSegments {
    <#
    .SYNOPSIS
        PURE: styled parts into rows of segments, broken at spaces so no
        row is wider than Get-WtRichWrapWidth. -Prefix lands on the first
        row only (a list marker); every later row starts at Indent +
        Hanging. A word longer than a whole row is cut hard. Internal
        helpers take -SegFg, not -Fg: these are dot-sourced closures, so
        a -Fg param would collide (case-insensitively) with the
        caller's own $fg loop variable and get clobbered.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][array]$Parts = @(),
        [int]$Width = 80,
        [int]$Indent = 0,
        [int]$Hanging = 0,
        [AllowEmptyString()][string]$Prefix = '',
        [string]$PrefixFg = 'Gray',
        [AllowNull()][hashtable]$Colors = $null
    )
    $map = $(if ($null -ne $Colors) { $Colors } else { Get-WtRichDefaultColors })
    $limit = Get-WtRichWrapWidth -Width $Width
    $sepFg = [string]$map['Normal']
    if (-not $sepFg) { $sepFg = 'Gray' }
    $rows = New-Object System.Collections.Generic.List[object]
    $line = New-Object System.Collections.Generic.List[object]
    $col = 0
    $hasWord = $false
    $leadPad = ' ' * [Math]::Max(0, [Math]::Min($Indent, $limit - 1))
    $contPad = ' ' * [Math]::Max(0, [Math]::Min($Indent + $Hanging, $limit - 1))

    $append = {
        param([string]$Text, [string]$SegFg)
        if ($line.Count -gt 0 -and ([string]$line[$line.Count - 1].F) -eq $SegFg) {
            $line[$line.Count - 1] = New-WtSeg -Text (([string]$line[$line.Count - 1].T) + $Text) -Fg $SegFg
        }
        else { $line.Add((New-WtSeg -Text $Text -Fg $SegFg)) }
        $col += $Text.Length
    }
    $startRow = {
        param([string]$Pad, [string]$Lead, [string]$LeadFg)
        $line = New-Object System.Collections.Generic.List[object]
        $col = 0
        $hasWord = $false
        if ($Pad -or $Lead) { . $append ($Pad + $Lead) $LeadFg }
    }
    $flush = { $rows.Add($line.ToArray()) }

    . $startRow $leadPad $Prefix $PrefixFg

    $tokens = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Parts)) {
        $style = [string]$p.Style
        foreach ($w in (([string]$p.Text).Split([char]' '))) {
            if ([string]$w) { $tokens.Add(@{ Text = [string]$w; Style = $style }) }
        }
    }

    foreach ($t in $tokens) {
        $fg = [string]$map[[string]$t.Style]
        if (-not $fg) { $fg = 'Gray' }
        $word = [string]$t.Text
        $sep = $(if ($hasWord) { 1 } else { 0 })

        if ($hasWord -and ($col + $sep + $word.Length) -gt $limit) {
            . $flush
            . $startRow $contPad '' $fg
            $sep = 0
        }

        if (($col + $sep + $word.Length) -gt $limit) {
            while ($word.Length -gt 0) {
                $room = $limit - $col - $(if ($hasWord) { 1 } else { 0 })
                if ($room -le 0) {
                    . $flush
                    . $startRow $contPad '' $fg
                    continue
                }
                if ($hasWord) { . $append ' ' $sepFg }
                $take = [Math]::Min($room, $word.Length)
                . $append ($word.Substring(0, $take)) $fg
                $hasWord = $true
                $word = $word.Substring($take)
                if ($word.Length -gt 0) {
                    . $flush
                    . $startRow $contPad '' $fg
                }
            }
            continue
        }

        if ($sep -eq 1) { . $append ' ' $sepFg }
        . $append $word $fg
        $hasWord = $true
    }

    if ($line.Count -gt 0) { . $flush }
    return , $rows.ToArray()
}

function Get-WtRichBlockRows {
    <#
    .SYNOPSIS
        PURE: one classified block into printable segment rows. Code and
        table rows are clipped, not wrapped, since breaking a command or
        a column at a space would corrupt it. A heading always emits a
        blank row before itself; Write-WtReplBlock collapses blank runs
        and drops one at the top of a page, so a heading that opens an
        answer still prints no stray leading blank.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Block,
        [int]$Width = 80,
        [int]$Indent = 0,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $limit = Get-WtRichWrapWidth -Width $Width
    $padWidth = [Math]::Max(0, [Math]::Min($Indent, $limit - 1))
    $pad = ' ' * $padWidth
    $rows = New-Object System.Collections.Generic.List[object]
    $clip = {
        param([string]$Text, [string]$Fg)
        $t = $pad + $Text
        if ($t.Length -gt $limit) { $t = $t.Substring(0, $limit - 1) + [string][char]0x2026 }
        $rows.Add(@(, (New-WtSeg -Text $t -Fg $Fg)))
    }
    switch ([string]$Block.Kind) {
        'Fence' { }
        'Blank' { $rows.Add(@(, (New-WtSeg -Text '' -Fg 'Gray'))) }
        'Rule'  { $rows.Add(@(, (New-WtSeg -Text ($pad + ([string]$Glyphs.Rule * [Math]::Max(1, $limit - $padWidth))) -Fg 'DarkGray'))) }
        'Code'  { . $clip ([string]$Block.Text) 'DarkCyan' }
        'Table' { . $clip ([string]$Block.Text) 'Gray' }
        'Heading' {
            $rows.Add(@(, (New-WtSeg -Text '' -Fg 'Gray')))
            $colors = @{ Normal = 'Cyan'; Strong = 'Cyan'; Code = 'Cyan'; Link = 'Cyan'; Url = 'Cyan' }
            foreach ($r in (Split-WtWrappedSegments -Parts (Split-WtRichInline -Text ([string]$Block.Text)) -Width $Width -Indent $Indent -Colors $colors)) { $rows.Add($r) }
        }
        'Quote' {
            $colors = @{ Normal = 'DarkGray'; Strong = 'DarkGray'; Code = 'DarkGray'; Link = 'DarkGray'; Url = 'DarkGray' }
            foreach ($r in (Split-WtWrappedSegments -Parts (Split-WtRichInline -Text ([string]$Block.Text)) -Width $Width -Indent ($Indent + 2) -Colors $colors)) { $rows.Add($r) }
        }
        'Bullet' {
            $lead = [string]$Glyphs.ListBullet + ' '
            foreach ($r in (Split-WtWrappedSegments -Parts (Split-WtRichInline -Text ([string]$Block.Text)) -Width $Width -Indent ($Indent + 2) -Hanging $lead.Length -Prefix $lead -PrefixFg 'Gray')) { $rows.Add($r) }
        }
        'Numbered' {
            $lead = [string]$Block.Marker + ' '
            foreach ($r in (Split-WtWrappedSegments -Parts (Split-WtRichInline -Text ([string]$Block.Text)) -Width $Width -Indent ($Indent + 2) -Hanging $lead.Length -Prefix $lead -PrefixFg 'Gray')) { $rows.Add($r) }
        }
        default {
            foreach ($r in (Split-WtWrappedSegments -Parts (Split-WtRichInline -Text ([string]$Block.Text)) -Width $Width -Indent $Indent)) { $rows.Add($r) }
        }
    }
    return , $rows.ToArray()
}

function Get-WtRichLines {
    <#
    .SYNOPSIS
        PURE: a whole answer (the raw text as the model wrote it) into
        printable rows. The streaming path calls Get-WtRichBlock and
        Get-WtRichBlockRows itself, one completed line at a time; this is
        the batch door used for reprints and for the low mode.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [int]$Width = 80,
        [int]$Indent = 0,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $state = @{ InFence = $false }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($raw in (([string]$Text).Split([char]10))) {
        $line = ([string]$raw).TrimEnd([char]13)
        $block = Get-WtRichBlock -Line $line -State $state
        $state = $block.State
        foreach ($r in (Get-WtRichBlockRows -Block $block -Width $Width -Indent $Indent -Glyphs $Glyphs)) { $rows.Add($r) }
    }
    return , $rows.ToArray()
}
