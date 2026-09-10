# Undo screen.
# Covered by: tests/Screens.Tests.ps1

function Get-WtRecordConsequence {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Record,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Sections
    )
    $section = $Sections | Where-Object Key -eq $Record.SectionKey | Select-Object -First 1
    if (-not $section -or -not $section.GetCatalog) { return '' }
    try {
        $entry = @(& $section.GetCatalog) | Where-Object Name -eq $Record.EntryName | Select-Object -First 1
        if ($entry -and ($entry.PSObject.Properties.Name -contains 'Consequence') -and $entry.Consequence) { return [string]$entry.Consequence }
    }
    catch { $null = $_ }
    return ''
}

# --- Undo / Profiles / Language screens ------------------------------------------

function Get-WtUndoScreenItems {
    <#
    .SYNOPSIS
        PURE: one Action row per undo entry (newest first), carrying the
        entry path; a single Info row when nothing is left to undo.
        Entries finished with - restored, or retired because another
        action wiped their state - are hidden here (Test-WtUndoEntryClosed)
        though the file stays on disk.
    #>
    param([AllowEmptyCollection()][array]$Entries = @(Get-WtUndoEntries))
    $pending = @(@($Entries) | Where-Object { -not (Test-WtUndoEntryClosed -Entry $_) })
    if ($pending.Count -eq 0) { return @(New-WtListItem -Kind 'Info' -Name 'UndoEmpty' -Label (Get-Translation 'UndoMenuEmpty')) }
    return @(foreach ($e in $pending) {
        New-WtListItem -Kind 'Action' -Name ([string]$e.Path) -Label (Format-WtUndoEntryLabel -Entry $e) -Data @{ EntryPath = [string]$e.Path; Action = [string]$e.Action; Entry = $e }
    })
}

$script:WtUndoLabelMemo = @{}

function Get-WtUndoCatalogLabel {
    <#
    .SYNOPSIS
        The localized catalog label behind one undo-record item - the
        text the user picked on the apply screen - or '' when no catalog
        knows it. A service is looked up by its template name (the
        per-user services carry a LUID suffix in Name), a package by
        name, others by CatalogEntry; first hit wins, a throwing catalog
        is skipped. Results are memoized per language and item, since a
        catalog can cost ~100ms to build and one record can hold a dozen
        items.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [AllowEmptyCollection()][array]$Sections = @(Get-WtApplySectionCatalog)
    )
    $names = @($Item.PSObject.Properties.Name)
    $type = [string]$Item.ItemType
    $only = @()
    $lookup = ''
    if ($type -eq 'Service') {
        $only = @('Services')
        $lookup = $(if (($names -contains 'Template') -and $Item.Template) { [string]$Item.Template } else { [string]$Item.Name })
    }
    elseif ($type -eq 'Package') {
        $only = @('Packages')
        $lookup = [string]$Item.Name
    }
    elseif (($names -contains 'CatalogEntry') -and $Item.CatalogEntry) {
        $lookup = [string]$Item.CatalogEntry
    }
    if (-not $lookup) { return '' }
    if ($null -eq $script:WtUndoLabelMemo) { $script:WtUndoLabelMemo = @{} }
    $memoKey = [string]$script:Language + '|' + $(if ($only.Count -gt 0) { $only[0] } else { 'Catalog' }) + '|' + $lookup
    if ($script:WtUndoLabelMemo.ContainsKey($memoKey)) { return [string]$script:WtUndoLabelMemo[$memoKey] }
    $label = ''
    foreach ($section in @($Sections)) {
        if ($null -eq $section) { continue }
        $key = [string]$section.Key
        if ($only.Count -gt 0) { if ($only -notcontains $key) { continue } }
        elseif ($key -eq 'Services' -or $key -eq 'Packages') { continue }
        if (-not $section.GetCatalog) { continue }
        $rows = @()
        try { $rows = @(& $section.GetCatalog) } catch { $rows = @() }
        foreach ($row in $rows) {
            if ($null -eq $row) { continue }
            if (-not [string]::Equals([string]$row.Name, $lookup, [System.StringComparison]::Ordinal)) { continue }
            if (($row.PSObject.Properties.Name -contains 'DisplayLabel') -and $row.DisplayLabel) { $label = [string]$row.DisplayLabel }
            break
        }
        if ($label) { break }
    }
    $script:WtUndoLabelMemo[$memoKey] = $label
    return $label
}

function Confirm-WtUndoRestore {
    <#
    .SYNOPSIS
        The undo confirm panel: the record's detail lines as a read-only
        compact box, Enter restores, Esc (and Q) cancel, any other key is
        ignored and the box stays. A read-only list, rather than a typed
        answer, lets a long record scroll with the arrow keys. Long lines
        are wrapped to the box; short ones keep their indent.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @()
    )
    $width = Get-WtPanelInnerWidth -Width ([int](Get-WtConsoleSize).Width)
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Lines)) {
        $pieces = @(ConvertTo-WtPanelLines -Lines @([string]$line) -Width $width -Risk 'CAUTION')
        if ($pieces.Count -le 1) { $rows.Add([string]$line) } else { foreach ($p in $pieces) { $rows.Add($p) } }
    }
    $items = @(Get-WtPanelItems -Lines $rows.ToArray() -Risk 'CAUTION')
    try {
        while ($true) {
            $r = Invoke-WtListScreen -Breadcrumb $Breadcrumb -Items $items -FooterText (Get-Translation 'UndoConfirmFooter') -Layout 'Compact'
            if ($r.Emit -eq 'Activate') { return $true }
            if ($r.Emit -eq 'Global') { continue }
            return $false
        }
    }
    finally { Reset-WtFrameCache }
}

function Invoke-WtUndoScreen {
    <#
    .SYNOPSIS
        Undo as a list screen: Enter on an entry opens the confirm panel
        (what the record changed, Enter = restore, Esc = cancel), restores
        through Restore-WtUndoEntry and shows per-item outcomes in the
        panel, each named the way the confirm panel named it. Two
        registry values of one catalog entry that both came back
        collapse into one "label: outcome" line, matching how the
        confirm panel listed them; a value with a different outcome
        keeps its own line.
    #>
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'UndoLastChange'
    $cursor = -1
    $resolve = { param($Item) Get-WtUndoCatalogLabel -Item $Item }
    while ($true) {
        $items = @(Get-WtUndoScreenItems)
        $r = Invoke-WtListScreen -Breadcrumb $crumb -Items $items -FooterText (Get-Translation 'UndoFooter') -InitialCursor $cursor -Layout 'Compact'
        $cursor = [int]$r.CursorIndex
        if ($r.Emit -eq 'Back') { return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false } }
        if ($r.Emit -eq 'Quit') { return @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
        if ($r.Emit -ne 'Activate' -or -not $r.Item -or $r.Item.Kind -ne 'Action') { continue }
        Show-WtListLoading -Breadcrumb $crumb
        $detail = @(Get-WtUndoEntryDetailLines -Entry $r.Item.Data.Entry -CatalogLabel $resolve)
        if (-not (Confirm-WtUndoRestore -Breadcrumb $crumb -Lines $detail)) { continue }
        $results = @(Restore-WtUndoEntry -EntryPath $r.Item.Data.EntryPath)
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(((Get-Translation 'UndoMenuResultsHeader') -f $r.Item.Data.Action))
        $listed = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
        foreach ($res in $results) {
            $label = switch ($res.Outcome) { 'Restored' { Get-Translation 'UndoResultRestored' } 'NotRestorable' { Get-Translation 'UndoResultNotRestorable' } default { Get-Translation 'UndoResultFailed' } }
            $name = $(if (($res.PSObject.Properties.Name -contains 'Item') -and $res.Item) { Get-WtUndoItemLabel -Item $res.Item -CatalogLabel $resolve } else { [string]$res.Name })
            $line = '  ' + $name + ': ' + $label
            if (-not $listed.Add($line)) { continue }
            $lines.Add($line)
        }
        $null = Read-WtPanelAnswer -Breadcrumb $crumb -Lines $lines.ToArray() -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
    }
}
