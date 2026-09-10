# The pure side of the assistant's plain-console REPL: formatters, the
# line-editor reducer, the key-to-token map, the command classifier and
# the slash-command table. Nothing here touches the console.
# Covered by: tests/ReplState.Tests.ps1

function Format-WtReplNumber {
    <#
    .SYNOPSIS
        One decimal, invariant digits, a comma as the decimal mark (e.g.
        "0,4 s"): never the thread culture, which would flip the mark
        with the user's locale.
    #>
    param([double]$Value)
    return ([Math]::Round($Value, 1)).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
}

function Format-WtReplTokenCount {
    <#
    .SYNOPSIS
        PURE: a token count with a dot as the thousands mark (e.g.
        "4.312"), invariant digits - never the thread culture.
    #>
    param([int]$Value)
    return $Value.ToString('#,0', [System.Globalization.CultureInfo]::InvariantCulture).Replace(',', '.')
}

function Format-WtReplUsageLine {
    <#
    .SYNOPSIS
        PURE: the /durum line for the last turn's token usage: input /
        output, plus the cached count only when the server reported one;
        a missing or empty usage says so instead of printing zeros.
    #>
    param([AllowNull()]$Usage)
    if ($null -eq $Usage -or [int]$Usage.Rounds -le 0) { return [string](Get-Translation 'AsStatusUsageNone') }
    $cache = ''
    if ([int]$Usage.CachedTokens -gt 0) { $cache = [string]((Get-Translation 'AsStatusUsageCache') -f (Format-WtReplTokenCount -Value ([int]$Usage.CachedTokens))) }
    return [string]((Get-Translation 'AsStatusUsage') -f (Format-WtReplTokenCount -Value ([int]$Usage.PromptTokens)), (Format-WtReplTokenCount -Value ([int]$Usage.CompletionTokens)), $cache)
}

function ConvertTo-WtReplArgText {
    <#
    .SYNOPSIS
        PURE, recursive: one parsed JSON value as compact prose for the
        tool start line. Objects become "key: value" pairs (nested
        objects collapse to {...}), arrays "[a, b, +N]", strings bare,
        booleans lower-case. Depth 0 is the argument object itself.
    #>
    param($Value, [int]$Depth = 0, [int]$MaxItems = 3)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject]) {
        if ($Depth -ge 1) { return '{...}' }
        $pairs = New-Object System.Collections.Generic.List[string]
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($k in $Value.Keys) { $pairs.Add([string]$k + ': ' + (ConvertTo-WtReplArgText -Value $Value[$k] -Depth ($Depth + 1) -MaxItems $MaxItems)) }
        }
        else {
            foreach ($p in $Value.PSObject.Properties) { $pairs.Add([string]$p.Name + ': ' + (ConvertTo-WtReplArgText -Value $p.Value -Depth ($Depth + 1) -MaxItems $MaxItems)) }
        }
        return ($pairs.ToArray() -join ', ')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        $shown = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt [Math]::Min($items.Count, $MaxItems); $i++) { $shown.Add((ConvertTo-WtReplArgText -Value $items[$i] -Depth ($Depth + 1) -MaxItems $MaxItems)) }
        if ($items.Count -gt $MaxItems) { $shown.Add('+' + ($items.Count - $MaxItems)) }
        return ('[' + ($shown.ToArray() -join ', ') + ']')
    }
    return [string]$Value
}

function Format-WtReplToolArgs {
    param([AllowNull()][AllowEmptyString()][string]$ArgumentsJson = '')
    $text = ([string]$ArgumentsJson).Trim()
    if (-not $text -or $text -eq '{}') { return '' }
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch { return $text }
    return [string](ConvertTo-WtReplArgText -Value $parsed -Depth 0)
}

function Format-WtReplToolStart {
    <#
    .SYNOPSIS
        The line a tool call opens with: "  * name(args)". One line, no
        newlines, clamped to Width-1 with a '~' tail (the frames' cut
        mark) so the console never wraps it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$ArgumentsJson = '',
        [int]$Width = 0,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $text = '  ' + [string]$Glyphs.Bullet + ' ' + $Name + '(' + (Format-WtReplToolArgs -ArgumentsJson $ArgumentsJson) + ')'
    $text = $text.Replace("`r", ' ').Replace("`n", ' ')
    if ($Width -gt 2 -and $text.Length -gt ($Width - 1)) { $text = $text.Substring(0, $Width - 2) + '~' }
    return $text
}

function Format-WtReplToolResult {
    <#
    .SYNOPSIS
        The branch line under a tool call: "    \ 0,4 s - 1,8 KB"; a
        failed call carries a "! " mark after the branch.
    #>
    param([double]$Seconds = 0, [int]$Chars = 0, [bool]$Ok = $true, [PSCustomObject]$Glyphs = $script:WtGlyphs)
    $mark = $(if ($Ok) { '' } else { '! ' })
    return ('    ' + [string]$Glyphs.Branch + ' ' + $mark + (Format-WtReplNumber -Value $Seconds) + ' s ' + [string]$Glyphs.Dot + ' ' + (Format-WtReplNumber -Value ([double]$Chars / 1024)) + ' KB')
}

function Format-WtReplToolLines {
    <#
    .SYNOPSIS
        A header under the branch mark, then the last Max output lines
        indented under it, and a "(+N lines ...)" note when more were
        cut. Max 0 (or less) means every line, no note.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Header,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [int]$Max = 5,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('    ' + [string]$Glyphs.Branch + ' ' + $Header)
    $rows = @($Lines)
    $start = $(if ($Max -le 0) { 0 } else { [Math]::Max(0, $rows.Count - $Max) })
    for ($i = $start; $i -lt $rows.Count; $i++) { $out.Add('      ' + [string]$rows[$i]) }
    if ($start -gt 0) { $out.Add('      ' + ((Get-Translation 'AsReplMoreLines') -f $start)) }
    return [string[]]$out.ToArray()
}

function Format-WtReplToolRunLines {
    <#
    .SYNOPSIS
        PURE: a tool row the USER ran by number, shaped like a tool call
        the model made: "  * <label>" on the bullet line (the row's own
        name, no arguments), the outcome under the branch, then the tail
        of the output through Format-WtReplToolLines' rules.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Status,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [int]$Max = 5,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('  ' + [string]$Glyphs.Bullet + ' ' + ([string]$Label).Replace("`r", ' ').Replace("`n", ' '))
    foreach ($l in @(Format-WtReplToolLines -Header $Status -Lines $Lines -Max $Max -Glyphs $Glyphs)) { $out.Add([string]$l) }
    return [string[]]$out.ToArray()
}

function Format-WtReplSpinnerLine {
    <#
    .SYNOPSIS
        PURE: the "working" status row - label, whole seconds, streamed
        size, the Esc hint. No animated glyph: braille frames render at
        another width on some console fonts and bend the box edge, and a
        once-a-second row lets the painter leave the screen alone.
    #>
    param(
        [AllowEmptyString()][string]$Label = '',
        [double]$Seconds = 0,
        [int]$Chars = 0,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $dot = ' ' + [string]$Glyphs.Dot + ' '
    $parts = @(([string][int][Math]::Floor($Seconds)) + ' s')
    if ($Chars -gt 0) { $parts += @((Format-WtReplNumber -Value ([double]$Chars / 1024)) + ' KB') }
    $parts += @([string](Get-Translation 'AsSpinTail'))
    return ($Label + ' (' + ($parts -join $dot) + ')')
}

function Get-WtReplStatusLeft {
    <#
    .SYNOPSIS
        PURE: the left half of the status line under the input box - the
        model, where it runs, how full the context is and what the
        assistant remembers. Parts fall off from the END as the window
        narrows; the model name never falls off.
    #>
    param(
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$WhereTag = '',
        [int]$Percent = 0,
        [int]$MessageCount = -1,
        [int]$NoteCount = -1,
        [int]$PermCount = -1,
        [int]$Width = 80,
        [int]$Reserve = 0,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $name = $(if ($Model) { $Model } else { [string](Get-Translation 'AsNotSet') })
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($name)
    if ($WhereTag) { $parts.Add([string]$WhereTag) }
    $parts.Add(((Get-Translation 'AsStatusContextShort') -f $Percent))
    if ($MessageCount -ge 0) { $parts.Add(((Get-Translation 'AsStatusMessagesShort') -f $MessageCount)) }
    if ($NoteCount -gt 0) { $parts.Add(((Get-Translation 'AsStatusNotesShort') -f $NoteCount)) }
    if ($PermCount -gt 0) { $parts.Add(((Get-Translation 'AsStatusPermsShort') -f $PermCount)) }

    $sep = ' ' + [string]$Glyphs.Dot + ' '
    $budget = [Math]::Max(8, $Width - 5 - $Reserve)
    while ($parts.Count -gt 1) {
        if ((($parts.ToArray()) -join $sep).Length -le $budget) { break }
        $parts.RemoveAt($parts.Count - 1)
    }
    return (($parts.ToArray()) -join $sep)
}

function Get-WtReplStatusRight {
    param([PSCustomObject]$Glyphs = $script:WtGlyphs)
    return (@((Get-Translation 'AsStatusHintEnter'), (Get-Translation 'AsStatusHintEsc'), (Get-Translation 'AsStatusHintHelp')) -join (' ' + [string]$Glyphs.Dot + ' '))
}

function Format-WtReplStatusLine {
    <#
    .SYNOPSIS
        PURE: the one-line status under the input box, two spaces in,
        left text then the right-hand hints right-aligned - dropped
        whole when they do not fit. Exactly Width-1 wide at most.
    #>
    param(
        [AllowEmptyString()][string]$Left = '',
        [AllowEmptyString()][string]$Right = '',
        [int]$Width = 80
    )
    $w = [Math]::Max(20, $Width - 1)
    $line = '  ' + $Left
    if ($Right -and ($line.Length + 2 + $Right.Length) -le $w) { $line = $line + (' ' * ($w - $line.Length - $Right.Length)) + $Right }
    if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
    return $line
}

function Get-WtReplContextPercent {
    <#
    .SYNOPSIS
        How full the model context is, as the trimming cap sees it:
        message chars over MaxChars, clamped to 0..100.
    #>
    param(
        [AllowEmptyCollection()][array]$Messages = @(),
        [int]$MaxChars = 60000
    )
    if ($MaxChars -le 0) { return 0 }
    $total = 0
    foreach ($message in @($Messages)) { $total += Get-WtAssistantMessageChars -Message $message }
    return [int][Math]::Min(100, [Math]::Round(100.0 * $total / $MaxChars))
}

function ConvertTo-WtReplKeyToken {
    <#
    .SYNOPSIS
        One ConsoleKeyInfo (passed as strings so tests need no console)
        into the REPL editor's token: navigation keys by ConsoleKey name,
        printable characters as Key='Char', Ctrl+letter as the letter
        with Ctrl set. Burst marks a key that arrived with more keys
        already queued (a paste).
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][AllowEmptyString()][string]$KeyChar = '',
        [AllowNull()][AllowEmptyString()][string]$Modifiers = '',
        [bool]$Burst = $false
    )
    $ctrl = (([string]$Modifiers).IndexOf('Control', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    $named = @('Enter', 'Escape', 'Backspace', 'Delete', 'LeftArrow', 'RightArrow', 'Home', 'End', 'UpArrow', 'DownArrow', 'Tab', 'PageUp', 'PageDown')
    if ($named -contains $Key) { return @{ Key = $Key; Char = ''; Ctrl = $ctrl; Burst = $Burst } }
    if ($ctrl) { return @{ Key = $Key; Char = ''; Ctrl = $true; Burst = $Burst } }
    $text = [string]$KeyChar
    if ($text.Length -eq 1 -and -not [char]::IsControl($text[0])) { return @{ Key = 'Char'; Char = $text; Ctrl = $false; Burst = $Burst } }
    return @{ Key = 'None'; Char = ''; Ctrl = $ctrl; Burst = $Burst }
}

function New-WtReplLineState {
    param([AllowEmptyCollection()][string[]]$History = @())
    return @{ Text = ''; Cursor = 0; History = [string[]]@($History); HistIdx = -1; Draft = ''; Popup = @(); PopupIndex = 0 }
}

function Update-WtReplLine {
    <#
    .SYNOPSIS
        The line editor. Pure: returns a copy. Enter submits (a newline
        inside a paste burst instead), Esc clears then cancels, Ctrl+C
        is its own emit, and Up/Down walk history newest-first with the
        draft preserved across the walk.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Token
    )
    $s = @{}
    foreach ($key in $State.Keys) { $s[$key] = $State[$key] }
    $done = { param($Emit)
        $s.Popup = @(Get-WtReplSlashMatches -Text ([string]$s.Text))
        if ($s.Popup.Count -eq 0) { $s.PopupIndex = 0 }
        elseif ([int]$s.PopupIndex -ge $s.Popup.Count) { $s.PopupIndex = $s.Popup.Count - 1 }
        return @{ State = $s; Emit = $Emit }
    }
    $text = [string]$s.Text
    $cursor = [int]$s.Cursor
    $insert = { param([string]$Piece)
        $s.Text = $text.Substring(0, $cursor) + $Piece + $text.Substring($cursor)
        $s.Cursor = $cursor + $Piece.Length
        $s.HistIdx = -1
    }
    $popup = @($State.Popup)
    $popupOpen = ($popup.Count -gt 0)
    $complete = { param([bool]$TrailingSpace)
        $pick = $popup[[Math]::Max(0, [Math]::Min([int]$State.PopupIndex, $popup.Count - 1))]
        $s.Text = '/' + [string]$pick.Alias + $(if ($TrailingSpace) { ' ' } else { '' })
        $s.Cursor = $s.Text.Length
        $s.HistIdx = -1
    }
    if ([string]$Token.Key -eq 'Paste') {
        $piece = ([string]$Token.Text).Replace("`r`n", "`n").Replace("`r", "`n")
        if ($piece) { & $insert $piece }
        return (& $done 'None')
    }
    if ($Token.Ctrl) {
        if ([string]$Token.Key -eq 'C') { return (& $done 'CtrlC') }
        return (& $done 'None')
    }
    switch ([string]$Token.Key) {
        'Char' { & $insert ([string]$Token.Char); return (& $done 'None') }
        'Enter' {
            if ($Token.Burst) { & $insert "`n"; return (& $done 'None') }
            if ($popupOpen) { & $complete $false; return (& $done 'Submit') }
            if ($text.EndsWith('\', [System.StringComparison]::Ordinal) -and $cursor -eq $text.Length) {
                $s.Text = $text.Substring(0, $text.Length - 1) + "`n"
                $s.Cursor = $s.Text.Length
                $s.HistIdx = -1
                return (& $done 'None')
            }
            return (& $done 'Submit')
        }
        'Tab' {
            if ($popupOpen) { & $complete $true }
            return (& $done 'None')
        }
        'Escape' {
            if ($text.Length -eq 0) { return (& $done 'Cancel') }
            $s.Text = ''; $s.Cursor = 0; $s.HistIdx = -1
            return (& $done 'Clear')
        }
        'Backspace' {
            if ($cursor -gt 0) { $s.Text = $text.Substring(0, $cursor - 1) + $text.Substring($cursor); $s.Cursor = $cursor - 1; $s.HistIdx = -1 }
            return (& $done 'None')
        }
        'Delete' {
            if ($cursor -lt $text.Length) { $s.Text = $text.Substring(0, $cursor) + $text.Substring($cursor + 1); $s.HistIdx = -1 }
            return (& $done 'None')
        }
        'LeftArrow' { if ($cursor -gt 0) { $s.Cursor = $cursor - 1 }; return (& $done 'None') }
        'RightArrow' { if ($cursor -lt $text.Length) { $s.Cursor = $cursor + 1 }; return (& $done 'None') }
        'Home' { $s.Cursor = 0; return (& $done 'None') }
        'End' { $s.Cursor = $text.Length; return (& $done 'None') }
        'UpArrow' {
            if ($popupOpen) { $s.PopupIndex = [Math]::Max(0, [int]$State.PopupIndex - 1); return (& $done 'None') }
            $history = [string[]]@($s.History)
            if ($history.Count -eq 0) { return (& $done 'None') }
            $index = [int]$s.HistIdx
            if ($index -lt 0) { $s.Draft = $text; $index = $history.Count - 1 }
            elseif ($index -gt 0) { $index-- }
            $s.HistIdx = $index
            $s.Text = [string]$history[$index]
            $s.Cursor = $s.Text.Length
            return (& $done 'None')
        }
        'DownArrow' {
            if ($popupOpen) { $s.PopupIndex = [Math]::Min($popup.Count - 1, [int]$State.PopupIndex + 1); return (& $done 'None') }
            $history = [string[]]@($s.History)
            $index = [int]$s.HistIdx
            if ($index -lt 0) { return (& $done 'None') }
            if ($index -lt ($history.Count - 1)) { $index++; $s.HistIdx = $index; $s.Text = [string]$history[$index] }
            else { $s.HistIdx = -1; $s.Text = [string]$s.Draft }
            $s.Cursor = $s.Text.Length
            return (& $done 'None')
        }
    }
    return (& $done 'None')
}

function Get-WtReplLineRender {
    <#
    .SYNOPSIS
        PURE: what one repaint of the edit line prints (prompt + the
        visible slice of the text, LF shown as the newline mark) and
        where the caret goes. A line longer than the console slides so
        the caret stays visible - the input line is never wrapped.
    #>
    param(
        [AllowEmptyString()][string]$Prompt = '> ',
        [AllowEmptyString()][string]$Text = '',
        [int]$Cursor = 0,
        [int]$Width = 80,
        [string]$NewlineMark = ([string][char]0xB6)
    )
    if ($Prompt.Length -ge $Width - 1) { $Prompt = $Prompt.Substring(0, [Math]::Max(0, $Width - 2)) }
    $shown = ([string]$Text).Replace("`n", $NewlineMark)
    $room = [Math]::Max(1, $Width - 1 - $Prompt.Length)
    $cursor = [Math]::Max(0, [Math]::Min($Cursor, $shown.Length))
    $offset = 0
    if ($cursor -ge $room) { $offset = $cursor - $room + 1 }
    $slice = $shown.Substring($offset, [Math]::Min($room, $shown.Length - $offset))
    return @{ Line = ($Prompt + $slice); CursorCol = ($Prompt.Length + $cursor - $offset); Offset = $offset }
}

function Get-WtReplSlashTable {
    <#
    .SYNOPSIS
        The slash commands as data: canonical name, the Turkish and
        English words that reach it, and the help line's key. /temizle
        and /clear are the SAME command as /yeni: a cleared screen with
        the old context still behind it was two commands the user had to
        tell apart, and the ask was one - a fresh page AND a fresh
        conversation.
    #>
    return @(
        @{ Name = 'new';      Aliases = @('yeni', 'new', 'temizle', 'clear');   HelpKey = 'AsSlashNew' }
        @{ Name = 'model';    Aliases = @('model');                            HelpKey = 'AsSlashModel' }
        @{ Name = 'endpoint'; Aliases = @('uc', 'endpoint');                    HelpKey = 'AsSlashEndpoint' }
        @{ Name = 'key';      Aliases = @('anahtar', 'key');                    HelpKey = 'AsSlashKey' }
        @{ Name = 'scan';     Aliases = @('tara', 'scan');                      HelpKey = 'AsSlashScan' }
        @{ Name = 'test';     Aliases = @('sina', 'test');                      HelpKey = 'AsSlashTest' }
        @{ Name = 'settings'; Aliases = @('ayarlar', 'settings', 'config');     HelpKey = 'AsSlashSettings' }
        @{ Name = 'perms';    Aliases = @('izinler', 'perms');                  HelpKey = 'AsSlashPerms' }
        @{ Name = 'tools';    Aliases = @('araclar', 'tools');                  HelpKey = 'AsSlashTools' }
        @{ Name = 'profile';  Aliases = @('profil', 'profile');                 HelpKey = 'AsSlashProfile' }
        @{ Name = 'notes';    Aliases = @('notlar', 'notes');                   HelpKey = 'AsSlashNotes' }
        @{ Name = 'status';   Aliases = @('durum', 'status');                   HelpKey = 'AsSlashStatus' }
        @{ Name = 'save';     Aliases = @('kaydet', 'save');                    HelpKey = 'AsSlashSave' }
        @{ Name = 'copy';     Aliases = @('kopyala', 'copy');                   HelpKey = 'AsSlashCopy' }
        @{ Name = 'forget';   Aliases = @('unut', 'forget');                    HelpKey = 'AsSlashForget' }
        @{ Name = 'help';     Aliases = @('yardim', 'help');                    HelpKey = 'AsSlashHelp' }
        @{ Name = 'quit';     Aliases = @('cik', 'quit', 'cikis', 'exit', 'q'); HelpKey = 'AsSlashQuit' }
    )
}

function Resolve-WtReplSlash {
    param([AllowNull()][AllowEmptyString()][string]$Word)
    $folded = ConvertTo-WtAssistantSearchText -Text ([string]$Word)
    foreach ($row in @(Get-WtReplSlashTable)) {
        foreach ($alias in @($row.Aliases)) {
            if ([string]::Equals($alias, $folded, [System.StringComparison]::Ordinal)) { return [string]$row.Name }
        }
    }
    return ''
}

function Get-WtReplHelpLines {
    <#
    .SYNOPSIS
        PURE: one help row per slash command - every alias, then the
        description. No leading indent: Write-WtReplLine puts every
        slash-command line in the page margin itself.
    #>
    return [string[]]@(foreach ($row in @(Get-WtReplSlashTable)) {
        (((@($row.Aliases) | ForEach-Object { '/' + [string]$_ }) -join ', ') + ' - ' + [string](Get-Translation ([string]$row.HelpKey)))
    })
}

function Get-WtReplSlashMatches {
    <#
    .SYNOPSIS
        PURE: the popup rows for what is typed so far - only a bare
        "/word" has one, matched by folded alias prefix, each command
        once, capped at 8. Returns a plain array, not "return , $x":
        Hashtable's own [0] indexer would collapse a size-1
        comma-guarded array to $null.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text = '')
    $text = [string]$Text
    if (-not $text.StartsWith('/', [System.StringComparison]::Ordinal)) { return @() }
    if ($text -cmatch '\s') { return @() }
    $word = ConvertTo-WtAssistantSearchText -Text $text.Substring(1)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in @(Get-WtReplSlashTable)) {
        foreach ($alias in @($row.Aliases)) {
            $folded = ConvertTo-WtAssistantSearchText -Text ([string]$alias)
            if ($folded.StartsWith($word, [System.StringComparison]::Ordinal)) {
                $rows.Add([PSCustomObject]@{ Name = [string]$row.Name; Alias = [string]$alias; Help = [string](Get-Translation ([string]$row.HelpKey)) })
                break
            }
        }
        if ($rows.Count -ge 8) { break }
    }
    return $rows.ToArray()
}

function Get-WtReplPopupRows {
    <#
    .SYNOPSIS
        PURE: the popup as segment rows under the input box - the
        highlighted alias in yellow behind the cursor glyph, the rest
        grey, the help text dark grey. Each row is clamped to Width-1.
        Returns a plain array, not "return , $x" (see
        Get-WtReplSlashMatches).
    #>
    param(
        [AllowEmptyCollection()][array]$Popup = @(),
        [int]$Index = 0,
        [int]$Width = 80,
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $w = [Math]::Max(20, $Width - 1)
    $rows = New-Object System.Collections.Generic.List[object]
    $items = @($Popup)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $selected = ($i -eq $Index)
        $lead = '  ' + $(if ($selected) { [string]$Glyphs.Cursor } else { '  ' })
        $alias = ('/' + [string]$items[$i].Alias).PadRight(12)
        $help = [string]$items[$i].Help
        $room = $w - $lead.Length - $alias.Length
        if ($help.Length -gt $room) { $help = $(if ($room -gt 1) { $help.Substring(0, $room - 1) + '~' } else { '' }) }
        $rows.Add(@(
            New-WtSeg -Text $lead -Fg $(if ($selected) { 'Yellow' } else { 'Gray' })
            New-WtSeg -Text $alias -Fg $(if ($selected) { 'Yellow' } else { 'Gray' })
            New-WtSeg -Text $help -Fg 'DarkGray'
        ))
    }
    return $rows.ToArray()
}

function ConvertTo-WtReplCommand {
    <#
    .SYNOPSIS
        What a submitted line means: digits-only is a suggestion index
        (Unknown if out of range), a leading slash is a local command
        (Unknown if unmatched), a bare /yeni word (yeni, new, temizle,
        clear) is 'Slash' new so "clear" never reaches the model, a bare
        /cik word (q, quit, exit, cik, cikis) is a 'Hint' rather than
        being sent to the model or dropping the conversation, anything
        else is 'Send', and $null is 'Eof'. Digits are matched with [0-9],
        never \d, which admits every Unicode digit and would make [int]
        throw on a full-width one.
    #>
    param(
        [AllowNull()][object]$Line,
        [int]$SuggestionCount = 0
    )
    $none = @{ Kind = 'None'; Text = ''; Index = 0; Command = ''; Argument = '' }
    if ($null -eq $Line) { $none.Kind = 'Eof'; return $none }
    $text = ([string]$Line).Trim()
    if ($text -eq '') { return $none }
    if ($text.IndexOf(' ') -lt 0) {
        $bareWord = Resolve-WtReplSlash -Word $text
        if ($bareWord -eq 'new') { return @{ Kind = 'Slash'; Text = $text; Index = 0; Command = 'new'; Argument = '' } }
        if ($bareWord -eq 'quit') { return @{ Kind = 'Hint'; Text = $text; Index = 0; Command = 'quit'; Argument = '' } }
    }
    if ($text -cmatch '^[0-9]{1,2}\z') {
        $index = [int]$text
        $kind = $(if ($index -ge 1 -and $index -le $SuggestionCount) { 'Suggest' } else { 'Unknown' })
        return @{ Kind = $kind; Text = $text; Index = $index; Command = ''; Argument = '' }
    }
    if ($text.StartsWith('/', [System.StringComparison]::Ordinal)) {
        $body = $text.Substring(1).Trim()
        $word = $body
        $argument = ''
        $space = $body.IndexOf(' ')
        if ($space -ge 0) { $word = $body.Substring(0, $space); $argument = $body.Substring($space + 1).Trim() }
        $name = Resolve-WtReplSlash -Word $word
        if ($name) { return @{ Kind = 'Slash'; Text = $text; Index = 0; Command = $name; Argument = $argument } }
        return @{ Kind = 'Unknown'; Text = $text; Index = 0; Command = $word; Argument = $argument }
    }
    return @{ Kind = 'Send'; Text = $text; Index = 0; Command = ''; Argument = '' }
}

function New-WtReplSession {
    <#
    .SYNOPSIS
        One conversation: the model messages (OpenAI array, never
        reformatted), the transcript entries the console already
        printed, the current suggestions, the input history and the
        Ctrl+C double-press clock.
    #>
    return @{
        Messages    = (New-Object System.Collections.Generic.List[object])
        Entries     = (New-Object System.Collections.Generic.List[object])
        Suggestions = @()
        History     = (New-Object System.Collections.Generic.List[string])
        LastCtrlC   = [datetime]::MinValue
        LastEsc     = [datetime]::MinValue
        EscCount    = 0
        Busy        = $false
        ProfileEnabled = $true
        SystemExtra = $null
        Schemas     = $null
        Disabled    = $null
        PendingNotes = (New-Object System.Collections.Generic.List[string])
        FollowUp    = ''
        ClientCompat = @{}
        SessionId   = [string][guid]::NewGuid()
        LastUsage = $null
        HistoryMaxChars = 0
    }
}

function Add-WtChatEntry {
    <#
    .SYNOPSIS
        Appends a transcript entry; while the REPL owns the console it
        is printed at once (append-only), unless -Silent says the text
        is already on screen (a streamed answer).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('User', 'Assistant', 'Tool', 'Error', 'Info')][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [switch]$Silent
    )
    $State.Entries.Add(@{ Kind = $Kind; Text = [string]$Text })
    if ($script:WtReplMode -and -not $Silent) { Write-WtReplEntry -Kind $Kind -Text ([string]$Text) }
}

function Get-WtReplBoxRows {
    <#
    .SYNOPSIS
        PURE: a bordered box as segment rows, Width-1 wide, the title
        set into the top border ("+- Title ---+"). Each content row is
        "| " + segments + padding + " |"; a row wider than the inside is
        cut with '~' (the frames' cut mark). Fg colours the border.
    #>
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyCollection()][array]$Rows = @(),
        [int]$Width = 80,
        [PSCustomObject]$Glyphs = $script:WtGlyphs,
        [string]$Fg = 'Cyan'
    )
    $w = [Math]::Max(20, $Width - 1)
    $inner = $w - 4
    $out = New-Object System.Collections.Generic.List[object]
    $top = [string]$Glyphs.TL + [string]$Glyphs.H
    if ($Title) {
        $t = ' ' + $Title + ' '
        if ($t.Length -gt ($w - 4)) { $t = $t.Substring(0, $w - 5) + '~ ' }
        $top += $t
    }
    $top += ([string]$Glyphs.H * ($w - 1 - $top.Length)) + [string]$Glyphs.TR
    $out.Add(@(, (New-WtSeg -Text $top -Fg $Fg)))
    foreach ($row in @($Rows)) {
        $segs = New-Object System.Collections.Generic.List[object]
        $used = 0
        foreach ($seg in @($row)) {
            $text = [string]$seg.T
            if (($used + $text.Length) -gt $inner) {
                $room = $inner - $used
                $text = $(if ($room -gt 1) { $text.Substring(0, $room - 1) + '~' } elseif ($room -eq 1) { '~' } else { '' })
            }
            if ($text.Length -gt 0) { $segs.Add((New-WtSeg -Text $text -Fg ([string]$seg.F) -Bg ([string]$seg.B))); $used += $text.Length }
            if ($used -ge $inner) { break }
        }
        $line = New-Object System.Collections.Generic.List[object]
        $line.Add((New-WtSeg -Text ([string]$Glyphs.V + ' ') -Fg $Fg))
        foreach ($s in $segs) { $line.Add($s) }
        $line.Add((New-WtSeg -Text ((' ' * ($inner - $used)) + ' ' + [string]$Glyphs.V) -Fg $Fg))
        $out.Add($line.ToArray())
    }
    $out.Add(@(, (New-WtSeg -Text ([string]$Glyphs.BL + ([string]$Glyphs.H * ($w - 2)) + [string]$Glyphs.BR) -Fg $Fg)))
    return $out.ToArray()
}

function Get-WtReplInputLines {
    <#
    .SYNOPSIS
        PURE: the three rows of the input box and where the caret sits.
        The text slides through Get-WtReplLineRender so the caret is
        always visible; an empty line shows the placeholder dimmed.
    #>
    param(
        [AllowEmptyString()][string]$Prompt = '> ',
        [AllowEmptyString()][string]$Text = '',
        [int]$Cursor = 0,
        [int]$Width = 80,
        [PSCustomObject]$Glyphs = $script:WtGlyphs,
        [AllowEmptyString()][string]$Placeholder = (Get-Translation 'AsReplPlaceholder')
    )
    $w = [Math]::Max(20, $Width - 1)
    $inner = $w - 4
    $shown = $Text
    $fg = 'White'
    $cursor = $Cursor
    if (-not $Text -and $Placeholder) { $shown = $Placeholder; $fg = 'DarkGray'; $cursor = 0 }
    $render = Get-WtReplLineRender -Prompt $Prompt -Text $shown -Cursor $cursor -Width ($inner + 1)
    $line = [string]$render.Line
    $promptPart = $line.Substring(0, [Math]::Min($Prompt.Length, $line.Length))
    $textPart = $(if ($line.Length -gt $Prompt.Length) { $line.Substring($Prompt.Length) } else { '' })
    $rows = Get-WtReplBoxRows -Title '' -Rows @(, @((New-WtSeg -Text $promptPart -Fg 'Cyan'), (New-WtSeg -Text $textPart -Fg $fg))) -Width $Width -Glyphs $Glyphs
    return @{ Rows = $rows; CaretRow = 1; CaretCol = (2 + [int]$render.CursorCol) }
}

function New-WtReplPickState {
    param(
        [AllowEmptyCollection()][array]$Options = @(),
        [AllowEmptyString()][string]$TextOption = ''
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($o in @($Options)) {
        if ($o -is [string]) { $rows.Add(@{ Label = [string]$o; Hotkey = ''; IsText = $false }) }
        else { $rows.Add(@{ Label = [string]$o.Label; Hotkey = [string]$o.Hotkey; IsText = $false }) }
    }
    if ($TextOption) { $rows.Add(@{ Label = $TextOption; Hotkey = ''; IsText = $true }) }
    return @{ Rows = $rows.ToArray(); Index = 0; WindowStart = 0 }
}

function Update-WtReplPickState {
    <#
    .SYNOPSIS
        PURE: the selector reducer. Arrows/Home/End/PageUp/PageDown move,
        Enter picks the current row, a digit 1-9 picks that row, a
        hotkey letter picks its row (OrdinalIgnoreCase - never ToUpper
        under tr-TR), Esc and Ctrl+C cancel.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Token)
    $s = @{}
    foreach ($key in $State.Keys) { $s[$key] = $State[$key] }
    $rows = @($s.Rows)
    $last = [Math]::Max(0, $rows.Count - 1)
    $index = [int]$s.Index
    $done = { param($Emit) return @{ State = $s; Emit = $Emit } }
    if ($Token.Ctrl) {
        if ([string]$Token.Key -eq 'C') { return (& $done 'Cancel') }
        return (& $done 'None')
    }
    switch ([string]$Token.Key) {
        'UpArrow' { $s.Index = [Math]::Max(0, $index - 1); return (& $done 'None') }
        'DownArrow' { $s.Index = [Math]::Min($last, $index + 1); return (& $done 'None') }
        'Home' { $s.Index = 0; return (& $done 'None') }
        'End' { $s.Index = $last; return (& $done 'None') }
        'PageUp' { $s.Index = [Math]::Max(0, $index - 10); return (& $done 'None') }
        'PageDown' { $s.Index = [Math]::Min($last, $index + 10); return (& $done 'None') }
        'Enter' { if ($rows.Count -gt 0) { return (& $done 'Pick') }; return (& $done 'Cancel') }
        'Escape' { return (& $done 'Cancel') }
        'Char' {
            $c = [string]$Token.Char
            if ($c -cmatch '^[1-9]$') {
                $n = [int]$c
                if ($n -le $rows.Count) { $s.Index = $n - 1; return (& $done 'Pick') }
                return (& $done 'None')
            }
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $hot = [string]$rows[$i].Hotkey
                if ($hot -and [string]::Equals($hot, $c, [System.StringComparison]::OrdinalIgnoreCase)) { $s.Index = $i; return (& $done 'Pick') }
            }
            return (& $done 'None')
        }
    }
    return (& $done 'None')
}

function Get-WtReplQuestionRows {
    <#
    .SYNOPSIS
        PURE: question lines wrapped to the INSIDE of a REPL box, as
        segment rows - needed because Get-WtReplBoxRows just cuts an
        overlong row with '~', which mangles long consent text. A blank
        line stays blank, a "- " bullet keeps a hanging indent, and
        every other line word-wraps at the inside width.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [int]$Width = 80,
        [string]$Fg = 'White'
    )
    $inner = [Math]::Max(20, $Width - 1) - 4
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($raw in @($Lines)) {
        $line = [string]$raw
        if ($line.Trim().Length -eq 0) { $rows.Add(@(, (New-WtSeg -Text '' -Fg 'Gray'))); continue }
        $lead = $line.Length - $line.TrimStart().Length
        $body = $line.TrimStart()
        $marker = ''
        if ($body.StartsWith('- ', [System.StringComparison]::Ordinal)) { $marker = '- '; $body = $body.Substring(2) }
        $indent = ' ' * $lead
        $room = [Math]::Max(8, $inner - $lead - $marker.Length)
        $first = $true
        foreach ($piece in @(Split-WtWrappedLines -Text $body -Width $room)) {
            $prefix = $indent + $(if ($first) { $marker } else { ' ' * $marker.Length })
            $rows.Add(@(, (New-WtSeg -Text ($prefix + [string]$piece) -Fg $Fg)))
            $first = $false
        }
    }
    return $rows.ToArray()
}

function Get-WtReplPickLines {
    <#
    .SYNOPSIS
        PURE: the selector box: title in the border, the question lines
        (wrapped to the box through Get-WtReplQuestionRows), a blank row,
        the option rows (cursor glyph on the selected one, "(h)" after a
        hotkey label), then the key hint. Tall lists are windowed around
        the selection. Risk colours the border.
    #>
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][hashtable]$State,
        [int]$Width = 80,
        [PSCustomObject]$Glyphs = $script:WtGlyphs,
        [AllowEmptyString()][string]$Risk = '',
        [int]$ViewHeight = 10
    )
    $fg = switch ($Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'Cyan' } }
    $textFg = switch ($Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'White' } }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-WtReplQuestionRows -Lines $Lines -Width $Width -Fg $textFg)) { $rows.Add($r) }
    if (@($Lines).Count -gt 0) { $rows.Add(@(, (New-WtSeg -Text '' -Fg 'Gray'))) }
    $items = @($State.Rows)
    $view = [Math]::Max(1, [Math]::Min($ViewHeight, $items.Count))
    $start = Get-WtViewportWindow -ItemCount $items.Count -CursorIndex ([int]$State.Index) -ViewHeight $view -WindowStart ([int]$State.WindowStart)
    for ($i = $start; $i -lt [Math]::Min($start + $view, $items.Count); $i++) {
        $selected = ($i -eq [int]$State.Index)
        $label = [string]$items[$i].Label
        if ([string]$items[$i].Hotkey) { $label += ' (' + ([string]$items[$i].Hotkey).ToLowerInvariant() + ')' }
        $lead = $(if ($selected) { [string]$Glyphs.Cursor } else { '  ' })
        $rows.Add(@((New-WtSeg -Text $lead -Fg 'Yellow'), (New-WtSeg -Text $label -Fg $(if ($selected) { 'Yellow' } else { 'Gray' }))))
    }
    $box = @(Get-WtReplBoxRows -Title $Title -Rows $rows.ToArray() -Width $Width -Glyphs $Glyphs -Fg $fg)
    $hint = '  ' + [string](Get-Translation 'AsPickHint')
    $w = [Math]::Max(20, $Width - 1)
    if ($hint.Length -gt $w) { $hint = $hint.Substring(0, $w) }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $box) { $list.Add($r) }
    $list.Add(@(, (New-WtSeg -Text $hint -Fg 'DarkGray')))
    return $list.ToArray()
}
