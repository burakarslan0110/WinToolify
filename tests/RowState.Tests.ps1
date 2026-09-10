#Requires -Modules Pester

<#
.SYNOPSIS
    Row state on apply screens: mark glyphs, the live-state / pending-verb
    column, Refused marks, column alignment, localized risk / undo labels,
    and Restore-WtUndoEntry -ItemFilter (item-level RestoredAt).
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Restore-WtUndoEntry -ItemFilter' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:items = @(
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'Keep'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' },
            [PSCustomObject]@{ ItemType = 'Service'; Name = 'Revert'; PreviousStatus = 'Running'; PreviousStartType = 'Automatic' }
        )
        $script:entryPath = Write-WtUndoEntry -Scope Machine -Action 'Disable Services' -Items $items -TestRootOverride $FakeRoot
    }
    It 'restores only the filtered items, stamps them item-level, and leaves the entry listed' {
        $script:touched = New-Object 'System.Collections.Generic.List[string]'
        $results = Restore-WtUndoEntry -EntryPath $entryPath -ItemFilter { param($i) $i.Name -eq 'Revert' } -RestoreServiceItem { param($item) $script:touched.Add($item.Name) }
        @($results).Count | Should -Be 1
        $results[0].Name | Should -Be 'Revert'
        @($touched) | Should -Be @('Revert')
        $reloaded = Read-WtJson -Path $entryPath
        ($reloaded.PSObject.Properties.Name -contains 'RestoredAt') -and $reloaded.RestoredAt | Should -BeFalse
        ($reloaded.Items | Where-Object Name -eq 'Revert').RestoredAt | Should -Not -BeNullOrEmpty
        ($reloaded.Items | Where-Object Name -eq 'Keep').PSObject.Properties.Name | Should -Not -Contain 'RestoredAt'
    }
    It 'a later full restore skips the already-reverted item and then marks the entry' {
        Restore-WtUndoEntry -EntryPath $entryPath -ItemFilter { param($i) $i.Name -eq 'Revert' } -RestoreServiceItem { param($item) } | Out-Null
        $script:touched = New-Object 'System.Collections.Generic.List[string]'
        $results = Restore-WtUndoEntry -EntryPath $entryPath -RestoreServiceItem { param($item) $script:touched.Add($item.Name) }
        @($touched) | Should -Be @('Keep')
        @($results).Count | Should -Be 1
        (Read-WtJson -Path $entryPath).RestoredAt | Should -Not -BeNullOrEmpty
    }
    It 'marks the entry itself once the filtered revert leaves nothing pending' {
        Restore-WtUndoEntry -EntryPath $entryPath -ItemFilter { param($i) $true } -RestoreServiceItem { param($item) } | Out-Null
        (Read-WtJson -Path $entryPath).RestoredAt | Should -Not -BeNullOrEmpty
    }
    It 'does not stamp anything when the filtered item fails' {
        Restore-WtUndoEntry -EntryPath $entryPath -ItemFilter { param($i) $i.Name -eq 'Revert' } -RestoreServiceItem { param($item) throw 'boom' } | Out-Null
        $reloaded = Read-WtJson -Path $entryPath
        ($reloaded.Items | Where-Object Name -eq 'Revert').PSObject.Properties.Name | Should -Not -Contain 'RestoredAt'
    }
}

Describe 'Localized risk and undo labels' {
    AfterEach { $script:Language = 'EN' }
    It 'Get-WtRiskLabel prints the Turkish words in TR and the constants in EN' {
        $script:Language = 'TR'
        Get-WtRiskLabel -Risk 'SAFE' | Should -Be 'GUVENLI'
        Get-WtRiskLabel -Risk 'CAUTION' | Should -Be 'DIKKAT'
        Get-WtRiskLabel -Risk 'ADVANCED' | Should -Be 'ILERI'
        $script:Language = 'EN'
        Get-WtRiskLabel -Risk 'CAUTION' | Should -Be 'CAUTION'
        Get-WtRiskLabel -Risk '' | Should -Be ''
    }
    It 'every ActionName used by the apply paths has a TR translation' {
        $src = Get-Content -LiteralPath $TargetPath -Raw
        $names = @([regex]::Matches($src, "ActionName '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $names.Count | Should -BeGreaterThan 20
        foreach ($n in $names) {
            $script:Translations['TR']['UndoAction.' + $n] | Should -Not -BeNullOrEmpty -Because "UndoAction.$n needs a Turkish label"
            $script:Translations['EN']['UndoAction.' + $n] | Should -Be $n
        }
    }
    It 'Format-WtUndoEntryLabel is fully Turkish in TR (action, count, restored note)' {
        $script:Language = 'TR'
        $entry = [PSCustomObject]@{ Timestamp = '2026-08-17T14:30:00'; Action = 'Disable Services'; Items = @(1, 2); RestoredAt = '2026-08-17T15:00:00' }
        Format-WtUndoEntryLabel -Entry $entry | Should -Be '2026-08-17 14:30:00 - Servisleri Devre Disi Birak (2 oge) [daha once geri yuklendi]'
    }
    It 'falls back to the raw action for an unknown name' {
        $script:Language = 'TR'
        Get-WtUndoActionLabel -Action 'Some Legacy Action' | Should -Be 'Some Legacy Action'
    }
    It 'the row renderer prints the localized risk tag' {
        $script:Language = 'TR'
        $g = Get-WtGlyphSet -Unicode $false
        $row = New-WtListItem -Kind 'Check' -Name 'A' -Label 'Alpha' -Risk 'CAUTION' -StateLabel ''
        $text = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 60) | ForEach-Object T) -join ''
        $text | Should -Match '\[DIKKAT\]'
        $text | Should -Not -Match 'CAUTION'
    }
}

Describe 'Marked rows: [x] = pending action, state column = live state or pending verb' {
    BeforeEach {
        $script:g = Get-WtGlyphSet -Unicode $false
        $script:items = @(
            New-WtListItem -Kind 'Check' -Name 'A' -Label 'Alpha' -Risk 'SAFE' -StateLabel (Get-Translation 'NotApplied')
            New-WtListItem -Kind 'Check' -Name 'B' -Label 'Beta' -Risk 'SAFE' -StateLabel (Get-Translation 'Applied') -Applied $true -Removable $true
            New-WtListItem -Kind 'Check' -Name 'C' -Label 'Gamma' -Risk 'SAFE' -StateLabel (Get-Translation 'Applied') -Applied $true -Selectable $false
        )
        $script:state = @{ CursorIndex = 1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        $script:text = { param($i, $sel) ((Get-WtListRowSegments -Item $items[$i] -IsCursor $false -Selected $sel -Glyphs $g -Width 70) | ForEach-Object T) -join '' }
    }
    It 'never renders [X]: unmarked rows are [ ] and marked rows are [x], applied or not' {
        (& $text 1 $false) | Should -Match '\[ \]'
        (& $text 1 $false) | Should -Not -CMatch '\[X\]'
        (& $text 1 $true) | Should -CMatch '\[x\]'
        (& $text 0 $true) | Should -CMatch '\[x\]'
        (Get-WtGlyphSet -Unicode $false).PSObject.Properties.Name | Should -Not -Contain 'CheckApplied'
        (Get-WtGlyphSet -Unicode $true).PSObject.Properties.Name | Should -Not -Contain 'CheckApplied'
    }
    It 'the state column shows the live state unmarked and the pending verb when marked' {
        (& $text 0 $false) | Should -Match ([regex]::Escape((Get-Translation 'NotApplied')))
        (& $text 0 $true) | Should -Match ([regex]::Escape((Get-Translation 'WillApply')))
        (& $text 0 $true) | Should -Not -Match ([regex]::Escape((Get-Translation 'NotApplied')))
        (& $text 1 $false) | Should -Match ([regex]::Escape((Get-Translation 'Applied')))
        (& $text 1 $true) | Should -Match ([regex]::Escape((Get-Translation 'WillRemove')))
    }
    It 'colours: applied green, not applied dark gray, pending yellow' {
        $fg = { param($i, $sel) (Get-WtListRowSegments -Item $items[$i] -IsCursor $false -Selected $sel -Glyphs $g -Width 70)[-1].F }
        (& $fg 1 $false) | Should -Be 'Green'
        (& $fg 0 $false) | Should -Be 'DarkGray'
        (& $fg 0 $true) | Should -Be 'Yellow'
        (& $fg 1 $true) | Should -Be 'Yellow'
    }
    It 'marking does not move the column: the right part is as wide marked as unmarked' {
        $w = { param($i, $sel) (Get-WtListRowRightParts -Item $items[$i] -StateWidth 0 -Selected $sel).Text.Length }
        (& $w 0 $true) | Should -Be (& $w 0 $false)
        (& $w 1 $true) | Should -Be (& $w 1 $false)
    }
    It 'a selected Radio row keeps its live state text and colour (only Check rows turn into a verb)' {
        $radio = New-WtListItem -Kind 'Radio' -Name 'R' -Label 'Rho' -Risk 'SAFE' -StateLabel (Get-Translation 'Applied') -Applied $true
        (Get-WtListRowRightParts -Item $radio -StateWidth 0 -Selected $true).State.Trim() | Should -Be (Get-Translation 'Applied')
        $segs = Get-WtListRowSegments -Item $radio -IsCursor $false -Selected $true -Glyphs $g -Width 70
        (($segs | ForEach-Object T) -join '') | Should -Not -Match ([regex]::Escape((Get-Translation 'WillRemove')))
        $segs[-1].F | Should -Be 'Green'
    }
    It 'a Check row without a state label gets no verb when marked' {
        $bare = New-WtListItem -Kind 'Check' -Name 'Z' -Label 'Zeta'
        (Get-WtListRowRightParts -Item $bare -StateWidth 0 -Selected $true).Text | Should -Be ''
    }
    It 'Space on an applied removable row marks it (no Revert emit exists any more)' {
        $r = Update-WtListState -State $state -Token 'Space' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.Emit | Should -Be 'None'
        $r.State.Selection.Contains('B') | Should -BeTrue
    }
    It 'Space on an applied row that is not removable emits Refused and marks nothing' {
        $state.CursorIndex = 2
        $r = Update-WtListState -State $state -Token 'Space' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.Emit | Should -Be 'Refused'
        $r.State.Selection.Count | Should -Be 0
    }
    It 'Digit on an applied removable row marks it too' {
        $state.CursorIndex = 0
        $r = Update-WtListState -State $state -Token 'Digit:2' -Items $items -ViewHeight 10 -MultiSelect $true
        $r.State.Selection.Contains('B') | Should -BeTrue
    }
    It 'Char:a marks only the not-applied rows; Char:c clears everything' {
        $r = Update-WtListState -State $state -Token 'Char:a' -Items $items -ViewHeight 10 -MultiSelect $true
        @($r.State.Selection | Sort-Object) | Should -Be @('A')
        $r2 = Update-WtListState -State $r.State -Token 'Char:c' -Items $items -ViewHeight 10 -MultiSelect $true
        $r2.State.Selection.Count | Should -Be 0
    }
    It 'Get-WtMarkSummary counts marks by direction and formats the counter' {
        $state.Selection.Add('A') | Out-Null
        $state.Selection.Add('B') | Out-Null
        $s = Get-WtMarkSummary -Items $items -Selection $state.Selection
        $s.ApplyCount | Should -Be 1
        $s.RemoveCount | Should -Be 1
        $s.Text | Should -Be (((Get-Translation 'MarkSummaryApply') -f 1) + ', ' + ((Get-Translation 'MarkSummaryRemove') -f 1))
        (Get-WtMarkSummary -Items $items -Selection (New-Object 'System.Collections.Generic.HashSet[string]')).Text | Should -Be ''
        Format-WtDirectionCounts -ApplyCount 0 -RemoveCount 3 | Should -Be ((Get-Translation 'MarkSummaryRemove') -f 3)
    }
    It 'Get-WtMarkSummary falls back to MarkedCount when no row in Items carries an Applied property (raw rows)' {
        $rawItems = @(
            [PSCustomObject]@{ Kind = 'Check'; Name = 'A'; Label = 'A'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null }
            [PSCustomObject]@{ Kind = 'Check'; Name = 'B'; Label = 'B'; Risk = $null; StateLabel = ''; Selectable = $true; Data = $null }
        )
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $sel.Add('A') | Out-Null
        $sel.Add('B') | Out-Null
        $s = Get-WtMarkSummary -Items $rawItems -Selection $sel
        $s.Text | Should -Be ((Get-Translation 'MarkedCount') -f 2)
    }
    It 'the apply footer no longer explains [X]' {
        (Get-Translation 'ApplyFooter') | Should -Not -CMatch '\[X\]'
        $script:Translations['EN']['ApplyFooter'] | Should -Be 'Up/Down: move - Space: mark - Enter: apply - A/C: all/none - Esc: back - Q: quit'
    }
}

Describe 'Risk / state columns line up (Get-WtListRowRightParts)' {
    AfterEach { $script:Language = 'EN' }
    It 'right-aligns the risk tag and left-pads the state so every row ends its tag at the same column' {
        $script:Language = 'TR'
        $g = Get-WtGlyphSet -Unicode $false
        $rows = @(
            New-WtListItem -Kind 'Check' -Name 'a' -Label 'A' -Risk 'SAFE' -StateLabel 'Kaldirildi'
            New-WtListItem -Kind 'Check' -Name 'b' -Label 'B' -Risk 'ADVANCED' -StateLabel 'Kaldirildi'
            New-WtListItem -Kind 'Check' -Name 'c' -Label 'C' -Risk 'CAUTION' -StateLabel (Get-Translation 'Applied') -Applied $true
            New-WtListItem -Kind 'Radio' -Name 'd' -Label 'D' -Risk 'CAUTION' -StateLabel ''
        )
        $stateWidth = 0
        foreach ($r in $rows) { $stateWidth = [Math]::Max($stateWidth, ([string]$r.StateLabel).Length) }
        $closers = foreach ($r in $rows) {
            $t = ((Get-WtListRowSegments -Item $r -IsCursor $false -Selected $false -Glyphs $g -Width 80 -StateWidth $stateWidth) | ForEach-Object T) -join ''
            $t.LastIndexOf(']')
        }
        ($closers | Sort-Object -Unique).Count | Should -Be 1
    }
    It 'gives the padding back to the label on a narrow console instead of truncating it' {
        $g = Get-WtGlyphSet -Unicode $false
        $row = New-WtListItem -Kind 'Check' -Name 'a' -Label 'Item 0' -Risk 'SAFE' -StateLabel 'NotApplied'
        $t = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $false -Glyphs $g -Width 35) | ForEach-Object T) -join ''
        $t | Should -Match 'Item 0'
        $t | Should -Not -Match '~'
    }
}

Describe 'Per-screen state column and localized service states' {
    AfterEach { $script:Language = 'EN' }
    It 'Get-WtFrameRows sizes the state column from the longest state on the screen' {
        $g = Get-WtGlyphSet -Unicode $false
        $rows = @(
            New-WtListItem -Kind 'Check' -Name 'a' -Label 'A' -Risk 'SAFE' -StateLabel 'Stopped/Disabled'
            New-WtListItem -Kind 'Check' -Name 'b' -Label 'B' -Risk 'CAUTION' -StateLabel 'Running/Manual'
            New-WtListItem -Kind 'Check' -Name 'c' -Label 'C' -Risk 'ADVANCED' -StateLabel 'Not present'
        )
        $state = @{ CursorIndex = -1; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        $frame = Get-WtFrameRows -Breadcrumb 'B' -Items $rows -State $state -Width 100 -Height 24 -Glyphs $g
        $closers = 16..18 | ForEach-Object { (($frame[$_] | ForEach-Object T) -join '').LastIndexOf(']') }
        ($closers | Sort-Object -Unique).Count | Should -Be 1
    }
    It 'Format-WtServiceStateLabel localizes both words and passes unknown ones through' {
        $script:Language = 'TR'
        Format-WtServiceStateLabel -Status 'Stopped' -StartType 'Disabled' | Should -Be 'Durdu/Devre disi'
        Format-WtServiceStateLabel -Status 'Running' -StartType 'Automatic' | Should -Be 'Calisiyor/Otomatik'
        Format-WtServiceStateLabel -Status 'Paused' -StartType 'Boot' | Should -Be 'Duraklatildi/Onyukleme'
        Format-WtServiceStateLabel -Status 'StartPending' -StartType 'System' | Should -Be 'Baslatiliyor/Sistem'
        Format-WtServiceStateLabel -Status 'Nonsense' -StartType 'Gibberish' | Should -Be 'Nonsense/Gibberish'
        $script:Language = 'EN'
        Format-WtServiceStateLabel -Status 'Stopped' -StartType 'Manual' | Should -Be 'Stopped/Manual'
    }
}

Describe 'A row can name its own pending verb without changing the apply direction' {
    BeforeAll {
        $script:vg = Get-WtGlyphSet -Unicode $false
        $script:appRow = New-WtListItem -Kind 'Check' -Name 'BingWeather' -Label 'Bing Weather' -Risk 'SAFE' -StateLabel (Get-Translation 'StateInstalled') -PendingVerbKey 'WillRemove'
        $script:plainRow = New-WtListItem -Kind 'Check' -Name 'Plain' -Label 'Plain' -Risk 'SAFE' -StateLabel (Get-Translation 'NotApplied')
    }
    It 'an installed app reads "will remove" when marked, not "will apply"' {
        (Get-WtListRowRightParts -Item $script:appRow -StateWidth 0 -Selected $true).State.Trim() | Should -Be (Get-Translation 'WillRemove')
    }
    It 'the verb key does NOT make it a Remove record - the engine still files a removal as Apply' {
        $script:appRow.Applied | Should -BeFalse
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $null = $sel.Add('BingWeather')
        $meta = @{ BingWeather = @{ SectionKey = 'Packages'; Entry = [PSCustomObject]@{ Name = 'BingWeather' }; Data = $null } }
        $records = @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta -Items @($script:appRow))
        $records[0].Direction | Should -Be 'Apply'
    }
    It 'a row without the key keeps the old behaviour' {
        (Get-WtListRowRightParts -Item $script:plainRow -StateWidth 0 -Selected $true).State.Trim() | Should -Be (Get-Translation 'WillApply')
    }
    It 'the verb does not move the column - both words share the same floor' {
        $w = { param($row, $sel) (Get-WtListRowRightParts -Item $row -StateWidth 0 -Selected $sel).Text.Length }
        (& $w $script:appRow $true) | Should -Be (& $w $script:appRow $false)
        (& $w $script:appRow $true) | Should -Be (& $w $script:plainRow $true)
    }
    It 'a cycling row still wins over the verb key' {
        $both = New-WtListItem -Kind 'Check' -Name 'X' -Label 'X' -StateLabel 'Stopped/Manual' -PendingVerbKey 'WillRemove' -CycleTargets @('Disabled')
        (Get-WtListRowRightParts -Item $both -StateWidth 0 -Selected $true -PendingLabel 'Disabled').State.Trim() | Should -Be '-> Disabled'
    }
    It 'the Apps screen tags every row it offers' {
        $groups = @(Get-WtPackagesGroups -GetState { param($n) @{ Installed = $true } } -ShowAll $true)
        $catalog = @(& $groups[0].GetCatalog $groups[0])
        $catalog.Count | Should -BeGreaterThan 10
        @($catalog | Where-Object { $_.PendingVerbKey -ne 'WillRemove' }).Count | Should -Be 0
    }
    It 'the Apps rows really render the removal verb end to end' {
        $groups = @(Get-WtPackagesGroups -GetState { param($n) @{ Installed = $true } } -ShowAll $true)
        $built = Get-WtApplyScreenItems -Groups $groups
        $row = @($built.Items | Where-Object { $_.Kind -eq 'Check' })[0]
        $row.PendingVerbKey | Should -Be 'WillRemove'
        $text = ((Get-WtListRowSegments -Item $row -IsCursor $false -Selected $true -Glyphs $script:vg -Width 100 -StateWidth 12) | ForEach-Object T) -join ''
        $text | Should -Match ([regex]::Escape((Get-Translation 'WillRemove')))
        $text | Should -Not -Match ([regex]::Escape((Get-Translation 'WillApply')))
    }
    It 'the firewall row is NOT tagged - its label already carries the direction' {
        $groups = @(Get-WtSystemSettingsGroups -FirewallState @{ Enabled = $true; Known = $true })
        $fw = @($groups | Where-Object { $_.SectionKey -eq 'Firewall' })
        $fw.Count | Should -Be 1
        $entry = @(& $fw[0].GetCatalog $fw[0])[0]
        $entry.PSObject.Properties.Name | Should -Not -Contain 'PendingVerbKey'
    }
}

Describe 'No English literal is left in a selector state label' {
    It 'the unselectable note comes from the table in both languages' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['AlreadyInTargetState'] | Should -Not -BeNullOrEmpty -Because "$lang needs AlreadyInTargetState"
            $script:Translations[$lang]['CleanupPreviewLabel'] | Should -Match '\{0\}'
            $script:Translations[$lang]['CleanupPreviewLabel'] | Should -Match '\{1\}'
        }
        $script:Translations['TR']['AlreadyInTargetState'] | Should -Not -Match 'target'
        $script:Translations['TR']['CleanupPreviewLabel'] | Should -Not -Match 'files'
    }
    It 'Show-WtSelector no longer hardcodes the English note' {
        $src = (Get-Command Show-WtSelector).ScriptBlock.ToString()
        $src | Should -Not -Match "UnselectableNote = ' \(already in target state\)'"
        $src | Should -Match "UnselectableNote = \(Get-Translation 'AlreadyInTargetState'\)"
    }
}