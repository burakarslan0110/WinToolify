# The assistant's tool handlers that ACT or talk to the screen: the
# suggestion sink, the tool-row runner, apply, and the digit-path helpers.
# Covered by: tests/AssistantActions.Tests.ps1, tests/AssistantRegistry.Tests.ps1

function Invoke-WtAssistantSuggest {
    <#
    .SYNOPSIS
        suggest_wintoolify: validates the ids, hands the entries to the
        screen through Context.OnSuggest and tells the model the NUMBER
        each accepted id got - the one the user will type.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Ids = @(),
        [Parameter(Mandatory)][hashtable]$Context
    )
    $resolved = Resolve-WtAssistantSuggestions -Ids $Ids
    if ($Context.OnSuggest) { & $Context.OnSuggest $resolved.Valid }
    $result = [ordered]@{}
    $n = 0
    foreach ($entry in @($resolved.Valid)) { $n++; $result[[string]$n] = [string]$entry.Id }
    if (@($resolved.Invalid).Count -gt 0) { $result['invalid'] = @($resolved.Invalid) }
    if ($n -eq 0 -and @($resolved.Invalid).Count -eq 0) { $result['error'] = 'no ids given'; $result['hint'] = 'pass ids from search_wintoolify' }
    return $result
}

function Get-WtAssistantOutputTail {
    param([AllowEmptyCollection()][string[]]$Lines = @(), [int]$Count = 200)
    $all = @($Lines)
    if ($all.Count -le $Count) { return [string[]]$all }
    return [string[]]@($all[($all.Count - $Count)..($all.Count - 1)])
}

function Invoke-WtAssistantToolRow {
    <#
    .SYNOPSIS
        The ONE way an Action/Info row runs from the assistant screen -
        only the user's DIGIT reaches this; the model has no tool that
        runs a row. Captured/Native rows run through the existing panel
        runners with -ShowResult replaced by a collector writing to
        $script:WtAssistantRowLines (no GetNewClosure, per repo rule).
        Runners run IN PLACE, with progress shown via the REPL spinner
        instead of a painted panel. Not-runnable entries are refused.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [AllowEmptyString()][string]$Breadcrumb = '',
        [scriptblock]$RunCaptured = { param($Data, $Crumb)
            $script:WtAssistantRowLines = @()
            Invoke-WtCapturedAction -Title ([string]$Data.Title) -Breadcrumb $Crumb -Action $Data.Action -Encoding $Data.Encoding `
                -ShowProgress { param($Lines, $Footer) Update-WtReplSpinner -Tail ([string[]]@(Get-WtAssistantOutputTail -Lines ([string[]]@($Lines)) -Count 6)) } `
                -ShowResult { param($Lines) $script:WtAssistantRowLines = @($Lines) }
            return @($script:WtAssistantRowLines)
        },
        [scriptblock]$RunNative = { param($Data, $Crumb)
            $script:WtAssistantRowLines = @()
            Invoke-WtCapturedNativeAction -FilePath ([string]$Data.FilePath) -Arguments ([string]$Data.Arguments) -Title ([string]$Data.Title) -Breadcrumb $Crumb -Encoding $Data.Encoding `
                -ShowProgress { param($Lines, $Footer) Update-WtReplSpinner -Tail ([string[]]@(Get-WtAssistantOutputTail -Lines ([string[]]@($Lines)) -Count 6)) } `
                -ShowResult { param($Lines) $script:WtAssistantRowLines = @($Lines) }
            return @($script:WtAssistantRowLines)
        }
    )
    if (-not $Entry.Runnable -or $null -eq $Entry.Item -or $null -eq $Entry.Item.Data) { return @{ Ran = $false; Lines = [string[]]@() } }
    $data = $Entry.Item.Data
    if (-not $data.Native -and -not $data.Captured) { return @{ Ran = $false; Lines = [string[]]@() } }
    $script:WtPanelBreadcrumb = $Breadcrumb
    $label = [string]((Get-Translation 'AsSpinRunning') -f [string]$data.Title)
    $ownSpinner = [bool]($script:WtReplMode -and ($null -eq $script:WtReplSpinner -or -not $script:WtReplSpinner.Active))
    if ($ownSpinner) { Show-WtReplSpinner -Label $label }
    elseif ($null -ne $script:WtReplSpinner) { $script:WtReplSpinner.Label = $label; Update-WtReplSpinner -Force }
    $lines = @()
    try {
        if ($data.Native) { $lines = @(& $RunNative $data $Breadcrumb) }
        else { $lines = @(& $RunCaptured $data $Breadcrumb) }
    }
    finally { if ($ownSpinner) { Hide-WtReplSpinner } }
    return @{ Ran = $true; Lines = [string[]]@($lines | ForEach-Object { [string]$_ }) }
}

function Invoke-WtAssistantApply {
    <#
    .SYNOPSIS
        The digit path's apply step: a toggle picked by NUMBER -> apply
        records -> the SAME gates and engine the screens use
        (Invoke-WtApplyGates asks the typed CONFIRM for ADVANCED through
        Context.ReadAnswer; the section delegates write the undo
        entries). Only Invoke-WtAssistantSuggestion calls this, after the
        user's own Enter/Esc confirms it - never a model tool call.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Ids = @(),
        [AllowEmptyString()][string]$Direction = 'apply',
        [AllowNull()][hashtable]$Targets = $null,
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowNull()][array]$Index = $null,
        [AllowNull()][array]$Sections = $null,
        [scriptblock]$Gates = $null,
        [scriptblock]$Engine = $null,
        [string]$TestRootOverride
    )
    if ($null -eq $Sections) { $Sections = @(Get-WtApplySectionCatalog) }
    $remove = [string]::Equals([string]$Direction, 'remove', [System.StringComparison]::OrdinalIgnoreCase)
    $recordDirection = $(if ($remove) { 'Remove' } else { 'Apply' })
    $failed = New-Object System.Collections.Generic.List[object]
    $records = New-Object System.Collections.Generic.List[object]
    $labels = @{}
    foreach ($id in @($Ids | ForEach-Object { [string]$_ } | Where-Object { $_ })) {
        $entry = Get-WtAssistantIndexEntry -Id $id -Index $Index
        if ($null -eq $entry) { $failed.Add([PSCustomObject]@{ id = $id; label = $id; error = 'unknown id (use search_wintoolify)' }); continue }
        $label = Get-WtAssistantIndexLabel -Entry $entry
        if ([string]$entry.Kind -ne 'Toggle') { $failed.Add([PSCustomObject]@{ id = $id; label = $label; error = 'not a setting' }); continue }
        if (-not $entry.Runnable) { $failed.Add([PSCustomObject]@{ id = $id; label = $label; error = 'not applicable from the chat - suggest it instead; its number opens the System Settings screen where the user picks it' }); continue }
        if ($remove -and -not $entry.Removable) { $failed.Add([PSCustomObject]@{ id = $id; label = $label; error = 'not removable (no Windows-default path for this entry)' }); continue }
        $catalogEntry = $entry.Entry
        $props = @($catalogEntry.PSObject.Properties.Name)
        $recordArgs = @{
            SectionKey       = [string]$entry.SectionKey
            EntryName        = [string]$catalogEntry.Name
            DisplayLabel     = $label
            Risk             = $(if ($props -contains 'Risk' -and $catalogEntry.Risk) { [string]$catalogEntry.Risk } else { 'SAFE' })
            RestartsExplorer = [bool](($props -contains 'RestartsExplorer') -and $catalogEntry.RestartsExplorer)
            RequiresReboot   = [bool](($props -contains 'RestartRequired') -and $catalogEntry.RestartRequired)
            Direction        = $recordDirection
        }
        if ($null -ne $Targets) {
            $target = ''
            if ($Targets.ContainsKey($id)) { $target = [string]$Targets[$id] }
            elseif ($Targets.ContainsKey([string]$catalogEntry.Name)) { $target = [string]$Targets[[string]$catalogEntry.Name] }
            if ($target) { $recordArgs['Data'] = @{ Target = $target } }
        }
        $records.Add((New-WtApplyRecord @recordArgs))
        $labels[[string]$entry.SectionKey + ':' + [string]$catalogEntry.Name] = $label
    }
    $empty = [PSCustomObject]@{ applied = @(); failed = @($failed.ToArray()); skipped = @(); undo_entry_id = ''; undo_entry_ids = @(); reboot_needed = $false; explorer_restart = $false }
    if ($records.Count -eq 0) { return $empty }

    $script:WtPanelBreadcrumb = [string]$(if ($Context.ContainsKey('Breadcrumb')) { $Context.Breadcrumb } else { '' })
    $readAnswer = $(if ($Context.ContainsKey('ReadAnswer') -and $Context.ReadAnswer) { $Context.ReadAnswer } else { { param($Lines, $Prompt, $Risk) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt $Prompt -Risk $Risk } })
    if ($null -eq $Gates) { $Gates = { param($Records) Invoke-WtApplyGates -Records $Records -Sections $Sections -ReadAnswer $readAnswer } }
    if ($null -eq $Engine) { $Engine = { param($Plan) Invoke-WtCommitChangeSet -Plan $Plan -Sections $Sections } }

    $before = @()
    try { $before = @(Get-WtUndoEntries -TestRootOverride $TestRootOverride | ForEach-Object { [string]$_.Id }) } catch { $before = @() }
    $gated = & $Gates $records.ToArray()
    $skipped = @(foreach ($d in @($gated.Dropped)) { @($d.Labels) })
    $plan = $gated.Plan
    $planned = 0
    foreach ($s in @($plan.Sections)) { $planned += @($s.EntryNames).Count }
    if ($planned -eq 0) { $empty.skipped = @($skipped); return $empty }

    $result = & $Engine $plan
    $applied = New-Object System.Collections.Generic.List[object]
    foreach ($sectionResult in @($result.Sections)) {
        foreach ($row in @($sectionResult.Results)) {
            $rowId = [string]$sectionResult.Key + ':' + [string]$row.Item.Name
            $rowLabel = $(if ($labels.ContainsKey($rowId)) { $labels[$rowId] } else { [string]$row.Item.Name })
            if ($row.Applied) { $applied.Add([PSCustomObject]@{ id = $rowId; label = $rowLabel }) }
            else { $failed.Add([PSCustomObject]@{ id = $rowId; label = $rowLabel; error = [string]$row.Error }) }
        }
        if ([string]$sectionResult.Outcome -eq 'Skipped') {
            foreach ($n in @(@($plan.Sections) | Where-Object Key -eq $sectionResult.Key | ForEach-Object EntryNames)) { $skipped += @([string]$n) }
        }
    }
    $after = @()
    try { $after = @(Get-WtUndoEntries -TestRootOverride $TestRootOverride | ForEach-Object { [string]$_.Id }) } catch { $after = @() }
    $newIds = @($after | Where-Object { $before -notcontains $_ })

    if ($Context.ContainsKey('OnApplied') -and $Context.OnApplied) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($a in $applied) { $lines.Add(((Get-Translation 'AsApplied') -f [string]$a.label)) }
        foreach ($f in $failed) { $lines.Add(((Get-Translation 'AsApplyFailed') -f [string]$f.label, [string]$f.error)) }
        try { & $Context.OnApplied ([string[]]$lines.ToArray()) } catch { $null = $_ }
    }
    return [PSCustomObject]@{
        applied = @($applied.ToArray())
        failed = @($failed.ToArray())
        skipped = @($skipped)
        undo_entry_id = [string]$(if ($newIds.Count -gt 0) { $newIds[0] } else { '' })
        undo_entry_ids = @($newIds)
        reboot_needed = ($null -ne $result.RebootEntryNames -and @($result.RebootEntryNames).Count -gt 0)
        explorer_restart = [bool]$result.NeedsExplorerRestart
    }
}

function Invoke-WtAssistantSaveNote {
    <#
    .SYNOPSIS
        save_note: one short fact into facts.json, masked before writing
        (every text that reaches the model or disk passes
        Protect-WtAssistantText) so the transcript shows what the model
        decided to remember. The screen hears it through
        Context.OnNoteSaved.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory)][hashtable]$Context
    )
    $mask = $(if ($Context.ContainsKey('Mask') -and $null -ne $Context.Mask) { $Context.Mask } else { Get-WtAssistantMaskContext })
    $maskedText = Protect-WtAssistantText -Text ([string]$Text) -Mask $mask
    $addArgs = @{ Text = $maskedText }
    if ($Context.ContainsKey('TestRootOverride') -and [string]$Context.TestRootOverride) { $addArgs['TestRootOverride'] = [string]$Context.TestRootOverride }
    $r = Add-WtAssistantNote @addArgs
    if (-not $r.Saved) { return @{ error = 'empty note' } }
    if ($Context.ContainsKey('OnNoteSaved') -and $null -ne $Context.OnNoteSaved) { try { & $Context.OnNoteSaved ([string]$r.Text) } catch { $null = $_ } }
    return [ordered]@{ saved = $true; note_count = [int]$r.Count; dropped_oldest = [bool]$r.Dropped }
}

function Get-WtAssistantDigitConfirmLines {
    <#
    .SYNOPSIS
        What the user sees before a toggle they picked by number is
        applied: the label, what it changes, the risk word - the same
        three facts the suggestion card showed, on one confirm line set.
    #>
    param([Parameter(Mandatory)]$Entry)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-WtAssistantIndexLabel -Entry $Entry))
    $what = Get-WtAssistantEntryWhat -Entry $Entry -Max 200
    if ($what) { $lines.Add($what) }
    $risk = [string]$Entry.Risk
    if ($risk) { $lines.Add([string](Get-Translation ('Risk' + $risk))) }
    return [string[]]$lines.ToArray()
}

function Format-WtAssistantRunNote {
    <#
    .SYNOPSIS
        The one line the model learns about a suggestion the user ran by
        number: masked, single-line, at most 200 characters. It is
        prepended to the NEXT user message - never recorded as a tool
        call the model did not make.
    #>
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Outcome,
        [AllowNull()][hashtable]$Mask = $null
    )
    $text = '(note: user ran ' + $Number + ' ' + $Id + ' -> ' + $Outcome + ')'
    $text = [regex]::Replace($text, '[\r\n\t]+', ' ')
    if ($null -ne $Mask) { $text = Protect-WtAssistantText -Text $text -Mask $Mask }
    if ($text.Length -gt 200) { $text = $text.Substring(0, 199) + ')' }
    return $text
}

function Get-WtAssistantReportLines {
    <#
    .SYNOPSIS
        PURE: what a tool row printed, shaped for the model: CR and tab
        become spaces, blank lines and bare rule lines ("-----", "=====")
        are dropped, a run of two or more
        spaces becomes the " | " the tool serializer already uses between
        columns - so a fixed-width table keeps its cell boundaries instead
        of merging neighbouring cells into one phrase - and every line is
        masked when a mask is given.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [AllowNull()][hashtable]$Mask = $null
    )
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Lines)) {
        $t = ([string]$raw).Replace("`r", ' ').Replace("`t", ' ').Trim()
        if (-not $t) { continue }
        if ($t -cmatch '^[-=_ ]+$') { continue }
        $t = [regex]::Replace($t, ' {2,}', ' | ')
        if ($null -ne $Mask) { $t = Protect-WtAssistantText -Text $t -Mask $Mask }
        $out.Add($t)
    }
    return [string[]]$out.ToArray()
}

function Format-WtAssistantRunReport {
    <#
    .SYNOPSIS
        The report turn's message body: one header line the system
        prompt keys on ("(result of N label, M lines; ..."), the live
        card as "numbers on screen: 1 A; 2 B" so the model can point at a
        next step the user can type, then the cleaned, masked output -
        cut at a LINE boundary under -MaxChars with an "omitted: N
        lines" line, like a tool result ("output: (none)" when empty).
        Measured in two passes since a mask token can be longer than the
        value it replaced - the cap applies to what actually goes out.
    #>
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [AllowEmptyCollection()][string[]]$Numbers = @(),
        [int]$MaxChars = 2500,
        [AllowNull()][hashtable]$Mask = $null
    )
    $name = [regex]::Replace([string]$Label, '[\r\n\t]+', ' ').Trim()
    if ($name.Length -gt 80) { $name = $name.Substring(0, 79) + '~' }
    $rows = @(Get-WtAssistantReportLines -Lines $Lines)
    $header = '(result of ' + $Number + ' ' + $name + ', ' + $rows.Count + ' lines; explain it, do not repeat it)'
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($header)
    $used = $header.Length + 1
    $cardRows = @($Numbers | Where-Object { [string]$_ })
    if ($cardRows.Count -gt 0) {
        $card = 'numbers on screen: ' + (@($cardRows | ForEach-Object { [string]$_ }) -join '; ')
        if ($null -ne $Mask) { $card = Protect-WtAssistantText -Text $card -Mask $Mask }
        if ($card.Length -gt 200) { $card = $card.Substring(0, 199) + '~' }
        $out.Add($card)
        $used += $card.Length + 1
    }
    if ($rows.Count -eq 0) { $out.Add('output: (none)'); return ($out.ToArray() -join "`n") }
    $budget = $MaxChars - 40
    $candidates = New-Object System.Collections.Generic.List[string]
    $probe = $used
    foreach ($row in $rows) {
        if ($MaxChars -gt 0 -and ($probe + $row.Length + 1) -gt $budget) { break }
        $candidates.Add($row)
        $probe += $row.Length + 1
    }
    $kept = 0
    foreach ($row in $candidates) {
        $masked = $(if ($null -ne $Mask) { Protect-WtAssistantText -Text $row -Mask $Mask } else { $row })
        if ($MaxChars -gt 0 -and ($used + $masked.Length + 1) -gt $budget) { break }
        $out.Add($masked)
        $used += $masked.Length + 1
        $kept++
    }
    if ($kept -lt $rows.Count) { $out.Add('omitted: ' + ($rows.Count - $kept) + ' lines') }
    return ($out.ToArray() -join "`n")
}

function Get-WtAssistantApplyReportLines {
    <#
    .SYNOPSIS
        PURE: an Invoke-WtAssistantApply result as report lines - the
        same applied / failed sentences the transcript shows, "skipped:"
        per entry (a catalog name rather than a label when a whole
        section was skipped), then the reboot and Explorer flags.
        Null-safe: a missing or empty field adds nothing - @($null).Count
        is 1 in PS 5.1, so every collection is filtered, never counted.
    #>
    param([AllowNull()]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Result) { return [string[]]@() }
    foreach ($a in @($Result.applied | Where-Object { $null -ne $_ })) { $lines.Add(((Get-Translation 'AsApplied') -f [string]$a.label)) }
    foreach ($f in @($Result.failed | Where-Object { $null -ne $_ })) { $lines.Add(((Get-Translation 'AsApplyFailed') -f [string]$f.label, [string]$f.error)) }
    foreach ($s in @($Result.skipped | Where-Object { $null -ne $_ -and [string]$_ })) { $lines.Add('skipped: ' + [string]$s) }
    if ($Result.reboot_needed) { $lines.Add('reboot needed: yes') }
    if ($Result.explorer_restart) { $lines.Add('explorer restarted: yes') }
    return [string[]]$lines.ToArray()
}

function Format-WtAssistantLooseNumberNote {
    <#
    .SYNOPSIS
        PURE: the note that rides a lone digit the card cannot answer -
        no list at all, or a number past the end of the one on screen.
        English like every note; the live labels
        ride along (cut at 200) so the model can name what IS there
        instead of inventing a list of its own.
    #>
    param(
        [Parameter(Mandatory)][int]$Number,
        [AllowEmptyCollection()][string[]]$Numbers = @()
    )
    $cardRows = @($Numbers | Where-Object { [string]$_ })
    if ($cardRows.Count -eq 0) {
        return ('(note: the user typed ' + $Number + ' but no numbered suggestion list is active - if it refers to an entry you listed, call search_wintoolify then suggest_wintoolify now so it gets a real number; otherwise treat ' + $Number + ' as their reply)')
    }
    $list = (@($cardRows | ForEach-Object { [string]$_ }) -join '; ')
    if ($list.Length -gt 200) { $list = $list.Substring(0, 199) + '~' }
    return ('(note: the user typed ' + $Number + ' but the numbers on screen are 1-' + $cardRows.Count + ': ' + $list + ' - if they mean something else you listed, call search_wintoolify then suggest_wintoolify; otherwise ask which one)')
}
