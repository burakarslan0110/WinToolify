# Store grid and table composers: cells, tab bar, search box, whole frame.
# Covered by: tests/WingetStoreFrame.Tests.ps1

function Get-WtStoreChromeHeight {
    <#
    .SYNOPSIS
        Rows a store frame spends outside its viewport, header included:
        the shared header (banner, credit, URL) plus 8 for Grid, 10 for
        Table, or 11 for Results - borders, breadcrumb+tabs, search row,
        and (Table/Results) a column header.
    #>
    param(
        [ValidateSet('Grid', 'Table', 'Results')][string]$Layout = 'Table',
        [Parameter(Mandatory)][int]$Width
    )
    $header = @(Get-WtBannerLines -Width $Width).Count + 4
    if ($Layout -eq 'Results') { return $header + 11 }
    if ($Layout -eq 'Table') { return $header + 10 }
    return $header + 8
}

$script:WtStoreHeaderCache = @{}

function Get-WtStoreHeaderRows {
    <#
    .SYNOPSIS
        The rows above the store box: block-letter banner, blank row,
        author credit, repository URL, blank row - matching what every
        other screen's header draws. Uses "return , $array" so a
        one-element result is not unwrapped to a scalar by the pipeline.
    #>
    param([Parameter(Mandatory)][int]$Width)
    $w = Get-WtFrameWidth -Width $Width
    $headerKey = [string]$Width + 'x' + [string]$w
    $cached = $script:WtStoreHeaderCache[$headerKey]
    if ($null -ne $cached) { return , $cached }
    $rows = New-Object System.Collections.Generic.List[object]
    $centered = { param([string]$Text, [string]$Fg)
        if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
        $pad = [Math]::Max(0, [Math]::Floor(($w - $Text.Length) / 2))
        , @(New-WtSeg -Text ((' ' * $pad) + $Text + (' ' * ($w - $pad - $Text.Length))) -Fg $Fg)
    }
    $blankRow = { , @(New-WtSeg -Text (' ' * $w) -Fg 'Gray') }
    foreach ($b in (Get-WtBannerLines -Width $Width)) { $rows.Add((& $centered $b 'Cyan')) }
    $rows.Add((& $blankRow))
    $credit = @(Get-WtBannerCreditLines)
    $rows.Add((& $centered ([string]$credit[0]) 'Gray'))
    $rows.Add((& $centered ([string]$credit[1]) 'DarkGray'))
    $rows.Add((& $blankRow))
    $built = $rows.ToArray()
    $script:WtStoreHeaderCache[$headerKey] = $built
    return , $built
}

function Get-WtStoreTabSegments {
    <#
    .SYNOPSIS
        PURE: the tab switch as segments - "Sekme: [Magaza]  Kurulu" - the
        caption and the idle tab DarkGray, the active tab bracketed and
        White so the eye lands on the one that is open. Shared by the grid
        and the table composer so the two draw the same switch.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [hashtable]$TabLabels = @{},
        [string]$Caption = ''
    )
    if (-not $Caption) { $Caption = [string](Get-Translation 'WsTabCaption') }
    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-WtSeg -Text ($Caption + ': ') -Fg 'DarkGray'))
    $first = $true
    foreach ($t in @('Store', 'Installed')) {
        $label = if ($TabLabels.ContainsKey($t)) { [string]$TabLabels[$t] } else { $t }
        if (-not $first) { $segs.Add((New-WtSeg -Text ' ' -Fg 'DarkGray')) }
        $first = $false
        if ([string]$State.Tab -eq $t) { $segs.Add((New-WtSeg -Text "[$label]" -Fg 'White')) }
        else { $segs.Add((New-WtSeg -Text " $label " -Fg 'DarkGray')) }
    }
    return $segs.ToArray()
}

function Get-WtStoreCrumbSegments {
    <#
    .SYNOPSIS
        PURE: the store's breadcrumb row - breadcrumb, tab switch, mark
        counter on the right - sized to exactly Inner columns. A narrow
        console shrinks the breadcrumb first, then the counter, never the
        tabs: the tabs are functional, the breadcrumb only orientation.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right,
        [Parameter(Mandatory)][int]$Inner,
        [AllowEmptyCollection()][array]$TabSegments = @()
    )
    $crumb = [string]$Breadcrumb
    $right = [string]$Right
    $tabs = @($TabSegments)
    $tabsLen = 0
    foreach ($s in $tabs) { $tabsLen += ([string]$s.T).Length }
    $sep = $(if ($tabs.Count -gt 0) { 3 } else { 0 })
    $room = $Inner - $sep - $tabsLen - $right.Length - 1
    if ($crumb.Length -gt $room) {
        $crumb = $(if ($room -gt 1) { $crumb.Substring(0, $room - 1) + '~' } else { '' })
    }
    $used = $crumb.Length + $sep + $tabsLen
    if (($used + $right.Length) -gt $Inner) {
        $right = $(if (($Inner - $used) -gt 0) { $right.Substring(0, $Inner - $used) } else { '' })
    }
    $gap = [Math]::Max(0, $Inner - $used - $right.Length)
    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-WtSeg -Text $crumb -Fg 'White'))
    if ($tabs.Count -gt 0) {
        $segs.Add((New-WtSeg -Text (' ' * $sep) -Fg 'DarkGray'))
        foreach ($s in $tabs) { $segs.Add($s) }
    }
    $segs.Add((New-WtSeg -Text ((' ' * $gap) + $right) -Fg 'DarkGray'))
    return $segs.ToArray()
}

function Get-WtStoreSearchRowSegments {
    <#
    .SYNOPSIS
        PURE: the store's permanent search row - label, typed query with
        a caret only while focused, and the caller's right-aligned count -
        sized to exactly Inner columns so both store composers (grid and
        table) draw byte-for-byte the same row.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Inner,
        [string]$CountText = '',
        [string]$Label = '',
        [string]$Placeholder = ''
    )
    $focused = ([string]$State.Focus -eq 'Input')
    $label = $(if ($Label) { $Label } else { Get-Translation 'WsSearchLabel' }) + ': '
    $query = [string]$State.Query
    $valueFg = if ($focused) { 'Yellow' } else { 'Gray' }
    if ($focused) { $query += '_' }
    elseif ($query -eq '' -and $Placeholder) { $query = $Placeholder; $valueFg = 'DarkGray' }
    $countText = [string]$CountText
    $used = $label.Length + $query.Length + $countText.Length
    $gap = [Math]::Max(1, $Inner - $used)
    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-WtSeg -Text $label -Fg 'Cyan'))
    $segs.Add((New-WtSeg -Text $query -Fg $valueFg))
    $segs.Add((New-WtSeg -Text ((' ' * $gap) + $countText) -Fg 'DarkGray'))
    $total = 0
    foreach ($s in $segs) { $total += ([string]$s.T).Length }
    if ($total -gt $Inner) {
        $over = $total - $Inner
        for ($i = $segs.Count - 1; $i -ge 0 -and $over -gt 0; $i--) {
            $t = [string]$segs[$i].T
            if ($t.Length -le $over) { $over -= $t.Length; $segs.RemoveAt($i) }
            else { $segs[$i] = New-WtSeg -Text $t.Substring(0, $t.Length - $over) -Fg $segs[$i].F -Bg $segs[$i].B; $over = 0 }
        }
    }
    elseif ($total -lt $Inner) {
        $segs.Add((New-WtSeg -Text (' ' * ($Inner - $total)) -Fg 'DarkGray'))
    }
    return $segs.ToArray()
}

function Get-WtStoreCellSegments {
    <#
    .SYNOPSIS
        One grid cell: checkbox, then the name, padded to exactly
        NameWidth + 4 so cells in the rows above and below stay in line.
        An installed app is green with a dot instead of an empty box, so
        state reads without a legend; an overlong name is cut with '~'.
        Segments are built as literals rather than through New-WtSeg: at
        roughly 100 cells a frame, the constructor's parameter binding
        alone measured 0.23 ms each on PS 5.1.
    #>
    param(
        [Parameter(Mandatory)]$Cell,
        [Parameter(Mandatory)][int]$NameWidth,
        [bool]$IsCursor = $false,
        [bool]$Marked = $false,
        [bool]$Installed = $false,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs
    )
    $box = if ($Marked) { '[x] ' } elseif ($Installed) { '[.] ' } else { '[ ] ' }
    $name = [string]$Cell.Name
    if ($name.Length -gt $NameWidth) {
        $name = if ($NameWidth -gt 1) { $name.Substring(0, $NameWidth - 1) + '~' } else { $name.Substring(0, $NameWidth) }
    }
    $name = $name.PadRight($NameWidth)

    if ($IsCursor) {
        return , @([PSCustomObject]@{ T = ($box + $name); F = 'Black'; B = 'DarkCyan' })
    }
    $nameFg = if ($Installed) { 'Green' } elseif ($Marked) { 'Yellow' } else { 'Gray' }
    $boxFg = if ($Marked) { 'Yellow' } else { 'DarkGray' }
    return , @(
        [PSCustomObject]@{ T = $box; F = $boxFg; B = '' }
        [PSCustomObject]@{ T = $name; F = $nameFg; B = '' }
    )
}

function Get-WtStoreFrameRows {
    <#
    .SYNOPSIS
        One complete store screen as segment-lines that own EVERY console row
        (Count == Height); Write-WtFrame prints exactly this. Builds into
        $frameRows, never $rows: PS is case-insensitive, so $rows would shadow
        the [array]$Rows parameter and .Add() would throw "fixed size".
        Cell rendering is inlined here rather than calling
        Get-WtStoreCellSegments, whose call alone measured 0.3 ms across
        roughly 100 cells a frame; the two must stay in step, and the
        frame tests compare them.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [string]$Breadcrumb = '',
        [hashtable]$TabLabels = @{},
        [string]$TabCaption = '',
        [string]$FooterText = '',
        [string]$CounterText = '',
        [string]$SearchCountText = '',
        [AllowEmptyCollection()][string[]]$InstalledIds = @()
    )
    $w = Get-WtFrameWidth -Width $Width
    $inner = $w - 4
    $h = $Glyphs.H
    $v = $Glyphs.V
    $geo = Get-WtGridGeometry -Inner $inner
    $nameWidth = [int]$geo.NameWidth
    $items = @()
    if ($null -ne $Rows) { $items = @($Rows) }
    $frameRows = New-Object System.Collections.Generic.List[object]
    $installedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($installedId in @($InstalledIds)) { if ($null -ne $installedId) { $null = $installedSet.Add([string]$installedId) } }

    $pad = { param([string]$Text) if ($Text.Length -ge $inner) { $Text.Substring(0, $inner) } else { $Text.PadRight($inner) } }
    $boxed = { param([array]$Segs)
        , (@([PSCustomObject]@{ T = ($v + ' '); F = 'Cyan'; B = '' }) + @($Segs) + @([PSCustomObject]@{ T = (' ' + $v); F = 'Cyan'; B = '' }))
    }
    $hline = { param([string]$L, [string]$R) , @([PSCustomObject]@{ T = ($L + ($h * ($w - 2)) + $R); F = 'Cyan'; B = '' }) }
    $clampSegs = { param([System.Collections.Generic.List[object]]$Segs, [string]$PadFg)
        $total = 0
        foreach ($seg in $Segs) { $total += ([string]$seg.T).Length }
        if ($total -gt $inner) {
            $over = $total - $inner
            for ($i = $Segs.Count - 1; $i -ge 0 -and $over -gt 0; $i--) {
                $t = [string]$Segs[$i].T
                if ($t.Length -le $over) {
                    $over -= $t.Length
                    $Segs.RemoveAt($i)
                }
                else {
                    $Segs[$i] = [PSCustomObject]@{ T = $t.Substring(0, $t.Length - $over); F = [string]$Segs[$i].F; B = [string]$Segs[$i].B }
                    $over = 0
                }
            }
        }
        elseif ($total -lt $inner) {
            $Segs.Add([PSCustomObject]@{ T = (' ' * ($inner - $total)); F = $PadFg; B = '' })
        }
    }

    $headerRows = Get-WtStoreHeaderRows -Width $Width
    $boxChrome = (Get-WtStoreChromeHeight -Layout 'Grid' -Width $Width) - @($headerRows).Count
    if (($Height - @($headerRows).Count - $boxChrome) -lt 1) { $headerRows = @() }
    foreach ($hr in $headerRows) { $frameRows.Add($hr) }

    $frameRows.Add((& $hline $Glyphs.TL $Glyphs.TR))
    $tabSegs = @(Get-WtStoreTabSegments -State $State -TabLabels $TabLabels -Caption $TabCaption)
    $frameRows.Add((& $boxed (Get-WtStoreCrumbSegments -Breadcrumb $Breadcrumb -Right ([string]$CounterText) -Inner $inner -TabSegments $tabSegs)))
    $frameRows.Add((& $hline $Glyphs.LT $Glyphs.RT))

    $frameRows.Add((& $boxed (Get-WtStoreSearchRowSegments -State $State -Inner $inner -CountText $SearchCountText)))
    $frameRows.Add((& $hline $Glyphs.LT $Glyphs.RT))

    $bodyHeight = [Math]::Max(1, $Height - @($headerRows).Count - $boxChrome)
    $total = Get-WtGridRowCount -Rows $items
    $window = 0
    if ($bodyHeight -gt 0) {
        $window = Get-WtViewportWindow -ItemCount $total -CursorIndex ([int]$State.Cursor.Row) `
            -ViewHeight $bodyHeight -WindowStart ([int]$State.WindowStart)
    }
    for ($r = 0; $r -lt $bodyHeight; $r++) {
        $idx = $window + $r
        $line = New-Object System.Collections.Generic.List[object]
        if ($idx -ge 0 -and $idx -lt $total) {
            $item = $items[$idx]
            if ([string]$item.Kind -eq 'Header') {
                $title = $h + $h + ' ' + [string]$item.Label + ' (' + [string]$item.AppCount + ') '
                $line.Add((New-WtSeg -Text $title -Fg 'Cyan'))
                if ($title.Length -lt $inner) {
                    $line.Add((New-WtSeg -Text ($h * ($inner - $title.Length)) -Fg 'DarkGray'))
                }
            }
            elseif ([string]$item.Kind -eq 'Spacer') {
            }
            else {
                $cells = @()
                if ($null -ne $item.Cells) { $cells = @($item.Cells) }
                for ($c = 0; $c -lt $cells.Count; $c++) {
                    $cell = $cells[$c]
                    $isCursor = ($c -eq [int]$State.Cursor.Col -and $idx -eq [int]$State.Cursor.Row -and [string]$State.Focus -eq 'Grid')
                    $id = [string]$cell.Id
                    $marked = $State.Marks.Contains($id)
                    $installed = $installedSet.Contains($id)
                    $box = if ($marked) { '[x] ' } elseif ($installed) { '[.] ' } else { '[ ] ' }
                    $name = [string]$cell.Name
                    if ($name.Length -gt $nameWidth) {
                        $name = if ($nameWidth -gt 1) { $name.Substring(0, $nameWidth - 1) + '~' } else { $name.Substring(0, $nameWidth) }
                    }
                    $name = $name.PadRight($nameWidth)
                    if ($isCursor) {
                        $line.Add([PSCustomObject]@{ T = ($box + $name); F = 'Black'; B = 'DarkCyan' })
                    }
                    else {
                        $line.Add([PSCustomObject]@{ T = $box; F = $(if ($marked) { 'Yellow' } else { 'DarkGray' }); B = '' })
                        $line.Add([PSCustomObject]@{ T = $name; F = $(if ($installed) { 'Green' } elseif ($marked) { 'Yellow' } else { 'Gray' }); B = '' })
                    }
                    $line.Add([PSCustomObject]@{ T = '  '; F = 'Gray'; B = '' })
                }
            }
        }
        & $clampSegs $line 'Gray'
        $frameRows.Add((& $boxed @($line.ToArray())))
    }

    $frameRows.Add((& $hline $Glyphs.LT $Glyphs.RT))
    $range = ''
    if ($total -gt $bodyHeight -and $bodyHeight -gt 0) {
        $range = '{0}-{1}/{2}' -f ($window + 1), ([Math]::Min($window + $bodyHeight, $total)), $total
    }
    $foot = [string]$FooterText
    $footGap = [Math]::Max(1, $inner - $foot.Length - $range.Length)
    $frameRows.Add((& $boxed @(New-WtSeg -Text (& $pad ($foot + (' ' * $footGap) + $range)) -Fg 'Yellow')))
    $frameRows.Add((& $hline $Glyphs.BL $Glyphs.BR))

    while ($frameRows.Count -lt $Height) { $frameRows.Add((, @(New-WtSeg -Text (' ' * $w) -Fg 'Gray'))) }
    if ($frameRows.Count -gt $Height) { return @($frameRows.ToArray()[0..($Height - 1)]) }
    return $frameRows.ToArray()
}

function Get-WtStoreTableLayout {
    <#
    .SYNOPSIS
        Column widths for the search / installed tables. The id column is
        deliberately generous: it is the string a user copies to run
        winget by hand, and a truncated id is useless.
    #>
    param(
        [Parameter(Mandatory)][int]$Inner,
        [bool]$ShowAvailable = $false
    )
    $free = [Math]::Max(0, $Inner - 4 - 3)
    $version = [Math]::Min(12, [Math]::Max(0, [Math]::Floor($free * 0.12)))
    $available = 0
    if ($ShowAvailable) {
        $available = $version
        $free = $free - $available - 1
    }
    $id = [Math]::Max(0, [Math]::Floor(($free - $version) * 0.45))
    $name = [Math]::Max(0, $free - $version - $id)
    return @{ NameWidth = [int]$name; IdWidth = [int]$id; VersionWidth = [int]$version; AvailableWidth = [int]$available }
}

function Get-WtStoreRowSegments {
    <#
    .SYNOPSIS
        One table row: checkbox, name, winget id, installed version and -
        on the installed tab - the version an upgrade would bring. A row
        with an available version is yellow, so "what can be updated"
        reads off the screen without a legend.
    #>
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$Layout,
        [bool]$IsCursor = $false,
        [bool]$Marked = $false,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs
    )
    $fit = {
        param([string]$Text, [int]$Width)
        if ($Width -le 0) { return '' }
        $t = [string]$Text
        if ($t.Length -gt $Width) { $t = $(if ($Width -gt 1) { $t.Substring(0, $Width - 1) + '~' } else { $t.Substring(0, $Width) }) }
        return $t.PadRight($Width)
    }
    $box = if ($Marked) { '[x] ' } else { '[ ] ' }
    $text = $box +
        (& $fit ([string]$Row.Name) $Layout.NameWidth) + ' ' +
        (& $fit ([string]$Row.Id) $Layout.IdWidth) + ' ' +
        (& $fit ([string]$Row.Version) $Layout.VersionWidth)
    if ($Layout.AvailableWidth -gt 0) { $text += ' ' + (& $fit ([string]$Row.Available) $Layout.AvailableWidth) }

    if ($IsCursor) { return , @(New-WtSeg -Text $text -Fg 'Black' -Bg 'DarkCyan') }
    $fg = if ([string]$Row.Available) { 'Yellow' } elseif ($Marked) { 'Yellow' } else { 'Gray' }
    return , @(New-WtSeg -Text $text -Fg $fg)
}

function Get-WtStoreTableRows {
    <#
    .SYNOPSIS
        The installed tab, and the store page's winget results, as a full
        screen of segment-lines (Count == Height). Shares the store's
        header, chrome height, tab bar and footer with
        Get-WtStoreFrameRows; only the body is a table instead of a grid.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [string]$Breadcrumb = '',
        [hashtable]$Headers = @{},
        [hashtable]$TabLabels = @{},
        [string]$TabCaption = '',
        [string]$FooterText = '',
        [string]$CounterText = '',
        [string]$SearchCountText = '',
        [string]$HeadingText = '',
        [string]$EmptyText = ''
    )
    $w = Get-WtFrameWidth -Width $Width
    $inner = $w - 4
    $h = $Glyphs.H
    $v = $Glyphs.V
    $showAvailable = ([string]$State.Tab -eq 'Installed')
    $layout = Get-WtStoreTableLayout -Inner $inner -ShowAvailable $showAvailable
    $out = New-Object System.Collections.Generic.List[object]

    $pad = { param([string]$Text) if ($Text.Length -ge $inner) { $Text.Substring(0, $inner) } else { $Text.PadRight($inner) } }
    $boxed = { param([array]$Segs)
        , (@(New-WtSeg -Text ($v + ' ') -Fg 'Cyan') + @($Segs) + @(New-WtSeg -Text (' ' + $v) -Fg 'Cyan'))
    }
    $hline = { param([string]$L, [string]$R) , @(New-WtSeg -Text ($L + ($h * ($w - 2)) + $R) -Fg 'Cyan') }
    $textRow = { param([string]$Text, [string]$Fg) & $boxed @(New-WtSeg -Text (& $pad $Text) -Fg $Fg) }

    $isResults = ([string]$State.Tab -eq 'Store' -and [string]$State.Mode -eq 'Results')
    $chromeLayout = $(if ($isResults) { 'Results' } else { 'Table' })
    $headerRows = Get-WtStoreHeaderRows -Width $Width
    $boxChrome = (Get-WtStoreChromeHeight -Layout $chromeLayout -Width $Width) - @($headerRows).Count
    if (($Height - @($headerRows).Count - $boxChrome) -lt 1) { $headerRows = @() }
    foreach ($hr in $headerRows) { $out.Add($hr) }

    $out.Add((& $hline $Glyphs.TL $Glyphs.TR))
    $tabSegs = @(Get-WtStoreTabSegments -State $State -TabLabels $TabLabels -Caption $TabCaption)
    $out.Add((& $boxed (Get-WtStoreCrumbSegments -Breadcrumb $Breadcrumb -Right ([string]$CounterText) -Inner $inner -TabSegments $tabSegs)))
    $out.Add((& $hline $Glyphs.LT $Glyphs.RT))

    $onInstalled = ([string]$State.Tab -eq 'Installed')
    if ($isResults -or $onInstalled) {
        $boxState = $State
        if ($onInstalled) { $boxState = @{ Focus = [string]$State.Focus; Query = [string]$State.InstalledQuery } }
        $out.Add((& $boxed (Get-WtStoreSearchRowSegments -State $boxState -Inner $inner -CountText $SearchCountText)))
        $out.Add((& $hline $Glyphs.LT $Glyphs.RT))
        if ($isResults) { $out.Add((& $textRow ([string]$HeadingText) 'Cyan')) }
    }

    $fit = { param([string]$T, [int]$W) if ($W -le 0) { '' } elseif ($T.Length -gt $W) { $T.Substring(0, $W) } else { $T.PadRight($W) } }
    $hdr = '    ' +
        (& $fit ([string]$Headers['Name']) $layout.NameWidth) + ' ' +
        (& $fit ([string]$Headers['Id']) $layout.IdWidth) + ' ' +
        (& $fit ([string]$Headers['Version']) $layout.VersionWidth)
    if ($layout.AvailableWidth -gt 0) { $hdr += ' ' + (& $fit ([string]$Headers['Available']) $layout.AvailableWidth) }
    $out.Add((& $textRow $hdr 'Cyan'))
    $out.Add((& $hline $Glyphs.LT $Glyphs.RT))

    $viewHeight = [Math]::Max(1, $Height - @($headerRows).Count - $boxChrome)
    $items = @($Rows)
    $window = Get-WtViewportWindow -ItemCount $items.Count -CursorIndex ([int]$State.Cursor.Row) `
        -ViewHeight $viewHeight -WindowStart ([int]$State.WindowStart)
    if ($items.Count -eq 0 -and $EmptyText) {
        $out.Add((& $textRow $EmptyText 'DarkGray'))
        for ($i = 1; $i -lt $viewHeight; $i++) { $out.Add((& $textRow '' 'Gray')) }
    }
    else {
        for ($i = 0; $i -lt $viewHeight; $i++) {
            $idx = $window + $i
            if ($idx -ge $items.Count) { $out.Add((& $textRow '' 'Gray')); continue }
            $row = $items[$idx]
            $isCursor = ($idx -eq [int]$State.Cursor.Row -and [string]$State.Focus -eq 'Grid')
            $segs = Get-WtStoreRowSegments -Row $row -Layout $layout -IsCursor $isCursor `
                -Marked ($State.Marks.Contains([string]$row.Id)) -Glyphs $Glyphs
            $rowFg = if (@($segs).Count -gt 0) { $segs[-1].F } else { 'Gray' }
            $used = 0
            foreach ($s in $segs) { $used += ([string]$s.T).Length }
            $line = New-Object System.Collections.Generic.List[object]
            foreach ($s in $segs) { $line.Add($s) }
            if ($used -gt $inner) {
                $over = $used - $inner
                for ($j = $line.Count - 1; $j -ge 0 -and $over -gt 0; $j--) {
                    $t = [string]$line[$j].T
                    if ($t.Length -le $over) {
                        $over -= $t.Length
                        $line.RemoveAt($j)
                    }
                    else {
                        $line[$j] = New-WtSeg -Text $t.Substring(0, $t.Length - $over) -Fg $line[$j].F -Bg $line[$j].B
                        $over = 0
                    }
                }
            }
            elseif ($used -lt $inner) {
                $fill = if ($isCursor) { New-WtSeg -Text (' ' * ($inner - $used)) -Fg 'Black' -Bg 'DarkCyan' }
                        else { New-WtSeg -Text (' ' * ($inner - $used)) -Fg $rowFg }
                $line.Add($fill)
            }
            $out.Add((& $boxed @($line.ToArray())))
        }
    }

    $out.Add((& $hline $Glyphs.LT $Glyphs.RT))
    $range = ''
    if ($items.Count -gt $viewHeight) { $range = '{0}-{1}/{2}' -f ($window + 1), ([Math]::Min($window + $viewHeight, $items.Count)), $items.Count }
    $footGap = [Math]::Max(1, $inner - ([string]$FooterText).Length - $range.Length)
    $out.Add((& $textRow ([string]$FooterText + (' ' * $footGap) + $range) 'Yellow'))
    $out.Add((& $hline $Glyphs.BL $Glyphs.BR))

    while ($out.Count -lt $Height) { $out.Add((, @(New-WtSeg -Text (' ' * $w) -Fg 'Gray'))) }
    if ($out.Count -gt $Height) { return @($out.ToArray()[0..($Height - 1)]) }
    return $out.ToArray()
}
