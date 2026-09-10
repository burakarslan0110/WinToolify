# Invoke-WtListScreen - the generic list screen loop.
# Covered by: tests/Tui.Tests.ps1, tests/Screens.Tests.ps1

function Invoke-WtListScreen {
    <#
    .SYNOPSIS
        The one interactive loop: frame -> key batch -> reducer, until the
        reducer emits @{ Emit; Char; Item; Selection; CursorIndex }. With
        Searchable on, CursorIndex always indexes the caller's Items, not
        the filtered view shown while a query is active.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [bool]$MultiSelect = $false,
        [System.Collections.Generic.HashSet[string]]$Selection,
        [string]$FooterText = '',
        [scriptblock]$OnSelectionChanged,
        [bool]$ShowBanner = $false,
        [string]$CounterText = '',
        [int]$InitialCursor = -1,
        [ValidateSet('Full', 'Compact')][string]$Layout = 'Full',
        [hashtable]$Cycle,
        [hashtable]$CycleLabels = @{},
        [bool]$Searchable = $false,
        [int]$DescriptionRows = 0
    )
    if ($null -eq $Selection) { $Selection = New-Object 'System.Collections.Generic.HashSet[string]' }
    if ($null -eq $Cycle) { $Cycle = @{} }
    $cursor = 0
    $anyFocusable = $false
    foreach ($probe in $Items) { if (Test-WtItemFocusable -Item $probe) { $anyFocusable = $true; break } }
    if (-not $anyFocusable) {
        $cursor = -1
    }
    elseif ($InitialCursor -ge 0 -and $InitialCursor -lt $Items.Count -and (Test-WtItemFocusable -Item $Items[$InitialCursor])) { $cursor = $InitialCursor }
    elseif ($Items.Count -gt 0 -and -not (Test-WtItemFocusable -Item $Items[0])) {
        $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex 0 -Direction 1
    }
    $state = @{ CursorIndex = $cursor; WindowStart = 0; Selection = $Selection; Cycle = $Cycle; Focus = 'List'; Query = '' }
    $shown = $Items
    $result = { param($Emit, $Char, $Item)
        $at = [int]$state.CursorIndex
        if ($Searchable -and $at -ge 0 -and $at -lt $shown.Count) {
            $name = [string]$shown[$at].Name
            $at = -1
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ([string]::Equals([string]$Items[$i].Name, $name, [System.StringComparison]::Ordinal)) { $at = $i; break }
            }
        }
        @{ Emit = $Emit; Char = $Char; Item = $Item; Selection = $Selection; Cycle = $Cycle; CursorIndex = $at }
    }
    $hintFooter = ''
    $footerSize = [string]$FooterText
    if ($Searchable) {
        foreach ($candidate in @((Get-WtSearchableFooter -Footer $FooterText -Hint (Get-Translation 'ListSearchKeyHint')), (Get-Translation 'ListSearchFooter'))) {
            if (([string]$candidate).Length -gt $footerSize.Length) { $footerSize = [string]$candidate }
        }
    }

    while ($true) {
        $shown = $Items
        $search = $null
        if ($Searchable) {
            $q = [string]$state.Query
            $filtered = ($q.Trim() -ne '')
            if ($filtered) {
                $shown = @(Select-WtListItems -Items $Items -Query $q)
                if ($shown.Count -eq 0) { $shown = @(Get-WtListSearchEmptyItem) }
            }
            $countText = ''
            if ($filtered) {
                $countText = (Get-Translation 'ListSearchCount') -f (Get-WtFocusableCount -Items $shown), (Get-WtFocusableCount -Items $Items)
                if ([string]$state.Focus -ne 'Input') { $countText += ' - ' + (Get-Translation 'ListSearchClearHint') }
            }
            $search = @{ Focus = [string]$state.Focus; Query = $q; CountText = $countText }
            $state.CursorIndex = Get-WtValidListCursor -Items $shown -CursorIndex ([int]$state.CursorIndex)
        }
        $size = Get-WtConsoleSize
        $viewHeight = [Math]::Max(1, $size.Height - (Get-WtFrameChromeHeight -Width $size.Width -ShowBanner $ShowBanner -Searchable $Searchable -DescriptionRows $DescriptionRows))
        $counter = $CounterText
        if ($MultiSelect) {
            $marked = (Get-WtMarkSummary -Items $Items -Selection $Selection).Text
            $counter = (@($CounterText, $marked) | Where-Object { $_ }) -join '  '
        }
        $footer = if ($hintFooter) { $hintFooter }
                  elseif ($Searchable -and [string]$state.Focus -eq 'Input') { Get-Translation 'ListSearchFooter' }
                  elseif ($Searchable) { Get-WtSearchableFooter -Footer $FooterText -Hint (Get-Translation 'ListSearchKeyHint') }
                  else { $FooterText }
        $hintFooter = ''
        $frame = Get-WtFrameRows -Breadcrumb $Breadcrumb -Items $shown -State $state -Width $size.Width -Height $size.Height `
            -Glyphs $script:WtGlyphs -CounterText $counter -FooterText $footer -CycleLabels $CycleLabels `
            -LineMode ($script:WtInputMode -eq 'Line') -ShowBanner $ShowBanner -Layout $Layout -Search $search `
            -SizeItems $Items -FooterSizeText $footerSize -DescriptionRows $DescriptionRows
        Write-WtFrame -FrameLines $frame -Width $size.Width -Height $size.Height

        $before = (@($Selection) | Sort-Object) -join "`n"
        $converter = $null
        if ($Searchable -and [string]$state.Focus -eq 'Input') {
            $converter = { param($Key, $KeyChar) ConvertTo-WtGridKeyToken -Key $Key -KeyChar $KeyChar }
        }
        $tokens = Read-WtInputBatch -Converter $converter
        $r = Invoke-WtTokenBatch -State $state -Tokens $tokens -Items $shown -ViewHeight $viewHeight -MultiSelect $MultiSelect -Searchable $Searchable
        $state = $r.State
        $after = (@($Selection) | Sort-Object) -join "`n"
        if ($OnSelectionChanged -and $after -ne $before) { & $OnSelectionChanged }

        if ($r.Emit -eq 'Back') { return (& $result 'Back' '' $null) }
        if ($r.Emit -eq 'Refused') { $hintFooter = Get-Translation 'RemoveUnavailableHint'; continue }
        if ($r.Emit -eq 'Activate') {
            $item = if ($state.CursorIndex -ge 0 -and $state.CursorIndex -lt $shown.Count) { $shown[$state.CursorIndex] } else { $null }
            return (& $result 'Activate' '' $item)
        }
        if ($r.Emit -eq 'Global') {
            if ($r.EmitChar -eq 'q') { return (& $result 'Quit' '' $null) }
            return (& $result 'Global' $r.EmitChar $null)
        }
    }
}
