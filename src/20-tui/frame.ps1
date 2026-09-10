# Segments, banner, state-column colouring, list rows, Get-WtFrameRows.
# Covered by: tests/Tui.Tests.ps1, tests/RowState.Tests.ps1

function New-WtSeg {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Fg = 'White',
        [string]$Bg = ''
    )
    return [PSCustomObject]@{ T = $Text; F = $Fg; B = $Bg }
}

$script:WtFrameHeaderCache = @{}

$script:WtRowColumnCache = @{}

function Get-WtRowColumnMetrics {
    <#
    .SYNOPSIS
        @{ RiskWidth; StateFloor; RiskLabels } for the active language,
        computed once per language: RiskWidth is the widest "[label]"
        of SAFE / CAUTION / ADVANCED, StateFloor the widest of the four
        state words a marked row can show, RiskLabels the three labels.
    #>
    $lang = [string]$script:Language
    $hit = $script:WtRowColumnCache[$lang]
    if ($null -ne $hit) { return $hit }
    $labels = @{}
    $riskWidth = 0
    foreach ($r in 'SAFE', 'CAUTION', 'ADVANCED') {
        $text = [string](Get-WtRiskLabel -Risk $r)
        $labels[$r] = $text
        $riskWidth = [Math]::Max($riskWidth, $text.Length + 2)
    }
    $floor = 0
    foreach ($k in 'Applied', 'NotApplied', 'WillApply', 'WillRemove') { $floor = [Math]::Max($floor, ([string](Get-Translation $k)).Length) }
    $metrics = @{ RiskWidth = $riskWidth; StateFloor = $floor; RiskLabels = $labels }
    $script:WtRowColumnCache[$lang] = $metrics
    return $metrics
}

$script:WtStateSegmentCache = @{}

function Get-WtStateSegmentsCached {
    <#
    .SYNOPSIS
        Cached wrapper around Split-WtStateSegments, keyed by
        language|colour|text. Returned segments are shared across rows
        and frames, so callers must never mutate one in place.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$DefaultFg = 'DarkGray'
    )
    $key = [string]$script:Language + '|' + $DefaultFg + '|' + $Text
    $hit = $script:WtStateSegmentCache[$key]
    if ($null -ne $hit) { return $hit }
    $segs = @(Split-WtStateSegments -Text $Text -DefaultFg $DefaultFg)
    $script:WtStateSegmentCache[$key] = $segs
    return $segs
}

$script:WtCompactNeedKey = ''
$script:WtCompactNeedValue = 0

$script:WtBrand = 'WinToolify V2'
$script:WtTagline = 'Windows Management Harness'
$script:WtRepoUrl = 'https://github.com/burakarslan0110/WinToolify'

function Get-WtWindowTitle {
    <#
    .SYNOPSIS
        What the console window's title bar reads: the brand, then what
        the tool is. Untranslated on purpose - it is the product name,
        and the title bar is read before any language choice is made.
        The banner keeps the bare brand: a narrow console falls back to
        that one line and has no room for more.
    #>
    return $script:WtBrand + ' - ' + $script:WtTagline
}

function Get-WtBannerCreditLines {
    <#
    .SYNOPSIS
        The two lines under the main-screen banner: author credit and the
        project's repository URL. Pure ASCII, language-independent.
    #>
    return @('Created by Burak Arslan', $script:WtRepoUrl)
}

function Get-WtBannerLines {
    <#
    .SYNOPSIS
        The main-screen brand header. The full 9-line block-letter banner
        needs 87 columns plus margin; anything narrower gets the one-line
        brand so the layout never breaks.
    #>
    param([Parameter(Mandatory)][int]$Width)

    if ($Width -lt 89) { return ,@($script:WtBrand) }

    return @(
        '+=====================================================================================+'
        '|##      ## #### ##    ## ########  #######   #######  ##       #### ######## ##    ##|'
        '|##  ##  ##  ##  ###   ##    ##    ##     ## ##     ## ##        ##  ##        ##  ## |'
        '|##  ##  ##  ##  ####  ##    ##    ##     ## ##     ## ##        ##  ##         ####  |'
        '|##  ##  ##  ##  ## ## ##    ##    ##     ## ##     ## ##        ##  ######      ##   |'
        '|##  ##  ##  ##  ##  ####    ##    ##     ## ##     ## ##        ##  ##          ##   |'
        '|##  ##  ##  ##  ##   ###    ##    ##     ## ##     ## ##        ##  ##          ##   |'
        '| ###  ###  #### ##    ##    ##     #######   #######  ######## #### ##          ##   |'
        '+=====================================================================================+'
    )
}

$script:WtStateColorCache = @{}

function Get-WtStateColorMap {
    <#
    .SYNOPSIS
        The state column's vocabulary: the localized word the app itself
        printed -> the colour that word means. Built from translation
        KEYS, never from literals, so a word and its colour cannot drift
        apart when a translation changes, and TR gets the same colours as
        EN for free. Sorted longest-first, because "currently: off" must
        match before anything shorter that lives inside it.
    #>
    param([string]$Language = $script:Language)
    if ($script:WtStateColorCache.ContainsKey($Language)) { return $script:WtStateColorCache[$Language] }
    $byKey = [ordered]@{
        'FirewallCurrentlyOff' = 'Red'
        'FirewallCurrentlyOn'  = 'Green'
        'NotSupportedWddm'     = 'DarkGray'
        'StateNotPresent'      = 'DarkGray'
        'SvcStart.Automatic'   = 'Green'
        'SvcStart.Disabled'    = 'Red'
        'SvcStart.Manual'      = 'Yellow'
        'SvcStatus.Running'    = 'Green'
        'SvcStatus.Stopped'    = 'Gray'
        'SvcStatus.Paused'     = 'Yellow'
        'SvcStatus.StartPending'    = 'Yellow'
        'SvcStatus.StopPending'     = 'Yellow'
        'SvcStatus.PausePending'    = 'Yellow'
        'SvcStatus.ContinuePending' = 'Yellow'
        'SvcStart.Boot'        = 'Green'
        'SvcStart.System'      = 'Green'
        'FlushAvailable'       = 'Green'
        'StateInstalled'       = 'Green'
        'StateRemoved'         = 'DarkGray'
        'StateUnknown'         = 'DarkGray'
        'FolderNotFound'       = 'DarkGray'
        'Applied'              = 'Green'
        'NotApplied'           = 'DarkGray'
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($key in $byKey.Keys) {
        $word = [string]$script:Translations[$Language][$key]
        if (-not $word) { continue }
        $pairs.Add([PSCustomObject]@{ Word = $word; Fg = [string]$byKey[$key] })
    }
    $map = @($pairs | Sort-Object -Property @{ Expression = { $_.Word.Length }; Descending = $true }, Word)
    $script:WtStateColorCache[$Language] = $map
    return $map
}

function Split-WtStateSegments {
    <#
    .SYNOPSIS
        PURE: turns the state column's text into colored segments. A
        vocabulary word gets its own colour; "/" and padding stay
        $DefaultFg. All-or-nothing: unless every character is a
        vocabulary word or the glue between them, the whole column comes
        back as one uncoloured segment, since a path or free-text state
        can match a word mid-string with no boundary. Joining the
        segments always returns $Text unchanged. Matching uses
        CompareOrdinal, not -match/-replace, because tr-TR's
        culture-aware comparison folds I/i the Turkish way.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$DefaultFg = 'DarkGray',
        [AllowEmptyCollection()][array]$Vocabulary = (Get-WtStateColorMap)
    )
    if (-not $Text) { return @() }
    $segs = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $Text.Length) {
        $hit = $null
        foreach ($v in $Vocabulary) {
            $w = [string]$v.Word
            if ($w.Length -gt 0 -and $w.Length -le ($Text.Length - $i) -and
                [string]::CompareOrdinal($Text, $i, $w, 0, $w.Length) -eq 0) { $hit = $v; break }
        }
        if ($hit) {
            $segs.Add((New-WtSeg -Text ([string]$hit.Word) -Fg ([string]$hit.Fg)))
            $i += ([string]$hit.Word).Length
            continue
        }
        $start = $i
        while ($i -lt $Text.Length -and ($Text[$i] -eq ' ' -or $Text[$i] -eq '/')) { $i++ }
        if ($i -eq $start) { return @(New-WtSeg -Text $Text -Fg $DefaultFg) }
        $segs.Add((New-WtSeg -Text $Text.Substring($start, $i - $start) -Fg $DefaultFg))
    }
    return $segs.ToArray()
}

function Get-WtListRowSegments {
    <#
    .SYNOPSIS
        Renders one list row into colored segments:
        "{cursor}{number}{marker} {label}  [{risk}]  {state}", truncated
        to fit Width. A marked row shows [x], its pending verb
        (WillApply/WillRemove) instead of the live state, and its state
        column as one solid yellow block instead of vocabulary-coloured.
        Get-WtListRowLabelRoom mirrors this layout arithmetic for callers
        that wrap instead of truncate. NumberWidth right-aligns the row
        number so numbering past 9 still keeps markers and columns
        aligned; unnumbered callers leave it at its 1-digit default.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][bool]$IsCursor,
        [Parameter(Mandatory)][bool]$Selected,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [Parameter(Mandatory)][int]$Width,
        [int]$VisibleNumber = 0,
        [int]$StateWidth = 0,
        [int]$NumberWidth = 1,
        [string]$PendingLabel = ''
    )

    if ($Item.Kind -eq 'Spacer') { return ,@([PSCustomObject]@{ T = ''; F = 'Gray'; B = '' }) }

    if ($Item.Kind -eq 'Header') {
        $text = '  ' + $Item.Label
        if ($text.Length -gt $Width) { $text = $text.Substring(0, $Width) }
        return ,@([PSCustomObject]@{ T = $text; F = 'Cyan'; B = '' })
    }

    if ($Item.Kind -eq 'Rule') {
        $rule = [string]$Glyphs.Rule
        $lead = '  ' + ($rule * 2) + ' '
        $title = [string]$Item.Label
        $room = $Width - $lead.Length - 2
        if ($title.Length -gt $room -and $room -gt 1) { $title = $title.Substring(0, $room - 1) + '~' }
        $tail = ' ' + ($rule * [Math]::Max(0, $Width - $lead.Length - $title.Length - 1))
        return @(([PSCustomObject]@{ T = $lead; F = 'DarkGray'; B = '' }), ([PSCustomObject]@{ T = $title; F = 'Cyan'; B = '' }), ([PSCustomObject]@{ T = $tail; F = 'DarkGray'; B = '' }))
    }

    $marker = ''
    $applied = ($Item.PSObject.Properties.Name -contains 'Applied') -and [bool]$Item.Applied
    if ($Item.Kind -eq 'Check') { $marker = if ($Selected) { $Glyphs.CheckOn } else { $Glyphs.CheckOff } }
    elseif ($Item.Kind -eq 'Radio') { $marker = if ($Selected) { $Glyphs.RadioOn } else { $Glyphs.RadioOff } }

    $cursorMark = if ($IsCursor) { $Glyphs.Cursor } else { ' ' * $Glyphs.Cursor.Length }
    $numberText = if ($VisibleNumber -gt 0) { ('{0}.' -f $VisibleNumber).PadLeft([Math]::Max(1, $NumberWidth) + 1) + ' ' } else { '' }

    $parts = Get-WtListRowRightParts -Item $Item -StateWidth $StateWidth -Selected $Selected -PendingLabel $PendingLabel
    $riskText = $parts.Risk
    $stateText = $parts.State

    $rightText = $parts.Text
    $leftFixed = $cursorMark + $numberText + $marker + ' '
    $labelRoom = $Width - $leftFixed.Length - $rightText.Length - 2
    $label = [string]$Item.Label
    if ($labelRoom -lt $label.Length -and $rightText) {
        $riskText = $riskText.TrimStart()
        $rightText = ($riskText + '  ' + $stateText).Trim()
        $labelRoom = $Width - $leftFixed.Length - $rightText.Length - 2
    }
    if ($labelRoom -lt 4) { $labelRoom = 4 }
    if ($label.Length -gt $labelRoom) { $label = $label.Substring(0, $labelRoom - 1) + '~' }
    $label = $label.PadRight($labelRoom)

    $rowFg = switch ($Item.Risk) { 'ADVANCED' { 'Red' } 'CAUTION' { 'Yellow' } default { 'White' } }
    if ($Item.Kind -eq 'Info' -and -not $Item.Risk) { $rowFg = 'Gray' }

    if ($IsCursor) {
        $text = $leftFixed + $label + '  ' + $rightText
        if ($text.Length -gt $Width) { $text = $text.Substring(0, $Width) }
        if ($text.Length -lt $Width) { $text = $text.PadRight($Width) }
        return ,@([PSCustomObject]@{ T = $text; F = 'Black'; B = 'DarkCyan' })
    }

    $pending = ($Selected -and $Item.Kind -eq 'Check' -and $stateText.Trim())
    $stateFg = if ($pending) { 'Yellow' } elseif ($applied) { 'Green' } else { 'DarkGray' }
    $stateOnly = $rightText.Substring($riskText.Length)
    $stateSegs = if ($pending) { @([PSCustomObject]@{ T = $stateOnly; F = $stateFg; B = '' }) }
                 else { @(Get-WtStateSegmentsCached -Text $stateOnly -DefaultFg $stateFg) }
    if ($stateSegs.Count -eq 0) { $stateSegs = @([PSCustomObject]@{ T = $stateOnly; F = $stateFg; B = '' }) }
    $segs = @(
        [PSCustomObject]@{ T = ($leftFixed + $label + '  '); F = $rowFg; B = '' }
        [PSCustomObject]@{ T = $riskText; F = $rowFg; B = '' }
    ) + $stateSegs
    $totalLength = 0
    foreach ($s in $segs) { $totalLength += ([string]$s.T).Length }
    if ($totalLength -gt $Width) {
        $total = ''
        foreach ($s in $segs) { $total += [string]$s.T }
        return ,@([PSCustomObject]@{ T = $total.Substring(0, $Width); F = $rowFg; B = '' })
    }
    return $segs
}

function Get-WtListRowRightParts {
    <#
    .SYNOPSIS
        PURE: builds the right-hand part of a list row as two
        fixed-width columns so rows line up - the risk tag right-aligned
        to the widest localized tag, then the state left-aligned and
        padded to the wider of the Applied/NotApplied labels. A row
        missing risk or state still reserves that column, unless no row
        on the screen has a state column at all (StateWidth 0), in which
        case nothing is reserved. PendingVerbKey lets a marked row show
        its own pending action (e.g. "Kaldirilacak") without touching
        Applied, which still decides direction and markability.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [int]$StateWidth = 0,
        [bool]$Selected = $false,
        [string]$PendingLabel = ''
    )
    $metrics = $script:WtRowColumnCache[[string]$script:Language]
    if ($null -eq $metrics) { $metrics = Get-WtRowColumnMetrics }
    $showTag = (-not ($Item.PSObject.Properties.Name -contains 'RiskTag')) -or [bool]$Item.RiskTag
    $riskRaw = ''
    if ($Item.Risk -and $showTag) {
        $riskKey = [string]$Item.Risk
        $riskText = $(if ($metrics.RiskLabels.ContainsKey($riskKey)) { [string]$metrics.RiskLabels[$riskKey] } else { [string](Get-WtRiskLabel -Risk $riskKey) })
        $riskRaw = '[' + $riskText + ']'
    }
    $stateRaw = [string]$Item.StateLabel
    if ($Selected -and $Item.Kind -eq 'Check' -and $PendingLabel) { $stateRaw = '-> ' + $PendingLabel }
    elseif ($Selected -and $Item.Kind -eq 'Check' -and $stateRaw) {
        $applied = ($Item.PSObject.Properties.Name -contains 'Applied') -and [bool]$Item.Applied
        $verbKey = if (($Item.PSObject.Properties.Name -contains 'PendingVerbKey') -and $Item.PendingVerbKey) { [string]$Item.PendingVerbKey }
                   elseif ($applied) { 'WillRemove' } else { 'WillApply' }
        $stateRaw = Get-Translation $verbKey
    }
    if (-not $riskRaw -and -not $stateRaw) { return @{ Risk = ''; State = ''; Text = '' } }
    $risk = $riskRaw.PadLeft([int]$metrics.RiskWidth)
    if (-not $stateRaw -and $StateWidth -le 0) { return @{ Risk = $risk; State = ''; Text = $risk } }
    $stateWidth = [Math]::Max($StateWidth, [int]$metrics.StateFloor)
    $state = $stateRaw.PadRight($stateWidth)
    return @{ Risk = $risk; State = $state; Text = ($risk + '  ' + $state) }
}

function Get-WtListRowLabelRoom {
    <#
    .SYNOPSIS
        PURE: how many characters this row's label may use at the given
        inner width - the same arithmetic Get-WtListRowSegments lays the
        row out with, exposed so callers can WRAP text to fit instead of
        letting the renderer cut it with '~'.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [Parameter(Mandatory)][int]$Width,
        [int]$VisibleNumber = 0,
        [int]$StateWidth = 0,
        [int]$NumberWidth = 1
    )
    $marker = if ($Item.Kind -eq 'Check' -or $Item.Kind -eq 'Radio') { 3 } else { 0 }
    $number = if ($VisibleNumber -gt 0) { [Math]::Max(1, $NumberWidth) + 2 } else { 0 }
    $right = (Get-WtListRowRightParts -Item $Item -StateWidth $StateWidth).Text
    $room = $Width - $Glyphs.Cursor.Length - $number - $marker - 1 - $right.Length - 2
    if ($room -lt 4) { $room = 4 }
    return $room
}

function ConvertTo-WtPanelLines {
    <#
    .SYNOPSIS
        Panel text wrapped so no row is ever cut with '~'. Every line is
        folded to the room a message row really has at this width; blank
        lines are kept because they are deliberate separators. All lines
        wrap to the FIRST row's room (the one carrying the risk tag), so
        a wrapped paragraph forms a straight block instead of widening on
        later lines.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][int]$Width,
        [string]$Risk = '',
        [PSCustomObject]$Glyphs = $script:WtGlyphs
    )
    $probe = New-WtListItem -Kind 'Info' -Name 'Probe' -Label '' -Risk $Risk
    $room = Get-WtListRowLabelRoom -Item $probe -Glyphs $Glyphs -Width $Width
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Lines)) {
        $text = [string]$line
        if (-not $text.Trim()) { $out.Add(''); continue }
        foreach ($piece in @(Split-WtWrappedLines -Text $text -Width $room)) { $out.Add($piece) }
    }
    return [string[]]$out.ToArray()
}

function Format-WtDirectionCounts {
    <#
    .SYNOPSIS
        PURE: "2 to apply, 1 to remove" - zero parts are omitted, both
        zero gives ''. Used by the list counter, the commit summary and
        the apply prompt so every place words the two directions alike.
    #>
    param(
        [Parameter(Mandatory)][int]$ApplyCount,
        [Parameter(Mandatory)][int]$RemoveCount
    )
    $parts = @()
    if ($ApplyCount -gt 0) { $parts += ((Get-Translation 'MarkSummaryApply') -f $ApplyCount) }
    if ($RemoveCount -gt 0) { $parts += ((Get-Translation 'MarkSummaryRemove') -f $RemoveCount) }
    return ($parts -join ', ')
}

function Get-WtMarkSummary {
    <#
    .SYNOPSIS
        PURE: how many marked rows will be applied and how many removed
        (a marked row whose Applied flag is set is a removal), plus the
        formatted counter text. Raw rows (no Applied property on any
        Item at all - the non-apply multi-select pickers such as the DNS
        flush / duplicate finder / cleanup screens) have no direction to
        speak of, so the counter just says how many are marked.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Selection
    )
    $apply = 0
    $remove = 0
    $hasAppliedProperty = $false
    foreach ($item in $Items) {
        if ($item.PSObject.Properties.Name -contains 'Applied') { $hasAppliedProperty = $true }
        if (-not $Selection.Contains([string]$item.Name)) { continue }
        if (($item.PSObject.Properties.Name -contains 'Applied') -and [bool]$item.Applied) { $remove++ } else { $apply++ }
    }
    if (-not $hasAppliedProperty) {
        return @{ ApplyCount = $apply; RemoveCount = $remove; Text = ((Get-Translation 'MarkedCount') -f $Selection.Count) }
    }
    return @{ ApplyCount = $apply; RemoveCount = $remove; Text = (Format-WtDirectionCounts -ApplyCount $apply -RemoveCount $remove) }
}

function Get-WtListRowNaturalWidth {
    <#
    .SYNOPSIS
        Columns one row needs so Get-WtListRowSegments shows its label
        untruncated: cursor + the right-aligned number column + marker +
        space + label + two spaces + risk/state. Mirrors that function's
        layout math (same NumberWidth); the compact box is sized from the
        widest row.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [int]$StateWidth = 0,
        [int]$NumberWidth = 1
    )
    $label = [string]$Item.Label
    if ($Item.Kind -eq 'Spacer') { return 0 }
    if ($Item.Kind -eq 'Header') { return 2 + $label.Length }
    if ($Item.Kind -eq 'Rule') { return 5 + $label.Length + 4 }
    $marker = if ($Item.Kind -eq 'Check' -or $Item.Kind -eq 'Radio') { 3 } else { 0 }
    $right = (Get-WtListRowRightParts -Item $Item -StateWidth $StateWidth).Text
    $gap = if ($right) { 2 } else { 0 }
    return $Glyphs.Cursor.Length + [Math]::Max(1, $NumberWidth) + 2 + $marker + 1 + $label.Length + $gap + $right.Length
}

function Get-WtFrameDescriptionLines {
    <#
    .SYNOPSIS
        PURE: the text of the description band for the row the cursor is
        on - the row's Desc word-wrapped to Width, ALWAYS exactly Rows
        lines, padded with empty ones. Fixed height is the whole point:
        the box must not change shape as the cursor walks the menu, so a
        row with no description (a rule, a spacer, a screen that never
        set one) yields blank lines rather than a shorter band. A
        description too long for the band ends its last line with '~'
        instead of being cut off in silence.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][int]$CursorIndex,
        [Parameter(Mandatory)][int]$Width,
        [int]$Rows = 2
    )
    $count = [Math]::Max(0, $Rows)
    $w = [Math]::Max(8, $Width)
    $text = ''
    if ($CursorIndex -ge 0 -and $CursorIndex -lt $Items.Count) {
        $item = $Items[$CursorIndex]
        if ($null -ne $item) { $text = [string]$item.Desc }
    }
    $wrapped = @(Split-WtWrappedLines -Text $text -Width $w)
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $count; $i++) {
        $line = $(if ($i -lt $wrapped.Count) { [string]$wrapped[$i] } else { '' })
        if ($i -eq ($count - 1) -and $wrapped.Count -gt $count) {
            if ($line.Length -ge $w) { $line = $line.Substring(0, $w - 1) }
            $line = $line.TrimEnd() + '~'
        }
        $out.Add($line)
    }
    return $out.ToArray()
}

function Get-WtFrameRows {
    <#
    .SYNOPSIS
        Composes one complete screen as an array of segment-lines that
        owns EVERY console row (Count == Height); pure, the painter only
        prints what this returns. Every row is exactly Width-1 columns so
        the last console column is never written and nothing can wrap or
        scroll. Layout 'Full' spans the console with a path row, content
        viewport, footer and border; 'Compact' menus/panels size to their
        rows and center horizontally, always sized by the worst case
        (full unfiltered list, longest footer guide) so a live filter or
        swapped footer never resizes it mid-interaction. Row segments are
        collected without wrapping calls in @(), which would re-box an
        already-array result instead of flattening it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][PSCustomObject]$Glyphs,
        [string]$CounterText = '',
        [string]$FooterText = '',
        [bool]$LineMode = $false,
        [bool]$ShowBanner = $false,
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full',
        [hashtable]$CycleLabels = @{},
        [hashtable]$Search = $null,
        [AllowNull()][array]$SizeItems = $null,
        [string]$FooterSizeText = '',
        [int]$DescriptionRows = 0
    )
    $w = Get-WtFrameWidth -Width $Width
    $h = $Glyphs.H
    $v = $Glyphs.V
    $measureItems = $Items
    if ($null -ne $SizeItems) { $measureItems = $SizeItems }
    $stateWidth = 0
    foreach ($item in $measureItems) { if ($item.StateLabel) { $stateWidth = [Math]::Max($stateWidth, ([string]$item.StateLabel).Length) } }
    $rows = New-Object System.Collections.Generic.List[object]
    $blankRow = { ,@(New-WtSeg -Text (' ' * $w) -Fg 'Gray') }
    $centered = { param([string]$Text, [string]$Fg)
        if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
        $pad = [Math]::Max(0, [Math]::Floor(($w - $Text.Length) / 2))
        ,@(New-WtSeg -Text ((' ' * $pad) + $Text + (' ' * ($w - $pad - $Text.Length))) -Fg $Fg)
    }

    $headerKey = [string]$Width + 'x' + [string]$w
    $header = $script:WtFrameHeaderCache[$headerKey]
    if ($null -eq $header) {
        $header = New-Object System.Collections.Generic.List[object]
        foreach ($b in (Get-WtBannerLines -Width $Width)) { $header.Add((& $centered $b 'Cyan')) }
        $header.Add((& $blankRow))
        $credit = @(Get-WtBannerCreditLines)
        $header.Add((& $centered ([string]$credit[0]) 'Gray'))
        $header.Add((& $centered ([string]$credit[1]) 'DarkGray'))
        $header.Add((& $blankRow))
        $script:WtFrameHeaderCache[$headerKey] = $header
    }
    foreach ($hr in $header) { $rows.Add($hr) }

    $searchable = ($null -ne $Search)
    $chromeCount = Get-WtFrameChromeHeight -Width $Width -ShowBanner $ShowBanner -Searchable $searchable -DescriptionRows $DescriptionRows
    $viewHeight = [Math]::Max(1, $Height - $chromeCount)
    if ($Layout -eq 'Compact') { $viewHeight = [Math]::Max(1, [Math]::Min($viewHeight, $measureItems.Count)) }
    $window = Get-WtViewportWindow -ItemCount $Items.Count -CursorIndex ([int]$State.CursorIndex) -ViewHeight $viewHeight -WindowStart ([int]$State.WindowStart)
    $listNumbers = 0
    foreach ($item in $measureItems) {
        $kind = [string]$item.Kind
        if ($kind -eq 'Check' -or $kind -eq 'Link' -or $kind -eq 'Action' -or $kind -eq 'Radio') { $listNumbers++ }
    }
    $numberWidth = [Math]::Max(1, ([string][Math]::Max(1, $listNumbers)).Length)
    $rangeText = ''
    if ($Items.Count -gt $viewHeight) {
        $rangeText = '{0}-{1}/{2}' -f ($window + 1), ([Math]::Min($window + $viewHeight, $Items.Count)), $Items.Count
    }
    $right = (@($CounterText, $rangeText) | Where-Object { $_ }) -join '  '
    $showPath = -not $ShowBanner
    $footerStatus = [string]$(if ($ShowBanner) { $rangeText })

    $bw = $w
    if ($Layout -eq 'Compact') {
        $needKey = [string][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($measureItems) + '|' + $measureItems.Count + '|' + $stateWidth + '|' + $numberWidth + '|' + $DescriptionRows + '|' + [string]$script:Language
        if ($script:WtCompactNeedKey -eq $needKey) { $need = [int]$script:WtCompactNeedValue }
        else {
            $need = 0
            foreach ($item in $measureItems) { $need = [Math]::Max($need, (Get-WtListRowNaturalWidth -Item $item -Glyphs $Glyphs -StateWidth $stateWidth -NumberWidth $numberWidth)) }
            if ($DescriptionRows -gt 0) {
                $longestDesc = 0
                foreach ($item in $measureItems) { $longestDesc = [Math]::Max($longestDesc, ([string]$item.Desc).Length) }
                if ($longestDesc -gt 0) { $need = [Math]::Max($need, [int][Math]::Ceiling($longestDesc / [double]$DescriptionRows) + 4) }
            }
            $script:WtCompactNeedKey = $needKey
            $script:WtCompactNeedValue = $need
        }
        if ($showPath) {
            $sizeRange = ''
            if ($measureItems.Count -gt $viewHeight) { $sizeRange = '{0}-{1}/{2}' -f ($measureItems.Count - $viewHeight + 1), $measureItems.Count, $measureItems.Count }
            $sizeRight = (@($CounterText, $sizeRange) | Where-Object { $_ }) -join '  '
            $need = [Math]::Max($need, ([string]$Breadcrumb).Length + [Math]::Max($right.Length, $sizeRight.Length) + 2)
        }
        if ($searchable) {
            $sLabel = (Get-Translation 'ListSearchLabel') + ': '
            $sValue = ([string](Get-Translation 'ListSearchPlaceholder')).Length
            $sTotal = Get-WtFocusableCount -Items $measureItems
            $sCount = ((Get-Translation 'ListSearchCount') -f $sTotal, $sTotal) + ' - ' + (Get-Translation 'ListSearchClearHint')
            $need = [Math]::Max($need, $sLabel.Length + $sValue + 2 + $sCount.Length)
        }
        $footerNeed = [Math]::Max(([string]$FooterText).Length, ([string]$FooterSizeText).Length)
        if ($footerStatus) { $footerNeed += 2 + $footerStatus.Length }
        $need = [Math]::Max($need, $footerNeed)
        $bw = [Math]::Min($w, [Math]::Max(40, $need + 2 + 4))
    }
    $inner = $bw - 4
    $lead = [Math]::Max(0, [Math]::Floor(($w - $bw) / 2))
    $trail = [Math]::Max(0, $w - $bw - $lead)
    $boxRow = { param([array]$Segs)
        $out = @()
        if ($lead -gt 0) { $out += @(New-WtSeg -Text (' ' * $lead) -Fg 'Gray') }
        $out += @($Segs)
        if ($trail -gt 0) { $out += @(New-WtSeg -Text (' ' * $trail) -Fg 'Gray') }
        ,$out
    }
    $hline = { param([string]$L, [string]$R) ,@(New-WtSeg -Text ($L + ($h * ($bw - 2)) + $R) -Fg 'Cyan') }

    $rows.Add((& $boxRow (& $hline $Glyphs.TL $Glyphs.TR)))

    if ($showPath) {
        $crumb = [string]$Breadcrumb
        $gap = $inner - $crumb.Length - $right.Length
        if ($gap -lt 1) {
            $room = [Math]::Max(0, $inner - $right.Length - 2)
            $crumb = $crumb.Substring(0, $room) + '~'
            $gap = 1
        }
        $rows.Add((& $boxRow @(
            New-WtSeg -Text ($v + ' ') -Fg 'Cyan'
            New-WtSeg -Text $crumb -Fg 'White'
            New-WtSeg -Text ((' ' * $gap) + $right) -Fg 'DarkGray'
            New-WtSeg -Text (' ' + $v) -Fg 'Cyan'
        )))
        $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
    }

    if ($searchable) {
        $searchSegs = @(Get-WtStoreSearchRowSegments -State $Search -Inner $inner -CountText ([string]$Search.CountText) `
            -Label (Get-Translation 'ListSearchLabel') -Placeholder (Get-Translation 'ListSearchPlaceholder'))
        $rows.Add((& $boxRow (@(New-WtSeg -Text ($v + ' ') -Fg 'Cyan') + $searchSegs + @(New-WtSeg -Text (' ' + $v) -Fg 'Cyan'))))
        $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
    }

    $rowNumber = 0
    for ($i = 0; $i -lt $window; $i++) {
        $kind = [string]$Items[$i].Kind
        if ($kind -eq 'Check' -or $kind -eq 'Link' -or $kind -eq 'Action' -or $kind -eq 'Radio') { $rowNumber++ }
    }
    $limit = [Math]::Min($window + $viewHeight, $Items.Count)
    for ($i = $window; $i -lt $limit; $i++) {
        $item = $Items[$i]
        $num = 0
        $kind = [string]$item.Kind
        if ($kind -eq 'Check' -or $kind -eq 'Link' -or $kind -eq 'Action' -or $kind -eq 'Radio') { $rowNumber++; $num = $rowNumber }
        $isCursor = ($i -eq [int]$State.CursorIndex)
        $pending = ''
        if ($State.ContainsKey('Cycle') -and $null -ne $State.Cycle -and $State.Cycle.ContainsKey([string]$item.Name)) {
            $target = [string]$State.Cycle[[string]$item.Name]
            $pending = $(if ($CycleLabels.ContainsKey($target)) { [string]$CycleLabels[$target] } else { $target })
        }
        $segs = Get-WtListRowSegments -Item $item -IsCursor $isCursor -Selected ($State.Selection.Contains($item.Name)) -Glyphs $Glyphs -Width $inner -VisibleNumber $num -StateWidth $stateWidth -NumberWidth $numberWidth -PendingLabel $pending
        $segLen = 0
        foreach ($s in $segs) { $segLen += ([string]$s.T).Length }
        if ($segLen -lt $inner) {
            $padSeg = if ($isCursor) { [PSCustomObject]@{ T = (' ' * ($inner - $segLen)); F = 'Black'; B = 'DarkCyan' } } else { [PSCustomObject]@{ T = (' ' * ($inner - $segLen)); F = 'Gray'; B = '' } }
            $segs = @($segs) + @($padSeg)
        }
        $rows.Add((& $boxRow (@([PSCustomObject]@{ T = ($v + ' '); F = 'Cyan'; B = '' }) + $segs + @([PSCustomObject]@{ T = (' ' + $v); F = 'Cyan'; B = '' }))))
    }
    for ($i = ($limit - $window); $i -lt $viewHeight; $i++) {
        $rows.Add((& $boxRow @(New-WtSeg -Text ($v + (' ' * ($bw - 2)) + $v) -Fg 'Cyan')))
    }

    if ($DescriptionRows -gt 0) {
        $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
        foreach ($line in (Get-WtFrameDescriptionLines -Items $Items -CursorIndex ([int]$State.CursorIndex) -Width $inner -Rows $DescriptionRows)) {
            $text = [string]$line
            if ($text.Length -gt $inner) { $text = $text.Substring(0, $inner) }
            $rows.Add((& $boxRow @(
                New-WtSeg -Text ($v + ' ') -Fg 'Cyan'
                New-WtSeg -Text ($text + (' ' * ($inner - $text.Length))) -Fg 'Gray'
                New-WtSeg -Text (' ' + $v) -Fg 'Cyan'
            )))
        }
    }

    $rows.Add((& $boxRow (& $hline $Glyphs.LT $Glyphs.RT)))
    $footer = [string]$FooterText
    $statusPart = ''
    if ($footerStatus) {
        if ($footerStatus.Length -gt $inner) { $footerStatus = $footerStatus.Substring(0, $inner) }
        $statusRoom = [Math]::Max(0, $inner - $footerStatus.Length - 2)
        if ($footer.Length -gt $statusRoom) { $footer = $(if ($statusRoom -gt 1) { $footer.Substring(0, $statusRoom - 1) + '~' } else { $footer.Substring(0, $statusRoom) }) }
        $statusPart = (' ' * [Math]::Max(0, $inner - $footer.Length - $footerStatus.Length)) + $footerStatus
    }
    elseif ($footer.Length -gt $inner) { $footer = $(if ($inner -gt 1) { $footer.Substring(0, $inner - 1) + '~' } else { $footer.Substring(0, $inner) }) }
    $rows.Add((& $boxRow @(
        New-WtSeg -Text ($v + ' ') -Fg 'Cyan'
        New-WtSeg -Text $footer -Fg 'Yellow'
        New-WtSeg -Text $statusPart -Fg 'Yellow'
        New-WtSeg -Text ((' ' * [Math]::Max(0, $inner - $footer.Length - $statusPart.Length)) + ' ' + $v) -Fg 'Cyan'
    )))
    $rows.Add((& $boxRow (& $hline $Glyphs.BL $Glyphs.BR)))

    while ($rows.Count -lt $Height) { $rows.Add((& $blankRow)) }
    return $rows.ToArray()
}
