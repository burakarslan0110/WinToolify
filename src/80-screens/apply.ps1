# Apply screen items, result lines/counts, Invoke-WtApplySelection, Invoke-WtApplyScreen.
# Covered by: tests/ApplyFlow.Tests.ps1, tests/Screens.Tests.ps1

function Test-WtEntryRemovable {
    <#
    .SYNOPSIS
        PURE: can this screen turn an applied entry back to its Windows
        default? Only when its section has a TurnOff delegate and (if the
        section defines IsRemovable) that delegate agrees for the entry.
    #>
    param(
        [AllowNull()][object]$Section,
        [Parameter(Mandatory)][PSCustomObject]$Entry
    )
    if ($null -eq $Section -or -not $Section.TurnOff) { return $false }
    if ($Section.IsRemovable) { return [bool](& $Section.IsRemovable $Entry) }
    return $true
}

function Get-WtApplyScreenItems {
    <#
    .SYNOPSIS
        PURE builder for an apply screen: turns catalog groups into
        Header/Info/Check(or Radio) rows plus a Meta map (Name ->
        SectionKey/Entry/Data) for the apply step. Delegates take the group
        as an argument, not a closure, since GetNewClosure breaks once built.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Groups,
        [array]$Sections = (Get-WtApplySectionCatalog)
    )
    $items = New-Object System.Collections.Generic.List[object]
    $meta = @{}
    foreach ($group in $Groups) {
        $sectionKey = [string]$group.SectionKey
        $section = $Sections | Where-Object Key -eq $sectionKey | Select-Object -First 1
        if ($group.HeaderKey) {
            $items.Add((New-WtListItem -Kind 'Header' -Name ('Header:' + $sectionKey) -Label (Get-Translation $group.HeaderKey)))
        }
        if ($group.InfoKey) {
            $items.Add((New-WtListItem -Kind 'Info' -Name ('Info:' + $sectionKey) -Label (Get-Translation $group.InfoKey)))
        }
        $kind = if ($group.Radio) { 'Radio' } else { 'Check' }
        $radioGroup = if ($group.Radio) { $sectionKey } else { '' }
        $lastSub = $null
        foreach ($entry in @(& $group.GetCatalog $group)) {
            if ($group.HeaderField -and ($entry.PSObject.Properties.Name -contains $group.HeaderField)) {
                $sub = [string]$entry.($group.HeaderField)
                if ($sub -and $sub -ne $lastSub) {
                    $items.Add((New-WtListItem -Kind 'Header' -Name ('Header:' + $sectionKey + ':' + $sub) -Label (Get-Translation $sub)))
                    $lastSub = $sub
                }
            }
            $state = & $group.GetEntryState $entry $group
            $applied = [bool]$state.Applied
            $available = if ($null -ne $state.Available) { [bool]$state.Available } else { $true }
            $stateLabel = if ($null -ne $state.StateLabel) { [string]$state.StateLabel }
                          elseif ($applied) { Get-Translation 'Applied' }
                          else { Get-Translation 'NotApplied' }
            $risk = if ($entry.PSObject.Properties.Name -contains 'Risk' -and $entry.Risk) { [string]$entry.Risk } else { '' }
            $removable = $applied -and (Test-WtEntryRemovable -Section $section -Entry $entry) -and $available
            $targets = @($(if ($entry.PSObject.Properties.Name -contains 'CycleTargets') { $entry.CycleTargets } else { @() }))
            $verbKey = $(if ($entry.PSObject.Properties.Name -contains 'PendingVerbKey') { [string]$entry.PendingVerbKey } else { '' })
            $items.Add((New-WtListItem -Kind $kind -Name $entry.Name -Label (Get-WtSelectorDisplayLabel -Entry $entry) `
                -Risk $risk -StateLabel $stateLabel -Selectable ($available -and (-not $applied -or $removable)) -Data $entry -Group $radioGroup `
                -Applied $applied -Removable $removable -CycleTargets $targets -PendingVerbKey $verbKey))
            $meta[[string]$entry.Name] = @{ SectionKey = $sectionKey; Entry = $entry; Data = $group.Data }
        }
    }
    return @{ Items = (Add-WtListGroupSpacers -Items $items.ToArray()); Meta = $meta }
}

function Get-WtApplyResultLines {
    <#
    .SYNOPSIS
        PURE formatter for the engine result: section title, then one line
        per row ("<label>: Applied" / "<label>: Not applied - <error>"). An
        Aborted section that already wrote rows before aborting prints those
        rows first, then the cancelled line, so the user sees what was written.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [array]$Sections = (Get-WtApplySectionCatalog)
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Result.Aborted -and @($Result.Sections).Count -eq 0) {
        $lines.Add((Get-Translation 'ActionCancelled'))
        return [string[]]$lines.ToArray()
    }
    $formatRow = {
        param($row)
        $isRemove = ($row.PSObject.Properties.Name -contains 'Direction') -and ([string]$row.Direction -eq 'Remove')
        $statusText = if ($isRemove) { if ($row.Applied) { Get-Translation 'Removed' } else { Get-Translation 'NotRemoved' } }
                      else { if ($row.Applied) { Get-Translation 'Applied' } else { Get-Translation 'NotApplied' } }
        if (-not $row.Applied -and $row.Error) { $statusText = "$statusText - $($row.Error)" }
        return '  ' + (Format-WtProfileResultLabel -Item $row.Item) + ': ' + $statusText
    }
    foreach ($sectionResult in @($Result.Sections)) {
        if ($sectionResult.Outcome -eq 'NothingToApply') { continue }
        $lines.Add([string](Get-Translation $sectionResult.TitleKey))
        switch ($sectionResult.Outcome) {
            'Aborted' {
                foreach ($row in @($sectionResult.Results)) { $lines.Add((& $formatRow $row)) }
                $lines.Add('  ' + (Get-Translation 'ActionCancelled'))
            }
            'Skipped' { $lines.Add('  ' + (Get-Translation 'ProfileImportStopped')) }
            default {
                foreach ($row in @($sectionResult.Results)) { $lines.Add((& $formatRow $row)) }
            }
        }
    }
    return [string[]]$lines.ToArray()
}

function Get-WtApplyResultCounts {
    <#
    .SYNOPSIS
        PURE: rows applied (Apply direction, Applied), removed (Remove
        direction, Applied) and failed (either direction, not Applied)
        across every section of an engine result.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    $applied = 0
    $removed = 0
    $failed = 0
    foreach ($sectionResult in @($Result.Sections)) {
        foreach ($row in @($sectionResult.Results)) {
            $isRemove = ($row.PSObject.Properties.Name -contains 'Direction') -and ([string]$row.Direction -eq 'Remove')
            if (-not $row.Applied) { $failed++ }
            elseif ($isRemove) { $removed++ }
            else { $applied++ }
        }
    }
    return @{ Applied = $applied; Removed = $removed; Failed = $failed }
}

function Invoke-WtApplySelection {
    <#
    .SYNOPSIS
        The apply flow of one screen, entirely inside the panel: marks ->
        gates -> summary with Enter-to-apply -> engine (in-panel progress)
        -> result lines -> Explorer-restart offer -> reboot note.
        Collaborators are injectable. Typing CONFIRM / ONAYLA / YES / EVET
        skips the summary step and applies immediately. The default
        -Engine/-OnSectionStart close over $progress/$Sections/$ShowMessage
        via dynamic scope, not GetNewClosure - codebase convention.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Selection,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Meta,
        [AllowEmptyCollection()][array]$Items = @(),
        [hashtable]$Cycle = @{},
        [array]$Sections = (Get-WtApplySectionCatalog),
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt, $Risk) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt $Prompt -Risk $Risk },
        [scriptblock]$ShowMessage = { param($Lines, $Footer) Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -FooterText $Footer },
        [scriptblock]$Engine = {
            param($Plan)
            Invoke-WtCommitChangeSet -Plan $Plan -Sections $Sections `
                -OnSectionStart {
                    param($Key)
                    $section = $Sections | Where-Object Key -eq $Key | Select-Object -First 1
                    $title = if ($section) { Get-Translation $section.TitleKey } else { $Key }
                    $progress.Add(((Get-Translation 'CommitSectionStart') -f $title))
                    & $ShowMessage $progress.ToArray() (Get-Translation 'ApplyingFooter')
                }
        },
        [scriptblock]$RestartExplorer = { Invoke-WtRestartExplorer }
    )
    $script:WtPanelBreadcrumb = $Breadcrumb
    $records = @(ConvertTo-WtApplyRecords -Selection $Selection -Meta $Meta -Items $Items -Cycle $Cycle)
    if ($records.Count -eq 0) { return @{ Applied = $false } }

    $gated = Invoke-WtApplyGates -Records $records -Sections $Sections -ReadAnswer $ReadAnswer
    $plan = $gated.Plan
    $totalApply = 0
    $totalRemove = 0
    foreach ($s in @($plan.Sections)) { $totalApply += @($s.ApplyNames).Count; $totalRemove += @($s.RemoveNames).Count }
    $refusal = @(Get-WtGateRefusalLines -Dropped @($gated.Dropped))
    if (($totalApply + $totalRemove) -eq 0) {
        $nothing = New-Object System.Collections.Generic.List[string]
        foreach ($l in $refusal) { $nothing.Add($l) }
        if ($nothing.Count -gt 0) { $nothing.Add('') }
        $nothing.Add((Get-Translation 'ApplyNothingLeft'))
        $null = & $ReadAnswer $nothing.ToArray() (Get-Translation 'PressEnterContinue') 'CAUTION'
        return @{ Applied = $false }
    }

    if (-not $gated.TypedConfirmation -or $refusal.Count -gt 0) {
        $summary = New-Object System.Collections.Generic.List[string]
        foreach ($l in $refusal) { $summary.Add($l) }
        if ($refusal.Count -gt 0) { $summary.Add('') }
        $summary.Add((Get-Translation 'CommitSummaryTitle'))
        $summary.Add('')
        foreach ($s in @($plan.Sections)) { $summary.Add(('  {0}: {1}' -f (Get-Translation $s.TitleKey), (Format-WtDirectionCounts -ApplyCount @($s.ApplyNames).Count -RemoveCount @($s.RemoveNames).Count))) }
        if ($plan.HasExplorerRestart) { $summary.Add(''); $summary.Add((Get-Translation 'CommitExplorerNote')) }
        if (@($plan.RebootEntryNames).Count -gt 0) { $summary.Add(((Get-Translation 'RebootRequiredNote') -f (@($plan.RebootEntryNames) -join ', '))) }
        $answer = & $ReadAnswer $summary.ToArray() ((Get-Translation 'ApplyNowPrompt') -f (Format-WtDirectionCounts -ApplyCount $totalApply -RemoveCount $totalRemove)) ''
        if ($null -eq $answer -or ([string]$answer).Trim() -ne '') { return @{ Applied = $false } }
    }

    $progress = New-Object System.Collections.Generic.List[string]
    $result = & $Engine $plan

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in @(Get-WtApplyResultLines -Result $result -Sections $Sections)) { $lines.Add($l) }
    if ($result.NeedsExplorerRestart) {
        $a = & $ReadAnswer $lines.ToArray() (Get-WtYesNoPrompt -Text (Get-Translation 'RestartExplorerPrompt')) ''
        if (Test-WtAffirmativeAnswer -Answer ([string]$a)) {
            $rs = & $RestartExplorer
            $lines.Add($(if ($rs -and $rs.Restarted) { Get-Translation 'RestartExplorerDone' } else { Get-Translation 'RestartExplorerFailed' }))
        }
        else { $lines.Add((Get-Translation 'RestartExplorerDeferred')) }
    }
    if (@($result.RebootEntryNames).Count -gt 0) { $lines.Add(((Get-Translation 'RebootRequiredNote') -f (@($result.RebootEntryNames) -join ', '))) }
    $counts = Get-WtApplyResultCounts -Result $result
    if (($counts.Applied + $counts.Removed + $counts.Failed) -gt 0) { $lines.Add(((Get-Translation 'ApplyDoneSummary') -f $counts.Applied, $counts.Removed, $counts.Failed)) }
    $applied = (@($result.Sections | Where-Object { $_.Outcome -eq 'Applied' }).Count -gt 0)
    if ($applied) { $lines.Add(''); $lines.Add((Get-Translation 'ApplySummaryDone')) }
    $null = & $ReadAnswer $lines.ToArray() (Get-Translation 'PressEnterContinue') ''
    return @{ Applied = $applied }
}

function Invoke-WtApplyScreen {
    <#
    .SYNOPSIS
        Shell shared by every "mark with Space, apply with Enter" screen:
        builds rows, runs the multi-select list, applies marks, rebuilds.
        -Groups/-ExtraItems take an array or a scriptblock re-resolved each
        rebuild; ExtraItems sit above the catalog (Link rows push a screen,
        Action rows run in console-output mode). A delegate's "return @()"
        binds $null in argument position, not an empty array, so $null here
        means "no extras". Returns
        @{ Nav = 'Back'|'Exit'|'Push'; Target; Char; HasMarks }.
    #>
    param(
        [Parameter(Mandatory)][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][object]$Groups,
        [AllowEmptyCollection()][object]$ExtraItems = @(),
        [string]$CounterKey = 'SettingsCount',
        [string]$FooterKey = 'ApplyFooter',
        [scriptblock]$OnHotkey,
        [hashtable]$CycleLabels = @{}
    )
    $cursor = -1
    while ($true) {
        Show-WtListLoading -Breadcrumb $Breadcrumb
        if ($Groups -is [scriptblock]) { $groupList = @(& $Groups) } else { $groupList = @($Groups) }
        if ($ExtraItems -is [scriptblock]) { $extraList = @(& $ExtraItems) }
        elseif ($null -eq $ExtraItems) { $extraList = @() }
        else { $extraList = @($ExtraItems) }
        $extraList = @($extraList | Where-Object { $null -ne $_ })
        $built = Get-WtApplyScreenItems -Groups $groupList
        $items = @($extraList) + @($built.Items)
        if ($items.Count -eq 0) { $items = @(New-WtListItem -Kind 'Info' -Name 'Empty' -Label (Get-Translation 'NoEntriesAvailable')) }
        $selection = New-Object 'System.Collections.Generic.HashSet[string]'
        $cycle = @{}
        $footer = Get-Translation $FooterKey
        $settingCount = @($built.Items | Where-Object { $_.Kind -eq 'Check' -or $_.Kind -eq 'Radio' }).Count
        $counter = (Get-Translation $CounterKey) -f $settingCount
        $rebuild = $false
        while (-not $rebuild) {
            $r = Invoke-WtListScreen -Breadcrumb $Breadcrumb -Items $items -MultiSelect $true -Selection $selection -FooterText $footer -CounterText $counter -InitialCursor $cursor -Cycle $cycle -CycleLabels $CycleLabels -Searchable $true
            $cursor = [int]$r.CursorIndex
            if ($r.Emit -eq 'Back') { return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false } }
            if ($r.Emit -eq 'Quit') { return @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = ($selection.Count -gt 0) } }
            if ($r.Emit -eq 'Global') {
                if ($OnHotkey -and (& $OnHotkey $r.Char)) { $rebuild = $true }
                continue
            }
            if ($r.Emit -ne 'Activate' -or -not $r.Item) { continue }
            $data = $r.Item.Data
            if ($r.Item.Kind -eq 'Link' -and $data -and $data.Screen) { return @{ Nav = 'Push'; Target = [string]$data.Screen; Char = ''; HasMarks = $false } }
            if ($r.Item.Kind -eq 'Action' -and $data -and $data.Action) {
                Invoke-WtCapturedAction -Title ([string]$r.Item.Label) -Breadcrumb $Breadcrumb -Action $data.Action
                continue
            }
            if ($selection.Count -eq 0) { $footer = Get-Translation 'MarkFirstHint'; continue }
            $null = Invoke-WtApplySelection -Breadcrumb $Breadcrumb -Selection $selection -Meta $built.Meta -Items $items -Cycle $cycle
            $rebuild = $true
        }
    }
}
