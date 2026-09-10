BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
}

Describe 'Test-WtUnicodeGlyphSupport' {
    It 'is true inside Windows Terminal regardless of PS version' {
        Test-WtUnicodeGlyphSupport -WtSession 'abc-123' -PSMajorVersion 5 | Should -BeTrue
    }
    It 'is true on PowerShell 7 outside Windows Terminal' {
        Test-WtUnicodeGlyphSupport -WtSession '' -PSMajorVersion 7 | Should -BeTrue
    }
    It 'is false on 5.1 conhost' {
        Test-WtUnicodeGlyphSupport -WtSession '' -PSMajorVersion 5 | Should -BeFalse
    }
}

Describe 'Get-WtGlyphSet' {
    It 'ASCII set uses only ASCII characters' {
        $g = Get-WtGlyphSet -Unicode $false
        foreach ($p in $g.PSObject.Properties) {
            [int[]][char[]]$p.Value | ForEach-Object { $_ | Should -BeLessThan 128 }
        }
    }
    It 'Unicode set uses box-drawing for the horizontal rule' {
        (Get-WtGlyphSet -Unicode $true).H | Should -Be ([string][char]0x2500)
    }
    It 'both sets expose the same property names' {
        $a = (Get-WtGlyphSet -Unicode $false).PSObject.Properties.Name | Sort-Object
        $u = (Get-WtGlyphSet -Unicode $true).PSObject.Properties.Name | Sort-Object
        ($a -join ',') | Should -Be ($u -join ',')
    }
    It 'carries the REPL glyphs in both sets: bullet, branch, dot and a spinner cycle' {
        $u = Get-WtGlyphSet -Unicode $true
        $a = Get-WtGlyphSet -Unicode $false
        $u.Bullet | Should -Be ([string][char]0x25CF)
        $u.Branch | Should -Be ([string][char]0x23BF)
        $u.Dot | Should -Be ([string][char]0xB7)
        $u.Spinner.Length | Should -Be 10
        $a.Bullet | Should -Be '*'
        $a.Branch | Should -Be '\'
        $a.Dot | Should -Be '-'
        $a.Spinner | Should -Be '|/-\'
    }
    It 'carries the list bullet and the rule in both sets' {
        (Get-WtGlyphSet -Unicode $true).ListBullet | Should -Be ([string][char]0x2022)
        (Get-WtGlyphSet -Unicode $true).Rule | Should -Be ([string][char]0x2500)
        (Get-WtGlyphSet -Unicode $false).ListBullet | Should -Be '-'
        (Get-WtGlyphSet -Unicode $false).Rule | Should -Be '-'
    }
}

Describe 'ConvertTo-WtKeyToken' {
    It 'maps arrows, paging and editing keys' {
        ConvertTo-WtKeyToken -Key 'UpArrow' -KeyChar '' | Should -Be 'Up'
        ConvertTo-WtKeyToken -Key 'DownArrow' -KeyChar '' | Should -Be 'Down'
        ConvertTo-WtKeyToken -Key 'PageUp' -KeyChar '' | Should -Be 'PageUp'
        ConvertTo-WtKeyToken -Key 'PageDown' -KeyChar '' | Should -Be 'PageDown'
        ConvertTo-WtKeyToken -Key 'Home' -KeyChar '' | Should -Be 'Home'
        ConvertTo-WtKeyToken -Key 'End' -KeyChar '' | Should -Be 'End'
        ConvertTo-WtKeyToken -Key 'Spacebar' -KeyChar ' ' | Should -Be 'Space'
        ConvertTo-WtKeyToken -Key 'Enter' -KeyChar '' | Should -Be 'Enter'
        ConvertTo-WtKeyToken -Key 'LeftArrow' -KeyChar '' | Should -Be 'Back'
        ConvertTo-WtKeyToken -Key 'Escape' -KeyChar '' | Should -Be 'Back'
    }
    It 'maps digits and letters, lowercasing letters' {
        ConvertTo-WtKeyToken -Key 'D3' -KeyChar '3' | Should -Be 'Digit:3'
        ConvertTo-WtKeyToken -Key 'Q' -KeyChar 'Q' | Should -Be 'Char:q'
    }
    It 'returns None for unmapped keys' {
        ConvertTo-WtKeyToken -Key 'F5' -KeyChar '' | Should -Be 'None'
    }
}

Describe 'ConvertTo-WtLineToken' {
    It 'empty line means Enter' { ConvertTo-WtLineToken -Line '' | Should -Be 'Enter' }
    It 'digits pass through' { ConvertTo-WtLineToken -Line ' 12 ' | Should -Be 'Digit:12' }
    It 'n/p page, b goes back' {
        ConvertTo-WtLineToken -Line 'n' | Should -Be 'PageDown'
        ConvertTo-WtLineToken -Line 'P' | Should -Be 'PageUp'
        ConvertTo-WtLineToken -Line 'b' | Should -Be 'Back'
    }
    It 'other words map to their first letter' {
        ConvertTo-WtLineToken -Line 'q' | Should -Be 'Char:q'
        ConvertTo-WtLineToken -Line 'All' | Should -Be 'Char:a'
    }
}

Describe 'Get-WtViewportWindow' {
    It 'returns 0 when everything fits' {
        Get-WtViewportWindow -ItemCount 5 -CursorIndex 4 -ViewHeight 10 -WindowStart 0 | Should -Be 0
    }
    It 'scrolls down just enough to keep the cursor visible' {
        Get-WtViewportWindow -ItemCount 30 -CursorIndex 12 -ViewHeight 10 -WindowStart 0 | Should -Be 3
    }
    It 'scrolls up to the cursor when it is above the window' {
        Get-WtViewportWindow -ItemCount 30 -CursorIndex 2 -ViewHeight 10 -WindowStart 5 | Should -Be 2
    }
    It 'never scrolls past the end' {
        Get-WtViewportWindow -ItemCount 12 -CursorIndex 11 -ViewHeight 10 -WindowStart 0 | Should -Be 2
    }
}

Describe 'Update-WtListState' {
    BeforeEach {
        $script:items = @(
            [PSCustomObject]@{ Kind = 'Header'; Name = 'H1'; Label = 'Group'; Risk = $null; StateLabel = ''; Selectable = $false; Data = $null }
            [PSCustomObject]@{ Kind = 'Check'; Name = 'A'; Label = 'Alpha'; Risk = 'SAFE'; StateLabel = 'NotApplied'; Selectable = $true; Data = $null }
            [PSCustomObject]@{ Kind = 'Check'; Name = 'B'; Label = 'Beta'; Risk = 'CAUTION'; StateLabel = 'NotApplied'; Selectable = $true; Data = $null }
            [PSCustomObject]@{ Kind = 'Check'; Name = 'C'; Label = 'Gamma'; Risk = 'SAFE'; StateLabel = 'Applied'; Selectable = $false; Data = $null }
        )
        $script:state = @{
            CursorIndex = 1
            WindowStart = 0
            Selection   = New-Object 'System.Collections.Generic.HashSet[string]'
        }
    }

    It 'Down moves to the next focusable row' {
        $r = Update-WtListState -State $state -Token 'Down' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 2
        $r.Emit | Should -Be 'None'
    }
    It 'Up from the first focusable row stays put (headers are skipped, no wrap)' {
        $r = Update-WtListState -State $state -Token 'Up' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 1
    }
    It 'Space toggles selection by Name' {
        $r = Update-WtListState -State $state -Token 'Space' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Contains('A') | Should -BeTrue
        $r2 = Update-WtListState -State $r.State -Token 'Space' -Items $items -ViewHeight 10 -MultiSelect $true
        $r2.State.Selection.Contains('A') | Should -BeFalse
    }
    It 'Space refuses an unselectable row' {
        $state.CursorIndex = 3
        $r = Update-WtListState -State $state -Token 'Space' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Count | Should -Be 0
    }
    It 'Space on a Radio row replaces the selection' {
        $radio = @(
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'R1'; Label = 'One'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null }
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'R2'; Label = 'Two'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null }
        )
        $s = @{ CursorIndex = 0; WindowStart = 0; Selection = New-Object 'System.Collections.Generic.HashSet[string]' }
        $r = Update-WtListState -State $s -Token 'Space' -Items $radio -ViewHeight 10 -MultiSelect $false
        $s2 = $r.State; $s2.CursorIndex = 1
        $r2 = Update-WtListState -State $s2 -Token 'Space' -Items $radio -ViewHeight 10 -MultiSelect $false
        $r2.State.Selection.Contains('R2') | Should -BeTrue
        $r2.State.Selection.Contains('R1') | Should -BeFalse
        $r2.State.Selection.Count | Should -Be 1
    }
    It 'Digit jumps to the Nth visible focusable row and toggles it' {
        $r = Update-WtListState -State $state -Token 'Digit:2' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 2
        $r.State.Selection.Contains('B') | Should -BeTrue
    }
    It 'Char:a selects every selectable row in the window, Char:c clears them' {
        $r = Update-WtListState -State $state -Token 'Char:a' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Count | Should -Be 2
        $r.Emit | Should -Be 'None'
        $r2 = Update-WtListState -State $r.State -Token 'Char:c' -Items $items -ViewHeight 10 -MultiSelect $true
        $r2.State.Selection.Count | Should -Be 0
        $r2.Emit | Should -Be 'None'
    }
    It 'Char:a emits Global in single-select mode instead of bulk-selecting' {
        $r = Update-WtListState -State $state -Token 'Char:a' -Items $items -ViewHeight 10 -MultiSelect $false
        $r.Emit | Should -Be 'Global'
        $r.EmitChar | Should -Be 'a'
    }
    It 'Enter emits Activate' {
        (Update-WtListState -State $state -Token 'Enter' -Items $items -ViewHeight 10 -MultiSelect $true).Emit | Should -Be 'Activate'
    }
    It 'Back emits Back' {
        (Update-WtListState -State $state -Token 'Back' -Items $items -ViewHeight 10 -MultiSelect $true).Emit | Should -Be 'Back'
    }
    It 'unclaimed letters emit Global with the letter' {
        $r = Update-WtListState -State $state -Token 'Char:d' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.Emit | Should -Be 'Global'
        $r.EmitChar | Should -Be 'd'
    }
    It 'PageDown moves the cursor a view-height forward, clamped' {
        $many = 0..24 | ForEach-Object {
            [PSCustomObject]@{ Kind = 'Check'; Name = "N$_"; Label = "Item $_"; Risk = 'SAFE'; StateLabel = ''; Selectable = $true; Data = $null }
        }
        $s = @{ CursorIndex = 0; WindowStart = 0; Selection = New-Object 'System.Collections.Generic.HashSet[string]' }
        $r = Update-WtListState -State $s -Token 'PageDown' -Items $many -ViewHeight 10 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 10
        $r.State.WindowStart | Should -Be 1
    }
}

Describe 'Get-WtBannerLines' {
    It 'returns the 9-line banner when the console is wide enough' {
        (Get-WtBannerLines -Width 120).Count | Should -Be 9
    }
    It 'returns the one-line compact brand when narrow' {
        $lines = Get-WtBannerLines -Width 80
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'WinToolify V2'
    }
    It 'the credit block is two ASCII lines: author and repository URL' {
        $credit = @(Get-WtBannerCreditLines)
        $credit.Count | Should -Be 2
        $credit[0] | Should -Be 'Created by Burak Arslan'
        $credit[1] | Should -Be 'https://github.com/burakarslan0110/WinToolify'
        foreach ($line in $credit) { [int[]][char[]]$line | ForEach-Object { $_ | Should -BeLessThan 128 } }
    }
    It 'banner lines are pure ASCII' {
        foreach ($line in (Get-WtBannerLines -Width 120)) {
            [int[]][char[]]$line | ForEach-Object { $_ | Should -BeLessThan 128 }
        }
    }
}

Describe 'Get-WtListRowSegments' {
    BeforeEach {
        $script:g = Get-WtGlyphSet -Unicode $false
        $script:row = [PSCustomObject]@{ Kind = 'Check'; Name = 'A'; Label = 'Alpha'; Risk = 'ADVANCED'; StateLabel = 'NotApplied'; Selectable = $true; Data = $null }
    }
    It 'cursor row uses the highlight background' {
        $segs = Get-WtListRowSegments -Item $row -IsCursor $true -Selected $false -Glyphs $g -Width 80 -VisibleNumber 0
        (@($segs | Where-Object { $_.B -eq 'DarkCyan' })).Count | Should -BeGreaterThan 0
    }
    It 'non-cursor ADVANCED row is red' {
        $segs = Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 80 -VisibleNumber 0
        ($segs | Where-Object { $_.F -eq 'Red' }).Count | Should -BeGreaterThan 0
    }
    It 'selected checkbox renders the CheckOn glyph' {
        $segs = Get-WtListRowSegments -Item $row -IsCursor $false -Selected $true -Glyphs $g -Width 80 -VisibleNumber 0
        ($segs | ForEach-Object T) -join '' | Should -Match '\[x\]'
    }
    It 'line-mode number is rendered when VisibleNumber is positive' {
        $segs = Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 80 -VisibleNumber 3
        ($segs | ForEach-Object T) -join '' | Should -Match '^\s*3\.'
    }
    It 'total row text never exceeds the width' {
        $long = [PSCustomObject]@{ Kind = 'Check'; Name = 'L'; Label = ('x' * 300); Risk = 'SAFE'; StateLabel = 'NotApplied'; Selectable = $true; Data = $null }
        $segs = Get-WtListRowSegments -Item $long -IsCursor $false -Selected $false -Glyphs $g -Width 60 -VisibleNumber 0
        (($segs | ForEach-Object T) -join '').Length | Should -BeLessOrEqual 60
    }
    It 'NumberWidth right-aligns the number so a 1-digit row lines up with a 2-digit one' {
        $nine = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 80 -VisibleNumber 9 -NumberWidth 2) | ForEach-Object T) -join ''
        $ten = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 80 -VisibleNumber 10 -NumberWidth 2) | ForEach-Object T) -join ''
        $nine | Should -Match '^\s+9\. \[ \] Alpha'
        $ten | Should -Match '^\s+10\. \[ \] Alpha'
        $nine.IndexOf('[') | Should -Be $ten.IndexOf('[')
        $nine.IndexOf('Alpha') | Should -Be $ten.IndexOf('Alpha')
    }
    It 'NumberWidth defaults to one digit so single-page screens are unchanged' {
        $segs = Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 80 -VisibleNumber 3
        ($segs | ForEach-Object T) -join '' | Should -Match '^\s*3\. \[ \] Alpha'
    }
    It 'a Spacer row renders as blank and carries no number' {
        $spacer = New-WtListItem -Kind 'Spacer' -Name 'Sp:1' -Label ''
        $segs = Get-WtListRowSegments -Item $spacer -IsCursor $false -Selected $false -Glyphs $g -Width 40 -VisibleNumber 0
        (($segs | ForEach-Object T) -join '').Trim() | Should -BeNullOrEmpty
        Test-WtItemFocusable -Item $spacer | Should -BeFalse
    }
}

Describe 'Cursorless scrolling (read-only output screens)' {
    BeforeAll {
        $script:infoItems = { param($n) 0..($n - 1) | ForEach-Object { New-WtListItem -Kind 'Info' -Name "L$_" -Label "line $_" } }
        $script:noCursor = { param($start) @{ CursorIndex = -1; WindowStart = $start; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') } }
    }
    It 'a negative cursor leaves the window where it is instead of snapping to the top' {
        Get-WtViewportWindow -ItemCount 50 -CursorIndex -1 -ViewHeight 10 -WindowStart 20 | Should -Be 20
        Get-WtViewportWindow -ItemCount 50 -CursorIndex -1 -ViewHeight 10 -WindowStart 99 | Should -Be 40
        Get-WtViewportWindow -ItemCount 5 -CursorIndex -1 -ViewHeight 10 -WindowStart 3 | Should -Be 0
    }
    It 'Down and Up scroll the window when no row can take the cursor' {
        $items = @(& $infoItems 30)
        $r = Update-WtListState -State (& $noCursor 0) -Token 'Down' -Items $items -ViewHeight 10
        $r.State.WindowStart | Should -Be 1
        $r.State.CursorIndex | Should -Be -1
        $r = Update-WtListState -State (& $noCursor 5) -Token 'Up' -Items $items -ViewHeight 10
        $r.State.WindowStart | Should -Be 4
    }
    It 'paging and Home/End move a whole screen and to the ends' {
        $items = @(& $infoItems 30)
        (Update-WtListState -State (& $noCursor 0) -Token 'PageDown' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 10
        (Update-WtListState -State (& $noCursor 12) -Token 'PageUp' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 2
        (Update-WtListState -State (& $noCursor 7) -Token 'End' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 20
        (Update-WtListState -State (& $noCursor 7) -Token 'Home' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 0
    }
    It 'never scrolls past either end' {
        $items = @(& $infoItems 30)
        (Update-WtListState -State (& $noCursor 0) -Token 'Up' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 0
        (Update-WtListState -State (& $noCursor 20) -Token 'Down' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 20
        (Update-WtListState -State (& $noCursor 0) -Token 'PageUp' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 0
    }
    It 'a list that fits needs no scrolling at all' {
        $items = @(& $infoItems 4)
        (Update-WtListState -State (& $noCursor 0) -Token 'Down' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 0
        (Update-WtListState -State (& $noCursor 0) -Token 'End' -Items $items -ViewHeight 10).State.WindowStart | Should -Be 0
    }
    It 'Enter and Esc still close the screen' {
        $items = @(& $infoItems 30)
        (Update-WtListState -State (& $noCursor 0) -Token 'Enter' -Items $items -ViewHeight 10).Emit | Should -Be 'Activate'
        (Update-WtListState -State (& $noCursor 0) -Token 'Back' -Items $items -ViewHeight 10).Emit | Should -Be 'Back'
    }
    It 'a list WITH focusable rows is untouched by all this' {
        $mixed = @(
            New-WtListItem -Kind 'Info' -Name 'i' -Label 'note'
            New-WtListItem -Kind 'Check' -Name 'a' -Label 'Alpha'
            New-WtListItem -Kind 'Check' -Name 'b' -Label 'Beta'
        )
        $state = @{ CursorIndex = 1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        (Update-WtListState -State $state -Token 'Down' -Items $mixed -ViewHeight 10).State.CursorIndex | Should -Be 2
    }
}

Describe 'ConvertTo-WtOutputLines' {
    It 'passes plain strings through and splits embedded newlines' {
        @(ConvertTo-WtOutputLines -InputObject 'one') | Should -Be @('one')
        @(ConvertTo-WtOutputLines -InputObject "a`r`nb`nc") | Should -Be @('a', 'b', 'c')
    }
    It 'unwraps what Write-Host emits' {
        $record = & { Write-Host 'hello from the action' 6>&1 }
        @(ConvertTo-WtOutputLines -InputObject $record) | Should -Be @('hello from the action')
    }
    It 'renders an error as its message, not as a stack trace' {
        $err = New-Object System.Management.Automation.ErrorRecord (New-Object System.InvalidOperationException 'boom'), 'id', 'NotSpecified', $null
        @(ConvertTo-WtOutputLines -InputObject $err) | Should -Be @('boom')
    }
    It 'renders a warning as its message' {
        $warn = & { Write-Warning 'careful' 3>&1 }
        @(ConvertTo-WtOutputLines -InputObject $warn) | Should -Be @('careful')
    }
    It 'formats a plain object through Out-String and drops the blank padding' {
        $lines = @(ConvertTo-WtOutputLines -InputObject ([PSCustomObject]@{ Alpha = 1; Beta = 2 }))
        $lines.Count | Should -BeGreaterThan 0
        ($lines -join ' ') | Should -Match 'Alpha'
        foreach ($l in $lines) { $l | Should -Not -BeNullOrEmpty }
    }
    It 'yields nothing for $null' {
        @(ConvertTo-WtOutputLines -InputObject $null).Count | Should -Be 0
    }
    It 'keeps a deliberately blank line inside a run of text' {
        @(ConvertTo-WtOutputLines -InputObject "a`n`nb") | Should -Be @('a', '', 'b')
    }
    It 'collapses a CR-overwritten progress run to the segment that was meant to be on screen (sfc)' {
        @(ConvertTo-WtOutputLines -InputObject "Verification 1% complete.`rVerification 50% complete.`rVerification 100% complete.") |
            Should -Be @('Verification 100% complete.')
    }
    It 'never returns a row with a carriage return in it - the frame would jump to column 1' {
        foreach ($row in @(ConvertTo-WtOutputLines -InputObject "a`rb`nc`rd")) {
            $row.IndexOf("`r") | Should -Be -1
        }
    }
    It 'keeps a trailing CR from swallowing the row it belongs to' {
        @(ConvertTo-WtOutputLines -InputObject "done.`r") | Should -Be @('done.')
    }
}

Describe 'Add-WtNativeOutputChunk' {
    BeforeEach { $script:outState = New-WtNativeOutputState }

    It 'starts with no rows, nothing being written and column 1' {
        @($outState.Lines).Count | Should -Be 0
        $outState.Current | Should -Be ''
        $outState.Column | Should -Be 0
    }
    It 'commits a row on LF and keeps the CRLF pair from leaving a blank one' {
        Add-WtNativeOutputChunk -State $outState -Chunk "one`r`ntwo`r`n"
        @($outState.Lines) | Should -Be @('one', 'two')
        $outState.Current | Should -Be ''
    }
    It 'overwrites the row in place on a lone CR, so only the last frame is committed (sfc)' {
        Add-WtNativeOutputChunk -State $outState -Chunk "Verification 1% complete.`rVerification 50% complete.`r"
        Add-WtNativeOutputChunk -State $outState -Chunk "Verification 100% complete.`r`n"
        @($outState.Lines) | Should -Be @('Verification 100% complete.')
    }
    It 'shows the row being overwritten as Current before it is committed' {
        Add-WtNativeOutputChunk -State $outState -Chunk "Verification 7% complete.`r"
        @($outState.Lines).Count | Should -Be 0
        $outState.Current | Should -Be 'Verification 7% complete.'
    }
    It 'keeps the tail of a longer previous frame, exactly as a console does' {
        Add-WtNativeOutputChunk -State $outState -Chunk "abcdef`rXY"
        $outState.Current | Should -Be 'XYcdef'
    }
    It 'walks the column back on a backspace (DISM draws its bar that way)' {
        Add-WtNativeOutputChunk -State $outState -Chunk "50.0%`b`b`b`b`b90.0%`r`n"
        @($outState.Lines) | Should -Be @('90.0%')
    }
    It 'survives a chunk boundary landing in the middle of a row' {
        Add-WtNativeOutputChunk -State $outState -Chunk 'half'
        Add-WtNativeOutputChunk -State $outState -Chunk "-done`n"
        @($outState.Lines) | Should -Be @('half-done')
    }
    It 'ignores an empty chunk' {
        Add-WtNativeOutputChunk -State $outState -Chunk ''
        @($outState.Lines).Count | Should -Be 0
    }
}

Describe 'Format-WtElapsed' {
    It 'renders mm:ss and keeps counting past an hour' {
        Format-WtElapsed -Seconds 0 | Should -Be '00:00'
        Format-WtElapsed -Seconds 61 | Should -Be '01:01'
        Format-WtElapsed -Seconds 3661 | Should -Be '61:01'
    }
}

Describe 'Cycling rows (a row with more than two target states)' {
    BeforeEach {
        $script:cycleItems = @(
            New-WtListItem -Kind 'Check' -Name 'WerSvc' -Label 'WerSvc' -StateLabel 'Durdu/El ile' -CycleTargets @('Disabled', 'Manual', 'Automatic')
            New-WtListItem -Kind 'Check' -Name 'Fax' -Label 'Fax' -StateLabel 'Durdu/El ile' -CycleTargets @('Disabled', 'Manual', 'Automatic')
            New-WtListItem -Kind 'Check' -Name 'Plain' -Label 'Plain' -StateLabel 'Uygulanmadi'
        )
        $script:cycleState = { @{ CursorIndex = 0; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]'); Cycle = @{} } }
    }

    It 'Space walks the targets in order and back to unmarked' {
        $s = & $cycleState
        foreach ($expected in 'Disabled', 'Manual', 'Automatic') {
            $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
            $s.Selection.Contains('WerSvc') | Should -BeTrue -Because $expected
            $s.Cycle['WerSvc'] | Should -Be $expected
        }
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s.Selection.Contains('WerSvc') | Should -BeFalse -Because 'the fourth press clears it again'
        $s.Cycle.ContainsKey('WerSvc') | Should -BeFalse
    }

    It 'each row keeps its own target' {
        $s = & $cycleState
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s.CursorIndex = 1
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s.Cycle['WerSvc'] | Should -Be 'Disabled'
        $s.Cycle['Fax'] | Should -Be 'Manual'
    }

    It 'a row without targets still toggles like a plain checkbox' {
        $s = & $cycleState
        $s.CursorIndex = 2
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s.Selection.Contains('Plain') | Should -BeTrue
        $s.Cycle.ContainsKey('Plain') | Should -BeFalse
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s.Selection.Contains('Plain') | Should -BeFalse
    }

    It 'C clears the targets along with the marks' {
        $s = & $cycleState
        $s = (Update-WtListState -State $s -Token 'Space' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s = (Update-WtListState -State $s -Token 'Char:c' -Items $cycleItems -ViewHeight 10 -MultiSelect $true).State
        $s.Selection.Count | Should -Be 0
        $s.Cycle.Count | Should -Be 0
    }

    It 'the state column shows the chosen target instead of the live state' {
        $g = Get-WtGlyphSet -Unicode $false
        $row = $cycleItems[0]
        $plain = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 90) | ForEach-Object T) -join ''
        $plain | Should -Match 'Durdu/El ile'
        $picked = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $true -Glyphs $g -Width 90 -PendingLabel 'El ile') | ForEach-Object T) -join ''
        $picked | Should -Match '-> El ile'
        $picked | Should -Not -Match 'Durdu/El ile'
    }

    It 'Get-WtFrameRows feeds each marked row its own target label' {
        $g = Get-WtGlyphSet -Unicode $false
        $state = & $cycleState
        $state.Selection.Add('WerSvc') | Out-Null
        $state.Selection.Add('Fax') | Out-Null
        $state.Cycle = @{ WerSvc = 'Automatic'; Fax = 'Disabled' }
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $cycleItems -State $state -Width 100 -Height 24 -Glyphs $g `
            -CycleLabels @{ Automatic = 'Otomatik'; Disabled = 'Devre disi'; Manual = 'El ile' }
        $rows = @($frame | ForEach-Object { (($_ | ForEach-Object T) -join '') })
        (@($rows | Where-Object { $_ -match 'WerSvc' -and $_ -match '-> Otomatik' })).Count | Should -Be 1
        (@($rows | Where-Object { $_ -match 'Fax' -and $_ -match '-> Devre disi' })).Count | Should -Be 1
    }
}

Describe 'Panel text never overflows the box' {
    BeforeAll {
        $script:g = Get-WtGlyphSet -Unicode $false
        $script:long = 'Extra: Office, Skype, Outlook ve NCSI yi engelleyebilir - kaynagin kendi "YALNIZCA ne yaptiginizi biliyorsaniz kullanin" uyarisi. Uygulamak birkac dakika surer ve genis etkisi vardir.'
    }

    It 'a message row with no state anywhere does not reserve the state column' {
        $row = New-WtListItem -Kind 'Info' -Name 'L1' -Label 'note' -Risk 'ADVANCED'
        $parts = Get-WtListRowRightParts -Item $row -StateWidth 0
        $parts.State | Should -BeNullOrEmpty
        $parts.Text.Trim() | Should -Be ("[{0}]" -f (Get-WtRiskLabel -Risk 'ADVANCED'))
    }

    It 'still reserves the state column on a screen that has states' {
        $row = New-WtListItem -Kind 'Check' -Name 'A' -Label 'Alpha' -Risk 'SAFE' -StateLabel (Get-Translation 'NotApplied')
        (Get-WtListRowRightParts -Item $row -StateWidth 11).State.Length | Should -BeGreaterOrEqual 11
    }

    It 'Get-WtListRowLabelRoom agrees with what the renderer actually fits' {
        foreach ($risk in '', 'ADVANCED') {
            $row = New-WtListItem -Kind 'Info' -Name 'L' -Label ('x' * 400) -Risk $risk
            $room = Get-WtListRowLabelRoom -Item $row -Glyphs $g -Width 100
            $text = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 100) | ForEach-Object T) -join ''
            ([regex]::Matches($text, 'x')).Count | Should -Be ($room - 1) -Because "risk '$risk'"
        }
    }

    It 'ConvertTo-WtPanelLines wraps instead of letting the renderer cut with ~' {
        $wrapped = @(ConvertTo-WtPanelLines -Lines @($script:long) -Width 100 -Risk 'ADVANCED')
        $wrapped.Count | Should -BeGreaterThan 1
        $room = Get-WtListRowLabelRoom -Item (New-WtListItem -Kind 'Info' -Name 'L' -Label '' -Risk 'ADVANCED') -Glyphs $g -Width 100
        foreach ($l in $wrapped) { $l.Length | Should -BeLessOrEqual $room }
        ($wrapped -join ' ') | Should -Be $script:long
    }

    It 'no rendered panel row is ever truncated' {
        $items = @(Get-WtPanelItems -Lines (ConvertTo-WtPanelLines -Lines @($script:long) -Width 100 -Risk 'ADVANCED') -Risk 'ADVANCED')
        foreach ($item in $items) {
            $text = ((Get-WtListRowSegments -Item $item -IsCursor $false -Selected $false -Glyphs $g -Width 100) | ForEach-Object T) -join ''
            $text | Should -Not -Match '~'
        }
    }

    It 'keeps blank separator lines and copes with an empty list' {
        @(ConvertTo-WtPanelLines -Lines @('a', '', 'b') -Width 100) | Should -Be @('a', '', 'b')
        @(ConvertTo-WtPanelLines -Lines @() -Width 100).Count | Should -Be 0
    }

    It 'Read-WtPanelAnswer -Secret reads masked input and returns the plain text' {
        $old = $script:WtInputMode
        $script:WtInputMode = 'Line'
        try {
            Mock Clear-Host { }
            Mock Read-Host { if ($AsSecureString) { ConvertTo-SecureString 'gizli-anahtar' -AsPlainText -Force } else { 'ACIK' } }
            Read-WtPanelAnswer -Breadcrumb 'b' -Prompt 'API anahtari' -Layout 'Compact' -Secret | Should -Be 'gizli-anahtar'
            Should -Invoke Read-Host -ParameterFilter { [bool]$AsSecureString } -Times 1 -Exactly
        }
        finally { $script:WtInputMode = $old }
    }

    It 'Get-WtPanelPromptFit keeps a short prompt and cuts a Read-Host-breaking one with ~' {
        Get-WtPanelPromptFit -Prompt 'Devam icin Enter' -Width 80 | Should -Be 'Devam icin Enter'
        $fit = [string](Get-WtPanelPromptFit -Prompt ('x' * 97) -Width 80)
        $fit.Length | Should -BeLessOrEqual 72
        $fit.Substring($fit.Length - 1) | Should -Be '~'
    }
}

Describe 'Split-WtWrappedLines' {
    It 'breaks on spaces and never exceeds the width' {
        $text = 'This command cannot be run due to the following error: the service cannot be started because it is disabled or does not have enabled devices associated with it.'
        $lines = @(Split-WtWrappedLines -Text $text -Width 40)
        $lines.Count | Should -BeGreaterThan 1
        foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 40 }
        ($lines -join ' ') | Should -Be $text
    }
    It 'returns a short text as a single line' {
        @(Split-WtWrappedLines -Text 'short' -Width 40) | Should -Be @('short')
    }
    It 'hard-breaks a word longer than the width instead of overflowing' {
        $lines = @(Split-WtWrappedLines -Text ('x' * 25) -Width 10)
        foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 10 }
        ($lines -join '') | Should -Be ('x' * 25)
    }
    It 'collapses runs of whitespace and drops empty input' {
        @(Split-WtWrappedLines -Text "a`r`n  b" -Width 40) | Should -Be @('a b')
        @(Split-WtWrappedLines -Text '   ' -Width 40).Count | Should -Be 0
        @(Split-WtWrappedLines -Text $null -Width 40).Count | Should -Be 0
    }
    It 'never loops forever on a nonsense width' {
        @(Split-WtWrappedLines -Text 'abc def' -Width 0).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-WtFrameDescriptionLines' {
    BeforeAll {
        $script:descItems = @(
            (New-WtListItem -Kind 'Rule' -Name 'R' -Label 'rule')
            (New-WtListItem -Kind 'Link' -Name 'A' -Label 'A' -Desc 'Buradan bunu yapabilirsiniz.')
            (New-WtListItem -Kind 'Link' -Name 'B' -Label 'B')
        )
    }
    It 'wraps the cursor row description into exactly the rows the band reserves' {
        $lines = @(Get-WtFrameDescriptionLines -Items $descItems -CursorIndex 1 -Width 40 -Rows 2)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be 'Buradan bunu yapabilirsiniz.'
        $lines[1] | Should -Be ''
    }
    It 'keeps the band its full height for a row with no description, and for a row that cannot take the cursor' {
        foreach ($at in 0, 2) {
            $lines = @(Get-WtFrameDescriptionLines -Items $descItems -CursorIndex $at -Width 40 -Rows 2)
            $lines.Count | Should -Be 2
            foreach ($l in $lines) { $l | Should -Be '' }
        }
    }
    It 'keeps its height when the cursor indexes nothing (empty list, cleared cursor)' {
        @(Get-WtFrameDescriptionLines -Items $descItems -CursorIndex -1 -Width 40 -Rows 2).Count | Should -Be 2
        @(Get-WtFrameDescriptionLines -Items @() -CursorIndex 0 -Width 40 -Rows 2).Count | Should -Be 2
    }
    It 'never exceeds the width and marks a description too long for the band with ~' {
        $long = New-WtListItem -Kind 'Link' -Name 'L' -Label 'L' -Desc (((1..40) | ForEach-Object { "word$_" }) -join ' ')
        $lines = @(Get-WtFrameDescriptionLines -Items @($long) -CursorIndex 0 -Width 30 -Rows 2)
        $lines.Count | Should -Be 2
        foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 30 }
        $lines[1].Substring($lines[1].Length - 1) | Should -Be '~'
    }
    It 'wraps a description that is longer than one row onto the second row' {
        $two = New-WtListItem -Kind 'Link' -Name 'T' -Label 'T' -Desc 'Telemetri, reklam kimligi, konum ve veri toplama ayarlarini buradan kapatabilirsiniz.'
        $lines = @(Get-WtFrameDescriptionLines -Items @($two) -CursorIndex 0 -Width 50 -Rows 2)
        $lines[0] | Should -Not -BeNullOrEmpty
        $lines[1] | Should -Not -BeNullOrEmpty
        (($lines -join ' ').Trim()) | Should -Be 'Telemetri, reklam kimligi, konum ve veri toplama ayarlarini buradan kapatabilirsiniz.'
    }
}

Describe 'Add-WtListGroupSpacers' {
    BeforeAll {
        $script:mk = { param($kind, $name) New-WtListItem -Kind $kind -Name $name -Label $name }
    }
    It 'puts a blank row before every header except the first row' {
        $items = @((& $mk 'Header' 'H1'), (& $mk 'Check' 'a'), (& $mk 'Header' 'H2'), (& $mk 'Check' 'b'))
        $kinds = @((Add-WtListGroupSpacers -Items $items) | ForEach-Object Kind)
        $kinds | Should -Be @('Header', 'Check', 'Spacer', 'Header', 'Check')
    }
    It 'never puts two blank rows in a row when headers are adjacent' {
        $items = @((& $mk 'Header' 'H1'), (& $mk 'Header' 'H2'), (& $mk 'Check' 'a'))
        $kinds = @((Add-WtListGroupSpacers -Items $items) | ForEach-Object Kind)
        $kinds | Should -Be @('Header', 'Header', 'Check')
    }
    It 'leaves a header-free list untouched' {
        $items = @((& $mk 'Check' 'a'), (& $mk 'Check' 'b'))
        @((Add-WtListGroupSpacers -Items $items) | ForEach-Object Kind) | Should -Be @('Check', 'Check')
    }
    It 'gives every spacer a unique name' {
        $items = @((& $mk 'Header' 'H1'), (& $mk 'Check' 'a'), (& $mk 'Header' 'H2'), (& $mk 'Check' 'b'), (& $mk 'Header' 'H3'))
        $names = @((Add-WtListGroupSpacers -Items $items) | Where-Object Kind -eq 'Spacer' | ForEach-Object Name)
        $names.Count | Should -Be 2
        (@($names | Sort-Object -Unique)).Count | Should -Be 2
    }
    It 'accepts an empty list' {
        @(Add-WtListGroupSpacers -Items @()).Count | Should -Be 0
    }
}

Describe 'Get-WtFrameRows' {
    BeforeAll {
        $script:g = Get-WtGlyphSet -Unicode $false
        $script:mkItems = { param($n) 0..($n - 1) | ForEach-Object { [PSCustomObject]@{ Kind = 'Check'; Name = "N$_"; Label = "Item $_"; Risk = 'SAFE'; StateLabel = 'NotApplied'; Selectable = $true; Data = $null } } }
        $script:mkState = { @{ CursorIndex = 0; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') } }
        $script:rowText = { param($row) ($row | ForEach-Object T) -join '' }
    }
    It 'owns exactly Height rows, even with more items than fit' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main > Test' -Items (& $mkItems 41) -State (& $mkState) -Width 100 -Height 30 -Glyphs $g -FooterText 'footer'
        $frame.Count | Should -Be 30
    }
    It 'owns exactly Height rows with fewer items than fit (blank fill)' {
        $frame = Get-WtFrameRows -Breadcrumb 'X' -Items (& $mkItems 3) -State (& $mkState) -Width 100 -Height 30 -Glyphs $g
        $frame.Count | Should -Be 30
        (& $rowText $frame[20]) | Should -Match '^\|\s+\|$'
    }
    It 'puts the banner block on every screen (no title row), then the box with the breadcrumb as its path row' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main > Test' -Items (& $mkItems 3) -State (& $mkState) -Width 100 -Height 30 -Glyphs $g -FooterText 'f'
        (& $rowText $frame[0]) | Should -Match '\+=+\+'
        (& $rowText $frame[8]) | Should -Match '\+=+\+'
        (& $rowText $frame[9]) | Should -Match '^\s*$'
        (& $rowText $frame[10]).Trim() | Should -Be 'Created by Burak Arslan'
        (& $rowText $frame[11]).Trim() | Should -Be 'https://github.com/burakarslan0110/WinToolify'
        (& $rowText $frame[12]) | Should -Match '^\s*$'
        (& $rowText $frame[13]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[14]) | Should -Match '^\| Main > Test\s+\|$'
        (& $rowText $frame[15]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[28]) | Should -Match '^\| f\s+\|$'
        $all = ($frame | ForEach-Object { & $rowText $_ }) -join "`n"
        $all | Should -Not -Match 'WinToolify V2'
        $all | Should -Not -Match 'Admin'
    }
    It 'falls back to the one-line brand on a narrow console, still with the credit block' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 1) -State (& $mkState) -Width 80 -Height 20 -Glyphs $g
        (& $rowText $frame[0]).Trim() | Should -Be $script:WtBrand
        (& $rowText $frame[1]) | Should -Match '^\s*$'
        (& $rowText $frame[2]).Trim() | Should -Be 'Created by Burak Arslan'
        (& $rowText $frame[4]) | Should -Match '^\s*$'
        (& $rowText $frame[5]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[6]) | Should -Match '^\| B\s+\|$'
        $script:WtBrand | Should -Be 'WinToolify V2'
    }
    It 'the title bar carries the brand and what the tool is, while the banner keeps the bare brand' {
        Get-WtWindowTitle | Should -Be 'WinToolify V2 - Windows Management Harness'
        (& $rowText (Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 1) -State (& $mkState) -Width 80 -Height 20 -Glyphs $g)[0]).Trim() | Should -Be $script:WtBrand
    }
    It 'fills the console with VT on and stops a column short without it, borders and rows alike' {
        $old = $script:WtVt
        try {
            foreach ($case in @(@{ Vt = $true; Wide = 158 }, @{ Vt = $false; Wide = 157 })) {
                $script:WtVt = $case.Vt
                $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 3) -State (& $mkState) -Width 158 -Height 20 -Glyphs $g
                foreach ($row in $frame) { (& $rowText $row).Length | Should -Be $case.Wide }
            }
        }
        finally { $script:WtVt = $old }
    }
    It 'shows the scroll range on the path row when the list overflows' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 41) -State (& $mkState) -Width 100 -Height 26 -Glyphs $g -CounterText '41 settings'
        (& $rowText $frame[14]) | Should -Match '41 settings  1-7/41 \|$'
    }
    It 'pins footer and bottom border to the last two rows' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 3) -State (& $mkState) -Width 80 -Height 20 -Glyphs $g -FooterText 'Esc Back'
        (& $rowText $frame[18]) | Should -Match '^\| Esc Back\s+\|$'
        (& $rowText $frame[19]) | Should -Match '^\+-+\+$'
    }
    It 'every row is exactly Width-1 characters wide' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 12) -State (& $mkState) -Width 90 -Height 22 -Glyphs $g -FooterText 'f'
        foreach ($row in $frame) { (& $rowText $row).Length | Should -Be 89 }
    }
    It 'draws the description band under the rows and above the footer, its own zone behind a separator' {
        $items = @(
            (New-WtListItem -Kind 'Link' -Name 'A' -Label 'Alpha' -Desc 'Buradan alfa isini yapabilirsiniz.')
            (New-WtListItem -Kind 'Link' -Name 'B' -Label 'Beta' -Desc 'Buradan beta isini yapabilirsiniz.')
        )
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State (& $mkState) -Width 80 -Height 20 -Glyphs $g -FooterText 'Esc Back' -DescriptionRows 2
        $frame.Count | Should -Be 20
        (& $rowText $frame[14]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[15]) | Should -Match 'Buradan alfa isini yapabilirsiniz\.'
        (& $rowText $frame[16]) | Should -Match '^\|\s+\|$'
        (& $rowText $frame[17]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[18]) | Should -Match '^\| Esc Back\s+\|$'
        (& $rowText $frame[19]) | Should -Match '^\+-+\+$'
        foreach ($row in $frame) { (& $rowText $row).Length | Should -Be 79 }
    }
    It 'the band follows the cursor' {
        $items = @(
            (New-WtListItem -Kind 'Link' -Name 'A' -Label 'Alpha' -Desc 'Buradan alfa isini yapabilirsiniz.')
            (New-WtListItem -Kind 'Link' -Name 'B' -Label 'Beta' -Desc 'Buradan beta isini yapabilirsiniz.')
        )
        $state = & $mkState
        $state.CursorIndex = 1
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State $state -Width 80 -Height 20 -Glyphs $g -FooterText 'Esc Back' -DescriptionRows 2
        (& $rowText $frame[15]) | Should -Match 'Buradan beta isini yapabilirsiniz\.'
        (& $rowText $frame[15]) | Should -Not -Match 'alfa'
    }
    It 'draws no band at all when no rows are reserved for it (every screen but the main menu)' {
        $items = @((New-WtListItem -Kind 'Link' -Name 'A' -Label 'Alpha' -Desc 'Buradan alfa isini yapabilirsiniz.'))
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State (& $mkState) -Width 80 -Height 20 -Glyphs $g -FooterText 'Esc Back'
        (($frame | ForEach-Object { & $rowText $_ }) -join "`n") | Should -Not -Match 'Buradan alfa'
    }
    It 'banner mode: banner, blank row, credit line, repo URL, blank row, then the box without title bar or path row' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main Menu' -Items (& $mkItems 5) -State (& $mkState) -Width 120 -Height 40 -Glyphs $g -ShowBanner $true -FooterText 'foot'
        $frame.Count | Should -Be 40
        (& $rowText $frame[0]) | Should -Match '\+=+\+'
        (& $rowText $frame[8]) | Should -Match '\+=+\+'
        (& $rowText $frame[9]) | Should -Match '^\s*$'
        (& $rowText $frame[10]).Trim() | Should -Be 'Created by Burak Arslan'
        (& $rowText $frame[11]).Trim() | Should -Be 'https://github.com/burakarslan0110/WinToolify'
        (& $rowText $frame[12]) | Should -Match '^\s*$'
        (& $rowText $frame[13]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[14]) | Should -Match '1\..*Item 0'
        $all = ($frame | ForEach-Object { & $rowText $_ }) -join "`n"
        $all | Should -Not -Match 'Main Menu'
        $all | Should -Not -Match 'WinToolify V2'
        (& $rowText $frame[38]) | Should -Match '^\| foot\s+\|$'
    }
    It 'banner mode shows the scroll range on the footer row when the menu does not fit (no path row to carry it)' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main Menu' -Items (& $mkItems 8) -State (& $mkState) -Width 100 -Height 21 -Glyphs $g -ShowBanner $true -Layout 'Compact' -FooterText 'f'
        $frame.Count | Should -Be 21
        (& $rowText $frame[19]) | Should -Match '^\s*\| f\s+1-4/8 \|\s*$'
        (& $rowText $frame[20]) | Should -Match '^\s*\+-+\+\s*$'
        $all = ($frame | ForEach-Object { & $rowText $_ }) -join "`n"
        $all | Should -Match 'Item 3'
        $all | Should -Not -Match 'Item 4'
    }
    It 'never emits a row wider than Width-1 or throws, even for an oversized footer' {
        foreach ($footer in @('', 'Footer text', 'A navigation guide far too long for a console this narrow')) {
            foreach ($banner in $true, $false) {
                foreach ($layout in 'Full', 'Compact') {
                    $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 3) -State (& $mkState) -Width 24 -Height 14 -Glyphs $g -FooterText $footer -ShowBanner $banner -Layout $layout
                    foreach ($row in $frame) { (& $rowText $row).Length | Should -Be 23 }
                }
            }
        }
    }
    It 'banner mode on a narrow console uses the one-line brand and the same credit block' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main Menu' -Items (& $mkItems 5) -State (& $mkState) -Width 80 -Height 30 -Glyphs $g -ShowBanner $true
        (& $rowText $frame[0]).Trim() | Should -Be 'WinToolify V2'
        (& $rowText $frame[1]) | Should -Match '^\s*$'
        (& $rowText $frame[2]).Trim() | Should -Be 'Created by Burak Arslan'
        (& $rowText $frame[3]).Trim() | Should -Be 'https://github.com/burakarslan0110/WinToolify'
        (& $rowText $frame[4]) | Should -Match '^\s*$'
        (& $rowText $frame[5]) | Should -Match '^\+-+\+$'
    }
    It 'compact layout: box is centered and only as tall as its rows, the rest of the console is blank' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main > Basic' -Items (& $mkItems 3) -State (& $mkState) -Width 100 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText 'f'
        $frame.Count | Should -Be 30
        foreach ($row in $frame) { (& $rowText $row).Length | Should -Be 99 }
        (& $rowText $frame[8]) | Should -Match '\+=+\+'
        (& $rowText $frame[12]) | Should -Match '^\s*$'
        $top = & $rowText $frame[13]
        $top | Should -Match '^\s+\+-+\+\s+$'
        $lead = $top.Length - $top.TrimStart().Length
        $boxWidth = $top.Trim().Length
        $boxWidth | Should -BeGreaterOrEqual 40
        $boxWidth | Should -BeLessThan 99
        [Math]::Abs($lead - (99 - $boxWidth - $lead)) | Should -BeLessOrEqual 1
        (& $rowText $frame[14]) | Should -Match ('^\s{' + $lead + '}\| Main > Basic\s+\|\s+$')
        (& $rowText $frame[15]) | Should -Match '^\s+\+-+\+\s+$'
        (& $rowText $frame[16]) | Should -Match '1\..*Item 0'
        (& $rowText $frame[18]) | Should -Match '3\..*Item 2'
        (& $rowText $frame[19]) | Should -Match '^\s+\+-+\+\s+$'
        (& $rowText $frame[20]) | Should -Match ('^\s{' + $lead + '}\| f\s+\|\s+$')
        (& $rowText $frame[21]) | Should -Match '^\s+\+-+\+\s+$'
        foreach ($i in 22..29) { (& $rowText $frame[$i]) | Should -Match '^\s*$' }
        foreach ($i in 13..21) { $r = & $rowText $frame[$i]; ($r.Length - $r.TrimStart().Length) | Should -Be $lead; $r.Trim().Length | Should -Be $boxWidth }
    }
    It 'compact layout widens the box to fit the longest row, the breadcrumb and the key hints' {
        $wide = @([PSCustomObject]@{ Kind = 'Link'; Name = 'W'; Label = ('Label ' * 9).Trim(); Risk = ''; StateLabel = ''; Selectable = $true; Data = $null })
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $wide -State (& $mkState) -Width 120 -Height 20 -Glyphs $g -Layout 'Compact' -FooterText 'f'
        (& $rowText $frame[16]) | Should -Match ([regex]::Escape($wide[0].Label))
        (& $rowText $frame[16]) | Should -Not -Match '~'
        (& $rowText $frame[13]).Trim().Length | Should -Be (2 + 3 + 1 + $wide[0].Label.Length + 6)
        $footer = 'Up/Down move - Enter open/run - 1-9 jump - Esc back - Q quit'
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 2) -State (& $mkState) -Width 120 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText $footer
        (& $rowText $frame[13]).Trim().Length | Should -Be ($footer.Length + 6)
        (& $rowText $frame[19]) | Should -Match ('^\s*\| ' + [regex]::Escape($footer) + '\s*\|\s*$')
        $crumb = 'Main Menu > Privacy Settings > Something Long'
        $frame = Get-WtFrameRows -Breadcrumb $crumb -Items (& $mkItems 2) -State (& $mkState) -Width 120 -Height 25 -Glyphs $g -Layout 'Compact'
        (& $rowText $frame[14]) | Should -Match ([regex]::Escape($crumb))
    }
    It 'compact layout never exceeds the console width and still caps the viewport' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 50) -State (& $mkState) -Width 60 -Height 20 -Glyphs $g -Layout 'Compact' -FooterText ('x' * 200)
        $frame.Count | Should -Be 20
        foreach ($row in $frame) { (& $rowText $row).Length | Should -Be 59 }
        (& $rowText $frame[5]) | Should -Match '^\s*\+-+\+\s*$'
        (& $rowText $frame[6]) | Should -Match '1-9/50 \|\s*$'
        (& $rowText $frame[18]) | Should -Match '^\s*\| x+~ \|\s*$'
    }
    It 'compact banner mode (main screen) stacks banner, credit block and a centered box' {
        $frame = Get-WtFrameRows -Breadcrumb 'Main Menu' -Items (& $mkItems 8) -State (& $mkState) -Width 120 -Height 40 -Glyphs $g -ShowBanner $true -Layout 'Compact' -FooterText 'f'
        $frame.Count | Should -Be 40
        $top = & $rowText $frame[13]
        $top | Should -Match '^\s+\+-+\+\s+$'
        $lead = $top.Length - $top.TrimStart().Length
        (& $rowText $frame[14]) | Should -Match ('^\s{' + $lead + '}\|.*1\..*Item 0')
        (& $rowText $frame[21]) | Should -Match '8\..*Item 7'
        (& $rowText $frame[22]) | Should -Match '^\s+\+-+\+\s+$'
        (& $rowText $frame[23]) | Should -Match ('^\s{' + $lead + '}\| f\s+\|\s+$')
        (& $rowText $frame[24]) | Should -Match '^\s+\+-+\+\s+$'
        foreach ($i in 25..39) { (& $rowText $frame[$i]) | Should -Match '^\s*$' }
    }
    It 'numbers focusable rows from 1 on the visible page' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 3) -State (& $mkState) -Width 80 -Height 20 -Glyphs $g
        (& $rowText $frame[8]) | Should -Match '1\..*Item 0'
        (& $rowText $frame[10]) | Should -Match '3\..*Item 2'
    }
    It 'widens the number column when the page reaches two digits so the markers stay in one column' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkItems 12) -State (& $mkState) -Width 80 -Height 40 -Glyphs $g
        $rows = @($frame | ForEach-Object { & $rowText $_ })
        $nine = @($rows | Where-Object { $_ -match '9\.\s+\[' })[0]
        $ten = @($rows | Where-Object { $_ -match '10\.\s+\[' })[0]
        $nine | Should -Not -BeNullOrEmpty
        $ten | Should -Not -BeNullOrEmpty
        $nine.IndexOf('[') | Should -Be $ten.IndexOf('[')
        $nine.IndexOf('Item 8') | Should -Be $ten.IndexOf('Item 9')
    }
    It 'reserves at least one content row on a tiny console' {
        $frame = Get-WtFrameRows -Breadcrumb 'X' -Items (& $mkItems 1) -State (& $mkState) -Width 40 -Height 7 -Glyphs $g
        (($frame | ForEach-Object { & $rowText $_ }) -join "`n") | Should -Match 'Item 0'
    }
}

Describe 'TUI shell surface' {
    It 'defines the shell functions after dot-sourcing' {
        foreach ($fn in 'Initialize-WtTui', 'Restore-WtTui', 'Write-WtFrame', 'Invoke-WtListScreen', 'Get-WtFrameChromeHeight', 'Reset-WtFrameCache', 'Get-WtConsoleSize') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    It 'dot-sourcing leaves Line-mode defaults and an empty frame cache (no console calls at parse time)' {
        $script:WtInputMode | Should -Be 'Line'
        $script:WtVt | Should -BeFalse
        @($script:WtPrevRows).Count | Should -Be 0
    }
    It 'turns progress bars off for the whole session and puts the setting back on the way out' {
        $before = $global:ProgressPreference
        $mode = $script:WtInputMode
        $vt = $script:WtVt
        try {
            Initialize-WtTui
            $global:ProgressPreference | Should -Be 'SilentlyContinue'
        }
        finally {
            Restore-WtTui
            $script:WtInputMode = $mode
            $script:WtVt = $vt
            Reset-WtFrameCache
        }
        $global:ProgressPreference | Should -Be $before
    }
    It 'chrome height = banner + blank + credit + URL + blank, then 6 box rows; banner mode (main screen) drops the path rows' {
        Get-WtFrameChromeHeight -Width 120 | Should -Be 19
        Get-WtFrameChromeHeight -Width 120 -ShowBanner $true | Should -Be 17
        Get-WtFrameChromeHeight -Width 80 | Should -Be 11
        Get-WtFrameChromeHeight -Width 80 -ShowBanner $true | Should -Be 9
    }
    It 'the description band costs its rows plus the separator above them' {
        Get-WtFrameChromeHeight -Width 120 -ShowBanner $true -DescriptionRows 2 | Should -Be 20
        Get-WtFrameChromeHeight -Width 120 -DescriptionRows 2 | Should -Be 22
        Get-WtFrameChromeHeight -Width 120 -DescriptionRows 1 | Should -Be 21
        Get-WtFrameChromeHeight -Width 120 -DescriptionRows 0 | Should -Be 19
    }
    It 'the source never assigns WtLastFrameHeight (replaced by Reset-WtFrameCache)' {
        $src = Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1') -Raw
        ([regex]::Matches($src, 'WtLastFrameHeight')).Count | Should -Be 0
    }
}

Describe 'Get-WtFrameDiff' {
    It 'returns every index when there is no previous frame' {
        Get-WtFrameDiff -Rows @('a', 'b', 'c') -PrevRows @() | Should -Be @(0, 1, 2)
    }
    It 'returns only the changed indexes' {
        Get-WtFrameDiff -Rows @('a', 'B', 'c', 'D') -PrevRows @('a', 'b', 'c', 'd') | Should -Be @(1, 3)
    }
    It 'returns nothing for identical frames' {
        @(Get-WtFrameDiff -Rows @('a', 'b') -PrevRows @('a', 'b')).Count | Should -Be 0
    }
    It 'returns rows beyond the previous frame length and everything when forced' {
        Get-WtFrameDiff -Rows @('a', 'b', 'c') -PrevRows @('a') | Should -Be @(1, 2)
        Get-WtFrameDiff -Rows @('a', 'b') -PrevRows @('a', 'b') -Force $true | Should -Be @(0, 1)
    }
    It 'is case-sensitive (SGR payloads differ only by case in places)' {
        Get-WtFrameDiff -Rows @('A') -PrevRows @('a') | Should -Be @(0)
    }
}

Describe 'ConvertTo-WtVtText' {
    BeforeAll { $script:ESC = [string][char]27 }
    It 'wraps text in a foreground SGR and a reset' {
        ConvertTo-WtVtText -Text 'ab' -Fg 'Red' | Should -Be ($ESC + '[91mab' + $ESC + '[0m')
    }
    It 'adds the background as +10' {
        ConvertTo-WtVtText -Text 'x' -Fg 'Black' -Bg 'DarkCyan' | Should -Be ($ESC + '[30;46mx' + $ESC + '[0m')
    }
    It 'returns an empty string for empty text' {
        ConvertTo-WtVtText -Text '' -Fg 'Red' | Should -Be ''
    }
    It 'falls back to Gray for an unknown color name' {
        ConvertTo-WtVtText -Text 'q' -Fg 'NotAColor' | Should -Be ($ESC + '[37mq' + $ESC + '[0m')
    }
}

Describe 'ConvertTo-WtRowString' {
    BeforeAll { $script:ESC = [string][char]27 }
    It 'pads a short plain row to exactly Width' {
        $segs = @((New-WtSeg -Text 'abc' -Fg 'White'))
        $row = ConvertTo-WtRowString -Segments $segs -Width 10 -Vt $false
        $row.Length | Should -Be 10
        $row | Should -Be 'abc       '
    }
    It 'truncates a long row to Width across segment boundaries' {
        $segs = @((New-WtSeg -Text 'abcdef' -Fg 'White'), (New-WtSeg -Text 'ghijkl' -Fg 'Red'))
        ConvertTo-WtRowString -Segments $segs -Width 8 -Vt $false | Should -Be 'abcdefgh'
    }
    It 'keeps exactly Width visible columns in VT mode and styles each segment' {
        $segs = @((New-WtSeg -Text 'ab' -Fg 'Cyan'), (New-WtSeg -Text 'cd' -Fg 'Black' -Bg 'DarkCyan'))
        $row = ConvertTo-WtRowString -Segments $segs -Width 6 -Vt $true
        Get-WtVisibleLength -Text $row | Should -Be 6
        $row | Should -Match ([regex]::Escape($ESC + '[96mab' + $ESC + '[0m'))
        $row | Should -Match ([regex]::Escape($ESC + '[30;46mcd' + $ESC + '[0m'))
        $row.EndsWith('  ') | Should -BeTrue
    }
    It 'an empty segment list yields Width spaces' {
        ConvertTo-WtRowString -Segments @() -Width 4 -Vt $true | Should -Be '    '
    }
}

Describe 'Get-WtVisibleLength' {
    It 'ignores SGR and CUP sequences' {
        $e = [string][char]27
        Get-WtVisibleLength -Text ($e + '[91mab' + $e + '[0m' + $e + '[3;1Hcd') | Should -Be 4
    }
}

Describe 'Test-WtNavToken' {
    It 'recognizes the six navigation tokens only' {
        foreach ($t in 'Up', 'Down', 'PageUp', 'PageDown', 'Home', 'End') { Test-WtNavToken -Token $t | Should -BeTrue }
        foreach ($t in 'Space', 'Enter', 'Back', 'Digit:3', 'Char:a', 'None') { Test-WtNavToken -Token $t | Should -BeFalse }
    }
}

Describe 'Invoke-WtTokenBatch' {
    BeforeEach {
        $script:items = 0..9 | ForEach-Object { [PSCustomObject]@{ Kind = 'Check'; Name = "N$_"; Label = "I$_"; Risk = 'SAFE'; StateLabel = ''; Selectable = $true; Data = $null } }
        $script:state = @{ CursorIndex = 0; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
    }
    It 'applies repeated Down tokens in one go' {
        $r = Invoke-WtTokenBatch -State $state -Tokens @('Down', 'Down', 'Down') -Items $items -ViewHeight 5 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 3
        $r.Emit | Should -Be 'None'
        $r.Processed | Should -Be 3
    }
    It 'processes a trailing Space after the moves' {
        $r = Invoke-WtTokenBatch -State $state -Tokens @('Down', 'Space') -Items $items -ViewHeight 5 -MultiSelect $true
        $r.State.Selection.Contains('N1') | Should -BeTrue
        $r.Processed | Should -Be 2
    }
    It 'stops at the first emitting token and drops the rest' {
        $r = Invoke-WtTokenBatch -State $state -Tokens @('Down', 'Enter', 'Down', 'Down') -Items $items -ViewHeight 5 -MultiSelect $true
        $r.Emit | Should -Be 'Activate'
        $r.State.CursorIndex | Should -Be 1
        $r.Processed | Should -Be 2
    }
    It 'an empty batch changes nothing' {
        $r = Invoke-WtTokenBatch -State $state -Tokens @() -Items $items -ViewHeight 5 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 0
        $r.Processed | Should -Be 0
    }
}

Describe 'Group-scoped radio selection' {
    BeforeEach {
        $script:items = @(
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'dns1'; Label = 'Cloudflare'; Risk = 'CAUTION'; StateLabel = ''; Selectable = $true; Data = $null; Group = 'DnsPreset' }
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'dns2'; Label = 'Quad9'; Risk = 'CAUTION'; StateLabel = ''; Selectable = $true; Data = $null; Group = 'DnsPreset' }
            [PSCustomObject]@{ Kind = 'Check'; Name = 'svc'; Label = 'Service'; Risk = 'SAFE'; StateLabel = ''; Selectable = $true; Data = $null; Group = '' }
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'lang1'; Label = 'EN'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null; Group = 'Lang' }
        )
        $script:sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $sel.Add('svc') | Out-Null
        $sel.Add('lang1') | Out-Null
        $sel.Add('dns1') | Out-Null
    }
    It 'Space on a radio replaces only radios of the same group' {
        $state = @{ CursorIndex = 1; WindowStart = 0; Selection = $sel }
        $r = Update-WtListState -State $state -Token 'Space' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Contains('dns2') | Should -BeTrue
        $r.State.Selection.Contains('dns1') | Should -BeFalse
        $r.State.Selection.Contains('svc') | Should -BeTrue
        $r.State.Selection.Contains('lang1') | Should -BeTrue
    }
    It 'items without a Group property behave as one ungrouped radio set' {
        $plain = @(
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'EN'; Label = 'English'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null }
            [PSCustomObject]@{ Kind = 'Radio'; Name = 'TR'; Label = 'Turkce'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null }
        )
        $s = New-Object 'System.Collections.Generic.HashSet[string]'
        $s.Add('EN') | Out-Null
        $r = Update-WtListState -State @{ CursorIndex = 1; WindowStart = 0; Selection = $s } -Token 'Space' -Items $plain -ViewHeight 10
        @($r.State.Selection) | Should -Be @('TR')
    }
    It 'New-WtListItem exposes Group (default empty)' {
        (New-WtListItem -Kind 'Radio' -Name 'a' -Label 'A').Group | Should -Be ''
        (New-WtListItem -Kind 'Radio' -Name 'a' -Label 'A' -Group 'G1').Group | Should -Be 'G1'
    }
}

Describe 'Input shell surface' {
    It 'defines Read-WtInputBatch and no longer Read-WtInputToken' {
        Get-Command Read-WtInputBatch -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Read-WtInputToken -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Clear-WtPendingInput (keys queued during a long action must not replay)' {
    BeforeEach {
        $script:oldMode = $script:WtInputMode
        $script:WtInputMode = 'Key'
        $script:queue = New-Object 'System.Collections.Generic.Queue[string]'
        $script:reads = 0
        $script:avail = { $script:queue.Count -gt 0 }
        $script:readKey = { $script:reads++; $script:queue.Dequeue() }
    }
    AfterEach { $script:WtInputMode = $script:oldMode }

    It 'reads every queued key and returns how many it discarded' {
        foreach ($k in 'Enter', 'Enter', 'D3') { $script:queue.Enqueue($k) }
        Clear-WtPendingInput -KeyAvailable $script:avail -ReadKey $script:readKey | Should -Be 3
        $script:queue.Count | Should -Be 0
    }

    It 'never blocks on an empty queue' {
        Clear-WtPendingInput -KeyAvailable $script:avail -ReadKey $script:readKey | Should -Be 0
        $script:reads | Should -Be 0
    }

    It 'does nothing in line mode, where there is no key queue to drain' {
        $script:WtInputMode = 'Line'
        $script:queue.Enqueue('Enter')
        Clear-WtPendingInput -KeyAvailable $script:avail -ReadKey $script:readKey | Should -Be 0
        $script:reads | Should -Be 0
    }

    It 'stops at the cap so a stuck KeyAvailable can never spin forever' {
        $stuck = { $true }
        $count = { $script:reads++; 'Enter' }
        Clear-WtPendingInput -KeyAvailable $stuck -ReadKey $count | Should -Be 1024
    }

    It 'swallows a console that throws instead of unwinding the screen' {
        $throws = { throw 'no console' }
        { Clear-WtPendingInput -KeyAvailable $throws -ReadKey $script:readKey } | Should -Not -Throw
    }

    It 'is the one place the shell drains, and never through FlushInputBuffer (separate cache -> phantom keys)' {
        $def = (Get-Command Clear-WtPendingInput).Definition
        $code = [regex]::Replace([regex]::Replace($def, '(?s)<#.*?#>', ''), '(?m)#.*$', '')
        $code | Should -Not -Match 'FlushInputBuffer'
        $code | Should -Not -Match 'RawUI'
    }
}

Describe 'Compact panels (Undo confirm) - footer sizing and Get-WtFrameFooterCell' {
    BeforeAll {
        $script:g = Get-WtGlyphSet -Unicode $false
        $script:mkState = { @{ CursorIndex = -1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') } }
        $script:rowText = { param($row) ($row | ForEach-Object T) -join '' }
    }
    It 'a compact box grows to fit its prompt instead of cutting it' {
        $items = @(Get-WtPanelItems -Lines @('short') -Risk 'CAUTION')
        $prompt = 'Restore this entry? Enter = restore, anything else = cancel: '
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State (& $mkState) -Width 140 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText $prompt
        $footer = & $rowText $frame[18]
        $footer | Should -Match ([regex]::Escape($prompt.TrimEnd()))
        $footer | Should -Not -Match '~'
        (& $rowText $frame[13]).Trim().Length | Should -BeLessThan 100
    }
    It 'a compact menu grows to fit its navigation guide too' {
        $items = @([PSCustomObject]@{ Kind = 'Link'; Name = 'A'; Label = 'Short'; Risk = ''; StateLabel = ''; Selectable = $true; Data = $null })
        $guide = [string]$script:Translations['TR']['NavFooter']
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State (& $mkState) -Width 140 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText $guide
        $rows = @($frame | ForEach-Object { & $rowText $_ })
        (@($rows | Where-Object { $_ -match [regex]::Escape($guide) })).Count | Should -Be 1
        (@($rows | Where-Object { $_ -match '~' })).Count | Should -Be 0
    }
    It 'locates the footer cell of a compact box (centered) and of a full box (row Height-2, col 2)' {
        $items = @(Get-WtPanelItems -Lines @('x'))
        $compact = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State (& $mkState) -Width 120 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText 'f'
        $geo = Get-WtFrameFooterCell -FrameLines $compact -Glyphs $g
        $geo.Row | Should -Be 18
        $top = & $rowText $compact[13]
        $geo.Col | Should -Be (($top.Length - $top.TrimStart().Length) + 2)
        $full = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State (& $mkState) -Width 120 -Height 30 -Glyphs $g -FooterText 'f'
        $geo = Get-WtFrameFooterCell -FrameLines $full -Glyphs $g
        $geo.Row | Should -Be 28
        $geo.Col | Should -Be 2
    }
}

Describe 'Invoke-WtListScreen Refused hint and direction counter' {
    It 'shows the remove-unavailable hint for one frame after a Refused emit, then the normal footer' {
        $script:footers = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-WtConsoleSize { @{ Width = 100; Height = 30 } }
        Mock Write-WtFrame { }
        Mock Get-WtFrameRows { $script:footers.Add($FooterText); ,@() }
        $script:batches = New-Object 'System.Collections.Generic.Queue[object]'
        $batches.Enqueue([string[]]@('Space')); $batches.Enqueue([string[]]@('Down')); $batches.Enqueue([string[]]@('Back'))
        Mock Read-WtInputBatch { $script:batches.Dequeue() }
        $items = @(
            New-WtListItem -Kind 'Check' -Name 'C' -Label 'Gamma' -StateLabel 'Applied' -Applied $true -Selectable $false
            New-WtListItem -Kind 'Check' -Name 'A' -Label 'Alpha' -StateLabel 'NotApplied'
        )
        Invoke-WtListScreen -Breadcrumb 'B' -Items $items -MultiSelect $true -FooterText 'normal' | Out-Null
        @($footers) | Should -Be @('normal', (Get-Translation 'RemoveUnavailableHint'), 'normal')
    }
    It 'the counter shows per-direction mark counts' {
        $script:counters = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-WtConsoleSize { @{ Width = 100; Height = 30 } }
        Mock Write-WtFrame { }
        Mock Get-WtFrameRows { $script:counters.Add($CounterText); ,@() }
        Mock Read-WtInputBatch { [string[]]@('Back') }
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $sel.Add('A') | Out-Null; $sel.Add('B') | Out-Null
        $items = @(
            New-WtListItem -Kind 'Check' -Name 'A' -Label 'Alpha' -StateLabel 'NotApplied'
            New-WtListItem -Kind 'Check' -Name 'B' -Label 'Beta' -StateLabel 'Applied' -Applied $true -Removable $true
        )
        Invoke-WtListScreen -Breadcrumb 'B' -Items $items -MultiSelect $true -Selection $sel -CounterText '2 settings' | Out-Null
        $counters[0] | Should -Be ('2 settings  ' + (Format-WtDirectionCounts -ApplyCount 1 -RemoveCount 1))
    }
}

Describe 'Mark-all on a cycling list' {
    BeforeAll {
        $script:cycleItems = @(
            New-WtListItem -Kind 'Check' -Name 'Fax' -Label 'Fax' -CycleTargets @('Disabled', 'Manual', 'Automatic')
            New-WtListItem -Kind 'Check' -Name 'Plain' -Label 'Plain'
        )
        $script:mkCycleState = { @{ CursorIndex = 0; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]'); Cycle = @{} } }
    }
    It 'A gives every cycling row the first target, so the mark means something' {
        $r = Update-WtListState -Items $script:cycleItems -State (& $script:mkCycleState) -Token 'Char:a' -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Contains('Fax') | Should -BeTrue
        $r.State.Cycle['Fax'] | Should -Be 'Disabled'
    }
    It 'A leaves a plain row without a cycle entry' {
        $r = Update-WtListState -Items $script:cycleItems -State (& $script:mkCycleState) -Token 'Char:a' -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Contains('Plain') | Should -BeTrue
        $r.State.Cycle.ContainsKey('Plain') | Should -BeFalse
    }
    It 'C clears the cycle it set' {
        $s = & $script:mkCycleState
        $s = (Update-WtListState -Items $script:cycleItems -State $s -Token 'Char:a' -ViewHeight 10 -MultiSelect $true).State
        $s = (Update-WtListState -Items $script:cycleItems -State $s -Token 'Char:c' -ViewHeight 10 -MultiSelect $true).State
        $s.Cycle.Count | Should -Be 0
        $s.Selection.Count | Should -Be 0
    }
}

Describe 'The state column is coloured by what its words mean' {
    BeforeAll {
        $script:seg = { param($Text, $Default) @(Split-WtStateSegments -Text $Text -DefaultFg $(if ($Default) { $Default } else { 'DarkGray' })) }
        $script:colourOf = { param($Text, $Word)
            $hit = @(& $script:seg $Text | Where-Object { $_.T -eq $Word })
            if ($hit.Count -eq 0) { return "<$Word is not its own segment>" }
            return [string]$hit[0].F
        }
    }
    It 'joining the segments returns the text unchanged - no width can move' {
        foreach ($text in '', '  Running/Automatic', '  Stopped/Disabled    ', '  currently: on   ',
                          '  C:\Users\Someone\Downloads', '  1.2 GB - 431 files', '  ') {
            ((& $script:seg $text | ForEach-Object T) -join '') | Should -Be $text -Because "text was [$text]"
        }
    }
    It 'a running service reads green, a stopped one gray' {
        & $script:colourOf '  Running/Automatic' 'Running' | Should -Be 'Green'
        & $script:colourOf '  Stopped/Manual' 'Stopped' | Should -Be 'Gray'
    }
    It 'the start type is a traffic light: Automatic green, Manual yellow, Disabled red' {
        & $script:colourOf '  Running/Automatic' 'Automatic' | Should -Be 'Green'
        & $script:colourOf '  Stopped/Manual' 'Manual' | Should -Be 'Yellow'
        & $script:colourOf '  Stopped/Disabled' 'Disabled' | Should -Be 'Red'
    }
    It 'a live firewall reads green, a downed one red' {
        & $script:colourOf '  currently: on' 'currently: on' | Should -Be 'Green'
        & $script:colourOf '  currently: off' 'currently: off' | Should -Be 'Red'
    }
    It 'the separator and the leading gap keep the default colour' {
        $segs = & $script:seg '  Running/Automatic  ' 'DarkGray'
        @($segs | Where-Object { $_.T -eq '/' })[0].F | Should -Be 'DarkGray'
        $segs[0].T | Should -Be '  '
        $segs[0].F | Should -Be 'DarkGray'
    }
    It 'the LAST segment is the padding in the default colour - other tests read it as the state colour' {
        $segs = & $script:seg ('  ' + 'Applied'.PadRight(11)) 'Green'
        $segs[-1].F | Should -Be 'Green'
        $segs[-1].T | Should -Be '    '
    }
    It 'a state the app did not build from a translation key stays one default segment' {
        foreach ($text in '  C:\Program Files\Thing', '  1.2 GB - 431 files') {
            $segs = & $script:seg $text 'DarkGray'
            @($segs | Where-Object { $_.F -ne 'DarkGray' }).Count | Should -Be 0 -Because "text was [$text]"
        }
    }
    It 'matches whole localized words, not fragments: Applied does not light up inside Not applied' {
        $segs = & $script:seg '  Not applied' 'DarkGray'
        @($segs | Where-Object { $_.T -eq 'Applied' }).Count | Should -Be 0
        & $script:colourOf '  Not applied' 'Not applied' | Should -Be 'DarkGray'
    }
    It 'Turkish gets the same colours from the same keys' {
        $tr = Get-WtStateColorMap -Language 'TR'
        $word = { param($w) [string](@($tr | Where-Object { $_.Word -eq $w })[0].Fg) }
        & $word 'Calisiyor' | Should -Be 'Green'
        & $word 'Durdu' | Should -Be 'Gray'
        & $word 'Otomatik' | Should -Be 'Green'
        & $word 'El ile' | Should -Be 'Yellow'
        & $word 'Devre disi' | Should -Be 'Red'
        & $word 'Mevcut degil' | Should -Be 'DarkGray'
    }
    It 'the Turkish vocabulary really does split a Turkish label' {
        $segs = @(Split-WtStateSegments -Text '  Calisiyor/Otomatik' -Vocabulary (Get-WtStateColorMap -Language 'TR'))
        (($segs | ForEach-Object T) -join '') | Should -Be '  Calisiyor/Otomatik'
        @($segs | Where-Object { $_.T -eq 'Calisiyor' })[0].F | Should -Be 'Green'
        @($segs | Where-Object { $_.T -eq 'Otomatik' })[0].F | Should -Be 'Green'
    }
    It 'the longest word wins - currently: off is never cut into a shorter hit' {
        $segs = & $script:seg '  currently: off' 'DarkGray'
        @($segs | Where-Object { $_.F -eq 'Red' })[0].T | Should -Be 'currently: off'
    }
    It 'the map is cached per language and never mixes two languages' {
        $en = Get-WtStateColorMap -Language 'EN'
        $en2 = Get-WtStateColorMap -Language 'EN'
        @($en2 | ForEach-Object Word) | Should -Be @($en | ForEach-Object Word)
        @(Get-WtStateColorMap -Language 'TR' | ForEach-Object Word) | Should -Not -Be @($en | ForEach-Object Word)
    }
}

Describe 'A rendered row carries the state colours through' {
    BeforeAll {
        $script:cg = Get-WtGlyphSet -Unicode $false
        $script:svcRow = New-WtListItem -Kind 'Check' -Name 'Fax' -Label 'Fax - Fax service' -Risk 'SAFE' -StateLabel 'Stopped/Disabled' -CycleTargets @('Disabled', 'Manual', 'Automatic')
        $script:runRow = New-WtListItem -Kind 'Check' -Name 'Trk' -Label 'TrkWks' -Risk 'SAFE' -StateLabel 'Running/Automatic'
    }
    It 'a stopped, disabled service shows a gray word and a red one' {
        $segs = Get-WtListRowSegments -Item $script:svcRow -IsCursor $false -Selected $false -Glyphs $script:cg -Width 90 -StateWidth 17
        @($segs | Where-Object { $_.T -eq 'Stopped' })[0].F | Should -Be 'Gray'
        @($segs | Where-Object { $_.T -eq 'Disabled' })[0].F | Should -Be 'Red'
    }
    It 'a running, automatic service is green twice' {
        $segs = Get-WtListRowSegments -Item $script:runRow -IsCursor $false -Selected $false -Glyphs $script:cg -Width 90 -StateWidth 17
        @($segs | Where-Object { $_.F -eq 'Green' } | ForEach-Object T) | Should -Be @('Running', 'Automatic')
    }
    It 'colouring does not change one character of the row' {
        foreach ($row in $script:svcRow, $script:runRow) {
            $text = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $script:cg -Width 90 -StateWidth 17) | ForEach-Object T) -join ''
            $text | Should -Match ([regex]::Escape([string]$row.StateLabel))
            $text.Length | Should -BeLessOrEqual 90
        }
    }
    It 'a marked row keeps ONE yellow block - the pending target is not colour-coded' {
        $segs = Get-WtListRowSegments -Item $script:svcRow -IsCursor $false -Selected $true -Glyphs $script:cg -Width 90 -StateWidth 17 -PendingLabel 'Automatic'
        (($segs | ForEach-Object T) -join '') | Should -Match '-> Automatic'
        @($segs | Where-Object { $_.T -eq 'Automatic' }).Count | Should -Be 0
        $segs[-1].F | Should -Be 'Yellow'
    }
    It 'the cursor row stays one flat highlight bar' {
        $segs = @(Get-WtListRowSegments -Item $script:runRow -IsCursor $true -Selected $false -Glyphs $script:cg -Width 90 -StateWidth 17)
        $segs.Count | Should -Be 1
        $segs[0].B | Should -Be 'DarkCyan'
    }
}
Describe 'Every service state word the OS can hand us is translated and coloured' {
    It 'the pending and paused statuses have a word in both languages' {
        foreach ($k in 'SvcStatus.Running', 'SvcStatus.Stopped', 'SvcStatus.Paused', 'SvcStatus.StartPending',
                       'SvcStatus.StopPending', 'SvcStatus.PausePending', 'SvcStatus.ContinuePending') {
            $script:Translations['EN'][$k] | Should -Not -BeNullOrEmpty -Because "EN needs $k"
            $script:Translations['TR'][$k] | Should -Not -BeNullOrEmpty -Because "TR needs $k"
        }
    }
    It 'Boot and System start types have a word in both languages' {
        foreach ($k in 'SvcStart.Boot', 'SvcStart.System') {
            $script:Translations['EN'][$k] | Should -Not -BeNullOrEmpty -Because "EN needs $k"
            $script:Translations['TR'][$k] | Should -Not -BeNullOrEmpty -Because "TR needs $k"
        }
    }
    It 'a Turkish screen shows no raw .NET enum name for any ServiceController state' {
        $script:Language = 'TR'
        try {
            foreach ($status in 'Running', 'Stopped', 'Paused', 'StartPending', 'StopPending', 'PausePending', 'ContinuePending') {
                foreach ($start in 'Boot', 'System', 'Automatic', 'Manual', 'Disabled') {
                    $label = Format-WtServiceStateLabel -Status $status -StartType $start
                    $label | Should -Not -Match ([regex]::Escape($status)) -Because "TR label for $status/$start was '$label'"
                    $label | Should -Not -Match ([regex]::Escape($start)) -Because "TR label for $status/$start was '$label'"
                }
            }
        }
        finally { $script:Language = 'EN' }
    }
    It 'every word the service label can print is in the colour map' {
        foreach ($lang in 'EN', 'TR') {
            $known = @(Get-WtStateColorMap -Language $lang | ForEach-Object Word)
            foreach ($k in 'SvcStatus.Running', 'SvcStatus.Stopped', 'SvcStatus.Paused', 'SvcStatus.StartPending',
                           'SvcStatus.StopPending', 'SvcStatus.PausePending', 'SvcStatus.ContinuePending',
                           'SvcStart.Boot', 'SvcStart.System', 'SvcStart.Automatic', 'SvcStart.Manual', 'SvcStart.Disabled',
                           'StateNotPresent', 'FlushAvailable') {
                $known | Should -Contain ([string]$script:Translations[$lang][$k]) -Because "$lang $k"
            }
        }
    }
    It 'a longer word wins over a shorter one it starts with (TR Durduruluyor over Durdu)' {
        $tr = Get-WtStateColorMap -Language 'TR'
        $segs = @(Split-WtStateSegments -Text '  Durduruluyor/El ile' -Vocabulary $tr -DefaultFg 'DarkGray')
        (($segs | ForEach-Object T) -join '') | Should -Be '  Durduruluyor/El ile'
        @($segs | Where-Object { $_.T -eq 'Durduruluyor' })[0].F | Should -Be 'Yellow'
        @($segs | Where-Object { $_.T -eq 'Durdu' }).Count | Should -Be 0
    }
}
Describe 'A state the app did not build from the table is never partly coloured' {
    BeforeAll {
        $script:seg2 = { param($Text, $Vocab) @(Split-WtStateSegments -Text $Text -DefaultFg 'DarkGray' -Vocabulary $(if ($Vocab) { $Vocab } else { Get-WtStateColorMap })) }
        $script:coloured = { param($Text, $Vocab) @((& $script:seg2 $Text $Vocab) | Where-Object { $_.F -ne 'DarkGray' }).Count }
    }
    It 'a Windows path never lights up a vocabulary word hiding inside it' {
        foreach ($path in '  C:\Windows\System32', '  C:\Users\Someone\Boot\Desktop', '  C:\Manuals',
                          '  C:\System Volume Information', '  D:\Automatic backups') {
            & $script:coloured $path | Should -Be 0 -Because "path was [$path]"
        }
    }
    It 'a Turkish path is just as safe' {
        $tr = Get-WtStateColorMap -Language 'TR'
        foreach ($path in '  C:\Sistem\yedek', '  D:\Yuklu', '  C:\Onyukleme', '  E:\El ile yedekleme') {
            & $script:coloured $path $tr | Should -Be 0 -Because "path was [$path]"
        }
    }
    It 'a size, a count and a raw enum stay uncoloured too' {
        foreach ($text in '  245.3 MB (1,204 files)', '  245.3 MB (1,204 dosya)', '  Nonsense/Gibberish', '  0 B (0 files)') {
            & $script:coloured $text | Should -Be 0 -Because "text was [$text]"
        }
    }
    It 'an uncoloured column is ONE segment carrying the text verbatim' {
        $segs = @(& $script:seg2 '  C:\Windows\System32')
        $segs.Count | Should -Be 1
        $segs[0].T | Should -Be '  C:\Windows\System32'
        $segs[0].F | Should -Be 'DarkGray'
    }
    It 'a label that is a vocabulary word plus free text is left alone entirely' {
        & $script:coloured ('  ' + (Get-Translation 'FlushAvailable') + (Get-Translation 'AlreadyInTargetState')) | Should -Be 0
    }
    It 'the real labels still colour - the rule only refuses text it does not own' {
        & $script:coloured '  Running/Automatic' | Should -Be 2
        & $script:coloured '  Stopped/Disabled  ' | Should -Be 2
        & $script:coloured '  currently: on' | Should -Be 1
        & $script:coloured ('  ' + (Get-Translation 'StateInstalled')) | Should -Be 1
    }
    It 'joining still returns the text unchanged on BOTH paths' {
        foreach ($text in '  Running/Automatic', '  C:\Windows\System32', '  245.3 MB (1,204 files)', '  ', '') {
            (((& $script:seg2 $text) | ForEach-Object T) -join '') | Should -Be $text -Because "text was [$text]"
        }
    }
    It 'every SvcStatus/SvcStart key in the table is in the colour map, and vice versa' {
        foreach ($lang in 'EN', 'TR') {
            $words = @(Get-WtStateColorMap -Language $lang | ForEach-Object Word)
            foreach ($key in @($script:Translations[$lang].Keys | Where-Object { $_ -like 'SvcStatus.*' -or $_ -like 'SvcStart.*' })) {
                $words | Should -Contain ([string]$script:Translations[$lang][$key]) -Because "$lang $key has no colour"
            }
        }
    }
}
Describe 'Ctrl+C is a key for the whole session' {
    It 'Initialize-WtTui''s helper saves the host value, sets the flag, and Restore puts it back' {
        $saved = $script:WtTuiSavedCtrlC
        try {
            $script:Calls = @()
            Enable-WtTuiCtrlCInput -GetConsole { $false } -SetConsole { param($Value) $script:Calls += @([string]$Value) }
            $script:WtTuiSavedCtrlC | Should -BeFalse
            $script:Calls | Should -Be @('True')
            Restore-WtTuiCtrlCInput -SetConsole { param($Value) $script:Calls += @([string]$Value) }
            $script:Calls | Should -Be @('True', 'False')
            $script:WtTuiSavedCtrlC | Should -BeNullOrEmpty
            Enable-WtTuiCtrlCInput -GetConsole { throw 'no console' } -SetConsole { param($Value) throw 'must not set' }
            $script:WtTuiSavedCtrlC | Should -BeNullOrEmpty
            $script:Calls = @()
            Restore-WtTuiCtrlCInput -SetConsole { param($Value) $script:Calls += @([string]$Value) }
            $script:Calls.Count | Should -Be 0
        }
        finally { $script:WtTuiSavedCtrlC = $saved }
    }

    It 'both key converters turn the Ctrl+C control character into a no-op token, so a stray press is ignored by every screen' {
        ConvertTo-WtKeyToken -Key 'C' -KeyChar ([string][char]3) | Should -Be 'None'
        ConvertTo-WtGridKeyToken -Key 'C' -KeyChar ([string][char]3) | Should -Be 'None'
    }
}

Describe 'Rule rows (the titled line that opens the assistant block)' {
    BeforeAll { $script:g = Get-WtGlyphSet -Unicode $false }
    It 'New-WtListItem accepts Rule and never makes it selectable or focusable' {
        $item = New-WtListItem -Kind 'Rule' -Name 'R' -Label 'WinToolify Asistan'
        $item.Kind | Should -Be 'Rule'
        $item.Selectable | Should -BeFalse
        Test-WtItemFocusable -Item $item | Should -BeFalse
    }
    It 'renders "  -- Title ----" exactly Width wide: the line dark gray, the title in the section cyan' {
        $item = New-WtListItem -Kind 'Rule' -Name 'R' -Label 'WinToolify Asistan'
        $segs = @(Get-WtListRowSegments -Item $item -IsCursor $false -Selected $false -Glyphs $script:g -Width 60)
        $text = ($segs | ForEach-Object T) -join ''
        $text | Should -Be ('  -- WinToolify Asistan ' + ('-' * (60 - 24)))
        $text.Length | Should -Be 60
        $segs[0].F | Should -Be 'DarkGray'
        $segs[1].T | Should -Be 'WinToolify Asistan'
        $segs[1].F | Should -Be 'Cyan'
        $segs[2].F | Should -Be 'DarkGray'
    }
    It 'cuts a title that does not fit and still stays within Width' {
        $item = New-WtListItem -Kind 'Rule' -Name 'R' -Label ('T' * 80)
        $text = (@(Get-WtListRowSegments -Item $item -IsCursor $false -Selected $false -Glyphs $script:g -Width 40) | ForEach-Object T) -join ''
        $text.Length | Should -BeLessOrEqual 40
        $text | Should -Match '~'
    }
    It 'sizes a compact box by the lead, the title and a few line cells - not by the full row' {
        $item = New-WtListItem -Kind 'Rule' -Name 'R' -Label 'Asistan'
        (Get-WtListRowNaturalWidth -Item $item -Glyphs $script:g) | Should -Be (5 + 7 + 4)
    }
    It 'the cursor skips a Rule row like a Header' {
        $items = @(
            New-WtListItem -Kind 'Link' -Name 'A' -Label 'a' -Data @{ Screen = 'X' }
            New-WtListItem -Kind 'Spacer' -Name 'S' -Label ''
            New-WtListItem -Kind 'Rule' -Name 'R' -Label 'rule'
            New-WtListItem -Kind 'Link' -Name 'B' -Label 'b' -Data @{ Screen = 'Y' }
        )
        (Get-WtNextFocusableIndex -Items $items -FromIndex 0 -Direction 1) | Should -Be 3
    }
}

Describe 'Assert-WtTuiCtrlCInput (a child process gave Ctrl+C back to the system)' {
    BeforeEach { $script:savedOwned = $script:WtTuiCtrlCOwned; $script:savedCtrl = $script:WtTuiSavedCtrlC }
    AfterEach { $script:WtTuiCtrlCOwned = $script:savedOwned; $script:WtTuiSavedCtrlC = $script:savedCtrl }
    It 'does nothing until Enable-WtTuiCtrlCInput has taken Ctrl+C' {
        $script:WtTuiCtrlCOwned = $false
        (Assert-WtTuiCtrlCInput -GetConsole { $false } -SetConsole { param($Value) throw 'must not set' }) | Should -BeFalse
    }
    It 'puts the key bit back when it is found cleared, and only then' {
        Enable-WtTuiCtrlCInput -GetConsole { $false } -SetConsole { param($Value) }
        $script:WtTuiCtrlCOwned | Should -BeTrue
        $script:sets = @()
        (Assert-WtTuiCtrlCInput -GetConsole { $true } -SetConsole { param($Value) $script:sets += @($Value) }) | Should -BeFalse
        @($script:sets).Count | Should -Be 0
        (Assert-WtTuiCtrlCInput -GetConsole { $false } -SetConsole { param($Value) $script:sets += @($Value) }) | Should -BeTrue
        @($script:sets) | Should -Be @($true)
    }
    It 'never throws, and stops once Restore-WtTuiCtrlCInput handed the key back' {
        Enable-WtTuiCtrlCInput -GetConsole { $false } -SetConsole { param($Value) }
        { Assert-WtTuiCtrlCInput -GetConsole { throw 'no console' } -SetConsole { param($Value) } } | Should -Not -Throw
        Restore-WtTuiCtrlCInput -SetConsole { param($Value) }
        $script:WtTuiCtrlCOwned | Should -BeFalse
        (Assert-WtTuiCtrlCInput -GetConsole { $false } -SetConsole { param($Value) throw 'must not set' }) | Should -BeFalse
    }
    It 'every blocking read re-asserts it: the key batch, the REPL line, the pick, the cancel poll, the panel answer and the native runner' {
        foreach ($fn in 'Read-WtInputBatch', 'Read-WtReplLine', 'Read-WtReplPick', 'Test-WtReplCancelRequested', 'Read-WtPanelAnswer', 'Invoke-WtStreamedProcess') {
            (Get-Command $fn).Definition | Should -Match 'Assert-WtTuiCtrlCInput' -Because $fn
        }
    }
}

Describe 'SGR prefix cache (the row renderer no longer calls a function per segment)' {
    It 'ConvertTo-WtRowString -Vt renders exactly what ConvertTo-WtVtText renders, and fills the cache as it goes' {
        $segs = @(([PSCustomObject]@{ T = 'ab'; F = 'Cyan'; B = '' }), (New-WtSeg -Text 'cd' -Fg 'Black' -Bg 'DarkCyan'), (New-WtSeg -Text 'e' -Fg 'NoSuchColor'))
        $row = ConvertTo-WtRowString -Segments $segs -Width 8 -Vt $true
        $expected = (ConvertTo-WtVtText -Text 'ab' -Fg 'Cyan') + (ConvertTo-WtVtText -Text 'cd' -Fg 'Black' -Bg 'DarkCyan') + (ConvertTo-WtVtText -Text 'e' -Fg 'NoSuchColor') + '   '
        $row | Should -Be $expected
        $script:WtSgrPrefixCache.ContainsKey('Cyan|') | Should -BeTrue
        $script:WtSgrPrefixCache.ContainsKey('Black|DarkCyan') | Should -BeTrue
        $script:WtSgrPrefixCache['Black|DarkCyan'] | Should -Be ([string][char]27 + '[30;46m')
        Get-WtSgrPrefix -Fg 'NoSuchColor' -Bg '' | Should -Be ([string][char]27 + '[37m')
        Get-WtSgrPrefix -Fg '' -Bg 'Nope' | Should -Be ([string][char]27 + '[37m')
    }
    It 'a segment literal and a New-WtSeg segment render the same, with and without VT' {
        foreach ($vt in $true, $false) {
            (ConvertTo-WtRowString -Segments @([PSCustomObject]@{ T = 'x'; F = 'Green'; B = '' }) -Width 3 -Vt $vt) | Should -Be (ConvertTo-WtRowString -Segments @((New-WtSeg -Text 'x' -Fg 'Green')) -Width 3 -Vt $vt)
        }
    }
    It 'the store cell composer and the list row composer emit segments of the shape New-WtSeg makes' {
        $cell = (Get-WtStoreCellSegments -Cell @{ Kind = 'App'; Id = 'a'; Name = 'App'; Category = 'c' } -NameWidth 6 -Glyphs (Get-WtGlyphSet -Unicode $false))
        $cell.Count | Should -Be 2
        foreach ($s in $cell) { @($s.PSObject.Properties.Name | Sort-Object) | Should -Be @('B', 'F', 'T') }
        $row = New-WtListItem -Kind 'Check' -Name 'n' -Label 'label' -StateLabel 'Uygulanmadi' -Risk 'SAFE'
        $segs = @(Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs (Get-WtGlyphSet -Unicode $false) -Width 60 -StateWidth 11)
        foreach ($s in $segs) { @($s.PSObject.Properties.Name | Sort-Object) | Should -Be @('B', 'F', 'T') }
        (($segs | ForEach-Object T) -join '').Length | Should -BeLessOrEqual 60
    }
}

Describe 'Row metrics, state segment memory and the compact width memory' {
    It 'Get-WtRowColumnMetrics matches the labels and widths computed the long way, per language, and is remembered' {
        $old = $script:Language
        try {
            foreach ($lang in 'EN', 'TR') {
                $script:Language = $lang
                $m = Get-WtRowColumnMetrics
                $width = 0
                foreach ($r in 'SAFE', 'CAUTION', 'ADVANCED') {
                    $m.RiskLabels[$r] | Should -Be (Get-WtRiskLabel -Risk $r) -Because "$lang/$r"
                    $width = [Math]::Max($width, (Get-WtRiskLabel -Risk $r).Length + 2)
                }
                $m.RiskWidth | Should -Be $width
                $floor = 0
                foreach ($k in 'Applied', 'NotApplied', 'WillApply', 'WillRemove') { $floor = [Math]::Max($floor, ([string](Get-Translation $k)).Length) }
                $m.StateFloor | Should -Be $floor
                [object]::ReferenceEquals((Get-WtRowColumnMetrics), $m) | Should -BeTrue
            }
        }
        finally { $script:Language = $old }
    }
    It 'Get-WtStateSegmentsCached returns what Split-WtStateSegments returns, and the same objects the second time' {
        $a = @(Get-WtStateSegmentsCached -Text 'Calisiyor/Otomatik   ' -DefaultFg 'DarkGray')
        $b = @(Split-WtStateSegments -Text 'Calisiyor/Otomatik   ' -DefaultFg 'DarkGray')
        (($a | ForEach-Object T) -join '') | Should -Be (($b | ForEach-Object T) -join '')
        @($a | ForEach-Object F) | Should -Be @($b | ForEach-Object F)
        $c = @(Get-WtStateSegmentsCached -Text 'Calisiyor/Otomatik   ' -DefaultFg 'DarkGray')
        [object]::ReferenceEquals($a[0], $c[0]) | Should -BeTrue
    }
    It 'a compact frame remembers its widest row while the rows are the same objects, and re-measures another row set' {
        $g = Get-WtGlyphSet -Unicode $false
        $items = @(0..7 | ForEach-Object { New-WtListItem -Kind 'Link' -Name "N$_" -Label ('Item ' + ('x' * $_)) -Data @{ Screen = 'X' } })
        $state = @{ CursorIndex = 0; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        $f1 = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State $state -Width 120 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText 'f'
        $key = $script:WtCompactNeedKey
        $key | Should -Not -BeNullOrEmpty
        $f2 = Get-WtFrameRows -Breadcrumb 'B' -Items $items -State $state -Width 120 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText 'f'
        $script:WtCompactNeedKey | Should -Be $key
        (($f1[13] | ForEach-Object T) -join '') | Should -Be (($f2[13] | ForEach-Object T) -join '')
        $wider = @($items) + @(New-WtListItem -Kind 'Link' -Name 'W' -Label ('W' * 60) -Data @{ Screen = 'X' })
        $f3 = Get-WtFrameRows -Breadcrumb 'B' -Items $wider -State $state -Width 120 -Height 30 -Glyphs $g -Layout 'Compact' -FooterText 'f'
        $script:WtCompactNeedKey | Should -Not -Be $key
        (($f3[13] | ForEach-Object T) -join '').Trim().Length | Should -BeGreaterThan (($f1[13] | ForEach-Object T) -join '').Trim().Length
    }
}

Describe 'Get-WtFrameWidth' {
    It 'stops one column short without VT: a row that fills the last cell leaves the console mid-wrap' {
        Get-WtFrameWidth -Width 158 -Vt $false | Should -Be 157
    }
    It 'takes the whole console with VT on, where every row is painted after an absolute cursor move' {
        Get-WtFrameWidth -Width 158 -Vt $true | Should -Be 158
    }
    It 'keeps the 20-column floor either way' {
        Get-WtFrameWidth -Width 4 -Vt $false | Should -Be 20
        Get-WtFrameWidth -Width 4 -Vt $true | Should -Be 20
    }
    It 'reads the session VT flag when it is not told which way to go' {
        $old = $script:WtVt
        try {
            $script:WtVt = $true
            Get-WtFrameWidth -Width 100 | Should -Be 100
            $script:WtVt = $false
            Get-WtFrameWidth -Width 100 | Should -Be 99
        }
        finally { $script:WtVt = $old }
    }
}
