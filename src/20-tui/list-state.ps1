# Viewport, focus, cursor memory, radio groups, mark toggles, Update-WtListState, token batching.
# Covered by: tests/Tui.Tests.ps1, tests/CursorMemory.Tests.ps1, tests/RowState.Tests.ps1

function Get-WtViewportWindow {
    <#
    .SYNOPSIS
        Scroll-window math: given the cursor and previous window start,
        returns the new start so the cursor stays visible and the window
        never runs past either end. A negative CursorIndex means "no
        cursor" (read-only view): the window is honoured as-is, clamped.
    #>
    param(
        [Parameter(Mandatory)][int]$ItemCount,
        [Parameter(Mandatory)][int]$CursorIndex,
        [Parameter(Mandatory)][int]$ViewHeight,
        [Parameter(Mandatory)][int]$WindowStart
    )

    if ($ItemCount -le $ViewHeight) { return 0 }
    if ($CursorIndex -lt 0) { return [Math]::Max(0, [Math]::Min($WindowStart, $ItemCount - $ViewHeight)) }

    $start = $WindowStart
    if ($CursorIndex -lt $start) { $start = $CursorIndex }
    elseif ($CursorIndex -ge ($start + $ViewHeight)) { $start = $CursorIndex - $ViewHeight + 1 }

    return [Math]::Max(0, [Math]::Min($start, $ItemCount - $ViewHeight))
}

function Test-WtItemFocusable {
    param([Parameter(Mandatory)][PSCustomObject]$Item)
    return (@('Link', 'Action', 'Check', 'Radio') -contains $Item.Kind)
}

function Get-WtNextFocusableIndex {
    <#
    .SYNOPSIS
        The next focusable row index in the given direction (+1/-1),
        skipping Header/Info rows. Returns FromIndex unchanged when no
        focusable row exists in that direction (no wrap-around).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][int]$FromIndex,
        [Parameter(Mandatory)][ValidateSet(-1, 1)][int]$Direction
    )

    $i = $FromIndex + $Direction
    while ($i -ge 0 -and $i -lt $Items.Count) {
        if (Test-WtItemFocusable -Item $Items[$i]) { return $i }
        $i += $Direction
    }
    return $FromIndex
}

function Get-WtFocusableCount {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items)
    $n = 0
    foreach ($item in $Items) { if (Test-WtItemFocusable -Item $item) { $n++ } }
    return $n
}

function Get-WtValidListCursor {
    <#
    .SYNOPSIS
        PURE: the cursor a list can actually show - the given index when it
        lands on a focusable row, else the first focusable row, else -1
        (nothing to focus: a read-only page, or a filter that matched
        nothing). Keeps the highlight on a real row as the search box changes.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [int]$CursorIndex = -1
    )
    if ($CursorIndex -ge 0 -and $CursorIndex -lt $Items.Count -and (Test-WtItemFocusable -Item $Items[$CursorIndex])) { return $CursorIndex }
    for ($i = 0; $i -lt $Items.Count; $i++) { if (Test-WtItemFocusable -Item $Items[$i]) { return $i } }
    return -1
}

function Select-WtListItems {
    <#
    .SYNOPSIS
        PURE: the rows a search query leaves. Every word of the query has
        to occur in the row's label or state column, in any order, compared
        OrdinalIgnoreCase - never a culture compare, which on tr-TR folds I
        to the dotless i. A Header/Rule stays only when a row of its group
        matched. Uses -split, not .Split(), since PS7 binds that call to the
        (string, options) overload and joins the terms into one separator.
        Emitted bare: wrap the call in @(), or empty comes back $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [AllowNull()][AllowEmptyString()][string]$Query = ''
    )
    $terms = @((([string]$Query).Trim() -split '\s+') | Where-Object { $_ -ne '' })
    if ($terms.Count -eq 0) { return @($Items) }
    $out = New-Object System.Collections.Generic.List[object]
    $pendingHeader = $null
    $headerShown = $false
    $pendingSpacer = $null
    foreach ($item in $Items) {
        $kind = [string]$item.Kind
        if ($kind -eq 'Header' -or $kind -eq 'Rule') { $pendingHeader = $item; $headerShown = $false; continue }
        if ($kind -eq 'Spacer') { if ($out.Count -gt 0) { $pendingSpacer = $item }; continue }
        if (-not (Test-WtItemFocusable -Item $item)) { continue }
        $hay = [string]$item.Label + ' ' + [string]$item.StateLabel
        $hit = $true
        foreach ($term in $terms) {
            if ($hay.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $hit = $false; break }
        }
        if (-not $hit) { continue }
        if ($null -ne $pendingSpacer) { $out.Add($pendingSpacer); $pendingSpacer = $null }
        if ($null -ne $pendingHeader -and -not $headerShown) { $out.Add($pendingHeader); $headerShown = $true }
        $out.Add($item)
    }
    return $out.ToArray()
}

function Get-WtSearchableFooter {
    <#
    .SYNOPSIS
        PURE: a screen's navigation guide with the search key added: "/: ara"
        goes in front of the Esc item, so the guide reads doing-to-leaving. A
        footer without an Esc item is not a guide and comes back untouched.
        Ordinal IndexOf, never -replace, to avoid tr-TR casefolding.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Footer,
        [Parameter(Mandatory)][string]$Hint
    )
    $text = [string]$Footer
    $at = $text.IndexOf(' - Esc:', [System.StringComparison]::Ordinal)
    if ($at -lt 0) { return $text }
    return $text.Substring(0, $at) + ' - ' + $Hint + $text.Substring($at)
}

function Get-WtListSearchEmptyItem {
    <#
    .SYNOPSIS
        The one Info row a filter that matched nothing shows. The shape is
        New-WtListItem's, spelled out here so the TUI layer does not call
        up into the screens layer for it.
    #>
    return [PSCustomObject]@{
        Kind           = 'Info'
        Name           = 'ListSearchEmpty'
        Label          = [string](Get-Translation 'ListSearchEmpty')
        Risk           = $null
        StateLabel     = ''
        PendingVerbKey = ''
        Selectable     = $false
        Data           = $null
        Group          = ''
        Applied        = $false
        Removable      = $false
        RiskTag        = $true
        CycleTargets   = [string[]]@()
    }
}

$script:WtMainMenuCursor = $null

function Resolve-WtCursorIndex {
    <#
    .SYNOPSIS
        PURE: which row a re-entered list opens on, given the row NAME and
        INDEX it was left on (only the main menu restores this way). Name is
        tried first since rows can be added/dropped/moved between visits, and
        compared via Ordinal equality (not -eq) since tr-TR would fold a
        dotted/dotless I; a stale index is clamped and walked to the nearest
        focusable row, forward before backward, since the row above a group
        is usually its header or spacer. Returns -1 for "nothing to restore".
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [AllowEmptyString()][string]$Name = '',
        [int]$Index = -1
    )

    if ($Items.Count -eq 0) { return -1 }

    if ($Name) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ([string]::Equals([string]$Items[$i].Name, $Name, [System.StringComparison]::Ordinal) -and (Test-WtItemFocusable -Item $Items[$i])) {
                return $i
            }
        }
    }

    if ($Index -lt 0) { return -1 }

    $target = [Math]::Min($Index, $Items.Count - 1)
    if (Test-WtItemFocusable -Item $Items[$target]) { return $target }
    $forward = Get-WtNextFocusableIndex -Items $Items -FromIndex $target -Direction 1
    if ($forward -ne $target) { return $forward }
    $back = Get-WtNextFocusableIndex -Items $Items -FromIndex $target -Direction -1
    if ($back -ne $target) { return $back }
    return -1
}

function Get-WtMainMenuCursor {
    <#
    .SYNOPSIS
        The row the main menu was last left on, resolved against the rows
        it is about to show; -1 before the first visit. The main menu is
        the only screen that remembers a cursor - row names are
        language-independent ids, so the position survives a language switch.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items)
    if ($null -eq $script:WtMainMenuCursor) { return -1 }
    return (Resolve-WtCursorIndex -Items $Items -Name ([string]$script:WtMainMenuCursor.Name) -Index ([int]$script:WtMainMenuCursor.Index))
}

function Set-WtMainMenuCursor {
    <#
    .SYNOPSIS
        Records where the cursor stands so the next return to the main
        menu opens there, keeping both the row name and index (see
        Resolve-WtCursorIndex for why). A negative index means no cursor
        to remember.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][int]$Index
    )
    if ($Index -lt 0) { return }
    $name = if ($Index -lt $Items.Count) { [string]$Items[$Index].Name } else { '' }
    $script:WtMainMenuCursor = @{ Name = $name; Index = $Index }
}

function Get-WtItemGroup {
    param([Parameter(Mandatory)][PSCustomObject]$Item)
    if ($Item.PSObject.Properties.Name -contains 'Group' -and $Item.Group) { return [string]$Item.Group }
    return ''
}

function Set-WtRadioSelection {
    <#
    .SYNOPSIS
        Radio semantics scoped to a group: removes every Radio item of the
        SAME group from the selection, then adds the chosen one. Items in
        other groups (and all Check items) are untouched, so one screen can
        host a single-choice DNS block next to multi-select blocks.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SelectionSet,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][PSCustomObject]$Item
    )
    $group = Get-WtItemGroup -Item $Item
    foreach ($other in $Items) {
        if ($other.Kind -eq 'Radio' -and (Get-WtItemGroup -Item $other) -eq $group) { $SelectionSet.Remove([string]$other.Name) | Out-Null }
    }
    $SelectionSet.Add([string]$Item.Name) | Out-Null
}

function Test-WtNavToken {
    <#
    .SYNOPSIS
        Whether a token is a navigation key. Includes 'Left'/'Right'
        (grid-only; ConvertTo-WtKeyToken never emits them) so
        Read-WtInputBatch can drain horizontal auto-repeat the same way it
        drains vertical.
    #>
    param([Parameter(Mandatory)][string]$Token)
    return (@('Up', 'Down', 'Left', 'Right', 'PageUp', 'PageDown', 'Home', 'End') -contains $Token)
}

function Invoke-WtListMarkToggle {
    <#
    .SYNOPSIS
        Space / digit on one row. Check rows toggle their mark ("apply" on a
        not-applied row, "remove" on an applied one - the checkbox never
        encodes live state); Radio rows move their group's single mark. An
        applied, non-Removable Check row cannot be marked: returns 'Refused'
        so the shell shows the hint; 'None' otherwise.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Selection,
        [hashtable]$Cycle
    )
    $props = $Item.PSObject.Properties.Name
    if ($Item.Kind -eq 'Check') {
        $applied = ($props -contains 'Applied') -and [bool]$Item.Applied
        $removable = ($props -contains 'Removable') -and [bool]$Item.Removable
        if ($applied -and -not $removable) { return 'Refused' }
        $targets = @($(if ($props -contains 'CycleTargets') { $Item.CycleTargets } else { @() }))
        if ($targets.Count -gt 0 -and $null -ne $Cycle) {
            $name = [string]$Item.Name
            $at = if ($Cycle.ContainsKey($name)) { [Array]::IndexOf($targets, [string]$Cycle[$name]) } else { -1 }
            $next = $at + 1
            if ($next -ge $targets.Count) { $Cycle.Remove($name); $Selection.Remove($name) | Out-Null }
            else { $Cycle[$name] = [string]$targets[$next]; $Selection.Add($name) | Out-Null }
            return 'None'
        }
        Set-WtSelectionToggle -SelectionSet $Selection -Item $Item | Out-Null
    }
    elseif ($Item.Kind -eq 'Radio' -and $Item.Selectable) {
        Set-WtRadioSelection -SelectionSet $Selection -Items $Items -Item $Item
    }
    return 'None'
}

function Update-WtListState {
    <#
    .SYNOPSIS
        The pure list-screen reducer: one input token in, a new state and an
        emit out. The interactive shell (Invoke-WtListScreen) is a dumb loop
        around this; every navigation rule lives here where Pester can reach
        it. Movement keys scroll the window directly when nothing is
        focusable (no cursor to chase); the search-box branch runs before
        that check so an empty-match filter still answers '/' and Back. A
        Digit token counts position through the whole list, not just the
        page, via TryParse (line mode can hand it a digit run too long for
        a plain [int] cast). Returns
        @{ State = <same shape as input>; Emit = 'None'|'Activate'|'Refused'|'Back'|'Global'; EmitChar = [string] }.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [int]$ViewHeight = 10,
        [bool]$MultiSelect = $false,
        [bool]$Searchable = $false
    )

    $cursor = [int]$State.CursorIndex
    $window = [int]$State.WindowStart
    $selection = $State.Selection
    $cycle = $(if ($State.ContainsKey('Cycle') -and $null -ne $State.Cycle) { $State.Cycle } else { @{} })
    $focus = $(if ($State.ContainsKey('Focus') -and [string]$State.Focus -eq 'Input') { 'Input' } else { 'List' })
    $query = $(if ($State.ContainsKey('Query') -and $null -ne $State.Query) { [string]$State.Query } else { '' })
    $emit = 'None'
    $emitChar = ''
    $finish = { param([int]$c, [int]$w)
        @{
            State    = @{ CursorIndex = $c; WindowStart = $w; Selection = $selection; Cycle = $cycle; Focus = $focus; Query = $query }
            Emit     = $emit
            EmitChar = $emitChar
        }
    }

    if ($Searchable -and $focus -eq 'Input') {
        $moveWith = ''
        switch -Regex ($Token) {
            '^Eof$'        { $emit = 'Back' }
            '^(Esc|Back)$' { $focus = 'List'; $query = ''; $cursor = 0; $window = 0 }
            '^Enter$'      { $focus = 'List'; $cursor = 0; $window = 0 }
            '^Backspace$'  { if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) }; $cursor = 0; $window = 0 }
            '^Space$'      { $query += ' '; $cursor = 0; $window = 0 }
            '^Char:'       { $query += $Token.Substring(5); $cursor = 0; $window = 0 }
            '^Digit:'      { $query += $Token.Substring(6); $cursor = 0; $window = 0 }
            '^(Up|Down|PageUp|PageDown|Home|End)$' { $focus = 'List'; $moveWith = $Token }
        }
        if (-not $moveWith) { return (& $finish $cursor $window) }
        $Token = $moveWith
    }
    elseif ($Searchable) {
        if ($Token -eq 'Char:/') {
            $focus = 'Input'
            $query = ''
            return (& $finish 0 0)
        }
        if ($Token -eq 'Back' -and $query.Trim() -ne '') {
            $query = ''
            return (& $finish 0 0)
        }
    }

    $hasFocusable = $false
    foreach ($item in $Items) { if (Test-WtItemFocusable -Item $item) { $hasFocusable = $true; break } }
    if (-not $hasFocusable) {
        $maxStart = [Math]::Max(0, $Items.Count - $ViewHeight)
        switch -Regex ($Token) {
            '^Up$'       { $window-- }
            '^Down$'     { $window++ }
            '^PageUp$'   { $window -= $ViewHeight }
            '^PageDown$' { $window += $ViewHeight }
            '^Home$'     { $window = 0 }
            '^End$'      { $window = $maxStart }
            '^Enter$'    { $emit = 'Activate' }
            '^Back$'     { $emit = 'Back' }
            '^Eof$'      { $emit = 'Back' }
            '^Char:'     { $emit = 'Global'; $emitChar = $Token.Substring(5) }
        }
        $window = [Math]::Max(0, [Math]::Min($window, $maxStart))
        return (& $finish (-1) $window)
    }

    switch -Regex ($Token) {
        '^Up$'   { $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction -1 }
        '^Down$' { $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction 1 }
        '^Home$' {
            $cursor = -1
            $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction 1
            if ($cursor -lt 0) { $cursor = [int]$State.CursorIndex }
        }
        '^End$' {
            $cursor = $Items.Count
            $cursor = Get-WtNextFocusableIndex -Items $Items -FromIndex $cursor -Direction -1
            if ($cursor -ge $Items.Count) { $cursor = [int]$State.CursorIndex }
        }
        '^PageDown$' {
            $target = [Math]::Min($cursor + $ViewHeight, $Items.Count - 1)
            if (-not (Test-WtItemFocusable -Item $Items[$target])) {
                $target = Get-WtNextFocusableIndex -Items $Items -FromIndex $target -Direction -1
            }
            $cursor = $target
        }
        '^PageUp$' {
            $target = [Math]::Max($cursor - $ViewHeight, 0)
            if (-not (Test-WtItemFocusable -Item $Items[$target])) {
                $target = Get-WtNextFocusableIndex -Items $Items -FromIndex $target -Direction 1
            }
            $cursor = $target
        }
        '^Space$' {
            if ($cursor -ge 0 -and $cursor -lt $Items.Count) {
                $emit = Invoke-WtListMarkToggle -Item $Items[$cursor] -Items $Items -Selection $selection -Cycle $cycle
            }
        }
        '^Enter$' { $emit = 'Activate' }
        '^Back$'  { $emit = 'Back' }
        '^Eof$'   { $emit = 'Back' }
        '^Digit:' {
            $n = 0
            if ([int]::TryParse($Token.Substring(6), [ref]$n) -and $n -ge 1) {
                $seen = 0
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    if (-not (Test-WtItemFocusable -Item $Items[$i])) { continue }
                    $seen++
                    if ($seen -eq $n) {
                        $cursor = $i
                        $emit = Invoke-WtListMarkToggle -Item $Items[$cursor] -Items $Items -Selection $selection -Cycle $cycle
                        break
                    }
                }
            }
        }
        '^Char:a$' {
            if ($MultiSelect) {
                $limit = [Math]::Min($window + $ViewHeight, $Items.Count)
                for ($i = $window; $i -lt $limit; $i++) {
                    $item = $Items[$i]
                    $isApplied = ($item.PSObject.Properties.Name -contains 'Applied') -and [bool]$item.Applied
                    if ($item.Kind -eq 'Check' -and $item.Selectable -and -not $isApplied -and -not $selection.Contains($item.Name)) {
                        $selection.Add($item.Name) | Out-Null
                        $ct = @($(if ($item.PSObject.Properties.Name -contains 'CycleTargets') { $item.CycleTargets } else { @() }))
                        if ($ct.Count -gt 0) { $cycle[[string]$item.Name] = [string]$ct[0] }
                    }
                }
            }
            else { $emit = 'Global'; $emitChar = 'a' }
            break
        }
        '^Char:c$' {
            if ($MultiSelect) {
                $limit = [Math]::Min($window + $ViewHeight, $Items.Count)
                for ($i = $window; $i -lt $limit; $i++) {
                    if ($selection.Contains($Items[$i].Name)) { $selection.Remove($Items[$i].Name) | Out-Null }
                    if ($cycle.ContainsKey([string]$Items[$i].Name)) { $cycle.Remove([string]$Items[$i].Name) }
                }
            }
            else { $emit = 'Global'; $emitChar = 'c' }
            break
        }
        '^Char:' { $emit = 'Global'; $emitChar = $Token.Substring(5) }
    }

    $window = Get-WtViewportWindow -ItemCount $Items.Count -CursorIndex $cursor -ViewHeight $ViewHeight -WindowStart $window

    return (& $finish $cursor $window)
}

function Invoke-WtTokenBatch {
    <#
    .SYNOPSIS
        Runs a batch of input tokens through the pure reducer with NO
        rendering in between (that is how a held arrow key stays smooth:
        N reducer steps, one paint). Stops at the first emitting token;
        tokens after it are dropped on purpose (they were typed before
        the user saw the result).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [int]$ViewHeight = 10,
        [bool]$MultiSelect = $false,
        [bool]$Searchable = $false
    )
    $state = $State
    $emit = 'None'
    $emitChar = ''
    $processed = 0
    foreach ($token in $Tokens) {
        $r = Update-WtListState -State $state -Token $token -Items $Items -ViewHeight $ViewHeight -MultiSelect $MultiSelect -Searchable $Searchable
        $state = $r.State
        $processed++
        if ($r.Emit -ne 'None') { $emit = $r.Emit; $emitChar = $r.EmitChar; break }
    }
    return @{ State = $state; Emit = $emit; EmitChar = $emitChar; Processed = $processed }
}
