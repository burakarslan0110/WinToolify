#Requires -Modules Pester

<#
.SYNOPSIS
    The REPL's console layer through its seams: mode switch strings and
    console calls, the alt-buffer hop, the printers (pure line lists),
    the line reader driven by a scripted key queue, the cancel poll.
    No test touches a real console.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:E = [string][char]27
    function New-WtKeyQueue { param([object[]]$Keys) $script:KeyQueue = New-Object System.Collections.Generic.Queue[object]; foreach ($k in $Keys) { $script:KeyQueue.Enqueue($k) } }
    function K { param([string]$Key, [string]$Char = '', [string]$Mod = '0') [PSCustomObject]@{ Key = $Key; KeyChar = $Char; Modifiers = $Mod } }
    function T { param([string]$Text) @($Text.ToCharArray() | ForEach-Object { K ([string]$_).ToUpperInvariant() ([string]$_) }) }
    $script:ReadKeySeam = { if ($script:KeyQueue.Count -eq 0) { return $null }; $script:KeyQueue.Dequeue() }
    $script:AvailSeam = { $script:KeyQueue.Count -gt 0 }
}

Describe 'Enter/Exit-WtReplMode' {
    It 'leaves the alt buffer, shows the cursor, unpins the buffer and takes Ctrl+C - then restores all of it' {
        $oldVt = $script:WtVt; $oldMode = $script:WtInputMode
        $script:WtVt = $true; $script:WtInputMode = 'Key'; $script:WtReplMode = $false
        try {
            Mock Enable-WtReplQuickEdit { $null }
            Mock Restore-WtReplQuickEdit { }
            $script:Out = New-Object System.Text.StringBuilder
            $script:Calls = @()
            $set = { param($Name, $Value) $script:Calls += @("$Name=$Value") }
            $get = { param($Name) switch ($Name) { 'BufferHeight' { 50 } 'CtrlC' { $false } 'WindowHeight' { 50 } } }
            Enter-WtReplMode -Write { param($Text) [void]$script:Out.Append($Text) } -SetConsole $set -GetConsole $get
            $script:WtReplMode | Should -BeTrue
            $script:WtReplLiveEnabled | Should -BeTrue
            $script:Out.ToString() | Should -Match ([regex]::Escape($E + '[?1049l'))
            $script:Out.ToString() | Should -Match ([regex]::Escape($E + '[?25h'))
            $script:Calls | Should -Contain 'BufferHeight=3000'
            $script:Calls | Should -Contain 'CtrlC=True'
            $script:WtReplSaved.CtrlC | Should -BeFalse
            $script:Calls = @()
            Enter-WtReplMode -Write { param($Text) } -SetConsole $set -GetConsole $get
            @($script:Calls).Count | Should -Be 0
            $script:Out = New-Object System.Text.StringBuilder
            Exit-WtReplMode -Write { param($Text) [void]$script:Out.Append($Text) } -SetConsole $set
            $script:WtReplMode | Should -BeFalse
            $script:WtReplLiveEnabled | Should -BeFalse
            $script:Calls | Should -Contain 'CtrlC=False'
            $script:Calls | Should -Contain 'Repin=True'
            $script:Out.ToString() | Should -Match ([regex]::Escape($E + '[?1049h'))
            $script:Out.ToString() | Should -Match ([regex]::Escape($E + '[2J'))
        }
        finally { $script:WtVt = $oldVt; $script:WtInputMode = $oldMode; $script:WtReplMode = $false }
    }

    It 'in Line mode touches no console setting and writes no VT' {
        $oldVt = $script:WtVt; $oldMode = $script:WtInputMode
        $script:WtVt = $false; $script:WtInputMode = 'Line'; $script:WtReplMode = $false
        try {
            Mock Enable-WtReplQuickEdit { $null }
            Mock Restore-WtReplQuickEdit { }
            $script:Calls = @()
            Enter-WtReplMode -Write { param($Text) throw 'no vt expected' } -SetConsole { param($Name, $Value) $script:Calls += @($Name) } -GetConsole { param($Name) 0 }
            $script:WtReplMode | Should -BeTrue
            $script:WtReplLiveEnabled | Should -BeFalse
            @($script:Calls | Where-Object { $_ -ne 'Cursor' }).Count | Should -Be 0
            Exit-WtReplMode -Write { param($Text) throw 'no vt expected' } -SetConsole { param($Name, $Value) }
            $script:WtReplMode | Should -BeFalse
        }
        finally { $script:WtVt = $oldVt; $script:WtInputMode = $oldMode; $script:WtReplMode = $false }
    }
}

Describe 'Invoke-WtReplHop' {
    It 'wraps the action in an alt-buffer round trip only while the REPL is active with VT, and returns its output' {
        $oldVt = $script:WtVt
        try {
            $script:WtVt = $true; $script:WtReplMode = $true
            $script:Out = New-Object System.Text.StringBuilder
            $r = Invoke-WtReplHop -Write { param($Text) [void]$script:Out.Append($Text) } -Action { [void]$script:Out.Append('ACTION'); 'result' }
            $r | Should -Be 'result'
            $text = $script:Out.ToString()
            $text.IndexOf($E + '[?1049h') | Should -BeLessThan $text.IndexOf('ACTION')
            $text.IndexOf('ACTION') | Should -BeLessThan $text.IndexOf($E + '[?1049l')
            $script:Out = New-Object System.Text.StringBuilder
            { Invoke-WtReplHop -Write { param($Text) [void]$script:Out.Append($Text) } -Action { throw 'boom' } } | Should -Throw
            $script:Out.ToString() | Should -Match ([regex]::Escape($E + '[?1049l'))
            $script:WtReplMode = $false
            $script:Out = New-Object System.Text.StringBuilder
            Invoke-WtReplHop -Write { param($Text) [void]$script:Out.Append($Text) } -Action { 'plain' } | Should -Be 'plain'
            $script:Out.Length | Should -Be 0
        }
        finally { $script:WtVt = $oldVt; $script:WtReplMode = $false }
    }

    It 'without VT it runs the action and reprints the transcript tail' {
        $oldVt = $script:WtVt; $oldMode = $script:WtReplMode; $oldChat = $script:WtAssistantChat
        try {
            $script:WtVt = $false
            $script:WtReplMode = $true
            $script:WtAssistantChat = New-WtReplSession
            Add-WtChatEntry -State $script:WtAssistantChat -Kind 'Info' -Text 'i'
            $script:TailPrinted = 0
            Mock Write-WtReplTranscriptTail { $script:TailPrinted++ }
            $script:ActionRan = $false
            $r = Invoke-WtReplHop -Action { $script:ActionRan = $true; 'plain' }
            $r | Should -Be 'plain'
            $script:ActionRan | Should -BeTrue
            $script:TailPrinted | Should -Be 1
        }
        finally { $script:WtVt = $oldVt; $script:WtReplMode = $oldMode; $script:WtAssistantChat = $oldChat }
    }

    It 'hides the live region before hopping into the alt buffer' {
        $oldVt = $script:WtVt
        try {
            $script:WtVt = $true; $script:WtReplMode = $true; $script:WtReplLiveEnabled = $true
            $script:WtReplLive = @{ Rows = 3; CaretRow = 1 }
            $script:Out = New-Object System.Text.StringBuilder
            Mock Hide-WtReplLive { [void]$script:Out.Append('HIDE'); $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }
            $null = Invoke-WtReplHop -Write { param($Text) [void]$script:Out.Append($Text) } -Action { 'r' }
            $text = $script:Out.ToString()
            $text.IndexOf('HIDE') | Should -BeLessThan $text.IndexOf($E + '[?1049h')
        }
        finally { $script:WtVt = $oldVt; $script:WtReplMode = $false; $script:WtReplLiveEnabled = $false }
    }
}

Describe 'printers' {
    It 'maps entry kinds to prefix and colour and splits multi-line text' {
        $Row = { param($R) (@($R) | ForEach-Object { [string]$_.T }) -join '' }
        $u = (Get-WtReplEntryLines -Kind 'User' -Text 'soru')
        (& $Row $u[0]) | Should -Be '  > soru'; $u[0][0].F | Should -Be 'Cyan'
        $a = (Get-WtReplEntryLines -Kind 'Assistant' -Text ("iki" + "`n" + "satir"))
        $a.Count | Should -Be 2; (& $Row $a[1]) | Should -Be '  satir'
        ((Get-WtReplEntryLines -Kind 'Tool' -Text '    \ x')[0])[0].F | Should -Be 'DarkGray'
        ((Get-WtReplEntryLines -Kind 'Tool' -Text ('  ' + [string]$script:WtGlyphs.Bullet + ' Diskleri iyilestir'))[0])[0].F | Should -Be 'White'
        ((Get-WtReplEntryLines -Kind 'Error' -Text 'e')[0])[0].F | Should -Be 'Red'
        ((Get-WtReplEntryLines -Kind 'Info' -Text 'i')[0])[0].F | Should -Be 'DarkYellow'
    }

    It 'numbers the suggestions with their risk badge and path' {
        $lines = @(Get-WtReplSuggestionLines -Suggestions @(@{ Label = 'Onar'; Path = 'A > B'; Risk = 'CAUTION' }, @{ Label = 'Bak'; Path = ''; Risk = '' }))
        $lines[0] | Should -Be ('  ' + (Get-Translation 'AsSuggestionsHeading'))
        $lines[1] | Should -Be ('  [1] Onar  [' + (Get-Translation 'RiskCAUTION') + '] - A > B')
        $lines[2] | Should -Be ''
        $lines[3] | Should -Be '  [2] Bak'
        $lines.Count | Should -Be 4
        $withWhat = @(Get-WtReplSuggestionLines -Suggestions @(@{ Label = 'DiagTrack'; Path = 'Servisler'; Risk = 'SAFE'; What = 'Telemetri yukleme servisi' }, @{ Label = 'Bak'; Path = ''; Risk = ''; What = '' }))
        $withWhat[1] | Should -Be ('  [1] DiagTrack  [' + (Get-Translation 'RiskSAFE') + '] - Servisler')
        $withWhat[2] | Should -Be '      Telemetri yukleme servisi'
        $withWhat[3] | Should -Be ''
        $withWhat[4] | Should -Be '  [2] Bak'
        $withWhat.Count | Should -Be 5
        $bare = @(Get-WtReplSuggestionLines -Suggestions @(@{ Label = 'X'; Path = 'P'; Risk = '' }))
        $bare[1] | Should -Be '  [1] X - P'
        $bare.Count | Should -Be 2
    }

    It 'the transcript tail keeps the last N printed lines plus the suggestions' {
        $session = New-WtReplSession
        for ($i = 1; $i -le 50; $i++) { $session.Entries.Add(@{ Kind = 'Info'; Text = "l$i" }) }
        $session.Suggestions = @(@{ Label = 'S'; Path = ''; Risk = '' }, @{ Label = 'T'; Path = ''; Risk = '' })
        $tail = (Get-WtReplTranscriptTail -Session $session -Count 40)
        $tailTexts = @($tail | ForEach-Object { (@($_) | ForEach-Object { $_.T }) -join '' })
        @($tailTexts | Where-Object { $_.StartsWith('  i l', [System.StringComparison]::Ordinal) }).Count | Should -Be 40
        $tailTexts[0] | Should -Be '  i l11'
        $tailTexts[-3..-1] | Should -Be @('  [1] S', '', '  [2] T')
        $script:Printed = @()
        Reset-WtReplBlockState
        Write-WtReplTranscriptTail -Session $session -Count 40 -Write { param($Text, $Fg) $script:Printed += @($Text) }
        @($script:Printed).Count | Should -Be $tail.Count
    }

    It 'the transcript tail opens with one blank when it follows the welcome, and none after the header blank' {
        $session = New-WtReplSession
        $session.Entries.Add(@{ Kind = 'User'; Text = 'soru' })
        $script:Printed = @()
        Reset-WtReplBlockState
        Write-WtReplWelcome -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @([string]$Text) }
        $welcomeRows = @($script:Printed).Count
        @($script:Printed)[-1].Trim() | Should -Not -Be ''
        Write-WtReplTranscriptTail -Session $session -Count 40 -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @([string]$Text) }
        @($script:Printed)[$welcomeRows].Trim() | Should -Be ''
        @($script:Printed)[$welcomeRows + 1] | Should -BeLike '*soru*'
        $script:Printed = @()
        Reset-WtReplBlockState
        Write-WtReplTranscriptTail -Session $session -Count 40 -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @([string]$Text) }
        @($script:Printed)[0] | Should -BeLike '*soru*'
    }

    It 'reflows a stored answer to the width it is reprinted at' {
        $session = New-WtReplSession
        Add-WtChatEntry -State $session -Kind 'Assistant' -Text ('kelime ' * 30) -Silent
        $narrow = (Get-WtReplTranscriptTail -Session $session -Count 400 -Width 40)
        $wide = (Get-WtReplTranscriptTail -Session $session -Count 400 -Width 120)
        $narrow.Count | Should -BeGreaterThan $wide.Count
        foreach ($r in $narrow) { ((@($r) | ForEach-Object { [string]$_.T }) -join '').Length | Should -BeLessOrEqual 39 }
    }

    It 'Write-WtReplLine and Write-WtReplStream go through the writer seam; the stream buffer collects pieces' {
        $script:Printed = @()
        Write-WtReplLine -Text 'hi' -Fg 'Gray' -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        $script:Printed[0] | Should -Be ((' ' * (Get-WtReplMargin)) + 'hi|Gray|False')
        Write-WtReplLine -Text 'banner' -Fg 'Cyan' -NoMargin -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        $script:Printed[1] | Should -Be 'banner|Cyan|False'
        Write-WtReplLine -Text '' -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        $script:Printed[2] | Should -Be '|Gray|False'
        Reset-WtReplStream
        Reset-WtReplBlockState
        $script:Printed = @()
        Write-WtReplStream -Piece 'ab' -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        Write-WtReplStream -Piece 'cd' -Kind 'Reasoning' -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        @($script:Printed).Count | Should -Be 0
        ($script:Printed -join "`n") | Should -Not -Match 'cd'
        (Get-WtReplStreamText -Kind 'Reasoning') | Should -Be 'cd'
        Get-WtReplStreamText | Should -Be ("cd`nab")
        Get-WtReplStreamText -Kind 'Content' | Should -Be 'ab'
        Reset-WtReplStream
        Reset-WtReplBlockState
        $script:Printed = @()
        Write-WtReplStream -Piece 'first' -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        Write-WtReplStream -Piece " second`n" -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Printed += @("$Text|$Fg|$NoNewline") }
        (@($script:Printed | ForEach-Object { $_.Split('|')[0] }) -join '').Trim() | Should -Be 'first second'
        ($script:Printed -join '') | Should -Not -Match ([regex]::Escape([string]$script:WtGlyphs.Bullet))
    }
}

Describe 'Read-WtReplLine (scripted keys, forced Key mode)' {
    BeforeEach { $script:OldMode = $script:WtInputMode; $script:WtInputMode = 'Key'; $script:Printed = New-Object System.Text.StringBuilder }
    AfterEach { $script:WtInputMode = $script:OldMode }

    It 'submits typed text, cancels on Esc, reports Ctrl+C, and treats exhausted keys as Eof' {
        New-WtKeyQueue -Keys (@(T 'ab') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) [void]$script:Printed.Append($Text) } -Width 80
        $r.Kind | Should -Be 'Submit'; $r.Text | Should -Be 'ab'
        $script:Printed.ToString() | Should -Match '> ab'
        New-WtKeyQueue -Keys @(K 'Escape' ([string][char]27))
        (Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) } -Width 80).Kind | Should -Be 'Cancel'
        New-WtKeyQueue -Keys (@(T 'x') + @(K 'C' ([string][char]3) 'Control'))
        $c = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) } -Width 80
        $c.Kind | Should -Be 'CtrlC'; $c.Text | Should -Be 'x'
        New-WtKeyQueue -Keys @()
        (Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) } -Width 80).Kind | Should -Be 'Eof'
    }

    It 'a pasted burst with an Enter in the middle becomes one multi-line submit' {
        New-WtKeyQueue -Keys (@(T 'ab') + @(K 'Enter' ([string][char]13)) + @(T 'cd'))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) } -Width 80
        $r.Kind | Should -Be 'Eof'
        New-WtKeyQueue -Keys (@(T 'ab') + @(K 'Enter' ([string][char]13)) + @(T 'cd') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) } -Width 80
        $r.Kind | Should -Be 'Submit'
        $r.Text | Should -Be ('ab' + "`n" + 'cd')
    }

    It 'Up recalls history and -Secret masks the echo' {
        New-WtKeyQueue -Keys @((K 'UpArrow'), (K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -History @('eski') -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) } -Width 80
        $r.Text | Should -Be 'eski'
        New-WtKeyQueue -Keys (@(T 'pw') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt 'key: ' -Secret -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) [void]$script:Printed.Append($Text) } -Width 80
        $r.Text | Should -Be 'pw'
        $script:Printed.ToString() | Should -Not -Match 'pw'
        $script:Printed.ToString() | Should -Match '\*\*'
    }
}

Describe 'Read-WtReplAnswer and the cancel poll' {
    It 'prints the lines then reads one answer; a cancel is $null' {
        $script:Printed = @()
        $script:SeenPrompt = $null
        $a = Read-WtReplAnswer -Lines @('l1', 'l2') -Prompt 'Allow?' -Risk 'CAUTION' -ReadLine { param($Prompt) $script:SeenPrompt = $Prompt; @{ Kind = 'Submit'; Text = 'y' } } -Write { param($Text, $Fg, $NoNewline) $script:Printed += @($Text) }
        $a | Should -Be 'y'
        $script:Printed | Should -Contain 'l1'
        $script:Printed | Should -Contain 'Allow?'
        $script:SeenPrompt | Should -Be (Get-Translation 'AsReplAnswerPrompt')
        (Read-WtReplAnswer -Lines @() -Prompt 'p' -ReadLine { param($Prompt) @{ Kind = 'CtrlC'; Text = '' } } -Write { param($Text, $Fg, $NoNewline) }) | Should -BeNullOrEmpty
    }

    It 'the cancel poll drains queued keys and fires on Esc or Ctrl+C only' {
        New-WtKeyQueue -Keys @((K 'A' 'a'), (K 'B' 'b'))
        Test-WtReplCancelRequested -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam | Should -BeFalse
        $script:KeyQueue.Count | Should -Be 0
        New-WtKeyQueue -Keys @((K 'A' 'a'), (K 'Escape' ([string][char]27)))
        Test-WtReplCancelRequested -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam | Should -BeTrue
        New-WtKeyQueue -Keys @(K 'C' ([string][char]3) 'Control')
        Test-WtReplCancelRequested -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam | Should -BeTrue
    }
}

Describe 'Add-WtChatEntry prints in REPL mode' {
    It 'appends always; prints only while the REPL is active and not -Silent' {
        $s = New-WtReplSession
        $script:WtReplMode = $false
        Add-WtChatEntry -State $s -Kind 'Info' -Text 'a'
        $s.Entries.Count | Should -Be 1
        $script:WtReplMode = $true
        try {
            Mock Write-WtReplEntry { }
            Add-WtChatEntry -State $s -Kind 'Info' -Text 'b'
            Add-WtChatEntry -State $s -Kind 'Assistant' -Text 'c' -Silent
            Should -Invoke Write-WtReplEntry -Times 1 -Exactly
            $s.Entries.Count | Should -Be 3
        }
        finally { $script:WtReplMode = $false }
    }
}

Describe 'The live region (Show/Hide-WtReplLive)' {
    BeforeEach { Reset-WtReplBlockState; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }; $script:Raw = New-Object System.Text.StringBuilder }
    AfterEach { Reset-WtReplBlockState; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }; $script:WtReplLiveEnabled = $false }

    It 'leads with ONE blank row when the last committed row is not blank, so the spinner and the input box never sit glued under the transcript' {
        $script:WtReplLiveEnabled = $true
        $oldVt = $script:WtVt; $script:WtVt = $false
        try {
            $rows = @(@(, (New-WtSeg -Text 'top' -Fg 'Cyan')), @(, (New-WtSeg -Text '| > ab' -Fg 'White')), @(, (New-WtSeg -Text 'bottom' -Fg 'Cyan')))
            $script:WtReplLastBlank = $false
            Show-WtReplLive -Rows $rows -CaretRow 1 -CaretCol 5 -Width 24 -Write { param($Text) [void]$script:Raw.Append($Text) }
            $out = $script:Raw.ToString()
            $out | Should -Match ('^' + [regex]::Escape($E + '[?25l' + "`r") + (' ' * 23) + "`ntop")
            $script:WtReplLive.Rows | Should -Be 4
            $script:WtReplLive.CaretRow | Should -Be 2
            $script:Raw = New-Object System.Text.StringBuilder
            Hide-WtReplLive -Write { param($Text) [void]$script:Raw.Append($Text) }
            $script:Raw.ToString() | Should -Match ([regex]::Escape($E + '[2A' + $E + '[J'))
            $script:WtReplLastBlank = $true
            Show-WtReplLive -Rows $rows -CaretRow 1 -CaretCol 5 -Width 24 -Write { param($Text) }
            $script:WtReplLive.Rows | Should -Be 3
            $script:WtReplLastBlank = $false; $script:WtReplToolBoxOpen = $true
            Show-WtReplLive -Rows $rows -CaretRow 1 -CaretCol 5 -Width 24 -Write { param($Text) }
            $script:WtReplLive.Rows | Should -Be 3
        }
        finally { $script:WtVt = $oldVt; $script:WtReplToolBoxOpen = $false }
    }

    It 'paints the rows joined by LF with no trailing newline, parks the caret on the caret row/col and remembers the row count' {
        $script:WtReplLiveEnabled = $true
        $oldVt = $script:WtVt; $script:WtVt = $false
        try {
            $rows = @(@(, (New-WtSeg -Text 'top' -Fg 'Cyan')), @(, (New-WtSeg -Text '| > ab' -Fg 'White')), @(, (New-WtSeg -Text 'bottom' -Fg 'Cyan')))
            Show-WtReplLive -Rows $rows -CaretRow 1 -CaretCol 5 -Width 24 -Write { param($Text) [void]$script:Raw.Append($Text) }
            $out = $script:Raw.ToString()
            $out | Should -Match ('^' + [regex]::Escape($E + '[?25l' + "`r") + 'top' + (' ' * 20) + "`n" + '\| > ab' + (' ' * 17) + "`nbottom")
            $out | Should -Not -Match "bottom +`n"
            $out | Should -Match ([regex]::Escape($E + '[1A'))
            $out | Should -Match ([regex]::Escape("`r" + $E + '[6G'))
            $out | Should -Match ([regex]::Escape($E + '[?25h'))
            $script:WtReplLive.Rows | Should -Be 3
            $script:WtReplLive.CaretRow | Should -Be 1
        }
        finally { $script:WtVt = $oldVt }
    }

    It 'hides by returning to the first row of the region and erasing to the end of screen, then forgets the region; a second hide writes nothing' {
        $script:WtReplLiveEnabled = $true
        $script:WtReplLive = @{ Rows = 3; CaretRow = 1 }
        Hide-WtReplLive -Write { param($Text) [void]$script:Raw.Append($Text) }
        $script:Raw.ToString() | Should -Be ("`r" + $E + '[1A' + $E + '[J' + $E + '[?25h')
        $script:WtReplLive.Rows | Should -Be 0
        $script:Raw = New-Object System.Text.StringBuilder
        Hide-WtReplLive -Write { param($Text) [void]$script:Raw.Append($Text) }
        $script:Raw.Length | Should -Be 0
        $script:WtReplLive = @{ Rows = 1; CaretRow = 0 }
        Hide-WtReplLive -Write { param($Text) [void]$script:Raw.Append($Text) }
        $script:Raw.ToString() | Should -Be ("`r" + $E + '[J' + $E + '[?25h')
    }

    It 'a caret row of -1 hides the cursor and parks it on the last row; Show overwrites the previous region in place and erases only what is left below' {
        $script:WtReplLiveEnabled = $true
        $script:WtReplLive = @{ Rows = 2; CaretRow = 0 }
        Show-WtReplLive -Rows @(, @(, (New-WtSeg -Text 'spin' -Fg 'DarkYellow'))) -CaretRow -1 -Width 20 -Write { param($Text) [void]$script:Raw.Append($Text) }
        $out = $script:Raw.ToString()
        $out.IndexOf($E + '[J') | Should -BeGreaterThan $out.IndexOf('spin')
        $out | Should -Match ([regex]::Escape($E + '[?25l'))
        $out | Should -Not -Match ([regex]::Escape($E + '[?25h'))
        $script:WtReplLive.Rows | Should -Be 1
    }

    It 'a repaint over a taller region climbs to its first row in the same write, so one console write does the whole update' {
        $script:WtReplLiveEnabled = $true
        $script:Writes = 0
        $script:WtReplLive = @{ Rows = 4; CaretRow = 2 }
        $rows = @(@(, (New-WtSeg -Text 'a' -Fg 'White')), @(, (New-WtSeg -Text 'b' -Fg 'White')))
        Show-WtReplLive -Rows $rows -CaretRow 1 -CaretCol 0 -Width 20 -Write { param($Text) $script:Writes++; [void]$script:Raw.Append($Text) }
        $script:Writes | Should -Be 1
        $out = $script:Raw.ToString()
        $out | Should -Match ('^' + [regex]::Escape($E + '[?25l' + "`r" + $E + '[2A') + 'a')
        $out.IndexOf($E + '[J') | Should -BeGreaterThan $out.IndexOf('b')
        $script:WtReplLive.Rows | Should -Be 2
        $script:WtReplLive.CaretRow | Should -Be 1
    }

    It 'does nothing at all when the live region is disabled (Line mode / no VT)' {
        $script:WtReplLiveEnabled = $false
        Show-WtReplLive -Rows @(, @(, (New-WtSeg -Text 'x' -Fg 'White'))) -Width 20 -Write { param($Text) throw 'must not write' }
        $script:WtReplLive.Rows | Should -Be 0
    }

    It 'a region taller than the window is cut from the FRONT and the caret row follows the cut' {
        $script:WtReplLiveEnabled = $true
        $oldVt = $script:WtVt; $script:WtVt = $false
        try {
            $rows = @(0..39 | ForEach-Object { , @(, (New-WtSeg -Text ('r{0:d2}' -f $_) -Fg 'White')) })
            Show-WtReplLive -Rows $rows -CaretRow 39 -Height 25 -Width 40 -Write { param($Text) [void]$script:Raw.Append($Text) }
            $out = $script:Raw.ToString()
            @([regex]::Matches($out, "`n")).Count | Should -Be 23
            $out | Should -Match ('^' + [regex]::Escape($E + '[?25l' + "`r") + 'r16')
            $out | Should -Not -Match 'r15'
            $script:WtReplLive.Rows | Should -Be 24
            $script:WtReplLive.CaretRow | Should -Be 23
            $script:Raw = New-Object System.Text.StringBuilder
            Show-WtReplLive -Rows $rows -CaretRow 2 -Height 25 -Width 40 -Write { param($Text) [void]$script:Raw.Append($Text) }
            $script:WtReplLive.CaretRow | Should -Be 23
            $script:Raw.ToString() | Should -Match ([regex]::Escape($E + '[?25l'))
        }
        finally { $script:WtVt = $oldVt }
    }

    It 'every transcript writer hides the region before it prints' {
        $script:WtReplLiveEnabled = $true
        foreach ($call in @(
            { Write-WtReplLine -Text 'x' -Write { param($T, $F, $N) $script:Order += @('print') } },
            { Write-WtReplEntry -Kind 'Info' -Text 'x' -Write { param($T, $F, $N) $script:Order += @('print') } },
            { Reset-WtReplStream; Reset-WtReplBlockState; Write-WtReplStream -Piece "x`n" -Width 80 -Write { param($T, $F, $N) $script:Order += @('print') } },
            { Write-WtReplSuggestions -Suggestions @(@{ Label = 'a'; Path = ''; Risk = '' }) -Write { param($T, $F, $N) $script:Order += @('print') } },
            { $s = New-WtReplSession; $s.Entries.Add(@{ Kind = 'Info'; Text = 'x' }); Write-WtReplTranscriptTail -Session $s -Write { param($T, $F, $N) $script:Order += @('print') } },
            { Write-WtReplRows -Rows @(, @(, (New-WtSeg -Text 'r' -Fg 'White'))) -Width 20 -Write { param($T, $F, $N) $script:Order += @('print') } }
        )) {
            $script:Order = @()
            $script:WtReplLive = @{ Rows = 2; CaretRow = 1 }
            Mock Hide-WtReplLive { $script:Order += @('hide'); $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }
            & $call
            $script:Order[0] | Should -Be 'hide'
            $script:Order | Should -Contain 'print'
        }
    }
}

Describe 'Clear-WtReplScreen' {
    It 'clears through Clear-Host first, then drops the scrollback and homes the cursor - never ESC[2J, which conhost turns into a blank gap above the banner' {
        $oldVt = $script:WtVt; $script:WtVt = $true; $script:WtReplLiveEnabled = $true
        try {
            $script:Raw = New-Object System.Text.StringBuilder
            $script:Cleared = 0
            Clear-WtReplScreen -Write { param($Text) [void]$script:Raw.Append($Text) } -ClearHost { $script:Cleared++ }
            $script:Cleared | Should -Be 1
            $script:Raw.ToString() | Should -Be ($E + '[3J' + $E + '[1;1H')
            $script:Raw.ToString() | Should -Not -Match '\[2J'
        }
        finally { $script:WtVt = $oldVt; $script:WtReplLiveEnabled = $false }
    }

    It 'without VT it clears through the ClearHost seam' {
        $oldVt = $script:WtVt; $script:WtVt = $false
        try {
            $script:Cleared = 0
            Clear-WtReplScreen -Write { param($Text) throw 'no vt' } -ClearHost { $script:Cleared++ }
            $script:Cleared | Should -Be 1
        }
        finally { $script:WtVt = $oldVt }
    }
}

Describe 'Write-WtReplHeader' {
    It 'prints the banner, the credits and the breadcrumb as the PATH ROW of a box (like every framed screen), then a blank row, and no welcome box' {
        $out = New-Object System.Collections.Generic.List[string]
        $w = { param($Text, $Fg, $NoNewline) $out.Add([string]$Text) }
        Write-WtReplHeader -Width 100 -Write $w
        $crumb = (Get-Translation 'MainMenu') + ' > ' + (Get-Translation 'Assistant')
        $g = $script:WtGlyphs
        $top = [string]$out[-4]
        $top | Should -Be ([string]$g.TL + ([string]$g.H * 97) + [string]$g.TR)
        $path = [string]$out[-3]
        $path.StartsWith([string]$g.V + ' ' + $crumb, [System.StringComparison]::Ordinal) | Should -BeTrue
        $path.Length | Should -Be 99
        $path.EndsWith(' ' + [string]$g.V, [System.StringComparison]::Ordinal) | Should -BeTrue
        $bottom = [string]$out[-2]
        $bottom | Should -Be ([string]$g.BL + ([string]$g.H * 97) + [string]$g.BR)
        ([string]$out[-1]).Trim() | Should -Be ''
        @($out).Count | Should -Be (@(Get-WtBannerLines -Width 100).Count + 8)
    }

    It 'records the width it drew at, so a later resize has a baseline to compare against' {
        $script:WtReplPageWidth = 0
        Write-WtReplHeader -Width 100 -Write { param($Text, $Fg, $NoNewline) }
        $script:WtReplPageWidth | Should -Be 100
        Write-WtReplHeader -Width 64 -Write { param($Text, $Fg, $NoNewline) }
        $script:WtReplPageWidth | Should -Be 64
        $script:WtReplPageWidth = 0
    }
}

Describe 'Read-WtReplLine in live mode' {
    BeforeEach {
        Reset-WtReplBlockState
        $script:OldMode = $script:WtInputMode; $script:OldVt = $script:WtVt
        $script:WtInputMode = 'Key'; $script:WtVt = $false; $script:WtReplLiveEnabled = $true; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        $script:Raw = New-Object System.Text.StringBuilder
        $script:Lines = @()
        Mock Write-WtReplLine { $script:Lines += @("$Text|$Fg") }
    }
    AfterEach { Reset-WtReplBlockState; $script:WtInputMode = $script:OldMode; $script:WtVt = $script:OldVt; $script:WtReplLiveEnabled = $false; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }

    It 'an Enter on an empty line commits NO "> " row to the transcript (-EchoAsUser), while a typed line is echoed' {
        $script:Entries = @()
        Mock Write-WtReplEntry { $script:Entries += @("$Kind|$Text") }
        New-WtKeyQueue -Keys @(K 'Enter' ([string][char]13))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -Width 40 -EchoAsUser
        $r.Kind | Should -Be 'Submit'; $r.Text | Should -Be ''
        $script:Entries.Count | Should -Be 0
        $script:WtReplLive.Rows | Should -Be 0
        New-WtKeyQueue -Keys (@(T '  ') + @(K 'Enter' ([string][char]13)))
        $null = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -Width 40 -EchoAsUser
        $script:Entries.Count | Should -Be 0
        New-WtKeyQueue -Keys (@(T 'hi') + @(K 'Enter' ([string][char]13)))
        $null = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -Width 40 -EchoAsUser
        $script:Entries | Should -Be @('User|hi')
    }

    It 'paints the box with the status rows under it, commits "> text" on Enter and leaves no live region behind' {
        New-WtKeyQueue -Keys @((T 'hi') + @(K 'Enter' ([string][char]13)))
        $status = @(, @(, (New-WtSeg -Text '  status' -Fg 'DarkGray')))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 40 -StatusRows $status -Placeholder 'ph'
        $r.Kind | Should -Be 'Submit'; $r.Text | Should -Be 'hi'
        $out = $script:Raw.ToString()
        $out | Should -Match 'ph'
        $out | Should -Match '  status'
        $out | Should -Match '\| > hi'
        $script:WtReplLive.Rows | Should -Be 0
        $script:Lines[-1] | Should -Be '> hi|Cyan'
    }

    It 'a paste burst is applied as one edit and painted once' {
        New-WtKeyQueue -Keys @((T 'abc') + @(K 'Enter' ([string][char]13)))
        $script:Paints = 0
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable $script:AvailSeam -Write { param($Text) $script:Paints++ } -Width 40
        $r.Text | Should -Be 'abc'
        $script:Paints | Should -BeLessOrEqual 3
    }

    It 'Ctrl+V inserts the clipboard text through the seam, folding CRLF' {
        New-WtKeyQueue -Keys @(@(K 'V' '' 'Control'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -Width 40 -GetClipboard { "one`r`ntwo" }
        $r.Text | Should -Be "one`ntwo"
        New-WtKeyQueue -Keys @(@(K 'V' '' 'Control'), @(K 'Enter' ([string][char]13)))
        (Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -Width 40 -GetClipboard { throw 'no clipboard' }).Text | Should -Be ''
    }

    It 'typing a slash shows the popup instead of the status rows; Tab completes' {
        New-WtKeyQueue -Keys @((T '/mo') + @(K 'Tab' ([string][char]9)) + @(K 'Enter' ([string][char]13)))
        $status = @(, @(, (New-WtSeg -Text '  STATUS' -Fg 'DarkGray')))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60 -StatusRows $status
        $r.Text | Should -Be '/model '
        $out = $script:Raw.ToString()
        $out | Should -Match '> /model'
        ($out -split '/mo' | Select-Object -Last 2)[0] | Should -Not -Match 'STATUS'
    }

    It 'a secret line echoes stars, never the text' {
        New-WtKeyQueue -Keys @((T 'sk') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt 'k: ' -Secret -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 40
        $r.Text | Should -Be 'sk'
        $script:Raw.ToString() | Should -Not -Match 'sk'
        $script:Lines[-1] | Should -Be 'k: **|Cyan'
    }

    It 'never queries the console inside the key loop (Get-WtConsoleSize is the only sanctioned accessor)' {
        (Get-Command Read-WtReplLine).Definition | Should -Not -Match '\[Console\]::Cursor'
        (Get-Command Read-WtReplLine).Definition | Should -Not -Match 'WindowHeight'
    }

    It 'a resize seen while WAITING for a key (the -WaitKey seam) hands the page owner a Resize at once, with the typed draft on it, and consumes no key' {
        Mock Get-WtConsoleSize { @{ Width = 70; Height = 30 } }
        New-WtKeyQueue -Keys @(@(T 'x') + @(K 'Enter' ([string][char]13)))
        $script:Waits = 0
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -AllowResize -InitialText 'yarim' `
            -WaitKey { $script:Waits++; if ($script:Waits -eq 1) { 'Resize' } else { 'Key' } }
        $r.Kind | Should -Be 'Resize'
        $r.Text | Should -Be 'yarim'
        $script:KeyQueue.Count | Should -Be 2
        $script:Paint = New-Object System.Collections.Generic.List[string]
        $script:Waits = 0
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) [void]$script:Paint.Add([string]$Text) } -QuestionLines @('soru?') -QuestionTitle 'T' `
            -WaitKey { $script:Waits++; if ($script:Waits -eq 1) { 'Resize' } else { 'Key' } }
        $r.Kind | Should -Be 'Submit'
        $r.Text | Should -Be 'x'
        @($script:Paint | Where-Object { $_ -match 'soru\?' }).Count | Should -BeGreaterOrEqual 3
    }

    It 'the draft restored through -InitialText is edited from its end' {
        New-WtKeyQueue -Keys @(@(T 'c') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -InitialText 'ab'
        $r.Kind | Should -Be 'Submit'
        $r.Text | Should -Be 'abc'
    }

    It 'the size poll is armed by Enter-WtReplMode in Key mode and disarmed by Exit; tests never poll because they set the live flags directly' {
        $script:WtReplResizePoll | Should -BeFalse
        $oldVt = $script:WtVt; $oldMode = $script:WtReplMode
        try {
            $script:WtVt = $false; $script:WtReplMode = $false
            Enter-WtReplMode -Write { param($Text) } -SetConsole { param($Name, $Value) } -GetConsole { param($Name) 50 }
            $script:WtReplResizePoll | Should -BeTrue
            Exit-WtReplMode -Write { param($Text) } -SetConsole { param($Name, $Value) }
            $script:WtReplResizePoll | Should -BeFalse
        }
        finally { $script:WtVt = $oldVt; $script:WtReplMode = $oldMode; $script:WtReplResizePoll = $false }
    }

    It 'a resize between keystrokes reaches the very next paint (the size is re-read outside a burst)' {
        $script:SizeCalls = 0
        Mock Get-WtConsoleSize { $script:SizeCalls++; if ($script:SizeCalls -le 1) { @{ Width = 40; Height = 40 } } else { @{ Width = 60; Height = 40 } } }
        New-WtKeyQueue -Keys @((T 'ab') + @(K 'Enter' ([string][char]13)))
        $script:Paint = New-Object System.Collections.Generic.List[string]
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) [void]$script:Paint.Add([string]$Text) }
        $r.Text | Should -Be 'ab'
        $boxes = @($script:Paint | Where-Object { $_ -match '> ab' })
        @($boxes).Count | Should -BeGreaterThan 0
        $first = @($boxes[-1] -split "`n")[0] -replace ('^' + [regex]::Escape($E + '[?25l' + "`r") + '(' + [regex]::Escape($E) + '\[\d+A)?'), ''
        $first.Length | Should -Be 59
    }
}

Describe 'Read-WtReplPick' {
    BeforeEach {
        $script:OldMode = $script:WtInputMode; $script:WtInputMode = 'Key'; $script:WtReplLiveEnabled = $true; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        $script:Raw = New-Object System.Text.StringBuilder
        Mock Write-WtReplLine { }
    }
    AfterEach { $script:WtInputMode = $script:OldMode; $script:WtReplLiveEnabled = $false; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }

    It 'Down+Enter picks the second option; a digit picks directly; a hotkey picks; Esc cancels; the region is gone afterwards' {
        $opts = @(@{ Label = 'Evet'; Hotkey = 'E' }, @{ Label = 'Hep'; Hotkey = 'T' }, @{ Label = 'Hayir'; Hotkey = 'H' })
        New-WtKeyQueue -Keys @(@(K 'DownArrow'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplPick -Title 't' -Lines @('q') -Options $opts -ReadKey $script:ReadKeySeam -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
        $r.Index | Should -Be 2; $r.Text | Should -Be 'Hep'
        $script:Raw.ToString() | Should -Match 'Evet \(e\)'
        $script:WtReplLive.Rows | Should -Be 0
        New-WtKeyQueue -Keys @(K 'D3' '3')
        (Read-WtReplPick -Options $opts -ReadKey $script:ReadKeySeam -Write { param($Text) } -Width 60).Index | Should -Be 3
        New-WtKeyQueue -Keys @(K 'T' 't')
        (Read-WtReplPick -Options $opts -ReadKey $script:ReadKeySeam -Write { param($Text) } -Width 60).Index | Should -Be 2
        New-WtKeyQueue -Keys @(K 'Escape')
        (Read-WtReplPick -Options $opts -ReadKey $script:ReadKeySeam -Write { param($Text) } -Width 60).Index | Should -Be 0
        New-WtKeyQueue -Keys @()
        (Read-WtReplPick -Options $opts -ReadKey $script:ReadKeySeam -Write { param($Text) } -Width 60).Index | Should -Be 0
    }

    It 'the text option opens the line reader and returns its text with Index 0' {
        New-WtKeyQueue -Keys @(@(K 'End'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplPick -Options @('a', 'b') -TextOption 'yaz' -ReadKey $script:ReadKeySeam -ReadLine { param($P) $script:SeenPrompt = $P; @{ Kind = 'Submit'; Text = 'http://x/v1' } } -Write { param($Text) } -Width 60
        $r.Index | Should -Be 0; $r.Text | Should -Be 'http://x/v1'
        $script:SeenPrompt | Should -Match 'yaz'
    }

    It 'in plain mode it prints a numbered list and reads a number or free text through -ReadLine' {
        $script:WtReplLiveEnabled = $false
        $script:Printed = @()
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $r = Read-WtReplPick -Title 'T' -Options @('a', 'b') -ReadLine { param($P) @{ Kind = 'Submit'; Text = '2' } }
        $r.Index | Should -Be 2; $r.Text | Should -Be 'b'
        $script:Printed | Should -Contain 'T'
        $script:Printed | Should -Contain '  2) b'
        (Read-WtReplPick -Options @('a') -TextOption 'yaz' -ReadLine { param($P) @{ Kind = 'Submit'; Text = 'free' } }).Text | Should -Be 'free'
        (Read-WtReplPick -Options @('a') -ReadLine { param($P) @{ Kind = 'Submit'; Text = 'free' } }).Index | Should -Be 0
    }
}

Describe 'Read-WtReplAnswer with choices' {
    It 'shows the lines and choices as a pick and returns the chosen letter; cancel is $null; without choices it is the text path' {
        $script:WtReplLiveEnabled = $true
        try {
            $choices = @(@{ Label = 'Evet'; Letter = 'E' }, @{ Label = 'Hayir'; Letter = 'H' })
            $a = Read-WtReplAnswer -Lines @('l1') -Prompt 'p' -Risk 'CAUTION' -Choices $choices -ReadPick { param($T, $L, $O, $R) $script:SeenRisk = $R; @{ Index = 2; Text = 'Hayir' } }
            $a | Should -Be 'H'
            $script:SeenRisk | Should -Be 'CAUTION'
            (Read-WtReplAnswer -Lines @() -Prompt 'p' -Choices $choices -ReadPick { param($T, $L, $O, $R) @{ Index = 0; Text = '' } }) | Should -BeNullOrEmpty
            (Read-WtReplAnswer -Lines @() -Prompt 'p' -ReadLine { param($P) @{ Kind = 'Submit'; Text = 'typed' } } -Write { param($T, $F, $N) }) | Should -Be 'typed'
        }
        finally { $script:WtReplLiveEnabled = $false }
    }

    It 'in plain mode the choices are printed as the prompt and the typed letter comes back' {
        $script:WtReplLiveEnabled = $false
        $script:Printed = @()
        $a = Read-WtReplAnswer -Lines @('l1') -Prompt 'p [e/h]' -Choices @(@{ Label = 'Evet'; Letter = 'E' }) -ReadLine { param($P) @{ Kind = 'Submit'; Text = 'e' } } -Write { param($T, $F, $N) $script:Printed += @($T) }
        $a | Should -Be 'e'
        $script:Printed | Should -Contain 'l1'
    }
}

Describe 'The spinner' {
    BeforeEach { Reset-WtReplBlockState; $script:WtReplLiveEnabled = $true; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }; $script:Raw = New-Object System.Text.StringBuilder; $script:Clock = [datetime]'2026-09-02T10:00:00' }
    AfterEach { Reset-WtReplBlockState; $script:WtReplLiveEnabled = $false; $script:WtReplSpinner = $null; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }

    It 'shows the label with elapsed seconds, repaints at most every 120 ms, counts chars, and hides cleanly' {
        $now = { $script:Clock }
        Show-WtReplSpinner -Label 'Dusunuyor...' -Now $now -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
        $script:Raw.ToString() | Should -Match 'Dusunuyor\.\.\. \(0 s'
        $script:WtReplLive.Rows | Should -Be 1
        $before = $script:Raw.Length
        $script:Clock = $script:Clock.AddMilliseconds(50)
        Update-WtReplSpinner -AddChars 500 -Now $now -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
        $script:Raw.Length | Should -Be $before
        $script:Clock = $script:Clock.AddSeconds(8)
        Update-WtReplSpinner -AddChars 800 -Now $now -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
        $script:Raw.ToString() | Should -Match '\(8 s - 1,3 KB'
        Hide-WtReplSpinner -Write { param($Text) [void]$script:Raw.Append($Text) }
        $script:WtReplLive.Rows | Should -Be 0
        $script:WtReplSpinner.Active | Should -BeFalse
        $len = $script:Raw.Length
        Update-WtReplSpinner -Force -Now $now -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
        $script:Raw.Length | Should -Be $len
    }

    It 'is silent when the live region is disabled but still counts' {
        $script:WtReplLiveEnabled = $false
        Show-WtReplSpinner -Label 'x' -Write { param($Text) throw 'no paint' }
        Update-WtReplSpinner -AddChars 10 -Force -Write { param($Text) throw 'no paint' }
        $script:WtReplSpinner.Chars | Should -Be 10
    }

    It 'the plain spinner sits at the transcript margin, not glued to the left edge' {
        $script:WtReplToolBoxOpen = $false
        Show-WtReplSpinner -Label 'Dusunuyor' -Now { $script:Clock } -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
        $margin = ' ' * (Get-WtReplMargin)
        (Get-WtReplMargin) | Should -BeGreaterThan 0
        $script:Raw.ToString() | Should -Match ([regex]::Escape($margin + 'Dusunuyor'))
    }

    It 'sits inside an open tool box and paints the box bottom in the live region, so the box never shows without its last side' {
        $g = $script:WtGlyphs
        $script:WtReplToolBoxOpen = $true; $script:WtReplToolBoxWidth = 60
        try {
            Show-WtReplSpinner -Label 'Calisiyor' -Now { $script:Clock } -Write { param($Text) [void]$script:Raw.Append($Text) } -Width 60
            $script:WtReplLive.Rows | Should -Be 2
            $painted = $script:Raw.ToString()
            $painted | Should -BeLike ('*' + [string]$g.V + ' *Calisiyor*')
            $painted | Should -BeLike ('*' + [string]$g.BL + ([string]$g.H * 57) + [string]$g.BR + '*')
            Hide-WtReplSpinner -Write { param($Text) [void]$script:Raw.Append($Text) }
            $script:WtReplLive.Rows | Should -Be 0
            $script:WtReplToolBoxOpen | Should -BeTrue
        }
        finally { $script:WtReplToolBoxOpen = $false; $script:WtReplToolBoxWidth = 0 }
    }

    It 'shows a running tool''s last output lines under the spinner, in a box of its own when none is open' {
        $g = $script:WtGlyphs
        $top = [string]$g.TL + ([string]$g.H * 57) + [string]$g.TR
        $bottom = [string]$g.BL + ([string]$g.H * 57) + [string]$g.BR
        $w = { param($Text) [void]$script:Raw.Append($Text) }
        Show-WtReplSpinner -Label 'Calisiyor: Winget' -Now { $script:Clock } -Write $w -Width 60
        $script:WtReplLive.Rows | Should -Be 1
        Update-WtReplSpinner -Force -Tail @('Starting package install...', '', 'Successfully installed') -Now { $script:Clock } -Write $w -Width 60
        $script:WtReplLive.Rows | Should -Be 5
        $painted = $script:Raw.ToString()
        $painted | Should -BeLike ('*' + $top + '*')
        $painted | Should -BeLike ('*      Successfully installed*')
        $painted | Should -BeLike ('*' + $bottom + '*')
        $script:WtReplToolBoxOpen = $true; $script:WtReplToolBoxWidth = 60
        try {
            Update-WtReplSpinner -Force -Now { $script:Clock } -Write $w -Width 60
            $script:WtReplLive.Rows | Should -Be 4
        }
        finally { $script:WtReplToolBoxOpen = $false; $script:WtReplToolBoxWidth = 0 }
    }

    It 'has no animated glyph and repaints only when the row text changes, not on every tick' {
        $now = { $script:Clock }
        $w = { param($Text) [void]$script:Raw.Append($Text) }
        Show-WtReplSpinner -Label 'Dusunuyor...' -Now $now -Write $w -Width 60
        $first = $script:Raw.ToString()
        foreach ($frame in [string]$script:WtGlyphs.Spinner) { $first.Contains([string]$frame) | Should -BeFalse -Because ('frame ' + $frame) }
        $script:Clock = $script:Clock.AddMilliseconds(200)
        $len = $script:Raw.Length
        Update-WtReplSpinner -Now $now -Write $w -Width 60
        $script:Raw.Length | Should -Be $len
        $script:Clock = $script:Clock.AddMilliseconds(900)
        Update-WtReplSpinner -Now $now -Write $w -Width 60
        $script:Raw.Length | Should -BeGreaterThan $len
        $script:Raw.ToString() | Should -Match '\(1 s'
    }
}

Describe 'Sync-WtReplResize (the window moved while the model works)' {
    BeforeEach {
        $script:WtReplMode = $true; $script:WtReplLiveEnabled = $true; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        $script:WtReplPageWidth = 80; $script:Out = New-Object System.Collections.Generic.List[string]
        $script:WtAssistantChat = New-WtReplSession
        Add-WtChatEntry -State $script:WtAssistantChat -Kind 'User' -Text 'soru' -Silent
        Reset-WtReplStream; Reset-WtReplBlockState
    }
    AfterEach { $script:WtReplMode = $false; $script:WtReplLiveEnabled = $false; $script:WtReplPageWidth = 0; $script:WtAssistantChat = $null; $script:WtReplStream = $null }

    It 'does nothing while the console is as wide as the page' {
        Mock Get-WtConsoleSize { @{ Width = 80; Height = 30 } }
        Mock Clear-WtReplScreen { }
        (Sync-WtReplResize -Force) | Should -BeFalse
        Should -Invoke Clear-WtReplScreen -Times 0
    }

    It 'repaints banner, breadcrumb, transcript and the streamed answer at the new width and keeps the answer text' {
        Mock Get-WtConsoleSize { @{ Width = 60; Height = 30 } }
        Mock Clear-WtReplScreen { }
        Mock Write-WtReplHeader { $script:WtReplPageWidth = $Width; $script:Out.Add('HEADER@' + $Width) }
        Mock Write-WtReplWelcome { $script:Out.Add('WELCOME@' + $Width) }
        Mock Get-WtReplDefaultWriter { { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) } }
        Write-WtReplStream -Piece "ilk satir`nikinci" -Width 80 -Write { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        $script:Out.Clear()
        (Sync-WtReplResize -Force) | Should -BeTrue
        $script:WtReplPageWidth | Should -Be 60
        $script:WtReplStream.Width | Should -Be 60
        $script:WtReplStream.Content.ToString() | Should -Be "ilk satir`nikinci"
        $script:WtReplStream.Buffer.ToString() | Should -Be 'ikinci'
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t[0] | Should -Be 'HEADER@60'
        $t[1] | Should -Be 'WELCOME@60'
        $t | Should -Contain '  > soru'
        $t | Should -Contain '  ilk satir'
        $script:Out.Clear()
        (Sync-WtReplResize -Force) | Should -BeFalse
        $script:Out.Count | Should -Be 0
    }
}

Describe 'QuickEdit around the REPL' {
    It 'Enter enables QuickEdit through the seam BEFORE taking Ctrl+C and Exit restores the saved mode AFTER giving Ctrl+C back' {
        $oldVt = $script:WtVt; $oldMode = $script:WtInputMode
        $script:WtVt = $true; $script:WtInputMode = 'Key'; $script:WtReplMode = $false
        try {
            $script:Calls = @()
            Mock Enable-WtReplQuickEdit { $script:Calls += @('quickedit'); 0x1F7 }
            Mock Restore-WtReplQuickEdit { param($Mode) $script:Calls += @("restore=$Mode") }
            $set = { param($Name, $Value) $script:Calls += @("$Name=$Value") }
            $get = { param($Name) switch ($Name) { 'BufferHeight' { 50 } 'CtrlC' { $false } 'WindowHeight' { 50 } } }
            Enter-WtReplMode -Write { param($Text) } -SetConsole $set -GetConsole $get
            [array]::IndexOf($script:Calls, 'quickedit') | Should -BeLessThan ([array]::IndexOf($script:Calls, 'CtrlC=True'))
            $script:WtReplConsoleModeSaved | Should -Be 0x1F7
            $script:Calls = @()
            Exit-WtReplMode -Write { param($Text) } -SetConsole $set
            [array]::IndexOf($script:Calls, 'CtrlC=False') | Should -BeLessThan ([array]::IndexOf($script:Calls, 'restore=503'))
        }
        finally { $script:WtVt = $oldVt; $script:WtInputMode = $oldMode; $script:WtReplMode = $false }
    }

    It 'a failing Apply is swallowed: Enable returns $null and Restore with $null does nothing' {
        (Enable-WtReplQuickEdit -Apply { throw 'no console' }) | Should -BeNullOrEmpty
        $script:Applied = 0
        Restore-WtReplQuickEdit -Mode $null -Apply { param($M) $script:Applied++ }
        $script:Applied | Should -Be 0
        Restore-WtReplQuickEdit -Mode 7 -Apply { param($M) $script:Applied++ }
        $script:Applied | Should -Be 1
    }
}

Describe 'Transcript vocabulary' {
    BeforeAll {
        $script:G = Get-WtGlyphSet -Unicode $false
        $script:Row = { param($R) (@($R) | ForEach-Object { [string]$_.T }) -join '' }
    }

    It 'prefixes the user line and wraps it under the prompt, inside the page margin' {
        $rows = (Get-WtReplEntryLines -Kind 'User' -Text 'aaaa bbbb cccc dddd eeee' -Width 22 -Glyphs $G)
        (& $Row $rows[0]) | Should -Be '  > aaaa bbbb cccc'
        (& $Row $rows[1]) | Should -Be '    dddd eeee'
        $rows[0][0].F | Should -Be 'Cyan'
    }

    It 'keeps you, the answer and the info lines two columns off BOTH window edges' {
        $rows = (Get-WtReplEntryLines -Kind 'Assistant' -Text ('kelime ' * 30) -Width 40 -Glyphs $G)
        $rows.Count | Should -BeGreaterThan 1
        foreach ($r in $rows) {
            $line = (& $Row $r)
            $line | Should -Match '^  \S'
            $line.TrimEnd().Length | Should -BeLessOrEqual 37
        }
        $u = (Get-WtReplEntryLines -Kind 'User' -Text ('soru ' * 20) -Width 40 -Glyphs $G)
        foreach ($r in $u) { (& $Row $r).TrimEnd().Length | Should -BeLessOrEqual 37 }
        $i = (Get-WtReplEntryLines -Kind 'Info' -Text ('bilgi ' * 20) -Width 40 -Glyphs $G)
        foreach ($r in $i) { (& $Row $r).TrimEnd().Length | Should -BeLessOrEqual 37 }
        $script:Out = New-Object System.Collections.Generic.List[string]
        Reset-WtReplStream; Reset-WtReplBlockState
        Write-WtReplStream -Piece ('kelime ' * 30) -Width 40 -Write { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        Write-WtReplStream -Piece "- madde madde madde madde madde madde madde`n" -Width 40 -Write { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        Complete-WtReplStream -Width 40 -Write { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        @($script:Out).Count | Should -BeGreaterThan 2
        foreach ($l in @($script:Out)) { if ($l.Trim()) { $l | Should -Match '^  \S'; $l.TrimEnd().Length | Should -BeLessOrEqual 37 } }
    }

    It 'renders an assistant entry through the rich layer' {
        $rows = (Get-WtReplEntryLines -Kind 'Assistant' -Text '**OneDrive** kapandi' -Width 80 -Glyphs $G)
        (& $Row $rows[0]) | Should -Be '  OneDrive kapandi'
        ($rows[0] | Where-Object { [string]$_.T -eq 'OneDrive' })[0].F | Should -Be 'White'
    }

    It 'colours a tool start line white up to the arguments' {
        $rows = (Get-WtReplEntryLines -Kind 'Tool' -Text '  * get_startup_items(limit: 5)' -Width 80 -Glyphs $G)
        $rows[0][0].T | Should -Be '  * get_startup_items'
        $rows[0][0].F | Should -Be 'White'
        $rows[0][1].T | Should -Be '(limit: 5)'
        $rows[0][1].F | Should -Be 'DarkGray'
    }

    It 'leaves a tool result line dark grey' {
        $rows = (Get-WtReplEntryLines -Kind 'Tool' -Text '    \ 0,4 sn' -Width 80 -Glyphs $G)
        @($rows[0]).Count | Should -Be 1
        $rows[0][0].F | Should -Be 'DarkGray'
    }

    It 'marks info and error lines two in' {
        (& $Row ((Get-WtReplEntryLines -Kind 'Info' -Text 'not kaydedildi' -Width 80 -Glyphs $G)[0])) | Should -Be '  i not kaydedildi'
        (& $Row ((Get-WtReplEntryLines -Kind 'Error' -Text 'baglanti yok' -Width 80 -Glyphs $G)[0])) | Should -Be '  ! baglanti yok'
    }
}

Describe 'Write-WtReplBlock' {
    It 'collapses runs of blank rows and never leads with one' {
        $out = New-Object System.Collections.Generic.List[string]
        $w = { param($Text, $Fg, $NoNewline) $out.Add([string]$Text) }
        Reset-WtReplBlockState
        Write-WtReplBlock -Rows @(, @(, (New-WtSeg -Text 'bir' -Fg 'Gray'))) -Separate -Width 40 -Write $w
        Write-WtReplBlock -Rows @(, @(, (New-WtSeg -Text 'iki' -Fg 'Gray'))) -Separate -Width 40 -Write $w
        Write-WtReplBlock -Rows @(, @(, (New-WtSeg -Text 'uc' -Fg 'Gray'))) -Width 40 -Write $w
        $trimmed = @($out | ForEach-Object { $_.TrimEnd() })
        $trimmed.Count | Should -Be 4
        $trimmed[0] | Should -Be 'bir'
        $trimmed[1] | Should -Be ''
        $trimmed[2] | Should -Be 'iki'
        $trimmed[3] | Should -Be 'uc'
    }

    It 'swallows a blank row that follows a blank row inside one block' {
        $out = New-Object System.Collections.Generic.List[string]
        $w = { param($Text, $Fg, $NoNewline) $out.Add([string]$Text) }
        Reset-WtReplBlockState
        $rows = @(
            @(, (New-WtSeg -Text 'a' -Fg 'Gray')),
            @(, (New-WtSeg -Text '' -Fg 'Gray')),
            @(, (New-WtSeg -Text '' -Fg 'Gray')),
            @(, (New-WtSeg -Text 'b' -Fg 'Gray'))
        )
        Write-WtReplBlock -Rows $rows -Width 40 -Write $w
        @($out).Count | Should -Be 3
    }

    It 'hides the live region before it writes' {
        $calls = New-Object System.Collections.Generic.List[string]
        $script:WtReplLive = @{ Rows = 2; CaretRow = 0 }
        $raw = { param($Text) $calls.Add('hide') }
        $w = { param($Text, $Fg, $NoNewline) $calls.Add('write') }
        Reset-WtReplBlockState
        Write-WtReplBlock -Rows @(, @(, (New-WtSeg -Text 'x' -Fg 'Gray'))) -Width 40 -Write $w -HideWrite $raw
        $calls[0] | Should -Be 'hide'
    }
}

Describe 'Streaming line buffer' {
    BeforeEach {
        $script:Out = New-Object System.Collections.Generic.List[string]
        $script:W = { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        Reset-WtReplStream
        Reset-WtReplBlockState
    }

    It 'prints nothing until a line completes' {
        Write-WtReplStream -Piece 'yarim ' -Width 80 -Write $W
        @($script:Out).Count | Should -Be 0
        Write-WtReplStream -Piece "satir`n" -Width 80 -Write $W
        (@($script:Out) | ForEach-Object { $_.Trim() }) | Should -Contain 'yarim satir'
    }

    It 'joins a word split across two pieces' {
        Write-WtReplStream -Piece 'One' -Width 80 -Write $W
        Write-WtReplStream -Piece "Drive kapandi`n" -Width 80 -Write $W
        (@($script:Out) | ForEach-Object { $_.Trim() }) | Should -Contain 'OneDrive kapandi'
    }

    It 'strips the marks it renders' {
        Write-WtReplStream -Piece "## Baslik`n" -Width 80 -Write $W
        (@($script:Out) | ForEach-Object { $_.Trim() }) | Should -Contain 'Baslik'
        (@($script:Out) | Where-Object { $_ -like '*##*' }).Count | Should -Be 0
    }

    It 'wraps a long line that never gets a newline' {
        Write-WtReplStream -Piece (('kelime ' * 40)) -Width 40 -Write $W
        @($script:Out).Count | Should -BeGreaterThan 1
        foreach ($l in @($script:Out)) { $l.TrimEnd().Length | Should -BeLessOrEqual 39 }
    }

    It 'waits when the overflowing buffer has no space to break at' {
        Write-WtReplStream -Piece ('z' * 200) -Width 40 -Write $W
        @($script:Out).Count | Should -Be 0
        Complete-WtReplStream -Width 40 -Write $W
        @($script:Out).Count | Should -BeGreaterThan 1
        foreach ($l in @($script:Out)) { $l.TrimEnd().Length | Should -BeLessOrEqual 39 }
        ((@($script:Out) | ForEach-Object { $_.Trim() }) -join '') | Should -Be ('z' * 200)
    }

    It 'flushes the tail on Complete and keeps Content raw' {
        Write-WtReplStream -Piece '**son** parca' -Width 80 -Write $W
        Complete-WtReplStream -Width 80 -Write $W
        (@($script:Out) | ForEach-Object { $_.Trim() }) | Should -Contain 'son parca'
        Get-WtReplStreamText -Kind 'Content' | Should -Be '**son** parca'
    }

    It 'never prints reasoning' {
        Write-WtReplStream -Piece "dusunuyorum`n" -Kind 'Reasoning' -Width 80 -Write $W
        @($script:Out).Count | Should -Be 0
        Get-WtReplStreamText -Kind 'Reasoning' | Should -Be "dusunuyorum`n"
    }

    It 'closes an unterminated fence on Complete' {
        $fence = ([string][char]96) * 3
        Write-WtReplStream -Piece ($fence + "`nGet-Service`n") -Width 80 -Write $W
        Complete-WtReplStream -Width 80 -Write $W
        $script:WtReplStream.Rich.InFence | Should -BeFalse
    }
}

Describe 'Read-WtReplLine question box' {
    It 'paints the question above the input box in the live region' {
        $script:WtReplLiveEnabled = $true
        $script:WtInputMode = 'Key'
        $painted = New-Object System.Collections.Generic.List[string]
        $w = { param($Text) $painted.Add([string]$Text) }
        $keys = New-Object System.Collections.Generic.Queue[object]
        foreach ($c in 'ok'.ToCharArray()) { $keys.Enqueue(@{ Key = 'Oem'; KeyChar = [string]$c; Modifiers = '' }) }
        $keys.Enqueue(@{ Key = 'Enter'; KeyChar = ''; Modifiers = '' })
        $r = Read-WtReplLine -Prompt '> ' -QuestionLines @('Anahtari yapistir') -QuestionTitle 'Soru' -Width 60 `
            -ReadKey { $keys.Dequeue() } -KeyAvailable { $keys.Count -gt 0 } -Write $w
        $r.Kind | Should -Be 'Submit'
        $r.Text | Should -Be 'ok'
        (($painted -join '') -like '*Anahtari yapistir*') | Should -BeTrue
        (($painted -join '') -like '*Soru*') | Should -BeTrue
    }
}

Describe 'Read-WtReplAnswer without choices' {
    BeforeEach { $script:OldLive = $script:WtReplLiveEnabled; $script:WtReplLiveEnabled = $true }
    AfterEach { $script:WtReplLiveEnabled = $script:OldLive }

    It 'sends the lines into the input box instead of the transcript' {
        $committed = New-Object System.Collections.Generic.List[string]
        $seen = $null
        $r = Read-WtReplAnswer -Lines @('Devam edilsin mi?') -Prompt 'Cevap' -Risk 'CAUTION' `
            -ReadLine { param($P, $Q, $T, $K) $script:seen = @($Q); @{ Kind = 'Submit'; Text = 'evet' } } `
            -Write { param($Text, $Fg, $NoNewline) $committed.Add([string]$Text) }
        $r | Should -Be 'evet'
        @($script:seen)[0] | Should -Be 'Devam edilsin mi?'
        @($committed).Count | Should -Be 0
    }
}

Describe 'Blank line rule across a turn (spec S4)' {
    BeforeEach {
        $script:Out = New-Object System.Collections.Generic.List[string]
        $script:W = { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        Reset-WtReplStream
        Reset-WtReplBlockState
    }

    It 'separates every change of speaker; tool rows sit inside ONE box that closes when someone else speaks' {
        $g = $script:WtGlyphs
        $top = [string]$g.TL + ([string]$g.H * 57) + [string]$g.TR
        $bottom = [string]$g.BL + ([string]$g.H * 57) + [string]$g.BR
        $row = { param([string]$Text) [string]$g.V + ' ' + $Text.PadRight(55) + ' ' + [string]$g.V }
        Write-WtReplEntry -Kind 'User' -Text 'soru' -Width 60 -Write $script:W
        Write-WtReplEntry -Kind 'Tool' -Text '  * get_startup_items()' -Width 60 -Write $script:W
        Write-WtReplEntry -Kind 'Tool' -Text '    ~ 0,4 sn' -Width 60 -Write $script:W
        Write-WtReplStream -Piece "Cevap satiri`n" -Width 60 -Write $script:W
        Complete-WtReplStream -Width 60 -Write $script:W
        Write-WtReplEntry -Kind 'Tool' -Text '  * verify()' -Width 60 -Write $script:W
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t[0] | Should -Be '  > soru'
        $t[1] | Should -Be ''
        $t[2] | Should -Be $top
        $t[3] | Should -Be (& $row '  * get_startup_items()')
        $t[4] | Should -Be (& $row '    ~ 0,4 sn')
        $t[5] | Should -Be $bottom
        $t[6] | Should -Be ''
        $t[7] | Should -Be '  Cevap satiri'
        $t[8] | Should -Be ''
        $t[9] | Should -Be $top
        $t[10] | Should -Be (& $row '  * verify()')
        $t.Count | Should -Be 11
        $script:WtReplToolBoxOpen | Should -BeTrue
        Write-WtReplLine -Text 'bitti' -Write $script:W
        @($script:Out | ForEach-Object { $_.TrimEnd() })[-2] | Should -Be $bottom
        $script:WtReplToolBoxOpen | Should -BeFalse
    }

    It 'leaves exactly one blank row between the breadcrumb box and the first message' {
        Write-WtReplHeader -Width 60 -Write $script:W
        Write-WtReplEntry -Kind 'User' -Text 'merhaba' -Width 60 -Write $script:W
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t[-1] | Should -Be '  > merhaba'
        $t[-2] | Should -Be ''
        $t[-3] | Should -Not -Be ''
        ([string]$t[-3]).StartsWith([string]$script:WtGlyphs.BL, [System.StringComparison]::Ordinal) | Should -BeTrue
        ([string]$t[-4]).IndexOf((Get-WtBreadcrumb -Keys 'MainMenu', 'Assistant'), [System.StringComparison]::Ordinal) | Should -BeGreaterThan 0
    }

    It 'Write-WtReplLine keeps the blank flag honest' {
        Write-WtReplLine -Text 'komut ciktisi' -Write $script:W
        Write-WtReplBlock -Rows @(, @(, (New-WtSeg -Text 'blok' -Fg 'Gray'))) -Separate -Width 40 -Write $script:W
        Write-WtReplLine -Text '' -Write $script:W
        Write-WtReplBlock -Rows @(, @(, (New-WtSeg -Text 'ikinci' -Fg 'Gray'))) -Separate -Width 40 -Write $script:W
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t | Should -Be @('  komut ciktisi', '', 'blok', '', 'ikinci')
    }

    It 'reopens the transcript after a slash command printed line by line' {
        Write-WtReplEntry -Kind 'User' -Text '/yardim' -Width 40 -Write $script:W
        Write-WtReplLine -Text 'yardim metni' -Write $script:W
        Write-WtReplEntry -Kind 'User' -Text 'merhaba' -Width 40 -Write $script:W
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t | Should -Be @('  > /yardim', '  yardim metni', '', '  > merhaba')
    }
}

Describe 'Reprinted transcript (spec S4)' {
    It 'carries the same blank rows the live transcript has' {
        $session = New-WtReplSession
        $session.Entries.Add(@{ Kind = 'User'; Text = 'soru' })
        $session.Entries.Add(@{ Kind = 'Tool'; Text = '  * arac()' })
        $session.Entries.Add(@{ Kind = 'Tool'; Text = '    ~ 0,4 sn' })
        $session.Entries.Add(@{ Kind = 'Assistant'; Text = 'cevap' })
        $session.Entries.Add(@{ Kind = 'Tool'; Text = '  * verify()' })
        $session.Suggestions = @(@{ Label = 'S'; Path = ''; Risk = '' })
        $rows = (Get-WtReplTranscriptTail -Session $session -Count 400 -Width 60)
        $t = @($rows | ForEach-Object { ((@($_) | ForEach-Object { [string]$_.T }) -join '').TrimEnd() })
        $g = $script:WtGlyphs
        $top = [string]$g.TL + ([string]$g.H * 57) + [string]$g.TR
        $bottom = [string]$g.BL + ([string]$g.H * 57) + [string]$g.BR
        $row = { param([string]$Text) [string]$g.V + ' ' + $Text.PadRight(55) + ' ' + [string]$g.V }
        $t | Should -Be @(
            '  > soru', '', $top, (& $row '  * arac()'), (& $row '    ~ 0,4 sn'), $bottom, '', '  cevap', '', $top, (& $row '  * verify()'), $bottom, '',
            ('  ' + (Get-Translation 'AsSuggestionsHeading')), '  [1] S')
    }
}

Describe 'Streaming overflow cut (spec S4/S5.5)' {
    BeforeEach {
        $script:Out = New-Object System.Collections.Generic.List[string]
        $script:W = { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        Reset-WtReplStream
        Reset-WtReplBlockState
    }

    It 'never cuts inside an open bold mark' {
        Write-WtReplStream -Piece 'kelime kelime kelime kelime **kalin vurgu** devami' -Width 44 -Write $script:W
        @($script:Out).Count | Should -Be 0
        Complete-WtReplStream -Width 44 -Write $script:W
        $joined = (@($script:Out) | ForEach-Object { $_.Trim() }) -join ' '
        $joined.IndexOf('**', [System.StringComparison]::Ordinal) | Should -Be -1
        $joined.IndexOf('kalin vurgu', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'never cuts inside an open code span' {
        Write-WtReplStream -Piece 'kelime kelime kelime kelime `services msc` ac' -Width 44 -Write $script:W
        @($script:Out).Count | Should -Be 0
    }

    It 'keeps the continuation of a cut paragraph a paragraph' {
        Write-WtReplStream -Piece ((('kelime ' * 5)) + 'ab - devam eden cumle') -Width 44 -Write $script:W
        Complete-WtReplStream -Width 44 -Write $script:W
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t[0] | Should -Be '  kelime kelime kelime kelime kelime ab'
        $t[-1] | Should -Be '  - devam eden cumle'
    }

    It 'cuts a streamed bullet at its RENDERED width and prints the tail under the bullet text' {
        Write-WtReplStream -Piece ('- ' + ('kelime ' * 8)) -Width 40 -Write $script:W
        Complete-WtReplStream -Width 40 -Write $script:W
        $t = @($script:Out | ForEach-Object { $_.TrimEnd() })
        $t[0] | Should -Be ('    ' + [string]$script:WtGlyphs.ListBullet + ' kelime kelime kelime kelime')
        $t[1] | Should -Be '      kelime kelime kelime kelime'
        $t.Count | Should -Be 2
        foreach ($row in $t) { $row.Length | Should -BeLessOrEqual 37 }
        (Get-WtRichBlockIndents -Block @{ Kind = 'Bullet'; Marker = '' }).Continuation | Should -Be 4
        (Get-WtRichBlockIndents -Block @{ Kind = 'Numbered'; Marker = '12.' }).Continuation | Should -Be 6
        (Get-WtRichBlockIndents -Block @{ Kind = 'Paragraph'; Marker = '' }).First | Should -Be 0
    }
}

Describe 'Read-WtReplLine on a console resize' {
    BeforeEach {
        $script:OldMode = $script:WtInputMode; $script:OldVt = $script:WtVt
        $script:WtInputMode = 'Key'; $script:WtVt = $false; $script:WtReplLiveEnabled = $true; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        Mock Write-WtReplLine { }
        $script:WtReplPageWidth = 0
        $script:SizeCalls = 0
        Mock Get-WtConsoleSize { $script:SizeCalls++; if ($script:SizeCalls -le 1) { @{ Width = 40; Height = 30 } } else { @{ Width = 70; Height = 30 } } }
    }
    AfterEach {
        $script:WtInputMode = $script:OldMode; $script:WtVt = $script:OldVt
        $script:WtReplLiveEnabled = $false; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        $script:WtReplPageWidth = 0
    }

    It 'a resize that happened while the model was streaming repaints at the NEXT prompt, before any key is read' {
        $script:WtReplPageWidth = 90
        $script:KeyReads = 0
        Mock Get-WtConsoleSize { @{ Width = 40; Height = 30 } }
        New-WtKeyQueue -Keys @(@(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -ReadKey { $script:KeyReads++; & $script:ReadKeySeam } -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Resize'
        $r.Text | Should -Be ''
        $script:KeyReads | Should -Be 0
    }

    It 'the page width alone does not fire it: an untouched prompt at the painted width just waits' {
        $script:WtReplPageWidth = 40
        Mock Get-WtConsoleSize { @{ Width = 40; Height = 30 } }
        New-WtKeyQueue -Keys @(@(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Submit'
    }

    It 'a question prompt is never resized away at entry either' {
        $script:WtReplPageWidth = 90
        Mock Get-WtConsoleSize { @{ Width = 40; Height = 30 } }
        New-WtKeyQueue -Keys @(@(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -QuestionLines @('gercekten mi') `
            -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Submit'
    }

    It 'a question under a moved window repaints the whole page (Sync-WtReplResize) before the box, instead of painting over the reflowed old one' {
        Mock Sync-WtReplResize { $true }
        New-WtKeyQueue -Keys @(@(K 'LeftArrow') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -QuestionLines @('gercekten mi') -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Submit'
        Should -Invoke Sync-WtReplResize -Times 1 -Exactly
    }

    It 'hands the width change back as Resize when the edit line is empty' {
        New-WtKeyQueue -Keys @(K 'LeftArrow')
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Resize'
        $r.Text | Should -Be ''
        $script:WtReplLive.Rows | Should -Be 0
    }

    It 'never throws away a half-typed line: the Resize carries the text, so the page owner can hand it back as -InitialText' {
        New-WtKeyQueue -Keys @((T 'ya') + @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Resize'
        $r.Text | Should -Be 'y'
        $script:KeyQueue.Count | Should -Be 2
    }

    It 'a height-only change is not a resize' {
        $script:SizeCalls = 0
        Mock Get-WtConsoleSize { $script:SizeCalls++; if ($script:SizeCalls -le 1) { @{ Width = 40; Height = 30 } } else { @{ Width = 40; Height = 12 } } }
        New-WtKeyQueue -Keys @(@(K 'LeftArrow'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Submit'
    }

    It 'a question prompt re-wraps in place: a resize must never answer it' {
        New-WtKeyQueue -Keys @(@(K 'LeftArrow'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -QuestionLines @('gercekten mi') -QuestionTitle 'baslik' `
            -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Submit'
    }

    It 'a caller that cannot repaint its page never gets a Resize' {
        New-WtKeyQueue -Keys @(@(K 'LeftArrow'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) }
        $r.Kind | Should -Be 'Submit'
    }

    It 'a caller-fixed width is authoritative, so it never resizes' {
        New-WtKeyQueue -Keys @(@(K 'LeftArrow'), @(K 'Enter' ([string][char]13)))
        $r = Read-WtReplLine -Prompt '> ' -AllowResize -ReadKey $script:ReadKeySeam -KeyAvailable { $false } -Write { param($Text) } -Width 40
        $r.Kind | Should -Be 'Submit'
    }
}

Describe 'the pick title and a question taller than the window' {
    It 'Read-WtReplAnswer drops the "E: Evet - H: Hayir" tail from the title: the option rows carry the letters' {
        $script:WtReplLiveEnabled = $true
        try {
            $prompt = Get-WtYesNoPrompt -Text 'Anonimlestirilmis sistem verisi bu uc noktaya gonderilsin mi?'
            $script:SeenTitle = $null
            $null = Read-WtReplAnswer -Lines @('l1') -Prompt $prompt -Choices @(@{ Label = 'Evet'; Letter = 'E' }, @{ Label = 'Hayir'; Letter = 'H' }) -ReadPick { param($T, $L, $O, $R) $script:SeenTitle = $T; @{ Index = 1; Text = 'Evet' } }
            $script:SeenTitle | Should -Be 'Anonimlestirilmis sistem verisi bu uc noktaya gonderilsin mi?'
        }
        finally { $script:WtReplLiveEnabled = $false }
    }
    It 'Read-WtReplPick commits a question taller than the window to the transcript and keeps only the options in the box' {
        $script:WtReplLiveEnabled = $true
        $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        try {
            Mock Get-WtConsoleSize { @{ Width = 80; Height = 12 } }
            $script:committed = @()
            Mock Write-WtReplBlock { $script:committed += @(@($Rows).Count) }
            $script:boxRows = @()
            Mock Show-WtReplLive { $script:boxRows = @($Rows) }
            $question = @(1..15 | ForEach-Object { "soru satiri $_" })
            $enter = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)
            $r = Read-WtReplPick -Title 'T' -Lines $question -Options @(@{ Label = 'Evet'; Hotkey = 'E' }, @{ Label = 'Hayir'; Hotkey = 'H' }) -Risk 'CAUTION' -ReadKey { $enter } -Write { param($Text) }
            $r.Index | Should -Be 1
            @($script:committed) | Should -Be @(15)
            (($script:boxRows | ForEach-Object { (@($_) | ForEach-Object T) -join '' }) -join "`n") | Should -Not -Match 'soru satiri'
            @($script:boxRows).Count | Should -BeLessOrEqual 6
        }
        finally { $script:WtReplLiveEnabled = $false; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }
    }
    It 'Read-WtReplPick leaves a question that fits alone' {
        $script:WtReplLiveEnabled = $true
        $script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
        try {
            Mock Get-WtConsoleSize { @{ Width = 80; Height = 40 } }
            Mock Write-WtReplBlock { throw 'must not commit a short question' }
            $script:boxRows2 = @()
            Mock Show-WtReplLive { $script:boxRows2 = @($Rows) }
            $enter = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)
            $null = Read-WtReplPick -Title 'T' -Lines @('kisa soru') -Options @(@{ Label = 'Evet'; Hotkey = 'E' }) -ReadKey { $enter } -Write { param($Text) }
            (($script:boxRows2 | ForEach-Object { (@($_) | ForEach-Object T) -join '' }) -join "`n") | Should -Match 'kisa soru'
        }
        finally { $script:WtReplLiveEnabled = $false; $script:WtReplLive = @{ Rows = 0; CaretRow = 0 } }
    }
}
