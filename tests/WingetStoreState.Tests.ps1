#Requires -Modules Pester

<#
.SYNOPSIS
    Winget store screen: the grid key vocabulary, the store reducer and the
    search-box input state. All pure - no console, no winget. A Turkish
    letter such as dotless i appears as its [char] escape (e.g.
    [char]0x0131) rather than a literal, so this ASCII-only file stays
    ASCII.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'ConvertTo-WtGridKeyToken' {
    <#
    .SYNOPSIS
        Maps a raw key press to the grid's own token vocabulary; unlike
        the shared converter, every printable character reaches the
        search box (needed for spaces, dots, dashes) and Turkish letters
        keep their typed case (the reducer lowercases only for
        shortcuts) - the dotless i must survive here, not get folded by
        a culture-aware compare.
    #>
    It 'separates the three keys the shared converter collapses into Back' {
        ConvertTo-WtGridKeyToken -Key 'LeftArrow' -KeyChar '' | Should -Be 'Left'
        ConvertTo-WtGridKeyToken -Key 'Escape'    -KeyChar '' | Should -Be 'Esc'
        ConvertTo-WtGridKeyToken -Key 'Backspace' -KeyChar '' | Should -Be 'Backspace'
    }

    It 'maps the keys the shared converter drops entirely' {
        ConvertTo-WtGridKeyToken -Key 'RightArrow' -KeyChar '' | Should -Be 'Right'
        ConvertTo-WtGridKeyToken -Key 'Tab'        -KeyChar "`t" | Should -Be 'Tab'
        ConvertTo-WtGridKeyToken -Key 'Delete'     -KeyChar '' | Should -Be 'Delete'
    }

    It 'carries every printable character, not just letters and digits' {
        ConvertTo-WtGridKeyToken -Key 'OemPeriod' -KeyChar '.' | Should -Be 'Char:.'
        ConvertTo-WtGridKeyToken -Key 'OemMinus'  -KeyChar '-' | Should -Be 'Char:-'
        ConvertTo-WtGridKeyToken -Key 'Oem2'      -KeyChar '/' | Should -Be 'Char:/'
    }

    It 'carries Turkish letters and preserves their case' {
        ConvertTo-WtGridKeyToken -Key 'Oem1' -KeyChar ([char]0x015F) | Should -Be ('Char:' + [char]0x015F)
        ConvertTo-WtGridKeyToken -Key 'I'    -KeyChar 'I' | Should -Be 'Char:I'
        ConvertTo-WtGridKeyToken -Key 'I'    -KeyChar ([char]0x0131) | Should -Be ('Char:' + [char]0x0131)
    }

    It 'returns None for control characters that are not mapped keys' {
        ConvertTo-WtGridKeyToken -Key 'F5' -KeyChar '' | Should -Be 'None'
    }
}

Describe 'Test-WtNavToken' {
    It 'treats horizontal movement as navigation so auto-repeat is drained' {
        Test-WtNavToken -Token 'Left'  | Should -BeTrue
        Test-WtNavToken -Token 'Right' | Should -BeTrue
    }

    It 'still rejects the tokens the list screen must never coalesce' {
        foreach ($t in 'Space', 'Enter', 'Back', 'Char:a', 'None') {
            Test-WtNavToken -Token $t | Should -BeFalse
        }
    }
}

Describe 'New-WtStoreState' {
    It 'starts with an empty query by default and with -Query pre-filled, so the assistant can open the store on one package' {
        (New-WtStoreState).Query | Should -Be ''
        $s = New-WtStoreState -Query 'Cloudflare WARP'
        $s.Query | Should -Be 'Cloudflare WARP'
        $s.Mode | Should -Be 'Catalog'
        $s.Tab | Should -Be 'Store'
    }
}

Describe 'Update-WtStoreState' {
    <#
    .SYNOPSIS
        The reducer for the winget store screen: tab switching, marking,
        the search box, and cursor movement over the flowed row model.
        Rows here are HASHTABLES, so - unlike the array-of-arrays column
        model this replaced - no unary comma is needed to stop @() from
        unrolling a level.
    #>
    BeforeAll {
        $script:Rows = @(
            @{ Kind = 'Cells'; Label = ''; Category = 'X'; AppCount = 3
                Cells = @(1..3 | ForEach-Object { @{ Kind = 'App'; Id = "A$_"; Name = "A$_" } })
            }
            @{ Kind = 'Cells'; Label = ''; Category = 'Y'; AppCount = 1
                Cells = @(@{ Kind = 'App'; Id = 'B1'; Name = 'B1' })
            }
        )
        function New-State { New-WtStoreState }
    }

    It 'cycles the TWO tabs with Tab and never leaves the set' {
        $s = New-State
        $s.Tab | Should -Be 'Store'
        $s = (Update-WtStoreState -State $s -Token 'Tab' -Rows $Rows).State
        $s.Tab | Should -Be 'Installed'
        $s = (Update-WtStoreState -State $s -Token 'Tab' -Rows $Rows).State
        $s.Tab | Should -Be 'Store'
    }

    It 'never lands on a tab outside Store / Installed, however long Tab is held' {
        $s = New-State
        for ($i = 0; $i -lt 7; $i++) {
            $s = (Update-WtStoreState -State $s -Token 'Tab' -Rows $Rows).State
            @('Store', 'Installed') | Should -Contain $s.Tab -Because "press $i"
        }
    }

    It 'marks and unmarks the cell under the cursor' {
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Space' -Rows $Rows).State
        $s.Marks.Contains('A1') | Should -BeTrue
        $s = (Update-WtStoreState -State $s -Token 'Space' -Rows $Rows).State
        $s.Marks.Contains('A1') | Should -BeFalse
    }

    It 'refuses to mark an already installed package and leaves no mark behind' {
        $s = New-State
        $r = Update-WtStoreState -State $s -Token 'Space' -Rows $Rows -InstalledIds @('A1')
        $r.Emit | Should -Be 'Refused'
        $r.State.Marks.Contains('A1') | Should -BeFalse
    }

    It 'emits Install on Enter and carries the marks' {
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Space' -Rows $Rows).State
        (Update-WtStoreState -State $s -Token 'Enter' -Rows $Rows).Emit | Should -Be 'Install'
    }

    It 'refuses Enter''s auto-mark on an already installed package' {
        $s = New-State
        $r = Update-WtStoreState -State $s -Token 'Enter' -Rows $Rows -InstalledIds @('A1')
        $r.Emit | Should -Be 'Refused'
        $r.State.Marks.Count | Should -Be 0
    }

    It 'does not mutate the caller''s Marks set' {
        $orig = New-State
        $null = Update-WtStoreState -State $orig -Token 'Space' -Rows $Rows
        $orig.Marks.Contains('A1') | Should -BeFalse
    }

    It 'opens the search box on slash and keeps the current tab' {
        $s = New-State
        $r = Update-WtStoreState -State $s -Token 'Char:/' -Rows $Rows
        $r.State.Focus | Should -Be 'Input'
        $r.State.Tab   | Should -Be 'Store'

        $s2 = New-State
        $s2.Mode = 'Results'
        $r2 = Update-WtStoreState -State $s2 -Token 'Char:/' -Rows $Rows
        $r2.State.Focus | Should -Be 'Input'
        $r2.State.Tab   | Should -Be 'Store'
        $r2.State.Mode  | Should -Be 'Catalog'
    }

    It 'opens the box on the installed tab too, typing into ITS query and leaving the store query alone' {
        $s = New-State
        $s.Tab = 'Installed'
        $s.Query = 'vlc'
        $r = Update-WtStoreState -State $s -Token 'Char:/' -Rows $Rows
        $r.State.Focus | Should -Be 'Input'
        $r.State.Tab   | Should -Be 'Installed'
        $r.State.InstalledQuery | Should -Be ''
        foreach ($t in 'Char:G', 'Char:i', 'Space', 'Char:1', 'Backspace') { $r = Update-WtStoreState -State $r.State -Token $t -Rows $Rows }
        $r.State.InstalledQuery | Should -Be 'Gi '
        $r.State.Query | Should -Be 'vlc'
        $r.State.Tab   | Should -Be 'Installed'
        $r.State.Focus | Should -Be 'Input'
    }

    It 'Enter on the installed box keeps the filter, hands the keyboard back to the rows and never asks winget' {
        $s = New-State
        $s.Tab = 'Installed'; $s.Focus = 'Input'; $s.InstalledQuery = 'git'; $s.Cursor = @{ Row = 3; Col = 0 }
        $r = Update-WtStoreState -State $s -Token 'Enter' -Rows $Rows
        $r.Emit | Should -Be 'None'
        $r.State.Focus | Should -Be 'Grid'
        $r.State.InstalledQuery | Should -Be 'git'
        $r.State.Mode | Should -Be 'Catalog'
        $r.State.Cursor.Row | Should -Be 0
    }

    It 'Esc in the installed box clears its query; on the rows it clears an active filter first and leaves only when there is none' {
        $s = New-State
        $s.Tab = 'Installed'; $s.Focus = 'Input'; $s.InstalledQuery = 'git'
        $r = Update-WtStoreState -State $s -Token 'Esc' -Rows $Rows
        $r.Emit | Should -Be 'None'
        $r.State.Focus | Should -Be 'Grid'
        $r.State.InstalledQuery | Should -Be ''
        $s2 = New-State
        $s2.Tab = 'Installed'; $s2.InstalledQuery = 'git'
        $r2 = Update-WtStoreState -State $s2 -Token 'Esc' -Rows $Rows
        $r2.Emit | Should -Be 'None'
        $r2.State.InstalledQuery | Should -Be ''
        $r3 = Update-WtStoreState -State $r2.State -Token 'Esc' -Rows $Rows
        $r3.Emit | Should -Be 'Back'
    }

    It 'a fresh state carries an empty installed query, and a tab switch keeps both queries' {
        (New-WtStoreState).InstalledQuery | Should -Be ''
        $s = New-State
        $s.Tab = 'Installed'; $s.InstalledQuery = 'git'; $s.Query = 'vlc'
        $r = Update-WtStoreState -State $s -Token 'Tab' -Rows $Rows
        $r.State.Tab | Should -Be 'Store'
        $r.State.InstalledQuery | Should -Be 'git'
        $r.State.Query | Should -Be 'vlc'
        $r = Update-WtStoreState -State $r.State -Token 'Char:/' -Rows $Rows
        $r = Update-WtStoreState -State $r.State -Token 'Char:x' -Rows $Rows
        $r = Update-WtStoreState -State $r.State -Token 'Enter' -Rows $Rows
        $r.Emit | Should -Be 'Search'
        $r.State.InstalledQuery | Should -Be 'git'
    }

    It 'types every printable character into the box, shortcuts included' {
        $dotlessI = [char]0x0131
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Char:/' -Rows $Rows).State
        foreach ($t in 'Char:q', 'Char:u', 'Char:a', 'Space', 'Char:1', ('Char:' + $dotlessI), 'Char:?') {
            $s = (Update-WtStoreState -State $s -Token $t -Rows $Rows).State
        }
        $s.Query | Should -Be ('qua 1' + $dotlessI + '?')
        $s.Focus | Should -Be 'Input'
        $s.Tab   | Should -Be 'Store'
    }

    It 'deletes with Backspace and abandons the box with Esc' {
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Char:/' -Rows $Rows).State
        $s = (Update-WtStoreState -State $s -Token 'Char:a' -Rows $Rows).State
        $s = (Update-WtStoreState -State $s -Token 'Char:b' -Rows $Rows).State
        $s = (Update-WtStoreState -State $s -Token 'Backspace' -Rows $Rows).State
        $s.Query | Should -Be 'a'
        $s = (Update-WtStoreState -State $s -Token 'Esc' -Rows $Rows).State
        $s.Query | Should -Be ''
        $s.Focus | Should -Be 'Grid'
    }

    It 'emits Search on Enter in the box, returns focus to the grid and switches to Results' {
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Char:/' -Rows $Rows).State
        $s = (Update-WtStoreState -State $s -Token 'Char:v' -Rows $Rows).State
        $r = Update-WtStoreState -State $s -Token 'Enter' -Rows $Rows
        $r.Emit        | Should -Be 'Search'
        $r.State.Focus | Should -Be 'Grid'
        $r.State.Query | Should -Be 'v'
        $r.State.Mode  | Should -Be 'Results'
        $r.State.Tab   | Should -Be 'Store' -Because 'the results land on the store page, not on a tab of their own'
    }

    It 'asks winget nothing on an empty box and stays on the catalog' {
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Char:/' -Rows $Rows).State
        $r = Update-WtStoreState -State $s -Token 'Enter' -Rows $Rows
        $r.Emit       | Should -Be 'None'
        $r.State.Mode | Should -Be 'Catalog'

        $blank = New-State
        $blank.Focus = 'Input'
        $blank.Query = '   '
        $r2 = Update-WtStoreState -State $blank -Token 'Enter' -Rows $Rows
        $r2.Emit       | Should -Be 'None'
        $r2.State.Mode | Should -Be 'Catalog'
    }

    It 'only offers upgrade and uninstall on the installed tab' {
        $s = New-State
        (Update-WtStoreState -State $s -Token 'Char:u' -Rows $Rows).Emit | Should -Be 'None'
        $s = (Update-WtStoreState -State $s -Token 'Space' -Rows $Rows).State
        $s.Tab = 'Installed'
        (Update-WtStoreState -State $s -Token 'Char:u' -Rows $Rows).Emit | Should -Be 'Upgrade'
        (Update-WtStoreState -State $s -Token 'Delete' -Rows $Rows).Emit | Should -Be 'Uninstall'
    }

    It 'marks all and clears all' {
        $s = New-State
        $s = (Update-WtStoreState -State $s -Token 'Char:a' -Rows $Rows).State
        $s.Marks.Count | Should -Be 4
        $s = (Update-WtStoreState -State $s -Token 'Char:n' -Rows $Rows).State
        $s.Marks.Count | Should -Be 0
    }

    It 'leaves on q' {
        (Update-WtStoreState -State (New-State) -Token 'Char:q' -Rows $Rows).Emit | Should -Be 'Back'
    }

    It 'refreshes on r' {
        (Update-WtStoreState -State (New-State) -Token 'Char:r' -Rows $Rows).Emit | Should -Be 'Refresh'
    }
}

Describe 'Update-WtStoreState tab switching clears marks' {
    <#
    .SYNOPSIS
        Marks are winget ids with no tab of their own. Carried across a
        tab switch, apps marked to INSTALL on the store tab were still
        marked after switching to Installed, where Del then uninstalled
        them from a tab showing no [x] anywhere.
    #>
    BeforeAll {
        $script:TabRows = @(
            @{ Kind = 'Cells'; Cells = @(1..3 | ForEach-Object { @{ Kind = 'App'; Id = "A$_"; Name = "A$_" } }) }
            @{ Kind = 'Cells'; Cells = @(@{ Kind = 'App'; Id = 'B1'; Name = 'B1' }) }
        )
    }

    It 'drops every mark when Tab moves to another tab' {
        $s = New-WtStoreState
        foreach ($id in 'A1', 'A2', 'B1') { $null = $s.Marks.Add($id) }
        $r = Update-WtStoreState -State $s -Token 'Tab' -Rows $TabRows
        $r.State.Tab | Should -Be 'Installed'
        $r.State.Marks.Count | Should -Be 0
    }

    It 'drops every mark on each digit shortcut too' {
        foreach ($pair in @(@('Char:1', 'Store'), @('Char:2', 'Installed'))) {
            $s = New-WtStoreState
            $null = $s.Marks.Add('A1')
            $null = $s.Marks.Add('A2')
            $r = Update-WtStoreState -State $s -Token $pair[0] -Rows $TabRows
            $r.State.Tab | Should -Be $pair[1] -Because "token $($pair[0])"
            $r.State.Marks.Count | Should -Be 0 -Because "token $($pair[0]) must not carry marks across"
        }
    }

    It 'has no third digit left to press - 3 switches nothing' {
        $s = New-WtStoreState
        $null = $s.Marks.Add('A1')
        foreach ($token in 'Char:3', 'Digit:3') {
            $r = Update-WtStoreState -State $s -Token $token -Rows $TabRows
            $r.State.Tab | Should -Be 'Store' -Because "token $token"
            $r.Emit | Should -Be 'None' -Because "token $token"
            $r.State.Marks.Count | Should -Be 1 -Because "token $token changed nothing, so it cleared nothing"
        }
    }

    It 'sends the store page back to the catalog on a tab switch' {
        $s = New-WtStoreState
        $s.Mode = 'Results'
        $s = (Update-WtStoreState -State $s -Token 'Tab' -Rows $TabRows).State
        $s.Tab | Should -Be 'Installed'
        $s = (Update-WtStoreState -State $s -Token 'Tab' -Rows $TabRows).State
        $s.Tab  | Should -Be 'Store'
        $s.Mode | Should -Be 'Catalog'
    }

    It 'leaves an install mark unable to reach the installed tab at all' {
        $s = New-WtStoreState
        foreach ($id in 'Google.Chrome', 'Mozilla.Firefox') { $null = $s.Marks.Add($id) }
        $onInstalled = (Update-WtStoreState -State $s -Token 'Char:2' -Rows $TabRows).State
        $onInstalled.Tab | Should -Be 'Installed'
        $r = Update-WtStoreState -State $onInstalled -Token 'Delete' -Rows $TabRows
        $r.Emit | Should -Be 'None'
    }

    It 'still resets the cursor and the scroll offset on a tab change' {
        $s = New-WtStoreState
        $s.Cursor = @{ Col = 1; Row = 0 }
        $s.WindowStart = 7
        $r = Update-WtStoreState -State $s -Token 'Tab' -Rows $TabRows
        $r.State.Cursor.Col | Should -Be 0
        $r.State.Cursor.Row | Should -Be 0
        $r.State.WindowStart | Should -Be 0
    }
}

Describe 'Update-WtStoreState line-mode vocabulary' {
    <#
    .SYNOPSIS
        Read-WtInputBatch returns 'Eof' when redirected stdin is
        exhausted. Mapped to None, the screen's while($true) never ended
        and Read-Host returned immediately - an infinite repaint loop, not
        a readable hang - so Eof maps to Back here, matching
        Update-WtListState. ConvertTo-WtLineToken accepts any run of
        digits, so an oversized one (a typo) must be ignored rather than
        thrown on by a bare [int] cast.
    #>
    BeforeAll {
        $script:LineRows = @(
            @{ Kind = 'Cells'; Cells = @(1..3 | ForEach-Object { @{ Kind = 'App'; Id = "A$_"; Name = "A$_" } }) }
        )
    }

    It 'leaves the screen on Eof instead of spinning forever' {
        (Update-WtStoreState -State (New-WtStoreState) -Token 'Eof' -Rows $LineRows).Emit | Should -Be 'Back'
    }

    It 'leaves the screen on Eof even while the search box has focus' {
        $s = New-WtStoreState
        $s.Focus = 'Input'
        (Update-WtStoreState -State $s -Token 'Eof' -Rows $LineRows).Emit | Should -Be 'Back'
    }

    It 'accepts the typed b of line mode, which arrives as Back and not as Esc' {
        (Update-WtStoreState -State (New-WtStoreState) -Token 'Back' -Rows $LineRows).Emit | Should -Be 'Back'
    }

    It 'switches tabs on the Digit tokens line mode produces for 1 and 2' {
        foreach ($pair in @(@('Digit:1', 'Store'), @('Digit:2', 'Installed'))) {
            $r = Update-WtStoreState -State (New-WtStoreState) -Token $pair[0] -Rows $LineRows
            $r.State.Tab | Should -Be $pair[1] -Because "token $($pair[0])"
        }
    }

    It 'ignores a digit outside the tab range rather than throwing' {
        $r = Update-WtStoreState -State (New-WtStoreState) -Token 'Digit:9' -Rows $LineRows
        $r.Emit | Should -Be 'None'
        $r.State.Tab | Should -Be 'Store'
        $big = Update-WtStoreState -State (New-WtStoreState) -Token 'Digit:99999999999' -Rows $LineRows
        $big.Emit | Should -Be 'None'
    }
}

Describe 'Update-WtStoreState query changes' {
    BeforeAll {
        $script:QueryRows = @(
            @{ Kind = 'Cells'; Cells = @(1..4 | ForEach-Object { @{ Kind = 'App'; Id = "A$_"; Name = "A$_" } }) }
            @{ Kind = 'Cells'; Cells = @(@{ Kind = 'App'; Id = 'B1'; Name = 'B1' }) }
        )
    }

    It 'sends the cursor home when a query is applied on the STORE tab, not only on Search' {
        $s = New-WtStoreState
        $s.Focus = 'Input'
        $s.Query = 'vlc'
        $s.Cursor = @{ Col = 0; Row = 3 }
        $s.WindowStart = 3
        $r = Update-WtStoreState -State $s -Token 'Enter' -Rows $QueryRows
        $r.Emit | Should -Be 'Search'
        $r.State.Tab | Should -Be 'Store'
        $r.State.Mode | Should -Be 'Results'
        $r.State.Cursor.Col | Should -Be 0
        $r.State.Cursor.Row | Should -Be 0
        $r.State.WindowStart | Should -Be 0
    }

    It 'sends the cursor home when Esc clears the query and widens the grid again' {
        $s = New-WtStoreState
        $s.Focus = 'Input'
        $s.Query = 'vlc'
        $s.Cursor = @{ Col = 1; Row = 0 }
        $s.WindowStart = 2
        $r = Update-WtStoreState -State $s -Token 'Esc' -Rows $QueryRows
        $r.State.Query | Should -Be ''
        $r.State.Mode | Should -Be 'Catalog'
        $r.State.Cursor.Col | Should -Be 0
        $r.State.Cursor.Row | Should -Be 0
        $r.State.WindowStart | Should -Be 0
    }
}

Describe 'Update-WtStoreState two-stage search' {
    <#
    .SYNOPSIS
        The catalog is a local filter (stage one); Enter with a non-blank
        query promotes it to a winget search (stage two, Results mode).
        A single-hit result used to break: cursor helpers read their row
        list through "$list = if (...) { @() } else { @($Rows) }", whose
        statement-block pipeline unrolled a one-element list back into
        the bare row hashtable, so $list[0] looked up key 0 and got
        $null - Space or Enter on that one hit did nothing.
    #>
    BeforeAll {
        $script:StageRows = @(
            @{ Kind = 'Cells'; Cells = @(1..4 | ForEach-Object { @{ Kind = 'App'; Id = "A$_"; Name = "A$_" } }) }
        )
    }

    It 'starts on the catalog' {
        (New-WtStoreState).Mode | Should -Be 'Catalog'
    }

    It 'keeps typing on the catalog - stage one is the local filter, not a winget call' {
        $s = New-WtStoreState
        $s = (Update-WtStoreState -State $s -Token 'Char:/' -Rows $StageRows).State
        foreach ($t in 'Char:v', 'Char:l', 'Char:c') {
            $r = Update-WtStoreState -State $s -Token $t -Rows $StageRows
            $r.Emit | Should -Be 'None' -Because "typing $t must not reach winget"
            $s = $r.State
            $s.Mode | Should -Be 'Catalog'
        }
        $s.Query | Should -Be 'vlc'
    }

    It 'returns from Results to the catalog on Esc, and clears the query with it' {
        $s = New-WtStoreState
        $s.Mode = 'Results'
        $s.Query = 'vlc'
        $s.Cursor = @{ Row = 0; Col = 0 }
        $null = $s.Marks.Add('A1')
        $r = Update-WtStoreState -State $s -Token 'Esc' -Rows $StageRows
        $r.Emit | Should -Be 'None' -Because 'Esc off the results page must not leave the screen'
        $r.State.Mode | Should -Be 'Catalog'
        $r.State.Query | Should -Be ''
        $r.State.Cursor.Row | Should -Be 0
        $r.State.WindowStart | Should -Be 0
        $r.State.Marks.Count | Should -Be 0 -Because 'the marks belonged to rows that are gone'
    }

    It 'still leaves the screen on Esc from the catalog' {
        (Update-WtStoreState -State (New-WtStoreState) -Token 'Esc' -Rows $StageRows).Emit | Should -Be 'Back'
        $inst = New-WtStoreState
        $inst.Tab = 'Installed'
        (Update-WtStoreState -State $inst -Token 'Esc' -Rows $StageRows).Emit | Should -Be 'Back'
    }

    It 'installs the marked winget results exactly as the old Search tab did' {
        $s = New-WtStoreState
        $s.Mode = 'Results'
        $s.Query = 'vlc'
        $marked = (Update-WtStoreState -State $s -Token 'Space' -Rows $StageRows).State
        $marked.Marks.Contains('A1') | Should -BeTrue
        (Update-WtStoreState -State $marked -Token 'Enter' -Rows $StageRows).Emit | Should -Be 'Install'
    }

    It 'refuses to mark an already installed package on the results page too' {
        $s = New-WtStoreState
        $s.Mode = 'Results'
        $r = Update-WtStoreState -State $s -Token 'Space' -Rows $StageRows -InstalledIds @('A1')
        $r.Emit | Should -Be 'Refused'
        $r.State.Marks.Count | Should -Be 0
    }

    It 'marks the ONE row a single-hit search leaves behind' {
        $single = @(@{ Kind = 'Cells'; Cells = @(@{ Kind = 'App'; Id = 'VideoLAN.VLC'; Name = 'VLC' }) })
        $s = New-WtStoreState
        $s.Mode = 'Results'
        (Get-WtStoreCursorCell -State $s -Rows $single).Id | Should -Be 'VideoLAN.VLC'
        $r = Update-WtStoreState -State $s -Token 'Space' -Rows $single
        $r.State.Marks.Contains('VideoLAN.VLC') | Should -BeTrue
        (Update-WtStoreState -State $r.State -Token 'Enter' -Rows $single).Emit | Should -Be 'Install'
        $glyphs = Get-WtGlyphSet -Unicode $false
        $rows = Get-WtStoreFrameRows -State $s -Rows $single -Width 120 -Height 40 -Glyphs $glyphs -FooterText 'x'
        ((@($rows) | ForEach-Object { (@($_) | ForEach-Object { [string]$_.T }) -join '' }) -join "`n") | Should -BeLike '*VLC*'
    }

    It 'refreshes the results page on R' {
        $s = New-WtStoreState
        $s.Mode = 'Results'
        $s.Query = 'vlc'
        (Update-WtStoreState -State $s -Token 'Char:r' -Rows $StageRows).Emit | Should -Be 'Refresh'
    }
}

Describe 'Update-WtStoreState movement over the flowed rows' {
    BeforeAll {
        $script:MoveRows = Get-WtStoreGridRows `
            -Apps @(0..7 | ForEach-Object { [PSCustomObject]@{ Id = "A.$_"; Name = "App$_"; Category = 'Browsers' } }) `
            -CategoryKeys @('Browsers') -CellsPerRow 3
        $script:TableRows = Get-WtStoreListRows -Rows @(0..29 | ForEach-Object { @{ Id = "P$_"; Name = "P$_" } })
    }

    It 'reads Right off the end of a row onto the first cell of the next' {
        $s = New-WtStoreState
        $s.Cursor = @{ Row = 1; Col = 2 }
        $r = Update-WtStoreState -State $s -Token 'Right' -Rows $MoveRows
        $r.State.Cursor.Row | Should -Be 2
        $r.State.Cursor.Col | Should -Be 0
        (Get-WtStoreCursorCell -State $r.State -Rows $MoveRows).Id | Should -Be 'A.3'
    }

    It 'clamps Col when Down lands on the short last row of a category' {
        $s = New-WtStoreState
        $s.Cursor = @{ Row = 2; Col = 2 }
        $r = Update-WtStoreState -State $s -Token 'Down' -Rows $MoveRows
        $r.State.Cursor.Row | Should -Be 3
        $r.State.Cursor.Col | Should -Be 1
        (Get-WtStoreCursorCell -State $r.State -Rows $MoveRows).Id | Should -Be 'A.7'
    }

    It 'scrolls the window with the cursor on a table tab' {
        $s = New-WtStoreState
        $s.Tab = 'Installed'
        for ($i = 0; $i -lt 12; $i++) {
            $s = (Update-WtStoreState -State $s -Token 'Down' -Rows $TableRows -ViewHeight 5).State
        }
        $s.Cursor.Row | Should -Be 12
        $s.WindowStart | Should -Be 8
        (Get-WtStoreCursorCell -State $s -Rows $TableRows).Id | Should -Be 'P12'
    }

    It 'marks every focusable cell of every row on A, headers included and skipped' {
        $s = New-WtStoreState
        $r = Update-WtStoreState -State $s -Token 'Char:a' -Rows $MoveRows
        $r.State.Marks.Count | Should -Be 8
        $r.State.Marks.Contains('A.7') | Should -BeTrue
    }
}
