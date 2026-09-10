#Requires -Modules Pester

<#
.SYNOPSIS
    Search in long lists and list-wide row numbers: the pure filter, the
    reducer's search box, the search row in the frame, row numbers that
    run on through the list instead of restarting per page, and the
    shell wiring. The winget store's search box is the model.
#>

BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
    $script:g = Get-WtGlyphSet -Unicode $false
    $script:rowText = { param($row) ($row | ForEach-Object T) -join '' }
    $script:catalog = {
        @(
            New-WtListItem -Kind 'Header' -Name 'H1' -Label '-- Oyun --'
            New-WtListItem -Kind 'Check' -Name 'XboxBar' -Label 'Xbox Game Bar' -StateLabel 'Uygulanmadi'
            New-WtListItem -Kind 'Check' -Name 'GameMode' -Label 'Oyun Modu' -StateLabel 'Uygulandi'
            New-WtListItem -Kind 'Spacer' -Name 'S1' -Label ''
            New-WtListItem -Kind 'Header' -Name 'H2' -Label '-- Gizlilik --'
            New-WtListItem -Kind 'Info' -Name 'I1' -Label 'bilgi satiri'
            New-WtListItem -Kind 'Check' -Name 'Telemetry' -Label 'Telemetri kapat' -StateLabel 'Uygulanmadi'
            New-WtListItem -Kind 'Check' -Name 'XboxSvc' -Label 'Xbox servisleri' -StateLabel 'Devre disi'
            New-WtListItem -Kind 'Spacer' -Name 'S2' -Label ''
            New-WtListItem -Kind 'Header' -Name 'H3' -Label '-- Isik --'
            New-WtListItem -Kind 'Check' -Name 'Light' -Label 'Gece Isik Modu' -StateLabel 'Uygulanmadi'
        )
    }
    $script:mkChecks = { param($n) 0..($n - 1) | ForEach-Object { New-WtListItem -Kind 'Check' -Name "N$_" -Label "Item $_" -StateLabel 'NotApplied' } }
    $script:mkState = { param([string]$Focus = 'List', [string]$Query = '', [int]$Cursor = 1)
        @{ CursorIndex = $Cursor; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]'); Cycle = @{}; Focus = $Focus; Query = $Query }
    }
    $script:mkQueue = { param([object[]]$Batches)
        $q = New-Object 'System.Collections.Generic.Queue[object]'
        foreach ($b in $Batches) { $q.Enqueue([string[]]@($b)) }
        ,$q
    }
}

Describe 'Select-WtListItems - the pure filter' {
    It 'an empty or blank query returns every row untouched' {
        $items = & $catalog
        @(Select-WtListItems -Items $items -Query '').Count | Should -Be $items.Count
        @(Select-WtListItems -Items $items -Query '   ').Count | Should -Be $items.Count
    }
    It 'matches the label case-insensitively and keeps only the headers of groups that still have a row' {
        @(Select-WtListItems -Items (& $catalog) -Query 'xbox' | ForEach-Object Name) | Should -Be @('H1', 'XboxBar', 'S1', 'H2', 'XboxSvc')
    }
    It 'every word of the query has to match (AND), in any order' {
        @(Select-WtListItems -Items (& $catalog) -Query 'servis xbox' | ForEach-Object Name) | Should -Be @('H2', 'XboxSvc')
    }
    It 'matches the state column too, so "devre" finds what is disabled' {
        @(Select-WtListItems -Items (& $catalog) -Query 'devre' | ForEach-Object Name) | Should -Be @('H2', 'XboxSvc')
    }
    It 'drops Info rows and never returns a spacer first or last' {
        $names = @(Select-WtListItems -Items (& $catalog) -Query 'a' | ForEach-Object Name)
        $names | Should -Not -Contain 'I1'
        $names[0] | Should -Not -Match '^S\d$'
        $names[-1] | Should -Not -Match '^S\d$'
    }
    It 'returns an empty array, not nothing, when no row matches' {
        @(Select-WtListItems -Items (& $catalog) -Query 'zzz').Count | Should -Be 0
    }
    It 'folds I/i ordinally so a tr-TR host does not lose "Isik" to "isik"' {
        @(Select-WtListItems -Items (& $catalog) -Query 'isik' | ForEach-Object Name) | Should -Be @('H3', 'Light')
        @(Select-WtListItems -Items (& $catalog) -Query 'ISIK' | ForEach-Object Name) | Should -Be @('H3', 'Light')
    }
}

Describe 'Update-WtListState - the search box' {
    BeforeAll { $script:items = & $catalog }
    It 'a typed "/" on a searchable list opens the box: focus Input, empty query, cursor at the top, no emit' {
        $r = Update-WtListState -State (& $mkState -Cursor 6) -Token 'Char:/' -Items $items -Searchable $true
        $r.Emit | Should -Be 'None'
        $r.State.Focus | Should -Be 'Input'
        $r.State.Query | Should -Be ''
        $r.State.CursorIndex | Should -Be 0
        $r.State.WindowStart | Should -Be 0
    }
    It 'a typed "/" on an ordinary list is still just a global character' {
        $r = Update-WtListState -State (& $mkState) -Token 'Char:/' -Items $items
        $r.Emit | Should -Be 'Global'
        $r.EmitChar | Should -Be '/'
    }
    It 'while the box has focus every printable key - letters, digits, space, even a and c - goes into the query' {
        $s = (& $mkState -Focus 'Input')
        foreach ($t in 'Char:X', 'Char:b', 'Space', 'Char:a', 'Digit:5', 'Char:c') {
            $r = Update-WtListState -State $s -Token $t -Items $items -Searchable $true -MultiSelect $true
            $r.Emit | Should -Be 'None' -Because $t
            $s = $r.State
        }
        $s.Query | Should -Be 'Xb a5c'
        $s.Focus | Should -Be 'Input'
        $s.Selection.Count | Should -Be 0
    }
    It 'Backspace drops the last character and does nothing on an empty box' {
        $r = Update-WtListState -State (& $mkState -Focus 'Input' -Query 'xb') -Token 'Backspace' -Items $items -Searchable $true
        $r.State.Query | Should -Be 'x'
        $r2 = Update-WtListState -State (& $mkState -Focus 'Input' -Query '') -Token 'Backspace' -Items $items -Searchable $true
        $r2.State.Query | Should -Be ''
        $r2.Emit | Should -Be 'None'
    }
    It 'Enter leaves the box and KEEPS the filter; the cursor starts over at the top of what is shown' {
        $r = Update-WtListState -State (& $mkState -Focus 'Input' -Query 'xbox' -Cursor 3) -Token 'Enter' -Items $items -Searchable $true
        $r.Emit | Should -Be 'None'
        $r.State.Focus | Should -Be 'List'
        $r.State.Query | Should -Be 'xbox'
        $r.State.CursorIndex | Should -Be 0
    }
    It 'Esc (and the shared Back token) in the box clears the filter and leaves the box' {
        foreach ($t in 'Esc', 'Back') {
            $r = Update-WtListState -State (& $mkState -Focus 'Input' -Query 'xbox') -Token $t -Items $items -Searchable $true
            $r.Emit | Should -Be 'None' -Because $t
            $r.State.Focus | Should -Be 'List'
            $r.State.Query | Should -Be ''
        }
    }
    It 'an arrow key in the box leaves it with the filter kept and moves at once' {
        $r = Update-WtListState -State (& $mkState -Focus 'Input' -Query 'x' -Cursor 1) -Token 'Down' -Items $items -Searchable $true
        $r.State.Focus | Should -Be 'List'
        $r.State.Query | Should -Be 'x'
        $r.State.CursorIndex | Should -Be 2
    }
    It 'Eof in the box still leaves the screen (exhausted input must never spin)' {
        (Update-WtListState -State (& $mkState -Focus 'Input' -Query 'x') -Token 'Eof' -Items $items -Searchable $true).Emit | Should -Be 'Back'
    }
    It 'with a filter active, Back on the rows clears the filter first; the second Back leaves' {
        $r = Update-WtListState -State (& $mkState -Query 'xbox') -Token 'Back' -Items $items -Searchable $true
        $r.Emit | Should -Be 'None'
        $r.State.Query | Should -Be ''
        (Update-WtListState -State $r.State -Token 'Back' -Items $items -Searchable $true).Emit | Should -Be 'Back'
    }
    It 'the box and the filter still answer on a page whose filtered list has nothing focusable' {
        $empty = @(Get-WtListSearchEmptyItem)
        $r = Update-WtListState -State (& $mkState -Query 'zzz' -Cursor -1) -Token 'Char:/' -Items $empty -Searchable $true
        $r.Emit | Should -Be 'None'
        $r.State.Focus | Should -Be 'Input'
        $r2 = Update-WtListState -State (& $mkState -Query 'zzz' -Cursor -1) -Token 'Back' -Items $empty -Searchable $true
        $r2.Emit | Should -Be 'None'
        $r2.State.Query | Should -Be ''
    }
    It 'a state without Focus/Query keys reads as an unfocused, unfiltered list and comes back with both keys' {
        $s = @{ CursorIndex = 1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        $r = Update-WtListState -State $s -Token 'Down' -Items $items
        $r.State.Focus | Should -Be 'List'
        $r.State.Query | Should -Be ''
        $r.State.CursorIndex | Should -Be 2
    }
    It 'Invoke-WtTokenBatch passes Searchable through, so "/xb" typed in one batch lands in the query' {
        $r = Invoke-WtTokenBatch -State (& $mkState) -Tokens @('Char:/', 'Char:x', 'Char:b') -Items $items -Searchable $true
        $r.State.Focus | Should -Be 'Input'
        $r.State.Query | Should -Be 'xb'
        $r.Emit | Should -Be 'None'
    }
    It 'Get-WtValidListCursor keeps a focusable cursor, else takes the first focusable row, else -1' {
        Get-WtValidListCursor -Items $items -CursorIndex 2 | Should -Be 2
        Get-WtValidListCursor -Items $items -CursorIndex 0 | Should -Be 1
        Get-WtValidListCursor -Items $items -CursorIndex 99 | Should -Be 1
        Get-WtValidListCursor -Items @(Get-WtListSearchEmptyItem) -CursorIndex 0 | Should -Be -1
    }
}

Describe 'Row numbers count through the whole list, not per page' {
    BeforeAll { $script:mkFrameState = { param([int]$Cursor, [int]$Window = 0) @{ CursorIndex = $Cursor; WindowStart = $Window; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') } } }
    It 'a scrolled page keeps counting: the last of 41 rows prints as 41., not as 11.' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkChecks 41) -State (& $mkFrameState 40) -Width 100 -Height 30 -Glyphs $g
        (& $rowText $frame[16]) | Should -Match '\|\s+31\. '
        (& $rowText $frame[26]) | Should -Match '\|\s*>\s*41\. '
    }
    It 'the number column is as wide as the LAST number of the list from the first page on, so 1. and 10. line up' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $mkChecks 41) -State (& $mkFrameState 0) -Width 100 -Height 30 -Glyphs $g
        $one = & $rowText $frame[16]
        $ten = & $rowText $frame[25]
        $one | Should -Match '\s1\. '
        $ten | Should -Match '\s10\. '
        $one.IndexOf('. ') | Should -Be $ten.IndexOf('. ')
    }
    It 'a typed digit picks the row printed with that number, wherever the page is scrolled' {
        $items = & $mkChecks 41
        $s = @{ CursorIndex = 35; WindowStart = 30; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        $r = Update-WtListState -State $s -Token 'Digit:2' -Items $items -ViewHeight 11 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 1
        $r.State.Selection.Contains('N1') | Should -BeTrue
        $r.State.WindowStart | Should -BeLessOrEqual 1
    }
    It 'line mode can name any row: Digit:12 marks the twelfth, an impossible number is ignored' {
        $items = & $mkChecks 41
        $r = Update-WtListState -State (& $mkFrameState 0) -Token 'Digit:12' -Items $items -ViewHeight 11 -MultiSelect $true
        $r.State.CursorIndex | Should -Be 11
        $r.State.Selection.Contains('N11') | Should -BeTrue
        $r2 = Update-WtListState -State (& $mkFrameState 0) -Token 'Digit:99999999999' -Items $items -ViewHeight 11 -MultiSelect $true
        $r2.State.CursorIndex | Should -Be 0
        $r2.Emit | Should -Be 'None'
    }
    It 'headers and spacers take no number: the first Check under a header is still 1.' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $catalog) -State (& $mkFrameState 1) -Width 100 -Height 30 -Glyphs $g
        (& $rowText $frame[16]) | Should -Not -Match '\d\. '
        (& $rowText $frame[17]) | Should -Match '\s1\. '
    }
}

Describe 'The search row in the frame' {
    BeforeAll { $script:st = { @{ CursorIndex = 1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') } } }
    It 'Get-WtFrameChromeHeight grows by two (the row and its separator) on a searchable screen' {
        Get-WtFrameChromeHeight -Width 120 -Searchable $true | Should -Be 21
        Get-WtFrameChromeHeight -Width 80 -Searchable $true | Should -Be 13
        Get-WtFrameChromeHeight -Width 120 | Should -Be 19
    }
    It 'sits under the path row: label, the query with a caret while focused, the count on the right' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $catalog) -State (& $st) -Width 100 -Height 30 -Glyphs $g -Search @{ Focus = 'Input'; Query = 'xb'; CountText = '2/6 satir' }
        $label = [regex]::Escape((Get-Translation 'ListSearchLabel'))
        (& $rowText $frame[16]) | Should -Match ('^\| ' + $label + ': xb_\s+2/6 satir \|$')
        (& $rowText $frame[17]) | Should -Match '^\+-+\+$'
        (& $rowText $frame[18]) | Should -Match 'Oyun'
        $frame.Count | Should -Be 30
    }
    It 'unfocused and empty it shows how to start, without a caret' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $catalog) -State (& $st) -Width 100 -Height 30 -Glyphs $g -Search @{ Focus = 'List'; Query = ''; CountText = '' }
        $row = & $rowText $frame[16]
        $row | Should -Match ([regex]::Escape((Get-Translation 'ListSearchPlaceholder')))
        $row | Should -Not -Match '_'
    }
    It 'a compact box makes room for the row too' {
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items (& $catalog) -State (& $st) -Width 120 -Height 40 -Glyphs $g -Layout 'Compact' -FooterText 'f' -Search @{ Focus = 'List'; Query = ''; CountText = '' }
        $row = (& $rowText $frame[16]).Trim()
        $row | Should -Match ([regex]::Escape((Get-Translation 'ListSearchPlaceholder')))
        $row | Should -Match '^\|.*\|$'
    }
    It 'the store search row composer takes a label and a placeholder but keeps its store defaults' {
        $segs = Get-WtStoreSearchRowSegments -State @{ Focus = 'List'; Query = '' } -Inner 40 -Label 'Ara' -Placeholder 'yazin'
        (($segs | ForEach-Object T) -join '') | Should -Match '^Ara: yazin\s+$'
        $segs2 = Get-WtStoreSearchRowSegments -State @{ Focus = 'List'; Query = '' } -Inner 40
        (($segs2 | ForEach-Object T) -join '') | Should -Match ('^' + [regex]::Escape((Get-Translation 'WsSearchLabel')) + ': \s+$')
    }
    It 'the shared key converter now passes "/" so a list can open its box' {
        ConvertTo-WtKeyToken -Key 'Oem2' -KeyChar '/' | Should -Be 'Char:/'
        ConvertTo-WtKeyToken -Key 'D7' -KeyChar '/' | Should -Be 'Char:/'
    }
}

Describe 'A searchable compact box keeps its size through focus and filter' {
    BeforeAll {
        $script:st2 = { param([string]$Focus = 'List', [string]$Query = '')
            @{ CursorIndex = 1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]'); Cycle = @{}; Focus = $Focus; Query = $Query }
        }
        $script:boxWidth = { param($frame) ((& $rowText $frame[13]).Trim()).Length }
        $script:boxHeight = { param($frame)
            $last = 13
            for ($i = 13; $i -lt $frame.Count; $i++) { if ((& $rowText $frame[$i]).Trim() -ne '') { $last = $i } }
            $last - 13 + 1
        }
        $script:guide = Get-WtSearchableFooter -Footer (Get-Translation 'NavFooter') -Hint (Get-Translation 'ListSearchKeyHint')
        $script:searchGuide = Get-Translation 'ListSearchFooter'
        $script:frameArgs = @{ Breadcrumb = 'B'; Width = 120; Height = 40; Glyphs = $script:g; Layout = 'Compact' }
    }
    It 'the guide switching to the search guide on "/" no longer narrows the box' {
        $full = & $catalog
        $before = Get-WtFrameRows @frameArgs -Items $full -SizeItems $full -State (& $st2 'List' '') -FooterText $guide -FooterSizeText $guide -Search @{ Focus = 'List'; Query = ''; CountText = '' }
        $after = Get-WtFrameRows @frameArgs -Items $full -SizeItems $full -State (& $st2 'Input' '') -FooterText $searchGuide -FooterSizeText $guide -Search @{ Focus = 'Input'; Query = ''; CountText = '' }
        (& $boxWidth $after) | Should -Be (& $boxWidth $before)
        (& $boxHeight $after) | Should -Be (& $boxHeight $before)
        $unsized = Get-WtFrameRows @frameArgs -Items $full -State (& $st2 'Input' '') -FooterText $searchGuide -Search @{ Focus = 'Input'; Query = ''; CountText = '' }
        (& $boxWidth $unsized) | Should -BeLessThan (& $boxWidth $before)
    }
    It 'a filtered view sized by the full list keeps both the width and the height, the empty-result row included' {
        $full = & $catalog
        $few = @(Select-WtListItems -Items $full -Query 'xbox')
        $few.Count | Should -BeLessThan $full.Count
        $whole = Get-WtFrameRows @frameArgs -Items $full -SizeItems $full -State (& $st2) -FooterText $guide -FooterSizeText $guide -Search @{ Focus = 'List'; Query = ''; CountText = '' }
        $filtered = Get-WtFrameRows @frameArgs -Items $few -SizeItems $full -State (& $st2) -FooterText $guide -FooterSizeText $guide -Search @{ Focus = 'List'; Query = 'xbox'; CountText = '2/6 satir - Esc: temizle' }
        (& $boxWidth $filtered) | Should -Be (& $boxWidth $whole)
        (& $boxHeight $filtered) | Should -Be (& $boxHeight $whole)
        $empty = Get-WtFrameRows @frameArgs -Items @(Get-WtListSearchEmptyItem) -SizeItems $full -State (& $st2 'List' 'zzz' ) -FooterText $guide -FooterSizeText $guide -Search @{ Focus = 'List'; Query = 'zzz'; CountText = '0/6 satir - Esc: temizle' }
        (& $boxWidth $empty) | Should -Be (& $boxWidth $whole)
        (& $boxHeight $empty) | Should -Be (& $boxHeight $whole)
        (& $rowText $filtered[18]) | Should -Match 'Oyun'
    }
    It 'a query longer than the placeholder does not widen the box either' {
        $full = & $catalog
        $short = Get-WtFrameRows @frameArgs -Items $full -SizeItems $full -State (& $st2 'Input' 'x') -FooterText $searchGuide -FooterSizeText $guide -Search @{ Focus = 'Input'; Query = 'x'; CountText = '' }
        $long = Get-WtFrameRows @frameArgs -Items $full -SizeItems $full -State (& $st2 'Input' ('x' * 70)) -FooterText $searchGuide -FooterSizeText $guide -Search @{ Focus = 'Input'; Query = ('x' * 70); CountText = '' }
        (& $boxWidth $long) | Should -Be (& $boxWidth $short)
        $long.Count | Should -Be 40
    }
    It 'the shell paints every frame of a search session - "/", letters, Enter, Esc - in one and the same box' {
        $script:widths = New-Object System.Collections.Generic.List[int]
        $script:heights = New-Object System.Collections.Generic.List[int]
        Mock Get-WtConsoleSize { @{ Width = 120; Height = 40 } }
        Mock Write-WtFrame { $script:widths.Add((& $script:boxWidth $FrameLines)); $script:heights.Add((& $script:boxHeight $FrameLines)) }
        $script:batches = & $mkQueue @(@('Char:/'), @('Char:x', 'Char:b', 'Char:o', 'Char:x'), @('Enter'), @('Char:/'), @('Char:z', 'Char:z'), @('Back'), @('Back'), @('Back'))
        Mock Read-WtInputBatch { [string[]]$script:batches.Dequeue() }
        $r = Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -Searchable $true -Layout 'Compact' -FooterText (Get-Translation 'NavFooter')
        $r.Emit | Should -Be 'Back'
        $script:widths.Count | Should -BeGreaterThan 5
        @($script:widths | Sort-Object -Unique).Count | Should -Be 1 -Because ('widths seen: ' + ($script:widths -join ','))
        @($script:heights | Sort-Object -Unique).Count | Should -Be 1 -Because ('heights seen: ' + ($script:heights -join ','))
    }
}

Describe 'Invoke-WtListScreen -Searchable (the shell)' {
    BeforeEach {
        Mock Write-WtFrame { }
        Mock Get-WtConsoleSize { @{ Width = 120; Height = 40 } }
    }
    It 'typing "/xbox" Enter narrows the list, Space marks the first hit, Enter returns it with its index in the FULL list' {
        $script:batches = & $mkQueue @(@('Char:/'), @('Char:x', 'Char:b', 'Char:o', 'Char:x'), @('Enter'), @('Space'), @('Enter'))
        Mock Read-WtInputBatch { [string[]]$script:batches.Dequeue() }
        $r = Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -MultiSelect $true -Searchable $true
        $r.Emit | Should -Be 'Activate'
        $r.Item.Name | Should -Be 'XboxBar'
        $r.CursorIndex | Should -Be 1
        $r.Selection.Contains('XboxBar') | Should -BeTrue
    }
    It 'with a filter on, the first Back only clears it; the screen leaves on the second' {
        $script:batches = & $mkQueue @(@('Char:/'), @('Char:z', 'Char:z'), @('Enter'), @('Back'), @('Back'))
        Mock Read-WtInputBatch { [string[]]$script:batches.Dequeue() }
        $r = Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -MultiSelect $true -Searchable $true
        $r.Emit | Should -Be 'Back'
        $script:batches.Count | Should -Be 0
    }
    It 'a query nobody matches shows one Info row; Esc brings the rows back and Enter opens the first of them' {
        $script:batches = & $mkQueue @(@('Char:/'), @('Char:z'), @('Enter'), @('Back'), @('Enter'))
        Mock Read-WtInputBatch { [string[]]$script:batches.Dequeue() }
        $r = Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -MultiSelect $true -Searchable $true
        $r.Emit | Should -Be 'Activate'
        $r.Item.Name | Should -Be 'XboxBar'
        $r.CursorIndex | Should -Be 1
    }
    It 'a plain list draws no row, and "/" reaches the caller as a global key as before' {
        Mock Read-WtInputBatch { [string[]]@('Char:/') }
        $r = Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -MultiSelect $true
        $r.Emit | Should -Be 'Global'
        $r.Char | Should -Be '/'
    }
    It 'the box asks for the store key vocabulary (case kept, Backspace, Esc) only while it has focus' {
        $script:seen = New-Object System.Collections.Generic.List[object]
        $script:batches = & $mkQueue @(@('Char:/'), @('Char:X'), @('Enter'), @('Back'), @('Back'))
        Mock Read-WtInputBatch { $script:seen.Add($Converter); [string[]]$script:batches.Dequeue() }
        Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -Searchable $true | Out-Null
        $script:seen.Count | Should -Be 5
        $null -eq $script:seen[0] | Should -BeTrue
        $script:seen[1] | Should -Not -BeNullOrEmpty
        (& $script:seen[1] 'Backspace' '') | Should -Be 'Backspace'
        (& $script:seen[1] 'Oem2' 'X') | Should -Be 'Char:X'
        $null -eq $script:seen[3] | Should -BeTrue
    }
}

Describe 'The search key in the navigation guide' {
    It 'Get-WtSearchableFooter puts the key item in front of the Esc item' {
        Get-WtSearchableFooter -Footer 'Up: move - A: all - Esc: back - Q: quit' -Hint '/: search' | Should -Be 'Up: move - A: all - /: search - Esc: back - Q: quit'
    }
    It 'leaves a footer without an Esc item alone - a hint sentence is not a guide' {
        Get-WtSearchableFooter -Footer 'Mark a row first' -Hint '/: search' | Should -Be 'Mark a row first'
        Get-WtSearchableFooter -Footer '' -Hint '/: search' | Should -Be ''
    }
    It 'every guide a searchable screen uses carries an Esc item to hang the key on, in both languages' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'ApplyFooter', 'ServicesFooter', 'NavFooter') {
                $script:Translations[$lang][$key] | Should -Match ' - Esc:' -Because "$lang/$key"
            }
        }
    }
    It 'the shell shows the key on the guide while the rows have the keyboard, and the box keys while the box has it' {
        Mock Get-WtConsoleSize { @{ Width = 120; Height = 40 } }
        $script:footers = New-Object System.Collections.Generic.List[string]
        Mock Write-WtFrame { $script:footers.Add((($FrameLines[-2] | ForEach-Object T) -join '')) }
        $script:batches = & $mkQueue @(@('Char:/'), @('Enter'), @('Back'))
        Mock Read-WtInputBatch { [string[]]$script:batches.Dequeue() }
        Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -MultiSelect $true -FooterText (Get-Translation 'ApplyFooter') -Searchable $true | Out-Null
        $hint = [regex]::Escape((Get-Translation 'ListSearchKeyHint'))
        $script:footers.Count | Should -Be 3
        $script:footers[0] | Should -Match ($hint + ' - Esc:')
        $script:footers[1] | Should -Match ([regex]::Escape((Get-Translation 'ListSearchFooter')))
        $script:footers[1] | Should -Not -Match $hint
        $script:footers[2] | Should -Match $hint
    }
    It 'a screen without the box keeps its guide as it is' {
        Mock Get-WtConsoleSize { @{ Width = 120; Height = 40 } }
        $script:footers = New-Object System.Collections.Generic.List[string]
        Mock Write-WtFrame { $script:footers.Add((($FrameLines[-2] | ForEach-Object T) -join '')) }
        Mock Read-WtInputBatch { [string[]]@('Back') }
        Invoke-WtListScreen -Breadcrumb 'B' -Items (& $catalog) -MultiSelect $true -FooterText (Get-Translation 'ApplyFooter') | Out-Null
        $script:footers[0] | Should -Not -Match ([regex]::Escape((Get-Translation 'ListSearchKeyHint')))
        $script:footers[0] | Should -Match ' - Esc:'
    }
}

Describe 'Which screens search' {
    It 'every apply screen and the two tool lists turn the box on; menus do not' {
        (Get-Command Invoke-WtApplyScreen).Definition | Should -Match 'Invoke-WtListScreen .*-Searchable \$true'
        (Get-Command Invoke-WtActionToolsScreen).Definition | Should -Match '-Searchable \$true'
        (Get-Command Invoke-WtInfoToolsScreen).Definition | Should -Match '-Searchable \$true'
        (Get-Command Invoke-WtNavScreen).Definition | Should -Match 'Invoke-WtListScreen .*-Searchable \$Searchable'
        (Get-Command Invoke-WtMainScreen).Definition | Should -Not -Match 'Searchable'
        (Get-Command Invoke-WtBasicToolsScreen).Definition | Should -Not -Match 'Searchable'
    }
    It 'the strings exist in both languages' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'ListSearchLabel', 'ListSearchPlaceholder', 'ListSearchCount', 'ListSearchClearHint', 'ListSearchFooter', 'ListSearchEmpty', 'ListSearchKeyHint') {
                $script:Translations[$lang][$key] | Should -Not -BeNullOrEmpty -Because "$lang/$key"
            }
            $script:Translations[$lang]['ListSearchCount'] | Should -Match '\{0\}.*\{1\}'
        }
    }
}
