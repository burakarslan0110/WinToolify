#Requires -Modules Pester

<#
.SYNOPSIS
    Winget store grid: cell geometry, the FLOWED row model built from the
    catalog, the one-cell-per-row projection the table tabs navigate, and
    cursor movement in reading order across rows of different lengths.
    Where a builder returns $null vs an empty array matters, tests assert
    GetType().FullName rather than -BeNullOrEmpty, since Pester counts
    both as "null or empty" and only the type tells them apart.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-WtTestRows {
        <#
        .SYNOPSIS
            A row list by hand, shaped exactly like Get-WtStoreGridRows
            output: 0 Header, 1 [A1 A2 A3], 2 [A4], 3 Header, 4 [D1 D2] - a
            long row, a SHORT end-of-category row, and headers between
            them, covering every clamping case the flow layout has.
        #>
        $cell = { param($Id) @{ Kind = 'App'; Id = $Id; Name = $Id; Category = 'X' } }
        return @(
            @{ Kind = 'Header'; Label = 'Browsers'; Category = 'Browsers'; AppCount = 4; Cells = @() }
            @{ Kind = 'Cells'; Label = ''; Category = 'Browsers'; AppCount = 3; Cells = @((& $cell 'A1'), (& $cell 'A2'), (& $cell 'A3')) }
            @{ Kind = 'Cells'; Label = ''; Category = 'Browsers'; AppCount = 1; Cells = @((& $cell 'A4')) }
            @{ Kind = 'Header'; Label = 'Dev'; Category = 'Dev'; AppCount = 2; Cells = @() }
            @{ Kind = 'Cells'; Label = ''; Category = 'Dev'; AppCount = 2; Cells = @((& $cell 'D1'), (& $cell 'D2')) }
        )
    }
}

Describe 'Get-WtGridGeometry' {
    <#
    .SYNOPSIS
        Inner = console width - 5 (one column never written, plus the
        box's own "| " and " |"), so 120 -> 115. ColumnCount is CELLS PER
        ROW now: the grid flows, so it no longer means "one category per
        column".
    #>
    It 'fits five cells on the 120-column window the tool asks for' {
        $g = Get-WtGridGeometry -Inner 115
        $g.ColumnCount | Should -Be 5
        $g.CellWidth   | Should -Be 21
        $g.NameWidth   | Should -Be 17
        $g.Starts      | Should -Be @(0, 23, 46, 69, 92)
    }

    It 'still fits five cells on a 100- and an 80-column window' {
        (Get-WtGridGeometry -Inner 95).CellWidth | Should -Be 17
        (Get-WtGridGeometry -Inner 95).NameWidth | Should -Be 13
        (Get-WtGridGeometry -Inner 75).CellWidth | Should -Be 13
        (Get-WtGridGeometry -Inner 75).NameWidth | Should -Be 9
    }

    It 'falls back to one cell per row rather than printing unreadable stubs' {
        (Get-WtGridGeometry -Inner 68).ColumnCount | Should -Be 5
        $narrow = Get-WtGridGeometry -Inner 67
        $narrow.ColumnCount | Should -Be 1
        $narrow.CellWidth   | Should -Be 67
        $narrow.Starts      | Should -Be @(0)
    }

    It 'never returns a name width below one, however narrow the box' {
        (Get-WtGridGeometry -Inner 3).NameWidth | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-WtStoreGridRows' {
    <#
    .SYNOPSIS
        Assertions take the result as a BARE assignment, never @(...): the
        builder ends in "return , $list" so the whole list arrives as ONE
        pipeline object, and @() would re-wrap it into a one-element array
        holding the array.
    #>
    BeforeAll {
        $script:FakeApps = @(
            [PSCustomObject]@{ Id = 'A.One';   Name = 'One';   Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'A.Two';   Name = 'Two';   Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'A.Three'; Name = 'Three'; Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'A.Four';  Name = 'Four';  Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'B.One';   Name = 'BOne';  Category = 'Dev' }
            [PSCustomObject]@{ Id = 'C.One';   Name = 'COne';  Category = 'Media' }
        )
        $script:FakeKeys = @('Browsers', 'Dev', 'Media', 'Comms')
    }

    It 'flows each category under its own header, in the order of the keys' {
        $rows = Get-WtStoreGridRows -Apps $FakeApps -CategoryKeys $FakeKeys -CellsPerRow 3
        @($rows).Count | Should -Be 9
        $rows[0].Kind | Should -Be 'Header'
        $rows[0].Category | Should -Be 'Browsers'
        $rows[1].Kind | Should -Be 'Cells'
        @($rows[1].Cells | ForEach-Object { $_.Id }) | Should -Be @('A.One', 'A.Two', 'A.Three')
        $rows[3].Kind | Should -Be 'Spacer'
        $rows[4].Kind | Should -Be 'Header'
        $rows[4].Category | Should -Be 'Dev'
        $rows[6].Kind | Should -Be 'Spacer'
        $rows[7].Kind | Should -Be 'Header'
        $rows[7].Category | Should -Be 'Media'
        $rows[8].Cells[0].Id | Should -Be 'C.One'
    }

    It 'puts a Spacer before every header but the first, over the full ten-category shape' {
        $rows = Get-WtStoreGridRows -Apps $FakeApps -CategoryKeys $FakeKeys -CellsPerRow 5
        $kinds = @($rows | ForEach-Object { [string]$_.Kind })
        $kinds | Should -Be @('Header', 'Cells', 'Spacer', 'Header', 'Cells', 'Spacer', 'Header', 'Cells')
    }

    It 'produces no spacer at all for a single-category catalog' {
        $one = Get-WtStoreGridRows -Apps @([PSCustomObject]@{ Id = 'Z.Z'; Name = 'Z'; Category = 'Dev' }) `
            -CategoryKeys @('Dev') -CellsPerRow 5
        @($one | Where-Object { $_.Kind -eq 'Spacer' }).Count | Should -Be 0
        @($one).Count | Should -Be 2
    }

    It 'leaves the last row of a category SHORT instead of padding it out' {
        $rows = Get-WtStoreGridRows -Apps $FakeApps -CategoryKeys $FakeKeys -CellsPerRow 3
        @($rows[2].Cells).Count | Should -Be 1
        $rows[2].Cells[0].Id | Should -Be 'A.Four'
        $rows[2].Category | Should -Be 'Browsers'
    }

    It 'gives a category with no apps no rows at all - not an empty header' {
        $rows = Get-WtStoreGridRows -Apps $FakeApps -CategoryKeys $FakeKeys -CellsPerRow 5
        @($rows | Where-Object { $_.Category -eq 'Comms' }).Count | Should -Be 0
        $none = Get-WtStoreGridRows -Apps @() -CategoryKeys $FakeKeys -CellsPerRow 5
        $none.GetType().FullName | Should -Be 'System.Object[]'
        @($none).Count | Should -Be 0
    }

    It 'keeps the array shape for a single app, where a bare return would give a hashtable' {
        $one = Get-WtStoreGridRows -Apps @([PSCustomObject]@{ Id = 'Z.Z'; Name = 'Z'; Category = 'Dev' }) `
            -CategoryKeys @('Dev') -CellsPerRow 5
        $one.GetType().FullName | Should -Be 'System.Object[]'
        @($one).Count | Should -Be 2
        $one[1].Cells[0].Id | Should -Be 'Z.Z'
    }

    It 'names the header in the active language and keeps the raw key on the row' {
        $rows = Get-WtStoreGridRows -Apps @([PSCustomObject]@{ Id = 'A'; Name = 'A'; Category = 'Browsers' }) `
            -CategoryKeys @('Browsers') -CellsPerRow 5 -CategoryLabels @{ Browsers = 'Tarayicilar' }
        $rows[0].Kind | Should -Be 'Header'
        $rows[0].Label | Should -Be 'Tarayicilar'
        $rows[0].Category | Should -Be 'Browsers'
        $rows[0].AppCount | Should -Be 1
    }

    It 'falls back to the key when no label was supplied' {
        $rows = Get-WtStoreGridRows -Apps @([PSCustomObject]@{ Id = 'A'; Name = 'A'; Category = 'Browsers' }) `
            -CategoryKeys @('Browsers') -CellsPerRow 5
        $rows[0].Label | Should -Be 'Browsers'
    }

    It 'takes CellsPerRow 1 without a layout path of its own - the narrow console' {
        $rows = Get-WtStoreGridRows -Apps $FakeApps -CategoryKeys $FakeKeys -CellsPerRow 1
        @($rows).Count | Should -Be 11
        @($rows | Where-Object { $_.Kind -eq 'Spacer' }).Count | Should -Be 2
        foreach ($r in @($rows | Where-Object { $_.Kind -eq 'Cells' })) {
            @($r.Cells).Count | Should -Be 1
        }
    }
}

Describe 'Get-WtGridRowCellCount' {
    <#
    .SYNOPSIS
        @($null) is a ONE-element array holding $null in PowerShell, so a
        naive @($Row.Cells).Count would call a missing Cells key "one
        cell"; Get-WtGridRowCellCount must report zero instead.
    #>
    It 'reports zero for a header row so the cursor can never land on one' {
        (Get-WtGridRowCellCount -Row @{ Kind = 'Header'; Label = 'x'; Cells = @() }) | Should -Be 0
    }

    It 'reports zero, not one, for a row whose Cells key is missing' {
        (Get-WtGridRowCellCount -Row @{ Kind = 'Cells' }) | Should -Be 0
        (Get-WtGridRowCellCount -Row $null) | Should -Be 0
    }

    It 'counts the cells of a real cells-row' {
        (Get-WtGridRowCellCount -Row @{ Kind = 'Cells'; Cells = @(1, 2, 3) }) | Should -Be 3
    }
}

Describe 'Move-WtGridCursor' {
    <#
    .SYNOPSIS
        Cursor movement follows READING ORDER, not per-row wrapping: in a
        flowed grid, Right past a row's last cell continues onto the next
        row's first cell, the way text reading continues onto the next
        line.
    #>
    BeforeAll { $script:Rows = New-WtTestRows }

    It 'reads on to the NEXT row when Right runs past the last cell' {
        $c = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 2 } -Token 'Right'
        $c.Row | Should -Be 2
        $c.Col | Should -Be 0
    }

    It 'steps sideways inside a row when there is room' {
        $c = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 0 } -Token 'Right'
        $c.Row | Should -Be 1
        $c.Col | Should -Be 1
    }

    It 'reads back to the PREVIOUS row''s last cell when Left runs off the front' {
        $c = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 2; Col = 0 } -Token 'Left'
        $c.Row | Should -Be 1
        $c.Col | Should -Be 2
    }

    It 'skips the header row when reading across a category boundary' {
        $c = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 2; Col = 0 } -Token 'Right'
        $c.Row | Should -Be 4
        $c.Col | Should -Be 0
    }

    It 'stays put at both ends of the list rather than wrapping around' {
        $end = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 4; Col = 1 } -Token 'Right'
        $end.Row | Should -Be 4
        $end.Col | Should -Be 1
        $start = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 0 } -Token 'Left'
        $start.Row | Should -Be 1
        $start.Col | Should -Be 0
    }

    It 'clamps Col when Down lands on a shorter row' {
        $c = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 2 } -Token 'Down'
        $c.Row | Should -Be 2
        $c.Col | Should -Be 0
    }

    It 'skips header rows going up and going down' {
        $down = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 2; Col = 0 } -Token 'Down'
        $down.Row | Should -Be 4 -Because 'row 3 is a header'
        $up = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 4; Col = 0 } -Token 'Up'
        $up.Row | Should -Be 2 -Because 'row 3 is a header'
    }

    It 'stops at the first and last cells-row vertically' {
        $up = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 1 } -Token 'Up'
        $up.Row | Should -Be 1
        $up.Col | Should -Be 1
        $down = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 4; Col = 0 } -Token 'Down'
        $down.Row | Should -Be 4
        $down.Col | Should -Be 0
    }

    It 'sends Home to the first cell and End to the last, never onto a header' {
        $first = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 4; Col = 1 } -Token 'Home'
        $first.Row | Should -Be 1
        $first.Col | Should -Be 0
        $end = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 0 } -Token 'End'
        $end.Row | Should -Be 4
        $end.Col | Should -Be 1
    }

    It 'settles a page jump on the nearest cells-row, with Col clamped' {
        $up = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 4; Col = 1 } -Token 'PageUp' -ViewHeight 2
        $up.Row | Should -Be 2
        $up.Col | Should -Be 0
        $down = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 0 } -Token 'PageDown' -ViewHeight 2
        (Get-WtGridRowCellCount -Row $Rows[$down.Row]) | Should -BeGreaterThan 0
        $down.Row | Should -BeGreaterThan 1
    }

    It 'returns the origin for an empty list instead of throwing' {
        $c = Move-WtGridCursor -Rows @() -Cursor @{ Row = 3; Col = 2 } -Token 'Down'
        $c.Row | Should -Be 0
        $c.Col | Should -Be 0
    }

    It 'leaves an unknown token alone' {
        $c = Move-WtGridCursor -Rows $Rows -Cursor @{ Row = 1; Col = 1 } -Token 'Space'
        $c.Row | Should -Be 1
        $c.Col | Should -Be 1
    }
}

Describe 'Move-WtGridCursor over a real Spacer row' {
    <#
    .SYNOPSIS
        Unlike New-WtTestRows, this shape comes straight out of
        Get-WtStoreGridRows, so it actually carries a Spacer row - a
        hand-built fixture with none would prove nothing about the
        movement functions skipping it.
    #>
    BeforeAll {
        $script:SpacerApps = @(
            [PSCustomObject]@{ Id = 'A.One'; Name = 'One'; Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'A.Two'; Name = 'Two'; Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'B.One'; Name = 'BOne'; Category = 'Dev' }
        )
        $script:SpacerRows = Get-WtStoreGridRows -Apps $SpacerApps -CategoryKeys @('Browsers', 'Dev') -CellsPerRow 5
        $script:SpacerRows[2].Kind | Should -Be 'Spacer'
    }

    It 'steps Down from a category''s last cells-row straight to the next category''s first, over the spacer and header' {
        $c = Move-WtGridCursor -Rows $SpacerRows -Cursor @{ Row = 1; Col = 0 } -Token 'Down'
        $c.Row | Should -Be 4
        $c.Col | Should -Be 0
        $SpacerRows[$c.Row].Cells[0].Id | Should -Be 'B.One'
    }

    It 'reverses with Up, back over the header and spacer to the previous category''s row' {
        $c = Move-WtGridCursor -Rows $SpacerRows -Cursor @{ Row = 4; Col = 0 } -Token 'Up'
        $c.Row | Should -Be 1
        $c.Col | Should -Be 0
        $SpacerRows[$c.Row].Cells[$c.Col].Id | Should -Be 'A.One'
    }

    It 'reads Right off the end of a category''s last row into the next category''s first cell' {
        $c = Move-WtGridCursor -Rows $SpacerRows -Cursor @{ Row = 1; Col = 1 } -Token 'Right'
        $c.Row | Should -Be 4
        $c.Col | Should -Be 0
        $SpacerRows[$c.Row].Cells[0].Id | Should -Be 'B.One'
    }

    It 'treats a Spacer row as holding zero cells, exactly like a Header' {
        (Get-WtGridRowCellCount -Row $SpacerRows[2]) | Should -Be 0
    }
}

Describe 'Get-WtStoreListRows' {
    <#
    .SYNOPSIS
        A table tab needs ONE CELL PER ROW, not one row holding every
        package. The predecessor shipped broken as an inline statement
        block whose pipeline emission unrolled the unary comma, so 40
        rows arrived as 40 COLUMNS of one row each - and with that flat
        shape, Right x3 moved the cursor while the composer kept
        highlighting row 0, so Space marked and Enter installed a
        different package than the one shown. This function must also
        tolerate $null: Get-WtWingetStoreTabRows' own unprotected
        'return @()' on the store tab unrolls to zero pipeline objects,
        collapsing a bare assignment to $null.
    #>
    BeforeAll {
        $script:ManyRows = @(0..39 | ForEach-Object { @{ Id = "Pkg$_"; Name = "Pkg$_" } })
    }

    It 'gives a table tab ONE CELL PER ROW, not one row holding every package' {
        $rows = Get-WtStoreListRows -Rows $ManyRows
        @($rows).Count | Should -Be 40
        foreach ($r in $rows) {
            $r.Kind | Should -Be 'Cells'
            @($r.Cells).Count | Should -Be 1
        }
        $rows[0].Cells[0].Id | Should -Be 'Pkg0'
        $rows[0].Cells[0].Kind | Should -Be 'App'
        $rows[39].Cells[0].Id | Should -Be 'Pkg39'
    }

    It 'lets Down actually advance the row - the flat shape froze it at 0' {
        $rows = Get-WtStoreListRows -Rows $ManyRows
        $moved = Move-WtGridCursor -Rows $rows -Cursor @{ Row = 0; Col = 0 } -Token 'Down'
        $moved.Row | Should -Be 1
        $moved.Col | Should -Be 0
        (Move-WtGridCursor -Rows $rows -Cursor @{ Row = 0; Col = 0 } -Token 'End').Row | Should -Be 39
    }

    It 'keeps the cursor and the highlighted cell on the SAME package after Right' {
        $rows = Get-WtStoreListRows -Rows $ManyRows
        $c = @{ Row = 0; Col = 0 }
        foreach ($i in 1..3) { $c = Move-WtGridCursor -Rows $rows -Cursor $c -Token 'Right' }
        $c.Row | Should -Be 3
        $c.Col | Should -Be 0
        $s = New-WtStoreState
        $s.Tab = 'Installed'
        $s.Cursor = $c
        (Get-WtStoreCursorCell -State $s -Rows $rows).Id | Should -Be 'Pkg3'
    }

    It 'keeps the array shape for a single result and for none at all' {
        $one = Get-WtStoreListRows -Rows @(@{ Id = 'VideoLAN.VLC'; Name = 'VLC' })
        $one.GetType().FullName | Should -Be 'System.Object[]'
        @($one).Count | Should -Be 1
        $one[0].Cells[0].Id | Should -Be 'VideoLAN.VLC'

        $none = Get-WtStoreListRows -Rows @()
        $none.GetType().FullName | Should -Be 'System.Object[]'
        @($none).Count | Should -Be 0
    }

    It 'tolerates $null, which is what the store tab actually hands it' {
        $rows = Get-WtStoreListRows -Rows $null
        @($rows).Count | Should -Be 0
    }
}

Describe 'Get-WtStoreValidCursor' {
    <#
    .SYNOPSIS
        Reclamps the cursor onto a real cell after a filter narrows the
        grid around it. Before this, "/ vlc Enter" from the store tab
        left the cursor on a now-empty spot and Enter did nothing at all.
    #>
    BeforeAll {
        $script:Catalog = @(
            [PSCustomObject]@{ Id = 'Mozilla.Firefox'; Name = 'Firefox'; Category = 'Browsers'; Tags = 'tarayici browser' }
            [PSCustomObject]@{ Id = 'Google.Chrome';   Name = 'Chrome';  Category = 'Browsers'; Tags = 'tarayici browser' }
            [PSCustomObject]@{ Id = 'Git.Git';         Name = 'Git';     Category = 'Dev';      Tags = 'kod code' }
            [PSCustomObject]@{ Id = 'VideoLAN.VLC';    Name = 'VLC';     Category = 'Media';    Tags = 'video oynatici player' }
        )
        $script:Keys = @('Browsers', 'Dev', 'Media', 'Comms', 'Utilities')
    }

    It 'leaves a cursor that already stands on a real cell exactly where it is' {
        $rows = Get-WtStoreGridRows -Apps @(Select-WtWingetStoreApps -Apps $Catalog -Query '') -CategoryKeys $Keys -CellsPerRow 5
        $c = Get-WtStoreValidCursor -Rows $rows -Cursor @{ Row = 1; Col = 1 }
        $c.Row | Should -Be 1
        $c.Col | Should -Be 1
    }

    It 'never leaves the cursor on a header row - row 0 always is one' {
        $rows = Get-WtStoreGridRows -Apps $Catalog -CategoryKeys $Keys -CellsPerRow 5
        $rows[0].Kind | Should -Be 'Header'
        (Get-WtStoreValidCursor -Rows $rows -Cursor @{ Row = 0; Col = 0 }).Row | Should -Be 1
    }

    It 'moves onto the one surviving app when a filter empties the grid around it' {
        $rows = Get-WtStoreGridRows -Apps @(Select-WtWingetStoreApps -Apps $Catalog -Query 'vlc') -CategoryKeys $Keys -CellsPerRow 5
        $c = Get-WtStoreValidCursor -Rows $rows -Cursor @{ Row = 4; Col = 3 }
        $s = New-WtStoreState
        $s.Cursor = $c
        (Get-WtStoreCursorCell -State $s -Rows $rows).Id | Should -Be 'VideoLAN.VLC'
        $r = Update-WtStoreState -State $s -Token 'Enter' -Rows $rows
        $r.Emit | Should -Be 'Install'
        @($r.State.Marks) | Should -Be @('VideoLAN.VLC')
    }

    It 'reports the origin, and nothing focusable, when a filter matches no app at all' {
        $rows = Get-WtStoreGridRows -Apps @(Select-WtWingetStoreApps -Apps $Catalog -Query 'zzzzz-no-such-app') -CategoryKeys $Keys -CellsPerRow 5
        $c = Get-WtStoreValidCursor -Rows $rows -Cursor @{ Row = 2; Col = 4 }
        $c.Row | Should -Be 0
        $c.Col | Should -Be 0
        $s = New-WtStoreState
        $s.Cursor = $c
        Get-WtStoreCursorCell -State $s -Rows $rows | Should -BeNullOrEmpty
        (Update-WtStoreState -State $s -Token 'Enter' -Rows $rows).Emit | Should -Be 'None'
    }

    It 'stays on its own row, clamped to its last cell, when only Col ran off the end' {
        $rows = Get-WtStoreGridRows -Apps @(Select-WtWingetStoreApps -Apps $Catalog -Query 'tarayici') -CategoryKeys $Keys -CellsPerRow 5
        $c = Get-WtStoreValidCursor -Rows $rows -Cursor @{ Row = 1; Col = 17 }
        $c.Row | Should -Be 1
        $c.Col | Should -Be 1 -Because 'the Browsers row holds Firefox and Chrome only'
    }

    It 'reclamps a table tab whose list shrank under it - an uninstall batch does exactly that' {
        $before = Get-WtStoreListRows -Rows @(0..9 | ForEach-Object { @{ Id = "P$_"; Name = "P$_" } })
        $after = Get-WtStoreListRows -Rows @(0..2 | ForEach-Object { @{ Id = "P$_"; Name = "P$_" } })
        (Get-WtStoreValidCursor -Rows $before -Cursor @{ Row = 9; Col = 0 }).Row | Should -Be 9
        (Get-WtStoreValidCursor -Rows $after -Cursor @{ Row = 9; Col = 0 }).Row | Should -Be 2
    }

    It 'reports the origin for an empty row list' {
        $c = Get-WtStoreValidCursor -Rows @() -Cursor @{ Row = 4; Col = 2 }
        $c.Row | Should -Be 0
        $c.Col | Should -Be 0
    }
}
