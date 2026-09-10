#Requires -Modules Pester

<#
.SYNOPSIS
    The pure side of the assistant REPL: formatters, the line-editor
    reducer, the key-to-token map, the command classifier and the slash
    table. No console anywhere in here.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'REPL formatters' {
    It 'the window-title formatter and the per-turn summary line are both gone, so the assistant keeps one steady title' {
        (Get-Command Format-WtReplTurnSummary -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        (Get-Command Format-WtReplTitle -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'computes the context percentage over the message chars and clamps it' {
        $messages = @(@{ role = 'user'; content = ('x' * 6000) }, @{ role = 'assistant'; content = ('y' * 6000) })
        Get-WtReplContextPercent -Messages $messages -MaxChars 60000 | Should -Be 20
        Get-WtReplContextPercent -Messages @() | Should -Be 0
        Get-WtReplContextPercent -Messages @(@{ role = 'user'; content = ('x' * 100) }) -MaxChars 50 | Should -Be 100
    }

    It 'renders a tool start line as bullet name(args) with compact arguments' {
        $g = Get-WtGlyphSet -Unicode $false
        Format-WtReplToolStart -Name 'get_system_overview' -ArgumentsJson '{}' -Width 80 -Glyphs $g | Should -Be '  * get_system_overview()'
        Format-WtReplToolStart -Name 'apply_wintoolify' -ArgumentsJson '{"ids":["A:B","C:D"],"direction":"apply"}' -Width 80 -Glyphs $g | Should -Be '  * apply_wintoolify(ids: [A:B, C:D], direction: apply)'
        Format-WtReplToolArgs -ArgumentsJson '{"ids":["a","b","c","d","e"]}' | Should -Be 'ids: [a, b, c, +2]'
        Format-WtReplToolArgs -ArgumentsJson '{"n":3,"ok":true,"o":{"x":1}}' | Should -Be 'n: 3, ok: true, o: {...}'
        Format-WtReplToolArgs -ArgumentsJson 'not json' | Should -Be 'not json'
        Format-WtReplToolArgs -ArgumentsJson '' | Should -Be ''
        $long = Format-WtReplToolStart -Name 'x' -ArgumentsJson ('{"q":"' + ('a' * 200) + '"}') -Width 40 -Glyphs $g
        $long.Length | Should -Be 39
        $long | Should -Match '~$'
        (Format-WtReplToolStart -Name 'x' -ArgumentsJson '{"q":"a\nb"}' -Width 80 -Glyphs $g) | Should -Not -Match "`n"
    }

    It 'renders the tool result and output lines under a branch mark' {
        $g = Get-WtGlyphSet -Unicode $false
        Format-WtReplToolResult -Seconds 0.42 -Chars 1843 -Ok $true -Glyphs $g | Should -Be '    \ 0,4 s - 1,8 KB'
        Format-WtReplToolResult -Seconds 12.06 -Chars 512 -Ok $false -Glyphs $g | Should -Be '    \ ! 12,1 s - 0,5 KB'
        $lines = @(Format-WtReplToolLines -Header 'Calistirildi: X' -Lines @('l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7') -Max 5 -Glyphs $g)
        $lines[0] | Should -Be '    \ Calistirildi: X'
        $lines[1] | Should -Be '      l3'
        $lines[5] | Should -Be '      l7'
        $lines[6] | Should -Be ('      ' + ((Get-Translation 'AsReplMoreLines') -f 2))
        @(Format-WtReplToolLines -Header 'h' -Lines @('a') -Glyphs $g).Count | Should -Be 2
        @(Format-WtReplToolLines -Header 'h' -Lines @() -Glyphs $g).Count | Should -Be 1
    }

    It 'renders a tool the USER ran by number like a tool call: its label on the bullet line, the outcome under the branch, then the tail' {
        $g = Get-WtGlyphSet -Unicode $false
        $lines = @(Format-WtReplToolRunLines -Label 'Diskleri iyilestir (TRIM)' -Status 'Calistirildi' -Lines @('l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7') -Max 5 -Glyphs $g)
        $lines[0] | Should -Be '  * Diskleri iyilestir (TRIM)'
        $lines[1] | Should -Be '    \ Calistirildi'
        $lines[2] | Should -Be '      l3'
        $lines[6] | Should -Be '      l7'
        $lines[7] | Should -Be ('      ' + ((Get-Translation 'AsReplMoreLines') -f 2))
        @(Format-WtReplToolRunLines -Label 'X' -Status 'S' -Glyphs $g) | Should -Be @('  * X', '    \ S')
        $whole = @(Format-WtReplToolRunLines -Label 'X' -Status 'S' -Lines @('l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7') -Max 0 -Glyphs $g)
        $whole.Count | Should -Be 9
        $whole[2] | Should -Be '      l1'
        $whole[8] | Should -Be '      l7'
        ($whole -join "`n") | Should -Not -Match 'kaydet'
        @(Format-WtReplToolLines -Header 'h' -Lines @('a', 'b', 'c', 'd', 'e', 'f') -Max 0 -Glyphs $g).Count | Should -Be 7
    }

    It 'indents a tool start two columns and its result four' {
        $g = Get-WtGlyphSet -Unicode $false
        Format-WtReplToolStart -Name 'get_startup_items' -ArgumentsJson '{}' -Width 80 -Glyphs $g | Should -Be '  * get_startup_items()'
        (Format-WtReplToolResult -Seconds 0.4 -Chars 1843 -Ok $true -Glyphs $g) | Should -BeLike '    \ *'
    }

    It 'indents tool output lines six columns under the branch' {
        $g = Get-WtGlyphSet -Unicode $false
        $lines = @(Format-WtReplToolLines -Header 'Calistirildi: X' -Lines @('a', 'b') -Max 5 -Glyphs $g)
        $lines[0] | Should -Be '    \ Calistirildi: X'
        $lines[1] | Should -Be '      a'
    }

    It 'renders the spinner line with a cycling frame, the label, elapsed seconds and optional KB' {
        $g = Get-WtGlyphSet -Unicode $false
        Format-WtReplSpinnerLine -Label 'Dusunuyor...' -Seconds 8.4 -Chars 0 -Glyphs $g | Should -Be ('Dusunuyor... (8 s - ' + (Get-Translation 'AsSpinTail') + ')')
        Format-WtReplSpinnerLine -Label 'L' -Seconds 0 -Chars 1229 -Glyphs $g | Should -Be ('L (0 s - 1,2 KB - ' + (Get-Translation 'AsSpinTail') + ')')
    }

    It 'renders the status line: left text, right hints only when they fit, never wider than Width-1' {
        Format-WtReplStatusLine -Left 'qwen3 - local - %12' -Right 'Enter: send' -Width 60 | Should -Be ('  qwen3 - local - %12' + (' ' * 27) + 'Enter: send')
        (Format-WtReplStatusLine -Left 'qwen3 - local - %12' -Right 'Enter: send' -Width 60).Length | Should -Be 59
        Format-WtReplStatusLine -Left ('x' * 50) -Right 'Enter: send' -Width 60 | Should -Be ('  ' + ('x' * 50))
        (Format-WtReplStatusLine -Left ('x' * 80) -Right '' -Width 60).Length | Should -Be 59
        $g = Get-WtGlyphSet -Unicode $false
        Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'yerel' -Percent 12 -Glyphs $g | Should -Be ('qwen3 - yerel - ' + ((Get-Translation 'AsStatusContextShort') -f 12))
        Get-WtReplStatusLeft -Model '' -WhereTag 'yerel' -Percent 0 -Glyphs $g | Should -Match ([regex]::Escape((Get-Translation 'AsNotSet')))
        Get-WtReplStatusRight -Glyphs $g | Should -Be ((Get-Translation 'AsStatusHintEnter') + ' - ' + (Get-Translation 'AsStatusHintEsc') + ' - ' + (Get-Translation 'AsStatusHintHelp'))
    }
}

Describe 'Get-WtReplStatusLeft' {
    It 'carries the memory summary when there is room' {
        $g = Get-WtGlyphSet -Unicode $false
        $s = Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'uzak' -Percent 12 -MessageCount 12 -NoteCount 2 -PermCount 3 -Width 120 -Glyphs $g
        $s | Should -BeLike '*qwen3*'
        $s | Should -BeLike '*uzak*'
        $s | Should -BeLike ('*' + ((Get-Translation 'AsStatusPermsShort') -f 3) + '*')
    }

    It 'drops the parts from the end as the window narrows, keeping the model' {
        $g = Get-WtGlyphSet -Unicode $false
        $wide = Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'uzak' -Percent 12 -MessageCount 12 -NoteCount 2 -PermCount 3 -Width 120 -Glyphs $g
        $mid = Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'uzak' -Percent 12 -MessageCount 12 -NoteCount 2 -PermCount 3 -Width 44 -Glyphs $g
        $tiny = Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'uzak' -Percent 12 -MessageCount 12 -NoteCount 2 -PermCount 3 -Width 14 -Glyphs $g
        $mid.Length | Should -BeLessThan $wide.Length
        $tiny | Should -Be 'qwen3'
        $mid | Should -BeLike '*qwen3*'
        $mid | Should -Not -BeLike ('*' + ((Get-Translation 'AsStatusPermsShort') -f 3) + '*')
    }

    It 'shrinks the left half instead of pushing the key hints off the row' {
        $g = Get-WtGlyphSet -Unicode $false
        $right = Get-WtReplStatusRight -Glyphs $g
        $width = 80
        $free = Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'uzak' -Percent 12 -MessageCount 12 -NoteCount 2 -PermCount 3 -Width $width -Glyphs $g
        $held = Get-WtReplStatusLeft -Model 'qwen3' -WhereTag 'uzak' -Percent 12 -MessageCount 12 -NoteCount 2 -PermCount 3 -Width $width -Reserve $right.Length -Glyphs $g
        $held.Length | Should -BeLessThan $free.Length
        $held | Should -BeLike '*qwen3*'
        (Format-WtReplStatusLine -Left $free -Right $right -Width $width).IndexOf($right, [System.StringComparison]::Ordinal) | Should -Be -1
        $line = Format-WtReplStatusLine -Left $held -Right $right -Width $width
        $line.IndexOf($right, [System.StringComparison]::Ordinal) | Should -BeGreaterThan 0
        $line.Length | Should -BeLessOrEqual ($width - 1)
    }

    It 'says the model is not set when there is none' {
        $g = Get-WtGlyphSet -Unicode $false
        (Get-WtReplStatusLeft -Model '' -WhereTag '' -Percent 0 -Width 80 -Glyphs $g) | Should -BeLike ('*' + (Get-Translation 'AsNotSet') + '*')
    }
}

Describe 'ConvertTo-WtReplKeyToken' {
    It 'maps navigation keys by name, printable characters to Char, and Ctrl+C to a control token' {
        (ConvertTo-WtReplKeyToken -Key 'LeftArrow' -KeyChar '' -Modifiers '0').Key | Should -Be 'LeftArrow'
        $a = ConvertTo-WtReplKeyToken -Key 'A' -KeyChar 'a' -Modifiers '0'
        $a.Key | Should -Be 'Char'
        $a.Char | Should -Be 'a'
        $c = ConvertTo-WtReplKeyToken -Key 'C' -KeyChar ([string][char]3) -Modifiers 'Control'
        $c.Key | Should -Be 'C'
        $c.Ctrl | Should -BeTrue
        (ConvertTo-WtReplKeyToken -Key 'Enter' -KeyChar ([string][char]13) -Modifiers '0' -Burst $true).Burst | Should -BeTrue
        (ConvertTo-WtReplKeyToken -Key 'F5' -KeyChar '' -Modifiers '0').Key | Should -Be 'None'
        (ConvertTo-WtReplKeyToken -Key 'Oem1' -KeyChar ([string][char]0x015F) -Modifiers '0').Char | Should -Be ([string][char]0x015F)
        (ConvertTo-WtReplKeyToken -Key 'Tab' -KeyChar ([string][char]9) -Modifiers '0').Key | Should -Be 'Tab'
    }
}

Describe 'Update-WtReplLine (the line editor reducer)' {
    BeforeAll {
        function Push-WtReplKeys { param($State, [object[]]$Tokens)
            $s = $State; $emit = 'None'
            foreach ($t in $Tokens) { $r = Update-WtReplLine -State $s -Token $t; $s = $r.State; $emit = $r.Emit }
            return @{ State = $s; Emit = $emit }
        }
        function K { param([string]$Key, [string]$Char = '', [bool]$Ctrl = $false, [bool]$Burst = $false) @{ Key = $Key; Char = $Char; Ctrl = $Ctrl; Burst = $Burst } }
        function T { param([string]$Text) @($Text.ToCharArray() | ForEach-Object { K 'Char' ([string]$_) }) }
    }

    It '1 typed submit' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'abc') + @(K 'Enter'))
        $r.Emit | Should -Be 'Submit'
        $r.State.Text | Should -Be 'abc'
    }
    It '2 mid-line insert via Left/Left' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'abd') + @((K 'LeftArrow'), (K 'LeftArrow')) + @(T 'X'))
        $r.State.Text | Should -Be 'aXbd'
        $r.State.Cursor | Should -Be 2
    }
    It '3 Home / Delete / End / Backspace' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'abcd') + @((K 'Home'), (K 'Delete'), (K 'End'), (K 'Backspace')))
        $r.State.Text | Should -Be 'bc'
        $r.State.Cursor | Should -Be 2
    }
    It '4 history Up/Up/Down/Down keeps the draft' {
        $s = New-WtReplLineState -History @('first', 'second')
        $r = Push-WtReplKeys -State $s -Tokens (@(T 'dra') + @(K 'UpArrow'))
        $r.State.Text | Should -Be 'second'
        $r = Push-WtReplKeys -State $r.State -Tokens @(K 'UpArrow')
        $r.State.Text | Should -Be 'first'
        $r = Push-WtReplKeys -State $r.State -Tokens @(K 'UpArrow')
        $r.State.Text | Should -Be 'first'
        $r = Push-WtReplKeys -State $r.State -Tokens @((K 'DownArrow'), (K 'DownArrow'))
        $r.State.Text | Should -Be 'dra'
        $r.State.HistIdx | Should -Be -1
    }
    It '5 a paste burst with an embedded Enter inserts a LF and does NOT submit' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'ab') + @(K 'Enter' -Burst $true) + @(T 'cd'))
        $r.Emit | Should -Be 'None'
        $r.State.Text | Should -Be ('ab' + "`n" + 'cd')
        (Push-WtReplKeys -State $r.State -Tokens @(K 'Enter')).Emit | Should -Be 'Submit'
    }
    It '6 recall-then-edit resets HistIdx' {
        $s = New-WtReplLineState -History @('old')
        $r = Push-WtReplKeys -State $s -Tokens (@(K 'UpArrow') + @(T 'x'))
        $r.State.Text | Should -Be 'oldx'
        $r.State.HistIdx | Should -Be -1
    }
    It '7 Esc clears a full line (Clear) and cancels an empty one (Cancel)' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'abc') + @(K 'Escape'))
        $r.Emit | Should -Be 'Clear'
        $r.State.Text | Should -Be ''
        (Push-WtReplKeys -State $r.State -Tokens @(K 'Escape')).Emit | Should -Be 'Cancel'
    }
    It '8 Ctrl+C is its own emit and leaves the text to the caller' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'abc') + @(K 'C' -Ctrl $true))
        $r.Emit | Should -Be 'CtrlC'
        $r.State.Text | Should -Be 'abc'
    }
    It '9 Right past the end and Left past the start stay put; Tab and unknown keys are ignored' {
        $r = Push-WtReplKeys -State (New-WtReplLineState) -Tokens (@(T 'a') + @((K 'RightArrow'), (K 'RightArrow'), (K 'Tab'), (K 'None')))
        $r.State.Cursor | Should -Be 1
        $r = Push-WtReplKeys -State $r.State -Tokens @((K 'LeftArrow'), (K 'LeftArrow'), (K 'LeftArrow'))
        $r.State.Cursor | Should -Be 0
        $r.State.Text | Should -Be 'a'
    }
    It 'never mutates the input state' {
        $s = New-WtReplLineState
        $null = Update-WtReplLine -State $s -Token (K 'Char' 'z')
        $s.Text | Should -Be ''
    }

    It 'a Paste token inserts at the cursor, CRLF folded to LF, and drops out of history recall' {
        $s = New-WtReplLineState -History @('old')
        $s = (Push-WtReplKeys $s @((T 'ab') + @(K 'LeftArrow'))).State
        $r = Update-WtReplLine -State $s -Token @{ Key = 'Paste'; Text = "x`r`ny"; Ctrl = $false; Burst = $false }
        $r.State.Text | Should -Be "ax`nyb"
        $r.State.Cursor | Should -Be 4
        $r.Emit | Should -Be 'None'
        $r.State.HistIdx | Should -Be -1
    }

    It 'a backslash right before Enter becomes a newline instead of a submit' {
        $s = New-WtReplLineState
        $r = Push-WtReplKeys $s @((T 'ab\') + @(K 'Enter'))
        $r.Emit | Should -Be 'None'
        $r.State.Text | Should -Be "ab`n"
        $r2 = Push-WtReplKeys $r.State @(@(T 'c') + @(K 'Enter'))
        $r2.Emit | Should -Be 'Submit'
        $r2.State.Text | Should -Be "ab`nc"
    }

    It 'a leading slash opens the popup, Up/Down walk it instead of history, Tab completes, Enter completes and submits, a space closes it' {
        $s = New-WtReplLineState -History @('old')
        $r = Push-WtReplKeys $s (T '/mo')
        @($r.State.Popup).Count | Should -Be 1
        $r.State.Popup[0].Name | Should -Be 'model'
        $r.State.PopupIndex | Should -Be 0
        $all = Push-WtReplKeys $s (T '/')
        @($all.State.Popup).Count | Should -Be 8
        $down = Push-WtReplKeys $all.State @(K 'DownArrow')
        $down.State.PopupIndex | Should -Be 1
        $down.State.Text | Should -Be '/'
        $tab = Push-WtReplKeys $r.State @(K 'Tab')
        $tab.State.Text | Should -Be '/model '
        @($tab.State.Popup).Count | Should -Be 0
        $enter = Push-WtReplKeys (Push-WtReplKeys $s (T '/temiz')).State @(K 'Enter')
        $enter.Emit | Should -Be 'Submit'
        $enter.State.Text | Should -Be '/temizle'
        (Push-WtReplKeys $s @((T 'hi') + @(K 'Tab'))).State.Text | Should -Be 'hi'
        (Push-WtReplKeys $s @((T '/zzz') + @(K 'Enter'))).Emit | Should -Be 'Submit'
    }
}

Describe 'Get-WtReplLineRender' {
    It 'renders prompt + text with the caret column and shows an embedded LF as the newline mark' {
        $r = Get-WtReplLineRender -Prompt '> ' -Text ('ab' + "`n" + 'c') -Cursor 4 -Width 80
        $r.Line | Should -Be ('> ab' + [string][char]0xB6 + 'c')
        $r.CursorCol | Should -Be 6
    }
    It 'keeps the caret visible on an overlong line by sliding the window' {
        $text = 'x' * 200
        $r = Get-WtReplLineRender -Prompt '> ' -Text $text -Cursor 200 -Width 40
        $r.Line.Length | Should -BeLessOrEqual 39
        $r.CursorCol | Should -BeLessOrEqual 39
        $r.Offset | Should -BeGreaterThan 0
        $r2 = Get-WtReplLineRender -Prompt '> ' -Text $text -Cursor 0 -Width 40
        $r2.Offset | Should -Be 0
        $r2.CursorCol | Should -Be 2
    }

    It 'never renders past the console width even with a prompt wider than it' {
        $p = 'x' * 95
        $r = Get-WtReplLineRender -Prompt $p -Text 'ab' -Cursor 2 -Width 80
        $r.Line.Length | Should -BeLessOrEqual 79
        $r.CursorCol | Should -BeLessOrEqual 79
    }
}

Describe 'slash table and command classifier' {
    It 'resolves Turkish and English aliases, case- and diacritic-insensitively' {
        Resolve-WtReplSlash -Word 'yeni' | Should -Be 'new'
        Resolve-WtReplSlash -Word 'NEW' | Should -Be 'new'
        Resolve-WtReplSlash -Word ('yard' + [char]0x0131 + 'm') | Should -Be 'help'
        Resolve-WtReplSlash -Word ([char]0x00E7 + [char]0x0131 + 'k') | Should -Be 'quit'
        Resolve-WtReplSlash -Word 'endpoint' | Should -Be 'endpoint'
        Resolve-WtReplSlash -Word 'uc' | Should -Be 'endpoint'
        Resolve-WtReplSlash -Word 'profil' | Should -Be 'profile'
        Resolve-WtReplSlash -Word 'unut' | Should -Be 'forget'
        Resolve-WtReplSlash -Word 'notlar' | Should -Be 'notes'
        Resolve-WtReplSlash -Word 'nope' | Should -Be ''
    }

    It 'every table row has a TR and an EN alias (model is the documented exception) and a help key present in both languages' {
        foreach ($row in @(Get-WtReplSlashTable)) {
            @($row.Aliases).Count | Should -BeGreaterOrEqual 1 -Because $row.Name
            if ([string]$row.Name -ne 'model') { @($row.Aliases).Count | Should -BeGreaterOrEqual 2 -Because $row.Name }
            @($row.Aliases | Select-Object -Unique).Count | Should -Be @($row.Aliases).Count -Because $row.Name
            $script:Translations['EN'][$row.HelpKey] | Should -Not -BeNullOrEmpty -Because $row.Name
            $script:Translations['TR'][$row.HelpKey] | Should -Not -BeNullOrEmpty -Because $row.Name
        }
        @(Get-WtReplSlashTable | ForEach-Object Name) | Should -Be @('new', 'model', 'endpoint', 'key', 'scan', 'test', 'settings', 'perms', 'tools', 'profile', 'notes', 'status', 'save', 'copy', 'forget', 'help', 'quit')
        @(Get-WtReplHelpLines).Count | Should -Be @(Get-WtReplSlashTable).Count
        (Get-WtReplHelpLines)[6] | Should -Match '^/ayarlar, /settings, /config - '
        (Get-WtReplHelpLines)[1] | Should -Match '^/model - '
        Resolve-WtReplSlash -Word 'config' | Should -Be 'settings'
        Resolve-WtReplSlash -Word 'exit' | Should -Be 'quit'
        Resolve-WtReplSlash -Word 'cikis' | Should -Be 'quit'
        Resolve-WtReplSlash -Word 'kopyala' | Should -Be 'copy'
        Resolve-WtReplSlash -Word 'clear' | Should -Be 'new'
        Resolve-WtReplSlash -Word 'temizle' | Should -Be 'new'
        (Get-WtReplHelpLines)[0] | Should -Match '^/yeni, /new, /temizle, /clear - '
    }

    It 'a bare yeni / new / temizle / clear (no slash, nothing else on the line) is the new-conversation command, not a message' {
        foreach ($word in @('yeni', 'new', 'temizle', 'clear', 'CLEAR', 'Yeni')) {
            $c = ConvertTo-WtReplCommand -Line (' ' + $word + ' ') -SuggestionCount 0
            $c.Kind | Should -Be 'Slash' -Because $word
            $c.Command | Should -Be 'new' -Because $word
        }
        (ConvertTo-WtReplCommand -Line 'yeni bir sorun var' -SuggestionCount 0).Kind | Should -Be 'Send'
        (ConvertTo-WtReplCommand -Line 'clear cache?' -SuggestionCount 0).Kind | Should -Be 'Send'
        (ConvertTo-WtReplCommand -Line 'help' -SuggestionCount 0).Kind | Should -Be 'Send'
        (ConvertTo-WtReplCommand -Line 'model' -SuggestionCount 0).Kind | Should -Be 'Send'
    }

    It 'a bare q / quit / exit / cik (no slash) is a leave HINT - not a message for the model, not a quit' {
        foreach ($word in @('q', 'Q', 'quit', 'exit', 'cik', 'cikis')) {
            $c = ConvertTo-WtReplCommand -Line (' ' + $word + ' ') -SuggestionCount 0
            $c.Kind | Should -Be 'Hint' -Because $word
            $c.Command | Should -Be 'quit' -Because $word
        }
        (ConvertTo-WtReplCommand -Line 'q nedir' -SuggestionCount 0).Kind | Should -Be 'Send'
        (ConvertTo-WtReplCommand -Line '/q' -SuggestionCount 0).Command | Should -Be 'quit'
        Resolve-WtReplSlash -Word 'q' | Should -Be 'quit'
        (Get-WtReplHelpLines)[-1] | Should -Match '^/cik, /quit, /cikis, /exit, /q - '
        ((Get-Translation 'AsReplQuitHint') -cmatch '/([a-z]+)') | Should -BeTrue
        Resolve-WtReplSlash -Word $Matches[1] | Should -Be 'quit'
    }

    It 'Get-WtReplSlashMatches filters by folded prefix on every alias, at most 8, and only for a bare leading slash' {
        @(Get-WtReplSlashMatches -Text '/').Count | Should -Be 8
        $m = @(Get-WtReplSlashMatches -Text '/AYAR')
        $m.Count | Should -Be 1
        $m[0].Name | Should -Be 'settings'; $m[0].Alias | Should -Be 'ayarlar'; $m[0].Help | Should -Be (Get-Translation 'AsSlashSettings')
        (Get-WtReplSlashMatches -Text '/conf')[0].Alias | Should -Be 'config'
        @(Get-WtReplSlashMatches -Text '/model x').Count | Should -Be 0
        @(Get-WtReplSlashMatches -Text 'model').Count | Should -Be 0
        @(Get-WtReplSlashMatches -Text '/zz').Count | Should -Be 0
        $rows = @(Get-WtReplPopupRows -Popup @(Get-WtReplSlashMatches -Text '/mo') -Index 0 -Width 80)
        $rows.Count | Should -Be 1
        (@($rows[0]) | ForEach-Object T) -join '' | Should -Match '^  > /model'
    }

    It 'every table name is a case in the slash handler' {
        $src = (Get-Command Invoke-WtAssistantSlash).Definition
        foreach ($row in @(Get-WtReplSlashTable)) {
            $src | Should -Match ("'" + [regex]::Escape([string]$row.Name) + "'\s*\{")
        }
    }

    It 'classifies a line: digits = suggestion when one exists, slash = command with its argument, else send' {
        (ConvertTo-WtReplCommand -Line 'neden yavas' -SuggestionCount 0).Kind | Should -Be 'Send'
        $s = ConvertTo-WtReplCommand -Line ' 2 ' -SuggestionCount 3
        $s.Kind | Should -Be 'Suggest'; $s.Index | Should -Be 2
        (ConvertTo-WtReplCommand -Line '7' -SuggestionCount 3).Kind | Should -Be 'Unknown'
        (ConvertTo-WtReplCommand -Line '7' -SuggestionCount 0).Kind | Should -Be 'Unknown'
        $m = ConvertTo-WtReplCommand -Line '/model qwen3:8b' -SuggestionCount 0
        $m.Kind | Should -Be 'Slash'; $m.Command | Should -Be 'model'; $m.Argument | Should -Be 'qwen3:8b'
        $u = ConvertTo-WtReplCommand -Line '/xyz' -SuggestionCount 0
        $u.Kind | Should -Be 'Unknown'; $u.Command | Should -Be 'xyz'
        (ConvertTo-WtReplCommand -Line '' -SuggestionCount 0).Kind | Should -Be 'None'
        (ConvertTo-WtReplCommand -Line $null -SuggestionCount 0).Kind | Should -Be 'Eof'
        (ConvertTo-WtReplCommand -Line '12 tane' -SuggestionCount 20).Kind | Should -Be 'Send'
    }

    It 'a full-width digit is a message, not a crash, and a three-digit line is a message too' {
        (ConvertTo-WtReplCommand -Line ([string][char]0xFF12) -SuggestionCount 3).Kind | Should -Be 'Send'
        (ConvertTo-WtReplCommand -Line '123' -SuggestionCount 3).Kind | Should -Be 'Send'
    }

    It 'a fresh session carries the lists the REPL loop reads' {
        $s = New-WtReplSession
        $s.Messages.Count | Should -Be 0
        $s.Entries.Count | Should -Be 0
        @($s.Suggestions).Count | Should -Be 0
        $s.History.Count | Should -Be 0
        $s.Busy | Should -BeFalse
        $s.ProfileEnabled | Should -BeTrue
    }
}

Describe 'REPL live-region builders (pure)' {
    BeforeAll {
        $script:g = Get-WtGlyphSet -Unicode $false
        function Row-Text { param($Row) (@($Row) | ForEach-Object { [string]$_.T }) -join '' }
    }

    It 'a box is exactly Width-1 wide on every row, carries its title in the top border and clamps long rows' {
        $rows = @(Get-WtReplBoxRows -Title 'T' -Rows @(, @(New-WtSeg -Text 'hello' -Fg 'White')) -Width 40 -Glyphs $g)
        $rows.Count | Should -Be 3
        foreach ($r in $rows) { (Row-Text $r).Length | Should -Be 39 }
        Row-Text $rows[0] | Should -Match '^\+- T -+\+$'
        Row-Text $rows[1] | Should -Match '^\| hello +\|$'
        $long = @(Get-WtReplBoxRows -Title '' -Rows @(, @(New-WtSeg -Text ('x' * 100) -Fg 'White')) -Width 40 -Glyphs $g)
        (Row-Text $long[1]).Length | Should -Be 39
        Row-Text $long[1] | Should -Match '~ \|$'
    }

    It 'the input box shows the prompt and text with the caret inside, or a dim placeholder when empty' {
        $box = Get-WtReplInputLines -Prompt '> ' -Text 'abc' -Cursor 1 -Width 40 -Glyphs $g
        $box.Rows.Count | Should -Be 3
        $box.CaretRow | Should -Be 1
        $box.CaretCol | Should -Be 5
        Row-Text $box.Rows[1] | Should -Match '^\| > abc +\|$'
        $empty = Get-WtReplInputLines -Prompt '> ' -Text '' -Cursor 0 -Width 40 -Glyphs $g -Placeholder 'type here'
        Row-Text $empty.Rows[1] | Should -Match 'type here'
        (@($empty.Rows[1]) | Where-Object { $_.T -match 'type here' }).F | Should -Be 'DarkGray'
        $empty.CaretCol | Should -Be 4
        $slide = Get-WtReplInputLines -Prompt '> ' -Text ('y' * 100) -Cursor 100 -Width 40 -Glyphs $g
        (Row-Text $slide.Rows[1]).Length | Should -Be 39
        $slide.CaretCol | Should -BeLessThan 39
    }

    It 'the pick reducer walks with arrows, picks by Enter / digit / hotkey (case-insensitive), cancels on Esc' {
        $s = New-WtReplPickState -Options @(@{ Label = 'Evet'; Hotkey = 'E' }, @{ Label = 'Hep'; Hotkey = 'T' }, @{ Label = 'Hayir'; Hotkey = 'H' }) -TextOption 'yaz'
        $s.Rows.Count | Should -Be 4
        $s.Rows[3].IsText | Should -BeTrue
        $r = Update-WtReplPickState -State $s -Token @{ Key = 'DownArrow'; Char = ''; Ctrl = $false; Burst = $false }
        $r.State.Index | Should -Be 1; $r.Emit | Should -Be 'None'
        (Update-WtReplPickState -State $r.State -Token @{ Key = 'Enter'; Char = ''; Ctrl = $false; Burst = $false }).Emit | Should -Be 'Pick'
        $d = Update-WtReplPickState -State $s -Token @{ Key = 'Char'; Char = '3'; Ctrl = $false; Burst = $false }
        $d.Emit | Should -Be 'Pick'; $d.State.Index | Should -Be 2
        (Update-WtReplPickState -State $s -Token @{ Key = 'Char'; Char = '9'; Ctrl = $false; Burst = $false }).Emit | Should -Be 'None'
        $h = Update-WtReplPickState -State $s -Token @{ Key = 'Char'; Char = 't'; Ctrl = $false; Burst = $false }
        $h.Emit | Should -Be 'Pick'; $h.State.Index | Should -Be 1
        (Update-WtReplPickState -State $s -Token @{ Key = 'Escape'; Char = ''; Ctrl = $false; Burst = $false }).Emit | Should -Be 'Cancel'
        (Update-WtReplPickState -State $s -Token @{ Key = 'C'; Char = ''; Ctrl = $true; Burst = $false }).Emit | Should -Be 'Cancel'
        (Update-WtReplPickState -State $s -Token @{ Key = 'UpArrow'; Char = ''; Ctrl = $false; Burst = $false }).State.Index | Should -Be 0
        (Update-WtReplPickState -State $s -Token @{ Key = 'End'; Char = ''; Ctrl = $false; Burst = $false }).State.Index | Should -Be 3
    }

    It 'pick lines: title, question lines, the options with the cursor on the selected one, a hint row, windowed when tall' {
        $s = New-WtReplPickState -Options @(1..12 | ForEach-Object { @{ Label = "opt$_"; Hotkey = '' } })
        $s.Index = 11
        $rows = @(Get-WtReplPickLines -Title 'Sec' -Lines @('soru') -State $s -Width 50 -Glyphs $g -ViewHeight 5)
        $texts = @($rows | ForEach-Object { Row-Text $_ })
        $texts[0] | Should -Match '^\+- Sec -'
        $texts[1] | Should -Match 'soru'
        ($texts -join "`n") | Should -Match '> opt12'
        ($texts -join "`n") | Should -Not -Match 'opt1 '
        $texts[-1] | Should -Match ([regex]::Escape((Get-Translation 'AsPickHint')))
        foreach ($t in $texts) { $t.Length | Should -BeLessOrEqual 49 }
        (Get-WtReplPickLines -Title '' -Lines @() -State $s -Width 50 -Glyphs $g -Risk 'ADVANCED')[0][0].F | Should -Be 'Red'
        (Get-WtReplPickLines -Title '' -Lines @() -State $s -Width 50 -Glyphs $g -Risk 'CAUTION')[0][0].F | Should -Be 'Yellow'
        (Get-WtReplPickLines -Title '' -Lines @() -State $s -Width 50 -Glyphs $g)[0][0].F | Should -Be 'Cyan'
    }

    It 'no longer carries a welcome box builder' {
        (Get-Command -Name 'Get-WtReplWelcomeLines' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtReplQuestionRows and the wrapped pick box' {
    BeforeAll { $script:g = Get-WtGlyphSet -Unicode $false }
    It 'wraps a long line to the inside of the box instead of leaving it to be cut at ~' {
        $long = ('kelime ' * 40).Trim()
        $rows = @(Get-WtReplQuestionRows -Lines @($long) -Width 60 -Fg 'Yellow')
        $rows.Count | Should -BeGreaterThan 3
        foreach ($r in $rows) {
            $t = (@($r) | ForEach-Object T) -join ''
            $t.Length | Should -BeLessOrEqual (59 - 4)
            $t | Should -Not -Match '~'
            @($r)[0].F | Should -Be 'Yellow'
        }
        (($rows | ForEach-Object { (@($_) | ForEach-Object T) -join '' }) -join ' ') | Should -Be $long
    }
    It 'keeps a blank line as a blank row and hangs a "- " bullet under its own text' {
        $rows = @(Get-WtReplQuestionRows -Lines @('Basi:', '', ('- ' + ('madde ' * 30).Trim())) -Width 50)
        ((@($rows[0]) | ForEach-Object T) -join '') | Should -Be 'Basi:'
        ((@($rows[1]) | ForEach-Object T) -join '') | Should -Be ''
        ((@($rows[2]) | ForEach-Object T) -join '') | Should -Match '^- madde'
        ((@($rows[3]) | ForEach-Object T) -join '') | Should -Match '^  madde'
    }
    It 'the pick box carries the wrapped question, so the privacy text is readable in full' {
        $s = New-WtReplPickState -Options @(@{ Label = 'Evet'; Hotkey = 'E' }, @{ Label = 'Hayir'; Hotkey = 'H' })
        $question = @('Bu asistan verileri su sunucuya gonderecek: https://api.example.com/v1', '', ('- ' + ('veri ' * 40).Trim()))
        $rows = @(Get-WtReplPickLines -Title 'Gonderilsin mi?' -Lines $question -State $s -Width 70 -Glyphs $script:g -Risk 'CAUTION')
        $texts = @($rows | ForEach-Object { (@($_) | ForEach-Object T) -join '' })
        ($texts -join "`n") | Should -Not -Match '~'
        foreach ($t in $texts) { $t.Length | Should -BeLessOrEqual 69 }
        $inside = ($texts | Where-Object { $_ -match '^\|' } | ForEach-Object { $_.Substring(2, $_.Length - 4).Trim() }) -join ' '
        $inside | Should -Match 'https://api\.example\.com/v1'
        ([regex]::Matches($inside, '\bveri\b')).Count | Should -Be 40
        $texts[-3] | Should -Match 'Hayir \(h\)'
        $texts[-4] | Should -Match 'Evet \(e\)'
    }
}

Describe 'Format-WtReplUsageLine' {
    It 'formats the last turn token counts with a thousands dot, adds the cache only when present, and says so when the server sent none' {
        Format-WtReplTokenCount -Value 4312 | Should -Be '4.312'
        Format-WtReplTokenCount -Value 210 | Should -Be '210'
        Format-WtReplTokenCount -Value 1234567 | Should -Be '1.234.567'
        Format-WtReplUsageLine -Usage $null | Should -Be (Get-Translation 'AsStatusUsageNone')
        Format-WtReplUsageLine -Usage @{ PromptTokens = 4312; CompletionTokens = 210; CachedTokens = 0; Rounds = 1 } | Should -Be ((Get-Translation 'AsStatusUsage') -f '4.312', '210', '')
        Format-WtReplUsageLine -Usage @{ PromptTokens = 4312; CompletionTokens = 210; CachedTokens = 3900; Rounds = 3 } | Should -Be ((Get-Translation 'AsStatusUsage') -f '4.312', '210', ((Get-Translation 'AsStatusUsageCache') -f '3.900'))
        Format-WtReplUsageLine -Usage @{ PromptTokens = 0; CompletionTokens = 0; CachedTokens = 0; Rounds = 0 } | Should -Be (Get-Translation 'AsStatusUsageNone')
        $s = New-WtReplSession
        $s.ClientCompat | Should -BeOfType [hashtable]
        $s.LastUsage | Should -BeNullOrEmpty
        $s.HistoryMaxChars | Should -Be 0
        $s.ContainsKey('FollowUp') | Should -BeTrue
        $s.FollowUp | Should -Be ''
    }
}
