# Grid key vocabulary, grid geometry, the flowed row model and the store
# reducer.
# Covered by: tests/WingetStoreState.Tests.ps1, tests/WingetStoreGrid.Tests.ps1

function ConvertTo-WtGridKeyToken {
    <#
    .SYNOPSIS
        The winget store's own key vocabulary: unlike the shared converter,
        keeps case and passes RightArrow/Tab/Delete and any printable
        character through (IsControl, not regex - tr-TR mishandles
        dotted/dotless i under -match).
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][AllowEmptyString()][string]$KeyChar = ''
    )

    switch ($Key) {
        'UpArrow'    { return 'Up' }
        'DownArrow'  { return 'Down' }
        'LeftArrow'  { return 'Left' }
        'RightArrow' { return 'Right' }
        'PageUp'     { return 'PageUp' }
        'PageDown'   { return 'PageDown' }
        'Home'       { return 'Home' }
        'End'        { return 'End' }
        'Tab'        { return 'Tab' }
        'Escape'     { return 'Esc' }
        'Backspace'  { return 'Backspace' }
        'Delete'     { return 'Delete' }
        'Enter'      { return 'Enter' }
        'Spacebar'   { return 'Space' }
    }

    if ($KeyChar.Length -eq 1 -and -not [char]::IsControl($KeyChar[0])) { return 'Char:' + $KeyChar }
    return 'None'
}

function Get-WtGridGeometry {
    <#
    .SYNOPSIS
        Cell layout for the store grid: cell width, per-cell start offsets,
        and the room left for the name after the "[ ] " marker. ColumnCount
        means cells-per-row, not category count, and a row collapses to a
        single cell once cells would fall below MinCell.
    #>
    param(
        [Parameter(Mandatory)][int]$Inner,
        [int]$ColumnCount = 5,
        [int]$Gap = 2,
        [int]$MinCell = 12
    )
    $cols = [Math]::Max(1, $ColumnCount)
    $cell = [Math]::Floor(($Inner - ($Gap * ($cols - 1))) / $cols)
    if ($cell -lt $MinCell) {
        $cols = 1
        $cell = $Inner
    }
    $starts = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $cols; $i++) { $starts.Add($i * ($cell + $Gap)) }
    return @{
        ColumnCount = $cols
        CellWidth   = [int]$cell
        NameWidth   = [Math]::Max(1, [int]$cell - 4)
        Starts      = [int[]]$starts.ToArray()
    }
}

function Test-WtGridCellFocusable {
    <#
    .SYNOPSIS
        Only App cells take the cursor. Kept as its own predicate so a
        non-App cell can never be marked, installed or highlighted even if
        one ever reaches a Cells row.
    #>
    param([AllowNull()]$Cell)
    if ($null -eq $Cell) { return $false }
    return ([string]$Cell.Kind -eq 'App')
}

function Get-WtGridRowCellCount {
    <#
    .SYNOPSIS
        How many cells one row of the flowed grid holds - 0 for a Header
        row, which makes "skip headers" and "stop at list end" the same
        test everywhere. Checks Row for $null explicitly, since @($null)
        wraps to a one-element array in PowerShell and would otherwise
        count as a row with one unfocusable cell.
    #>
    param([AllowNull()]$Row)
    if ($null -eq $Row) { return 0 }
    if ([string]$Row.Kind -ne 'Cells') { return 0 }
    if ($null -eq $Row.Cells) { return 0 }
    return @($Row.Cells).Count
}

function Get-WtGridCellsRowIndex {
    <#
    .SYNOPSIS
        The first row index past From, walking in direction Delta, that
        actually holds cells. -1 when the walk runs off the end. Delta 0
        tests From itself.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][int]$From,
        [Parameter(Mandatory)][int]$Delta
    )
    $list = @()
    if ($null -ne $Rows) { $list = @($Rows) }
    if ($Delta -eq 0) {
        if ($From -ge 0 -and $From -lt $list.Count -and (Get-WtGridRowCellCount -Row $list[$From]) -gt 0) { return $From }
        return -1
    }
    $i = $From + $Delta
    while ($i -ge 0 -and $i -lt $list.Count) {
        if ((Get-WtGridRowCellCount -Row $list[$i]) -gt 0) { return $i }
        $i += $Delta
    }
    return -1
}

function Get-WtGridNearestCellsRow {
    <#
    .SYNOPSIS
        The cells-row nearest to PreferredRow in either direction, a tie
        going upwards. -1 when the list holds no cells at all. This is
        what makes a page jump, or a cursor carried over from a changed
        frame, land on something real rather than a Header row.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [int]$PreferredRow = 0
    )
    $list = @()
    if ($null -ne $Rows) { $list = @($Rows) }
    if ($list.Count -eq 0) { return -1 }
    $p = [Math]::Max(0, [Math]::Min($PreferredRow, $list.Count - 1))
    if ((Get-WtGridRowCellCount -Row $list[$p]) -gt 0) { return $p }
    $up = Get-WtGridCellsRowIndex -Rows $list -From $p -Delta -1
    $down = Get-WtGridCellsRowIndex -Rows $list -From $p -Delta 1
    if ($up -lt 0) { return $down }
    if ($down -lt 0) { return $up }
    if (($p - $up) -le ($down - $p)) { return $up }
    return $down
}

function Get-WtStoreGridRows {
    <#
    .SYNOPSIS
        The catalog as a FLAT list of rows: a full-width Header row per
        category, then that category's apps flowed CellsPerRow at a time,
        left to right, then the next category's Header, with a blank
        Spacer row before every Header but the first. A category with no
        apps produces no rows at all, and the last row of a category is
        short rather than padded, so no unfocusable filler cell ever sits
        under the cursor.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Apps,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$CategoryKeys,
        [int]$CellsPerRow = 5,
        [hashtable]$CategoryLabels = @{}
    )
    $appList = @()
    if ($null -ne $Apps) { $appList = @($Apps) }
    $keys = @()
    if ($null -ne $CategoryKeys) { $keys = @($CategoryKeys) }
    $per = [Math]::Max(1, $CellsPerRow)
    $labels = if ($null -eq $CategoryLabels) { @{} } else { $CategoryLabels }
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($key in $keys) {
        $cells = New-Object System.Collections.Generic.List[object]
        foreach ($app in $appList) {
            if ([string]$app.Category -eq [string]$key) {
                $cells.Add(@{
                        Kind     = 'App'
                        Id       = [string]$app.Id
                        Name     = [string]$app.Name
                        Category = [string]$app.Category
                    })
            }
        }
        if ($cells.Count -eq 0) { continue }

        if ($rows.Count -gt 0) {
            $rows.Add(@{ Kind = 'Spacer'; Label = ''; Category = ''; AppCount = 0; Cells = @() })
        }

        $label = if ($labels.ContainsKey($key)) { [string]$labels[$key] } else { [string]$key }
        if (-not $label) { $label = [string]$key }
        $rows.Add(@{ Kind = 'Header'; Label = $label; Category = [string]$key; AppCount = $cells.Count; Cells = @() })

        for ($i = 0; $i -lt $cells.Count; $i += $per) {
            $take = [Math]::Min($per, $cells.Count - $i)
            $slice = New-Object 'object[]' $take
            for ($j = 0; $j -lt $take; $j++) { $slice[$j] = $cells[$i + $j] }
            $rows.Add(@{ Kind = 'Cells'; Label = ''; Category = [string]$key; AppCount = $take; Cells = $slice })
        }
    }
    return , $rows.ToArray()
}

function Get-WtStoreListRows {
    <#
    .SYNOPSIS
        The same row model over a TABLE: one cell per row, no headers, so
        the search and installed tabs share the grid's cursor logic.
        Returns with a protecting unary comma - a bare statement-block
        assignment once unrolled a one-row result back to a scalar, so
        Enter installed a package the cursor was not on.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [int]$CellsPerRow = 1
    )
    $per = [Math]::Max(1, $CellsPerRow)
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Rows) {
        foreach ($row in $Rows) {
            if ($null -eq $row) { continue }
            $items.Add(@{ Kind = 'App'; Id = [string]$row.Id; Name = [string]$row.Name; Category = '' })
        }
    }
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $items.Count; $i += $per) {
        $take = [Math]::Min($per, $items.Count - $i)
        $slice = New-Object 'object[]' $take
        for ($j = 0; $j -lt $take; $j++) { $slice[$j] = $items[$i + $j] }
        $out.Add(@{ Kind = 'Cells'; Label = ''; Category = ''; AppCount = $take; Cells = $slice })
    }
    return , $out.ToArray()
}

function Get-WtGridRowCount {
    <#
    .SYNOPSIS
        Rows the grid occupies, headers included - they are drawn and
        scrolled like everything else. One WindowStart over this one list
        is the whole scroll model.
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows)
    if ($null -eq $Rows) { return 0 }
    return @($Rows).Count
}

function Move-WtGridCursor {
    <#
    .SYNOPSIS
        One movement token applied to the grid cursor. Up/Down skip
        header rows and clamp Col to the landing row; Left/Right follow
        READING ORDER, continuing onto the adjacent cells-row instead of
        wrapping in place. Nothing moves past either end of the list.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][hashtable]$Cursor,
        [Parameter(Mandatory)][string]$Token,
        [int]$ViewHeight = 10
    )
    $list = @()
    if ($null -ne $Rows) { $list = @($Rows) }
    $row = [int]$Cursor.Row
    $col = [int]$Cursor.Col
    $same = @{ Row = $row; Col = $col }
    if ($list.Count -eq 0) { return @{ Row = 0; Col = 0 } }

    $cur = [Math]::Max(0, [Math]::Min($row, $list.Count - 1))
    $curCount = Get-WtGridRowCellCount -Row $list[$cur]
    $land = {
        param([int]$Index, [int]$WantCol)
        $n = Get-WtGridRowCellCount -Row $list[$Index]
        @{ Row = $Index; Col = [Math]::Max(0, [Math]::Min($WantCol, $n - 1)) }
    }

    switch ($Token) {
        'Up' {
            $i = Get-WtGridCellsRowIndex -Rows $list -From $cur -Delta -1
            if ($i -lt 0) { return $same }
            return (& $land $i $col)
        }
        'Down' {
            $i = Get-WtGridCellsRowIndex -Rows $list -From $cur -Delta 1
            if ($i -lt 0) { return $same }
            return (& $land $i $col)
        }
        'Left' {
            if ($curCount -gt 0 -and $col -gt 0) { return (& $land $cur ($col - 1)) }
            $i = Get-WtGridCellsRowIndex -Rows $list -From $cur -Delta -1
            if ($i -lt 0) { return $same }
            return (& $land $i ([int]::MaxValue))
        }
        'Right' {
            if ($curCount -gt 0 -and $col -lt ($curCount - 1)) { return (& $land $cur ($col + 1)) }
            $i = Get-WtGridCellsRowIndex -Rows $list -From $cur -Delta 1
            if ($i -lt 0) { return $same }
            return (& $land $i 0)
        }
        'Home' {
            $i = Get-WtGridNearestCellsRow -Rows $list -PreferredRow 0
            if ($i -lt 0) { return $same }
            return (& $land $i 0)
        }
        'End' {
            $i = Get-WtGridNearestCellsRow -Rows $list -PreferredRow ($list.Count - 1)
            if ($i -lt 0) { return $same }
            return (& $land $i ([int]::MaxValue))
        }
        'PageUp' {
            $i = Get-WtGridNearestCellsRow -Rows $list -PreferredRow ([Math]::Max(0, $cur - $ViewHeight))
            if ($i -lt 0) { return $same }
            return (& $land $i $col)
        }
        'PageDown' {
            $i = Get-WtGridNearestCellsRow -Rows $list -PreferredRow ([Math]::Min($list.Count - 1, $cur + $ViewHeight))
            if ($i -lt 0) { return $same }
            return (& $land $i $col)
        }
    }
    return $same
}

function New-WtStoreState {
    <#
    .SYNOPSIS
        A fresh winget store screen: catalog tab, cursor on the first
        cell, nothing marked, no query. Mode (Catalog or Results) tracks
        what the store page shows, kept separate from Tab so a search
        result page is never an unreachable third tab.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Query = '')
    return @{
        Tab         = 'Store'
        Mode        = 'Catalog'
        Focus       = 'Grid'
        Cursor      = @{ Row = 0; Col = 0 }
        WindowStart = 0
        Marks       = (New-Object 'System.Collections.Generic.HashSet[string]')
        Query       = [string]$Query
        Results     = @()
        Installed   = @()
        InstalledQuery = ''
        Hint        = ''
    }
}

function Get-WtStoreCursorCell {
    <#
    .SYNOPSIS
        The cell the cursor stands on, or $null when the grid is empty or
        the cursor sits on a header row. Rows is copied via an if
        STATEMENT, not a statement-block expression: the pipeline a
        statement block emits through unrolls a one-row result back to a
        bare hashtable, silently turning $list.Count into a key count.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows
    )
    $list = @()
    if ($null -ne $Rows) { $list = @($Rows) }
    $r = [int]$State.Cursor.Row
    $c = [int]$State.Cursor.Col
    if ($r -lt 0 -or $r -ge $list.Count) { return $null }
    $n = Get-WtGridRowCellCount -Row $list[$r]
    if ($c -lt 0 -or $c -ge $n) { return $null }
    $cell = @($list[$r].Cells)[$c]
    if (-not (Test-WtGridCellFocusable -Cell $cell)) { return $null }
    return $cell
}

function Get-WtStoreValidCursor {
    <#
    .SYNOPSIS
        A cursor guaranteed to sit on a focusable cell of THESE rows:
        unchanged when it already does, otherwise Col clamped into its
        own row, and failing that the nearest row that holds cells.
        Applied once per frame, since rows are re-derived every frame (a
        filter, a reload, an uninstall) while the cursor carries over from
        the one before, and a stale cursor makes Enter do nothing at all.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][hashtable]$Cursor
    )
    $list = @()
    if ($null -ne $Rows) { $list = @($Rows) }
    if ($list.Count -eq 0) { return @{ Row = 0; Col = 0 } }
    $r = [int]$Cursor.Row
    $c = [int]$Cursor.Col
    if ($r -ge 0 -and $r -lt $list.Count) {
        $n = Get-WtGridRowCellCount -Row $list[$r]
        if ($n -gt 0) { return @{ Row = $r; Col = [Math]::Max(0, [Math]::Min($c, $n - 1)) } }
    }
    $near = Get-WtGridNearestCellsRow -Rows $list -PreferredRow $r
    if ($near -lt 0) { return @{ Row = 0; Col = 0 } }
    $nearCount = Get-WtGridRowCellCount -Row $list[$near]
    return @{ Row = $near; Col = [Math]::Max(0, [Math]::Min($c, $nearCount - 1)) }
}

function Update-WtStoreState {
    <#
    .SYNOPSIS
        The pure winget-store reducer: one token in, a new state and an
        emit out (None, Back, Install, Upgrade, Uninstall, Search,
        Refresh, Refused). While Focus is 'Input' every printable
        character is typed into the query; only Enter/Esc leave the box.
        Eof (line-mode stdin exhausted) returns Back, not None - mapped to
        None it once spun an infinite repaint loop on an empty Read-Host.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [int]$ViewHeight = 10,
        [AllowEmptyCollection()][string[]]$InstalledIds = @()
    )
    $s = @{}
    foreach ($k in $State.Keys) { $s[$k] = $State[$k] }
    $s.Cursor = @{ Row = [int]$State.Cursor.Row; Col = [int]$State.Cursor.Col }
    $s.Marks = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in $State.Marks) { $null = $s.Marks.Add($m) }
    $s.Hint = ''
    $tabs = @('Store', 'Installed')
    $done = { param($E) return @{ State = $s; Emit = $E } }
    $setTab = { param([string]$Name)
        $s.Tab = $Name
        $s.Mode = 'Catalog'
        $s.Cursor = @{ Row = 0; Col = 0 }
        $s.WindowStart = 0
        $s.Marks.Clear()
    }

    if ($Token -eq 'Eof') { return (& $done 'Back') }

    if ([string]$s.Focus -eq 'Input') {
        $onInstalled = ([string]$s.Tab -eq 'Installed')
        $field = $(if ($onInstalled) { 'InstalledQuery' } else { 'Query' })
        if ($Token -eq 'Enter') {
            $s.Focus = 'Grid'
            $s.Cursor = @{ Row = 0; Col = 0 }
            $s.WindowStart = 0
            if ($onInstalled) { return (& $done 'None') }
            if (([string]$s.Query).Trim() -eq '') {
                $s.Mode = 'Catalog'
                return (& $done 'None')
            }
            $s.Mode = 'Results'
            return (& $done 'Search')
        }
        if ($Token -eq 'Esc') {
            $s.Focus = 'Grid'
            if (-not $onInstalled) { $s.Mode = 'Catalog' }
            $s[$field] = ''
            $s.Cursor = @{ Row = 0; Col = 0 }
            $s.WindowStart = 0
            return (& $done 'None')
        }
        if ($Token -eq 'Backspace') {
            $q = [string]$s[$field]
            if ($q.Length -gt 0) { $s[$field] = $q.Substring(0, $q.Length - 1) }
            return (& $done 'None')
        }
        if ($Token -eq 'Space') { $s[$field] = [string]$s[$field] + ' '; return (& $done 'None') }
        if ($Token.StartsWith('Char:', [StringComparison]::Ordinal)) {
            $s[$field] = [string]$s[$field] + $Token.Substring(5)
            return (& $done 'None')
        }
        return (& $done 'None')
    }

    if (@('Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown') -contains $Token) {
        $moved = Move-WtGridCursor -Rows $Rows -Cursor $s.Cursor -Token $Token -ViewHeight $ViewHeight
        if ([int]$moved.Row -ge 0) { $s.Cursor = @{ Row = [int]$moved.Row; Col = [int]$moved.Col } }
        $total = Get-WtGridRowCount -Rows $Rows
        $s.WindowStart = Get-WtViewportWindow -ItemCount $total -CursorIndex ([int]$s.Cursor.Row) `
            -ViewHeight $ViewHeight -WindowStart ([int]$s.WindowStart)
        return (& $done 'None')
    }

    if ($Token -eq 'Tab') {
        $i = [Array]::IndexOf($tabs, [string]$s.Tab)
        & $setTab $tabs[(($i + 1) % $tabs.Count)]
        return (& $done 'None')
    }

    if ($Token -eq 'Back') { return (& $done 'Back') }
    if ($Token.StartsWith('Digit:', [StringComparison]::Ordinal)) {
        $number = 0
        if ([int]::TryParse($Token.Substring(6), [ref]$number)) {
            $index = $number - 1
            if ($index -ge 0 -and $index -lt $tabs.Count) { & $setTab $tabs[$index] }
        }
        return (& $done 'None')
    }

    if ($Token -eq 'Space') {
        $cell = Get-WtStoreCursorCell -State $s -Rows $Rows
        if ($null -eq $cell) { return (& $done 'None') }
        $id = [string]$cell.Id
        if ([string]$s.Tab -ne 'Installed' -and ($InstalledIds -contains $id)) {
            return (& $done 'Refused')
        }
        if ($s.Marks.Contains($id)) { $null = $s.Marks.Remove($id) } else { $null = $s.Marks.Add($id) }
        return (& $done 'None')
    }

    if ($Token -eq 'Enter') {
        if ([string]$s.Tab -eq 'Installed') { return (& $done 'None') }
        if ($s.Marks.Count -eq 0) {
            $cell = Get-WtStoreCursorCell -State $s -Rows $Rows
            if ($null -eq $cell) { return (& $done 'None') }
            $id = [string]$cell.Id
            if ([string]$s.Tab -ne 'Installed' -and ($InstalledIds -contains $id)) {
                return (& $done 'Refused')
            }
            $null = $s.Marks.Add($id)
        }
        return (& $done 'Install')
    }

    if ($Token -eq 'Delete') {
        if ([string]$s.Tab -eq 'Installed' -and $s.Marks.Count -gt 0) { return (& $done 'Uninstall') }
        return (& $done 'None')
    }

    if ($Token -eq 'Esc') {
        if ([string]$s.Mode -eq 'Results') {
            $s.Mode = 'Catalog'
            $s.Query = ''
            $s.Cursor = @{ Row = 0; Col = 0 }
            $s.WindowStart = 0
            $s.Marks.Clear()
            return (& $done 'None')
        }
        if ([string]$s.Tab -eq 'Installed' -and ([string]$s.InstalledQuery).Trim() -ne '') {
            $s.InstalledQuery = ''
            $s.Cursor = @{ Row = 0; Col = 0 }
            $s.WindowStart = 0
            return (& $done 'None')
        }
        return (& $done 'Back')
    }

    if ($Token.StartsWith('Char:', [StringComparison]::Ordinal)) {
        $ch = $Token.Substring(5).ToLowerInvariant()
        switch ($ch) {
            '/' {
                if ([string]$s.Tab -eq 'Installed') {
                    $s.Focus = 'Input'
                    $s.InstalledQuery = ''
                    $s.Cursor = @{ Row = 0; Col = 0 }
                    $s.WindowStart = 0
                    return (& $done 'None')
                }
                $s.Focus = 'Input'
                $s.Mode = 'Catalog'
                $s.Query = ''
                $s.Cursor = @{ Row = 0; Col = 0 }
                $s.WindowStart = 0
                return (& $done 'None')
            }
            'q' { return (& $done 'Back') }
            'r' { return (& $done 'Refresh') }
            'a' {
                foreach ($row in @($Rows)) {
                    if ($null -eq $row -or $null -eq $row.Cells) { continue }
                    foreach ($cell in @($row.Cells)) {
                        if (-not (Test-WtGridCellFocusable -Cell $cell)) { continue }
                        $id = [string]$cell.Id
                        if ([string]$s.Tab -ne 'Installed' -and ($InstalledIds -contains $id)) { continue }
                        $null = $s.Marks.Add($id)
                    }
                }
                return (& $done 'None')
            }
            'n' { $s.Marks.Clear(); return (& $done 'None') }
            'u' {
                if ([string]$s.Tab -eq 'Installed' -and $s.Marks.Count -gt 0) { return (& $done 'Upgrade') }
                return (& $done 'None')
            }
            '1' { & $setTab 'Store'; return (& $done 'None') }
            '2' { & $setTab 'Installed'; return (& $done 'None') }
        }
    }

    return (& $done 'None')
}
