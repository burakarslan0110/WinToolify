BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
}

Describe 'Get-WtMainMenuItems (V1 tree)' {
    It 'lists the V1 entries in order (VCRedist under Basic Tools, System Settings promoted to row 3), then the restore point, Undo, Profiles and Exit' {
        $items = @(Get-WtMainMenuItems)
        @($items | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name) | Should -Be @('BasicTools', 'Services', 'SystemSettings', 'Privacy', 'Packages', 'WingetStore', 'Language', 'CreateRestorePoint', 'Undo', 'Profiles', 'Assistant', 'Exit')
        @($items | ForEach-Object Kind)[-5..-1] | Should -Be @('Spacer', 'Rule', 'Link', 'Spacer', 'Action')
        @($items | Where-Object { $_.Kind -eq 'Link' } | ForEach-Object { $_.Data.Screen }) | Should -Be @('BasicTools', 'Services', 'SystemSettings', 'Privacy', 'Packages', 'WingetStore', 'Language', 'Undo', 'Profiles', 'Assistant')
        @($items | Where-Object Name -eq 'InstallVCRedist').Count | Should -Be 0
        ($items | Where-Object Name -eq 'Exit').Data.Exit | Should -BeTrue
        @($items | Where-Object { $_.Kind -eq 'Header' }).Count | Should -Be 0
    }
    It 'the 5th entry is the bloatware remover with its new label in both languages' {
        $old = $script:Language
        try {
            $script:Language = 'TR'
            @(Get-WtMainMenuItems)[5].Label | Should -Be 'Gereksiz (Bloatware) Uygulamalari Kaldir'
            $script:Language = 'EN'
            @(Get-WtMainMenuItems)[5].Label | Should -Be 'Remove Unnecessary (Bloatware) Apps'
        }
        finally { $script:Language = $old }
    }
    It 'labels resolve through the active language' {
        $old = $script:Language
        try {
            $script:Language = 'TR'
            ((Get-WtMainMenuItems) | Where-Object Name -eq 'BasicTools').Label | Should -Be $script:Translations['TR']['BasicTools']
            $script:Language = 'EN'
            ((Get-WtMainMenuItems) | Where-Object Name -eq 'BasicTools').Label | Should -Be 'Basic Tools'
        }
        finally { $script:Language = $old }
    }
}

Describe 'Get-WtBasicToolsItems' {
    It 'links Actions and Information in V1 order and carries no action row, since VCRedist moved to Action Tools > Software' {
        $items = @(Get-WtBasicToolsItems)
        @($items | Where-Object Kind -eq 'Link' | ForEach-Object { $_.Data.Screen }) | Should -Be @('ActionTools', 'InfoTools')
        @($items | ForEach-Object Name) | Should -Be @('ActionTools', 'InfoTools')
        @($items | Where-Object Kind -eq 'Action').Count | Should -Be 0
    }
}

Describe 'Navigation layout (compact menus, full lists)' {
    It 'Invoke-WtNavScreen renders its list compact' {
        Mock Invoke-WtListScreen { $script:navLayout = $Layout; @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 } }
        Invoke-WtNavScreen -Breadcrumb 'B' -Items @(New-WtListItem -Kind 'Link' -Name 'X' -Label 'x' -Data @{ Screen = 'X' }) | Out-Null
        $script:navLayout | Should -Be 'Compact'
    }
    It 'the main screen is compact with the banner' {
        Mock Invoke-WtListScreen { $script:mainLayout = $Layout; $script:mainBanner = $ShowBanner; @{ Emit = 'Quit'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 } }
        Invoke-WtMainScreen | Out-Null
        $script:mainLayout | Should -Be 'Compact'
        $script:mainBanner | Should -BeTrue
    }
    It 'apply screens stay full-window' {
        Mock Invoke-WtListScreen { $script:applyLayout = $Layout; @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 } }
        $groups = @(@{ SectionKey = 'S'; HeaderKey = $null; GetCatalog = { param($g) @([PSCustomObject]@{ Name = 'a'; DisplayLabel = 'A'; Risk = 'SAFE' }) }; GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } } })
        Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $groups | Out-Null
        @('Full', '', $null) | Should -Contain $script:applyLayout
    }
    It 'Invoke-WtListScreen exposes a Layout parameter that defaults to Full' {
        $p = (Get-Command Invoke-WtListScreen).Parameters['Layout']
        $p | Should -Not -BeNullOrEmpty
        (Get-Command Get-WtFrameRows).Parameters['Layout'] | Should -Not -BeNullOrEmpty
    }
}

Describe 'Footer hints and relabels' {
    It 'every key-hint footer separates its hints with " - " in both languages' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'MainFooter', 'NavFooter', 'ApplyFooter', 'ServicesFooter', 'UndoFooter', 'SelectorFooter') {
                $text = [string]$script:Translations[$lang][$key]
                $text | Should -Match ' - ' -Because "$lang $key"
                $text | Should -Not -Match '\S  \S' -Because "$lang $key must not rely on double spaces"
            }
        }
    }
    It 'every key-hint footer item names its key, a colon, then the action' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'MainFooter', 'NavFooter', 'ApplyFooter', 'ServicesFooter', 'UndoFooter', 'SelectorFooter') {
                $text = [string]$script:Translations[$lang][$key]
                foreach ($part in ($text -split ' - ')) {
                    $part | Should -Match '^\S[^:]*: \S' -Because "$lang $key item '$part'"
                }
            }
        }
    }
    It 'key-hint footers fit a 100-column box without being cut' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'MainFooter', 'NavFooter', 'ApplyFooter', 'ServicesFooter', 'UndoFooter', 'SelectorFooter') {
                ([string]$script:Translations[$lang][$key]).Length | Should -BeLessOrEqual 95 -Because "$lang $key"
            }
        }
    }
    It 'every scrollable screen tells you the arrows move' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'MainFooter', 'NavFooter', 'ApplyFooter', 'ServicesFooter', 'UndoFooter', 'SelectorFooter', 'OutputFooter') {
                [string]$script:Translations[$lang][$key] | Should -Match '(Up/Down|Yukari/Asagi)' -Because "$lang $key"
            }
        }
    }
    It 'the hardening "more settings" header is a plain sub-header in both languages' {
        foreach ($lang in 'EN', 'TR') {
            [string]$script:Translations[$lang]['HardeningMoreSettings'] | Should -Match '^-- \S.* --$' -Because "$lang must name the group, not the tool it came from"
        }
    }
}

Describe 'Confirm-WtExit' {
    It 'leaves immediately when nothing is marked' {
        Confirm-WtExit -HasMarks $false -ReadAnswer { throw 'must not prompt' } | Should -BeTrue
    }
    It 'with marks: Enter leaves, anything else stays, exhausted input leaves' {
        Confirm-WtExit -HasMarks $true -ReadAnswer { param($Lines, $Prompt) '' } | Should -BeTrue
        Confirm-WtExit -HasMarks $true -ReadAnswer { param($Lines, $Prompt) 'x' } | Should -BeFalse
        Confirm-WtExit -HasMarks $true -ReadAnswer { param($Lines, $Prompt) $null } | Should -BeTrue
    }
}

Describe 'screen registry' {
    It 'dispatches every main-menu and Basic Tools target' {
        $targets = @((Get-WtMainMenuItems) + (Get-WtBasicToolsItems) | Where-Object Kind -eq 'Link' | ForEach-Object { $_.Data.Screen })
        $src = (Get-Command Invoke-WtScreenByKey).Definition
        foreach ($t in $targets) { $src | Should -Match ([regex]::Escape("'$t'")) }
    }
    It 'has no staging store, Changes screen or commit flow left' {
        foreach ($fn in 'Add-WtStagedChange', 'Get-WtStagedChangeCount', 'Invoke-WtCommitFlow', 'Invoke-WtChangesScreen', 'Invoke-WtStagingCatalogScreen', 'Get-WtStagingScreenItems', 'Invoke-WtPerformanceScreen', 'Invoke-WtTelemetryScreen') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$fn must be deleted"
        }
    }
    It 'main-screen keys exist in both languages' {
        foreach ($key in 'BasicTools', 'ServicesManagement', 'PrivacySettings', 'AppsMenu', 'InstallVCRedist', 'Language', 'UndoLastChange', 'ConfigProfiles', 'Exit', 'ActionTools', 'InformationTools', 'SystemSettings', 'MainFooter', 'NavFooter', 'MainMenu', 'MarksWillBeLost', 'ExitConfirmPrompt') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
}

Describe 'New-WtListItem' {
    It 'builds a focusable Link row by default and a non-focusable Header' {
        $link = New-WtListItem -Kind 'Link' -Name 'X' -Label 'x' -Data @{ Screen = 'X' }
        Test-WtItemFocusable -Item $link | Should -BeTrue
        $link.Selectable | Should -BeTrue
        $header = New-WtListItem -Kind 'Header' -Name 'H' -Label 'h'
        Test-WtItemFocusable -Item $header | Should -BeFalse
        $header.Selectable | Should -BeFalse
    }
}

Describe 'Get-WtMainScreenFrame (static main frame behind Show-Menu)' {
    It 'composes a frame without a TUI session (glyphs resolved on demand)' {
        $frame = @(Get-WtMainScreenFrame -Width 100 -Height 40)
        $frame.Count | Should -BeGreaterThan 10
        $text = ($frame | ForEach-Object { ($_ | ForEach-Object T) -join '' }) -join "`n"
        $text | Should -Match ([regex]::Escape((Get-Translation 'BasicTools')))
        $text | Should -Match ([regex]::Escape((Get-Translation 'MainFooter')))
    }
    It 'shows the banner, the credit block and a centered box without a title bar or breadcrumb' {
        $frame = @(Get-WtMainScreenFrame -Width 120 -Height 40)
        $frame.Count | Should -Be 40
        $rows = @($frame | ForEach-Object { ($_ | ForEach-Object T) -join '' })
        $rows[9] | Should -Match '^\s*$'
        $rows[10].Trim() | Should -Be 'Created by Burak Arslan'
        $rows[11].Trim() | Should -Be 'https://github.com/burakarslan0110/WinToolify'
        $rows[12] | Should -Match '^\s*$'
        $rows[13] | Should -Match '^\s+\+-+\+\s+$'
        ($rows -join "`n") | Should -Not -Match ([regex]::Escape((Get-Translation 'MainMenu')))
        ($rows -join "`n") | Should -Not -Match 'WinToolify V2'
        ($rows -join "`n") | Should -Not -Match ([regex]::Escape((Get-Translation 'InstallVCRedist')))
        $rows[14] | Should -Match ('-- ' + [regex]::Escape((Get-Translation 'MainToolsRule')))
        $rows[15] | Should -Match ('\b1\.\s+' + [regex]::Escape((Get-Translation 'BasicTools')))
        $rows[26] | Should -Match ([regex]::Escape((Get-Translation 'Assistant')))
        $rows[27] | Should -Match ([regex]::Escape((Get-Translation 'MainAssistantRow')))
        $rows[29] | Should -Match ([regex]::Escape((Get-Translation 'Exit')))
        $rows[30] | Should -Match '^\s+\+-+\+\s*$'
        $band = ((($rows[31] + ' ' + $rows[32]) -replace '\|', ' ') -replace '\s+', ' ').Trim()
        $band | Should -Be (Get-Translation 'MainDescBasicTools')
        $band | Should -Not -Match ([regex]::Escape((Get-Translation 'MainDescExit')))
        $rows[33] | Should -Match '^\s+\+-+\+\s*$'
        $rows[34] | Should -Match ([regex]::Escape((Get-Translation 'MainFooter')))
        $rows[35] | Should -Match '^\s+\+-+\+\s*$'
        ($rows -join "`n") | Should -Not -Match 'Ipucu|^\s*\|\s*Tip:'
        foreach ($i in 36..39) { $rows[$i] | Should -Match '^\s*$' }
        @($rows | ForEach-Object { $_.Length } | Sort-Object -Unique).Count | Should -Be 1
    }
}

Describe 'Invoke-WtApplyPerAppPermissionGroups' {
    It 'splits composite names per capability and aggregates the guarded results' {
        $script:calls = New-Object 'System.Collections.Generic.List[string]'
        $fake = { param($Capability, $Sid, [string[]]$Names) $script:calls.Add("$Capability=" + ($Names -join '+')); [PSCustomObject]@{ Aborted = $false; Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = $true; Error = $null } }) } }
        $r = Invoke-WtApplyPerAppPermissionGroups -Names @('webcam|App_a', 'microphone|App_a', 'webcam|App_b') -Sid 'S-1-5-21-1' -ApplyAction $fake
        @($script:calls) | Should -Be @('webcam=App_a+App_b', 'microphone=App_a')
        $r.Aborted | Should -BeFalse
        @($r.Results).Count | Should -Be 3
    }
    It 'stops after an aborted group' {
        $script:calls2 = New-Object 'System.Collections.Generic.List[string]'
        $fake = { param($Capability, $Sid, [string[]]$Names) $script:calls2.Add($Capability); [PSCustomObject]@{ Aborted = $true; Results = @() } }
        $r = Invoke-WtApplyPerAppPermissionGroups -Names @('webcam|A', 'microphone|B') -Sid 'S' -ApplyAction $fake
        $r.Aborted | Should -BeTrue
        @($script:calls2).Count | Should -Be 1
    }
}

Describe 'Get-WtFirewallOfferEntry' {
    It 'offers the direction opposite to the live state' {
        (Get-WtFirewallOfferEntry -CurrentlyEnabled $true).Name | Should -Be 'DisableFirewall'
        (Get-WtFirewallOfferEntry -CurrentlyEnabled $false).Name | Should -Be 'EnableFirewall'
    }
}

Describe 'Get-WtBreadcrumb' {
    It 'joins translated keys with the separator' {
        $old = $script:Language
        try {
            $script:Language = 'EN'
            Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools' | Should -Be 'Main Menu > Basic Tools'
        }
        finally { $script:Language = $old }
    }
}

Describe 'Input exhaustion (redirected stdin)' {
    It 'the reducer treats Eof as Back' {
        $items = @(New-WtListItem -Kind 'Link' -Name 'X' -Label 'x')
        $state = @{ CursorIndex = 0; WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
        (Update-WtListState -State $state -Token 'Eof' -Items $items).Emit | Should -Be 'Back'
    }
}

Describe 'Get-WtSystemIdentityLines' {
    It 'combines machine, user, serial and license lines via injected sources' {
        $lines = Get-WtSystemIdentityLines -GetSerial { 'SN-123' } -GetLicenseLines { @('License Status: Licensed') } -ComputerName 'PC1' -UserName 'burak'
        ($lines -join "`n") | Should -Match 'PC1'
        ($lines -join "`n") | Should -Match 'burak'
        ($lines -join "`n") | Should -Match 'SN-123'
        ($lines -join "`n") | Should -Match 'License Status'
    }
    It 'survives a failing serial lookup' {
        { Get-WtSystemIdentityLines -GetSerial { throw 'no cim' } -GetLicenseLines { @() } } | Should -Not -Throw
    }
}

Describe 'Get-WtLanguageScreenItems' {
    It 'returns exactly two Radio rows (EN/TR) with the current language preselected' {
        $old = $script:Language
        try {
            $script:Language = 'TR'
            $built = Get-WtLanguageScreenItems
            @($built.Items | ForEach-Object Kind) | Should -Be @('Radio', 'Radio')
            @($built.Items | ForEach-Object Name) | Should -Be @('EN', 'TR')
            $built.Selection.Contains('TR') | Should -BeTrue
            $built.Selection.Contains('EN') | Should -BeFalse
            ($built.Items | Where-Object Name -eq 'TR').Label | Should -Be 'Turkce'
        }
        finally { $script:Language = $old }
    }
}

Describe 'Set-WtLanguageChoice' {
    It 'switches the active language and persists it' {
        $old = $script:Language
        $root = Join-Path $TestDrive 'lang-root'
        try {
            Set-WtLanguageChoice -Language 'TR' -TestRootOverride $root
            $script:Language | Should -Be 'TR'
            (Read-WtSettings -TestRootOverride $root).Language | Should -Be 'TR'
        }
        finally { $script:Language = $old }
    }
    It 'rejects an unknown language' {
        $old = $script:Language
        try { { Set-WtLanguageChoice -Language 'XX' } | Should -Throw }
        finally { $script:Language = $old }
    }
}

Describe 'Get-WtProfileRebootNotice' {
    It 'is true only when an applied row maps to a RestartRequired catalog entry' {
        $sections = @(
            [PSCustomObject]@{ Outcome = 'Applied'; Catalog = @([PSCustomObject]@{ Name = 'EnableGpuScheduling'; RestartRequired = $true })
                Results = @([PSCustomObject]@{ Item = [PSCustomObject]@{ CatalogEntry = 'EnableGpuScheduling'; Name = 'HwSchMode' }; Applied = $true }) }
        )
        Test-WtProfileRebootNeeded -Sections $sections | Should -BeTrue
        $sections[0].Results[0].Applied = $false
        Test-WtProfileRebootNeeded -Sections $sections | Should -BeFalse
    }
}

Describe 'Undo/Profiles/Language registry' {
    It 'routes Undo, Profiles and Language to real screens (no placeholder)' {
        $src = (Get-Command Invoke-WtScreenByKey).Definition
        $src | Should -Match "'Undo' \{ return Invoke-WtUndoScreen \}"
        $src | Should -Match "'Profiles' \{ return Invoke-WtProfilesScreen \}"
        $src | Should -Match "'Language' \{ return Invoke-WtLanguageScreen \}"
    }
}

Describe 'Get-WtPanelItems' {
    It 'turns lines into non-focusable Info rows in order' {
        $items = @(Get-WtPanelItems -Lines @('one', 'two'))
        $items.Count | Should -Be 2
        $items[0].Kind | Should -Be 'Info'
        $items[0].Label | Should -Be 'one'
        $items[1].Name | Should -Be 'Line:2'
        $items[0].Selectable | Should -BeFalse
    }
    It 'stamps the requested risk on every row so panels can render red notices' {
        (Get-WtPanelItems -Lines @('x') -Risk 'ADVANCED')[0].Risk | Should -Be 'ADVANCED'
    }
    It 'tags only the first line of a wrapped message, but colours them all alike' {
        $items = @(Get-WtPanelItems -Lines @('one', 'two', 'three') -Risk 'CAUTION')
        foreach ($i in $items) { $i.Risk | Should -Be 'CAUTION' }
        $items[0].RiskTag | Should -BeTrue
        $items[1].RiskTag | Should -BeFalse
        $items[2].RiskTag | Should -BeFalse
        $g = Get-WtGlyphSet -Unicode $false
        $text = { param($item) ((Get-WtListRowSegments -Item $item -IsCursor $false -Selected $false -Glyphs $g -Width 60) | ForEach-Object T) -join '' }
        (& $text $items[0]) | Should -Match '\['
        (& $text $items[1]) | Should -Not -Match '\['
        (Get-WtListRowSegments -Item $items[1] -IsCursor $false -Selected $false -Glyphs $g -Width 60)[0].F | Should -Be 'Yellow'
    }
    It 'an empty line list yields no rows' {
        @(Get-WtPanelItems -Lines @()).Count | Should -Be 0
    }
}

Describe 'Get-WtOutputTail' {
    It 'keeps the newest lines, which is what a running command is showing' {
        @(Get-WtOutputTail -Lines @('a', 'b', 'c', 'd') -Count 2) | Should -Be @('c', 'd')
    }
    It 'returns everything when it already fits' {
        @(Get-WtOutputTail -Lines @('a', 'b') -Count 10) | Should -Be @('a', 'b')
        @(Get-WtOutputTail -Lines @() -Count 10).Count | Should -Be 0
    }
    It 'never asks for zero or fewer rows' {
        @(Get-WtOutputTail -Lines @('a', 'b', 'c') -Count 0) | Should -Be @('c')
    }
}

Describe 'Get-WtNativeOutputEncoding' {
    It 'decodes with the OEM page, because the legacy console tools write OEM even on a UTF-8 console' {
        (Get-WtNativeOutputEncoding -OemCodePage 857).CodePage | Should -Be 857
        (Get-WtNativeOutputEncoding -OemCodePage 437).CodePage | Should -Be 437
    }
    It 'falls back to the console encoding for a code page Windows does not know' {
        (Get-WtNativeOutputEncoding -OemCodePage 999999).CodePage | Should -Be ([Console]::OutputEncoding.CodePage)
    }
}

Describe 'Invoke-WtCapturedAction' {
    BeforeEach {
        $script:progress = New-Object 'System.Collections.Generic.List[string]'
        $script:footers = New-Object 'System.Collections.Generic.List[string]'
        $script:final = $null
        $script:show = { param($Lines, $Footer) $script:progress.Add((@($Lines) -join '|')); $script:footers.Add([string]$Footer) }
        $script:result = { param($Lines) $script:final = @($Lines) }
    }

    It 'captures Write-Host, native-style strings and objects into the result panel' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action {
            Write-Host 'from Write-Host'
            'from the pipeline'
            "two`nlines"
        }
        @($script:final) | Should -Be @('from Write-Host', 'from the pipeline', 'two', 'lines')
    }

    It 'writes nothing to the host - everything goes through the injected renderers' {
        $out = Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { Write-Host 'noisy'; 'more' } 6>&1
        @($out).Count | Should -Be 0
    }

    It 'shows an empty progress frame first, so the box is up before the command starts' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { 'x' }
        $script:progress[0] | Should -Be ''
        $script:footers[0] | Should -Be ((Get-Translation 'OutputRunning') -f '00:00')
    }

    It 'repaints as lines arrive so a long command visibly progresses' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { 'one'; 'two'; 'three' }
        @($script:progress).Count | Should -Be 4
        $script:progress[1] | Should -Be 'one'
        $script:progress[3] | Should -Be 'one|two|three'
    }

    It 'throttles the repaint instead of redrawing per line' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 60000 -Action { 1..50 | ForEach-Object { "line $_" } }
        @($script:progress).Count | Should -Be 1
        @($script:final).Count | Should -Be 50
    }

    It 'a throwing action still shows what it managed to print, plus the error' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { 'before'; throw 'exploded' }
        @($script:final) | Should -Be @('before', 'exploded')
    }

    It 'a non-terminating error becomes a plain line, not a stack trace' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { Write-Error 'bad thing' -ErrorAction Continue; 'carried on' }
        @($script:final) | Should -Be @('bad thing', 'carried on')
    }

    It 'the footer carries a running clock' {
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { 'x' }
        foreach ($f in $script:footers) { $f | Should -Match '\d\d:\d\d' }
    }

    It 'puts the console encoding back exactly as it found it' {
        $before = [Console]::OutputEncoding.CodePage
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { 'x' }
        [Console]::OutputEncoding.CodePage | Should -Be $before
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { throw 'boom' }
        [Console]::OutputEncoding.CodePage | Should -Be $before
    }

    It 'leaves the encoding alone entirely when asked to' {
        $before = [Console]::OutputEncoding.CodePage
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -UseNativeEncoding $false -Action {
            "cp=$([Console]::OutputEncoding.CodePage)"
        }
        @($script:final) | Should -Be @("cp=$before")
    }

    It 'drains the key queue AFTER the action and BEFORE the result panel opens' {
        $script:order = @()
        Mock Clear-WtPendingInput { $script:order += 'drain'; 0 }
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -RefreshMs 0 `
            -ShowResult { param($Lines) $script:order += 'result' } `
            -Action { $script:order += 'action'; 'x' }
        $script:order | Should -Be @('action', 'drain', 'result')
    }

    It 'drains even when the action threw, so the error panel is not skipped by a queued Enter' {
        Mock Clear-WtPendingInput { 0 }
        Invoke-WtCapturedAction -Title 'T' -ShowProgress $show -ShowResult $result -RefreshMs 0 -Action { throw 'boom' }
        Should -Invoke Clear-WtPendingInput -Times 1 -Exactly
    }
}

Describe 'Invoke-WtCapturedNativeAction' {
    BeforeEach {
        $script:progress = New-Object 'System.Collections.Generic.List[string]'
        $script:footers = New-Object 'System.Collections.Generic.List[string]'
        $script:final = $null
        $script:show = { param($Lines, $Footer) $script:progress.Add((@($Lines) -join '|')); $script:footers.Add([string]$Footer) }
        $script:result = { param($Lines) $script:final = @($Lines) }
    }

    It 'runs the command line and captures its output into the result panel' {
        Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c echo one& echo two' -ShowProgress $show -ShowResult $result
        @($script:final) | Should -Be @('one', 'two')
    }

    It 'drains the key queue between the tool ending and the result panel opening' {
        $script:order = @()
        Mock Clear-WtPendingInput { $script:order += 'drain'; 0 }
        Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c echo x' -ShowProgress $show `
            -ShowResult { param($Lines) $script:order += 'result' }
        $script:order | Should -Be @('drain', 'result')
    }

    It 'captures stderr in the same stream, so an error is never silently dropped' {
        Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c echo oops 1>&2' -ShowProgress $show -ShowResult $result
        @($script:final | ForEach-Object { $_.TrimEnd() }) | Should -Be @('oops')
    }

    It 'repaints on a TIMER while the tool is silent - the regression that froze the elapsed counter' {
        Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c ping -n 3 127.0.0.1 >nul& echo done' `
            -ShowProgress $show -ShowResult $result -RefreshMs 120
        @($script:final) | Should -Be @('done')
        @($script:progress).Count | Should -BeGreaterThan 4
        @($script:footers | Sort-Object -Unique).Count | Should -BeGreaterThan 1
    }

    It 'shows an empty progress frame first, so the box is up before the tool starts' {
        Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c echo x' -ShowProgress $show -ShowResult $result
        $script:progress[0] | Should -Be ''
        $script:footers[0] | Should -Be ((Get-Translation 'OutputRunning') -f '00:00')
    }

    It 'reports a command that cannot even start instead of throwing out of the panel' {
        Invoke-WtCapturedNativeAction -FilePath 'no-such-tool-ba3f.exe' -ShowProgress $show -ShowResult $result
        @($script:final).Count | Should -BeGreaterThan 0
        $script:final[0] | Should -Not -BeNullOrEmpty
    }

    It 'never touches the console encoding - the child decodes its own pipe' {
        $before = [Console]::OutputEncoding.CodePage
        Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c echo x' -Encoding ([System.Text.Encoding]::Unicode) `
            -ShowProgress $show -ShowResult $result
        [Console]::OutputEncoding.CodePage | Should -Be $before
    }

    It 'writes nothing to the host - everything goes through the injected renderers' {
        $out = Invoke-WtCapturedNativeAction -FilePath 'cmd.exe' -Arguments '/c echo noisy' -ShowProgress $show -ShowResult $result *>&1
        @($out).Count | Should -Be 0
    }
}

Describe 'Show-WtOutputScreen' {
    It 'renders the lines as a scrollable read-only list with the output footer' {
        $seen = $null
        Mock Invoke-WtListScreen { $script:seen = @{ Items = @($Items); Footer = $FooterText }; @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = -1 } }
        Show-WtOutputScreen -Breadcrumb 'B' -Lines @('one', 'two')
        @($script:seen.Items | ForEach-Object Label) | Should -Be @('one', 'two')
        foreach ($i in $script:seen.Items) { Test-WtItemFocusable -Item $i | Should -BeFalse }
        $script:seen.Footer | Should -Be (Get-Translation 'OutputFooter')
    }
    It 'says so when a command printed nothing at all' {
        Mock Invoke-WtListScreen { $script:seen = @{ Items = @($Items) }; @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = -1 } }
        Show-WtOutputScreen -Breadcrumb 'B' -Lines @()
        @($script:seen.Items | ForEach-Object Label) | Should -Be @((Get-Translation 'OutputEmpty'))
    }
}

Describe 'Wi-Fi password lookup (panel flow, no console)' {
    It 'asks for the name in the panel and shows the profile in the box' {
        $shown = $null
        Invoke-WtWifiPasswordAction -AskName { '  HomeNet  ' } `
            -LookUp { param($Name) $script:asked = $Name; [PSCustomObject]@{ Found = $true; Name = $Name; Authentication = 'WPA2'; Key = 'hunter2' } } `
            -ShowResult { param($Lines) $script:shown = @($Lines) }
        $script:asked | Should -Be 'HomeNet'
        @($script:shown) | Should -Contain ('{0}: {1}' -f (Get-Translation 'WiFiPassword'), 'hunter2')
    }
    It 'an empty name just returns - nothing is looked up and nothing is drawn' {
        Invoke-WtWifiPasswordAction -AskName { '   ' } -LookUp { throw 'must not look up' } -ShowResult { throw 'must not draw' }
    }
    It 'reports a missing profile and a passwordless one' {
        @(Get-WtWifiPasswordLines -Result ([PSCustomObject]@{ Found = $false })) | Should -Be @((Get-Translation 'WiFiProfileNotFound'))
        $open = @(Get-WtWifiPasswordLines -Result ([PSCustomObject]@{ Found = $true; Name = 'Cafe'; Authentication = 'Open'; Key = '' }))
        $open | Should -Contain (Get-Translation 'NoPasswordFound')
    }
}

Describe 'Show-WtSavableReport' {
    It 'offers S on the footer and appends where it saved' {
        $script:frames = New-Object 'System.Collections.Generic.List[object]'
        $script:keys = New-Object 'System.Collections.Generic.Queue[string]'
        's', '' | ForEach-Object { $script:keys.Enqueue($_) }
        Show-WtSavableReport -Breadcrumb 'B' -Lines @('disk ok', 'fan ok') -ReportName 'health' `
            -SaveAction { param($Name, $Rows) "C:\reports\$Name.txt" } `
            -ShowResult { param($Crumb, $Rows, $Footer) $script:frames.Add(@{ Rows = @($Rows); Footer = $Footer }); $script:keys.Dequeue() }
        $script:frames.Count | Should -Be 2
        $script:frames[0].Footer | Should -Match ([regex]::Escape((Get-Translation 'OutputSaveHint')))
        $script:frames[1].Rows[-1] | Should -Be ('{0}: {1}' -f (Get-Translation 'ReportSaved'), 'C:\reports\health.txt')
        $script:frames[1].Footer | Should -Be (Get-Translation 'OutputFooter')
    }
    It 'leaving without pressing S saves nothing' {
        Show-WtSavableReport -Breadcrumb 'B' -Lines @('x') -ReportName 'health' `
            -SaveAction { throw 'must not save' } -ShowResult { param($Crumb, $Rows, $Footer) '' }
    }
}

Describe 'Invoke-WtSystemHealthAction' {
    It 'hands its lines to the savable report instead of writing to the console' {
        $seen = $null
        Invoke-WtSystemHealthAction -GetLines { @('disk: ok', 'cpu: 45 C') } -Show { param($Crumb, $Rows) $script:seen = @($Rows) }
        @($script:seen) | Should -Be @('disk: ok', 'cpu: 45 C')
    }
}

Describe 'Panel prompt surface' {
    It 'defines the panel functions and the captured-output mode' {
        foreach ($fn in 'Show-WtPanelMessage', 'Read-WtPanelAnswer', 'Confirm-WtDestructiveAction', 'Invoke-WtCreateRestorePointAction', 'Split-WtWrappedLines', 'Invoke-WtCapturedAction', 'Show-WtOutputScreen', 'Wait-WtEnter') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    It 'console-output mode is gone - nothing clears the screen to print any more' {
        foreach ($fn in 'Invoke-WtConsoleAction', 'New-WtConsoleActionItem') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$fn must not come back"
        }
        $src = Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1') -Raw
        $src | Should -Not -Match 'Console = \$true'
    }
    It 'no menu row anywhere still asks for console-output mode' {
        $rows = @(Get-WtMainMenuItems) + @(Get-WtBasicToolsItems) + @(Get-WtActionToolsItems) + @(Get-WtInfoToolsItems) + @(Get-WtProfilesMenuItems) | Where-Object { $_.Data }
        foreach ($row in $rows) {
            if ($row.Data) { $row.Data.Console | Should -BeNullOrEmpty -Because $row.Name }
        }
    }
    It 'Confirm-WtDestructiveAction accepts the typed word in any case, and nothing else' {
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) 'YES' } | Should -BeTrue
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) 'yes' } | Should -BeTrue
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) 'ye' } | Should -BeFalse
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) $null } | Should -BeFalse
    }
    It 'Confirm-WtDestructiveAction shows the consequence and extra lines to the prompt' {
        $script:seen = $null
        Confirm-WtDestructiveAction -Consequence 'boom' -Lines @('detail 1') -ReadAnswer { param($Lines, $Prompt) $script:seen = $Lines; 'no' } | Out-Null
        @($script:seen) | Should -Contain 'boom'
        @($script:seen) | Should -Contain 'detail 1'
    }
}

Describe 'Get-WtApplyScreenItems' {
    BeforeEach {
        $script:catalogA = @(
            [PSCustomObject]@{ Name = 'one'; DisplayLabel = 'One'; Risk = 'SAFE'; Consequence = $null }
            [PSCustomObject]@{ Name = 'two'; DisplayLabel = 'Two'; Risk = 'ADVANCED'; Consequence = 'bad' }
        )
        $script:groups = @(
            @{ SectionKey = 'A'; HeaderKey = 'Telemetry'; GetCatalog = { param($g) $g.Data.Catalog }; Data = @{ Catalog = $script:catalogA }
               GetEntryState = { param($e, $g) if ($e.Name -eq 'two') { @{ Applied = $true; Available = $true } } else { @{ Applied = $false; Available = $true } } } }
            @{ SectionKey = 'B'; HeaderKey = $null; Radio = $true; InfoKey = 'DohSupportedInfo'
               GetCatalog = { param($g) @([PSCustomObject]@{ Name = 'r1'; DisplayLabel = 'R1'; Risk = 'CAUTION' }, [PSCustomObject]@{ Name = 'r2'; DisplayLabel = 'R2'; Risk = 'CAUTION' }) }
               GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true; StateLabel = '' } } }
        )
    }
    It 'emits a header, check rows with live state, then an info row and radio rows for a radio group' {
        $built = Get-WtApplyScreenItems -Groups $groups
        $kinds = @($built.Items | ForEach-Object Kind)
        $kinds | Should -Be @('Header', 'Check', 'Check', 'Info', 'Radio', 'Radio')
        $built.Items[1].StateLabel | Should -Be (Get-Translation 'NotApplied')
        $built.Items[2].StateLabel | Should -Be (Get-Translation 'Applied')
        $built.Items[2].Selectable | Should -BeFalse
        $built.Items[4].Group | Should -Be 'B'
    }
    It 'passes the group object to both delegates (no closures needed)' {
        $built = Get-WtApplyScreenItems -Groups @($groups[0])
        $built.Items[1].Label | Should -Be 'One'
    }
    It 'fills Meta with section, entry and group data' {
        $built = Get-WtApplyScreenItems -Groups $groups
        $built.Meta['one'].SectionKey | Should -Be 'A'
        $built.Meta['one'].Entry.Name | Should -Be 'one'
        $built.Meta['r1'].SectionKey | Should -Be 'B'
    }
    It 'emits a sub-header whenever HeaderField changes' {
        $g = @{ SectionKey = 'S'; HeaderKey = $null; HeaderField = 'Category'
                GetCatalog = { param($g) @([PSCustomObject]@{ Name = 'x'; DisplayLabel = 'X'; Risk = 'SAFE'; Category = 'Telemetry' }, [PSCustomObject]@{ Name = 'y'; DisplayLabel = 'Y'; Risk = 'SAFE'; Category = 'Telemetry' }, [PSCustomObject]@{ Name = 'z'; DisplayLabel = 'Z'; Risk = 'SAFE'; Category = 'ExplorerView' }) }
                GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } } }
        $kinds = @((Get-WtApplyScreenItems -Groups @($g)).Items | ForEach-Object Kind)
        $kinds | Should -Be @('Header', 'Check', 'Check', 'Spacer', 'Header', 'Check')
    }
    It 'opens every group after the first with a blank row, and never the first one' {
        $mk = { param($key) @{ SectionKey = $key; HeaderKey = 'Telemetry'
                GetCatalog = { param($g) @([PSCustomObject]@{ Name = ($g.SectionKey + 'x'); DisplayLabel = 'X'; Risk = 'SAFE' }) }
                GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } } } }
        $kinds = @((Get-WtApplyScreenItems -Groups @((& $mk 'P'), (& $mk 'Q'), (& $mk 'R'))).Items | ForEach-Object Kind)
        $kinds | Should -Be @('Header', 'Check', 'Spacer', 'Header', 'Check', 'Spacer', 'Header', 'Check')
    }
    It 'spacer rows stay out of Meta and out of the focus order' {
        $built = Get-WtApplyScreenItems -Groups $groups
        foreach ($row in @($built.Items | Where-Object Kind -eq 'Spacer')) {
            $built.Meta.ContainsKey([string]$row.Name) | Should -BeFalse
            Test-WtItemFocusable -Item $row | Should -BeFalse
        }
    }
    It 'an entry flagged unavailable is not selectable and shows its StateLabel' {
        $g = @{ SectionKey = 'S'; HeaderKey = $null; GetCatalog = { param($g) @([PSCustomObject]@{ Name = 'gpu'; DisplayLabel = 'GPU'; Risk = 'CAUTION' }) }
                GetEntryState = { param($e, $g) @{ Applied = $false; Available = $false; StateLabel = 'n/a' } } }
        $item = (Get-WtApplyScreenItems -Groups @($g)).Items[0]
        $item.Selectable | Should -BeFalse
        $item.StateLabel | Should -Be 'n/a'
    }
    It 'an applied row is markable (Selectable + Removable) only when its section has TurnOff and IsRemovable agrees' {
        $sections = @(
            [PSCustomObject]@{ Key = 'A'; TitleKey = 'T'; TurnOff = { param([string[]]$Names, $Data) }; IsRemovable = { param($Entry) $Entry.Name -ne 'two' } }
            [PSCustomObject]@{ Key = 'B'; TitleKey = 'T' }
        )
        $catalog = @(
            [PSCustomObject]@{ Name = 'one'; DisplayLabel = 'One'; Risk = 'SAFE' }
            [PSCustomObject]@{ Name = 'two'; DisplayLabel = 'Two'; Risk = 'SAFE' }
        )
        $allApplied = { param($e, $g) @{ Applied = $true; Available = $true } }
        $gA = @{ SectionKey = 'A'; HeaderKey = $null; GetCatalog = { param($g) $g.Data.Catalog }; Data = @{ Catalog = $catalog }; GetEntryState = $allApplied }
        $gB = @{ SectionKey = 'B'; HeaderKey = $null; GetCatalog = { param($g) $g.Data.Catalog }; Data = @{ Catalog = $catalog }; GetEntryState = $allApplied }
        $built = Get-WtApplyScreenItems -Groups @($gA, $gB) -Sections $sections
        $built.Items[0].Selectable | Should -BeTrue
        $built.Items[0].Removable | Should -BeTrue
        $built.Items[1].Selectable | Should -BeFalse
        $built.Items[1].Removable | Should -BeFalse
        $built.Items[2].Selectable | Should -BeFalse
        $built.Items[2].Applied | Should -BeTrue
    }
    It 'a not-applied row is Selectable and never Removable' {
        $sections = @([PSCustomObject]@{ Key = 'A'; TitleKey = 'T'; TurnOff = { param([string[]]$Names, $Data) } })
        $g = @{ SectionKey = 'A'; HeaderKey = $null; GetCatalog = { param($g) @([PSCustomObject]@{ Name = 'x'; DisplayLabel = 'X'; Risk = 'SAFE' }) }; GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } } }
        $row = (Get-WtApplyScreenItems -Groups @($g) -Sections $sections).Items[0]
        $row.Selectable | Should -BeTrue
        $row.Removable | Should -BeFalse
    }
}

Describe 'Get-WtApplyResultLines' {
    BeforeAll {
        $script:sections = @([PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; GetCatalog = { @() } })
    }
    It 'lists applied and failed rows under the section title' {
        $result = [PSCustomObject]@{ Aborted = $false; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@(); Sections = @(
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; Outcome = 'Applied'; Results = @(
                [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'Fax'; CatalogEntry = 'Fax' }; Applied = $true; Error = $null }
                [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'Spooler'; CatalogEntry = 'Spooler' }; Applied = $false; Error = 'denied' }
            ) }
        ) }
        $lines = @(Get-WtApplyResultLines -Result $result -Sections $sections)
        $lines[0] | Should -Be (Get-Translation 'ServicesManagement')
        $lines[1] | Should -Match ('Fax.*' + [regex]::Escape((Get-Translation 'Applied')))
        $lines[2] | Should -Match ('Spooler.*' + [regex]::Escape((Get-Translation 'NotApplied')) + '.*denied')
    }
    It 'explains Aborted and Skipped sections and a gate-aborted run' {
        $result = [PSCustomObject]@{ Aborted = $true; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@(); Sections = @(
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; Outcome = 'Aborted'; Results = @() }
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; Outcome = 'Skipped'; Results = @() }
        ) }
        $lines = @(Get-WtApplyResultLines -Result $result -Sections $sections)
        $lines | Should -Contain ('  ' + (Get-Translation 'ActionCancelled'))
        $lines | Should -Contain ('  ' + (Get-Translation 'ProfileImportStopped'))
        $empty = [PSCustomObject]@{ Aborted = $true; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@(); Sections = @() }
        @(Get-WtApplyResultLines -Result $empty -Sections $sections) | Should -Be @((Get-Translation 'ActionCancelled'))
    }
}

Describe 'Invoke-WtApplySelection' {
    BeforeEach {
        $script:sections = @([PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Fax'; Risk = 'SAFE' }) } })
        $script:meta = @{ Fax = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Fax'; Risk = 'SAFE' }; Data = $null } }
        $script:sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $sel.Add('Fax') | Out-Null
        $script:enginePlans = New-Object 'System.Collections.Generic.List[object]'
        $script:okEngine = {
            param($Plan)
            $script:enginePlans.Add($Plan)
            [PSCustomObject]@{ Aborted = $false; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@(); Sections = @(
                [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; Outcome = 'Applied'; Results = @([PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'Fax'; CatalogEntry = 'Fax' }; Applied = $true; Error = $null }) }
            ) }
        }
    }
    It 'Enter on the summary applies; the engine receives the plan once' {
        $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Sections $sections -ReadAnswer { param($Lines, $Prompt, $Risk) '' } -Engine $okEngine -ShowMessage { }
        $r.Applied | Should -BeTrue
        $script:enginePlans.Count | Should -Be 1
        @($script:enginePlans[0].Sections | ForEach-Object Key) | Should -Be @('Services')
    }
    It 'any non-empty answer on the summary cancels without calling the engine' {
        $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Sections $sections -ReadAnswer { param($Lines, $Prompt, $Risk) 'n' } -Engine $okEngine -ShowMessage { }
        $r.Applied | Should -BeFalse
        $script:enginePlans.Count | Should -Be 0
    }
    It 'typing the gate word applies straight away - no second Enter on a summary' {
        $script:advSections = @([PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Risky'; Risk = 'ADVANCED' }) } })
        $script:advMeta = @{ Risky = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Risky'; DisplayLabel = 'Risky'; Risk = 'ADVANCED' }; Data = $null } }
        $script:advSel = New-Object 'System.Collections.Generic.HashSet[string]'
        $advSel.Add('Risky') | Out-Null
        $script:seenPrompts = New-Object 'System.Collections.Generic.List[string]'
        $reader = { param($Lines, $Prompt, $Risk) $script:seenPrompts.Add([string]$Prompt); 'confirm' }
        $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection $advSel -Meta $advMeta -Sections $advSections -ReadAnswer $reader -Engine $okEngine -ShowMessage { }
        $r.Applied | Should -BeTrue
        @($script:seenPrompts | Where-Object { $_ -like ((Get-Translation 'ApplyNowPrompt') -replace '\{0\}', '*') }).Count | Should -Be 0
        @($script:seenPrompts | Where-Object { $_ -eq (Get-Translation 'ApplyNothingLeft') }).Count | Should -Be 0
    }
    It 'a plain apply with no typed gate still asks for Enter on the summary' {
        $script:seenPrompts = New-Object 'System.Collections.Generic.List[string]'
        $reader = { param($Lines, $Prompt, $Risk) $script:seenPrompts.Add([string]$Prompt); '' }
        Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Sections $sections -ReadAnswer $reader -Engine $okEngine -ShowMessage { } | Out-Null
        @($script:seenPrompts | Where-Object { $_ -like ((Get-Translation 'ApplyNowPrompt') -replace '\{0\}', '*') }).Count | Should -Be 1
    }
    It 'an empty selection applies nothing' {
        $none = New-Object 'System.Collections.Generic.HashSet[string]'
        (Invoke-WtApplySelection -Breadcrumb 'B' -Selection $none -Meta $meta -Sections $sections -ReadAnswer { throw 'no prompt' } -Engine $okEngine -ShowMessage { }).Applied | Should -BeFalse
    }
    It 'offers exactly one Explorer restart when the engine asks for it' {
        $script:prompts = @()
        $engine = {
            param($Plan)
            [PSCustomObject]@{ Aborted = $false; NeedsExplorerRestart = $true; RebootEntryNames = [string[]]@('EnableGpuScheduling'); Sections = @(
                [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $true; Outcome = 'Applied'; Results = @([PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'Fax'; CatalogEntry = 'Fax' }; Applied = $true; Error = $null }) }
            ) }
        }
        $script:explorerPrompt = Get-WtYesNoPrompt -Text (Get-Translation 'RestartExplorerPrompt')
        $reader = { param($Lines, $Prompt, $Risk) $script:prompts += $Prompt; if ($Prompt -eq $script:explorerPrompt) { 'n' } else { '' } }
        Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Sections $sections -ReadAnswer $reader -Engine $engine -ShowMessage { } -RestartExplorer { throw 'must not restart' } | Out-Null
        @($script:prompts | Where-Object { $_ -eq $script:explorerPrompt }).Count | Should -Be 1
    }
    It 'prints no success line when the only section aborted' {
        $script:lastLines = @()
        $abortEngine = {
            param($Plan)
            [PSCustomObject]@{ Aborted = $true; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@(); Sections = @(
                [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; Outcome = 'Aborted'; Results = @() }
            ) }
        }
        $reader = { param($Lines, $Prompt, $Risk) $script:lastLines = @($Lines); '' }
        $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Sections $sections -ReadAnswer $reader -Engine $abortEngine -ShowMessage { }
        $r.Applied | Should -BeFalse
        @($script:lastLines) | Should -Contain ('  ' + (Get-Translation 'ActionCancelled'))
        @($script:lastLines) | Should -Not -Contain (Get-Translation 'ApplySummaryDone')
    }
    It 'has the apply-flow keys in both languages' {
        foreach ($key in 'ApplyFooter', 'MarkFirstHint', 'ApplyNowPrompt', 'ApplyingFooter', 'SettingsCount', 'ApplySummaryDone', 'ApplyNothingLeft') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
        $script:Translations['EN']['ApplyNowPrompt'] | Should -Match '\{0\}'
        $script:Translations['EN']['SettingsCount'] | Should -Match '\{0\}'
    }
    It 'the summary and the prompt word both directions and the engine gets a plan with RemoveNames' {
        $script:prompts = New-Object 'System.Collections.Generic.List[string]'
        $script:seenPlan = $null
        $sections = @([PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; StageOnly = $false })
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        'on', 'off' | ForEach-Object { $sel.Add($_) | Out-Null }
        $meta = @{
            on  = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'on'; DisplayLabel = 'On'; Risk = 'SAFE' }; Data = $null }
            off = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'off'; DisplayLabel = 'Off'; Risk = 'SAFE' }; Data = $null }
        }
        $items = @(
            New-WtListItem -Kind 'Check' -Name 'on' -Label 'On' -Applied $true -Removable $true
            New-WtListItem -Kind 'Check' -Name 'off' -Label 'Off'
        )
        $engine = { param($Plan) $script:seenPlan = $Plan; [PSCustomObject]@{ Aborted = $false; Sections = @(); NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@() } }
        Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Items $items -Sections $sections `
            -ReadAnswer { param($Lines, $Prompt, $Risk) $script:prompts.Add(($Lines -join '|') + '##' + $Prompt); '' } `
            -ShowMessage { param($Lines, $Footer) } -Engine $engine | Out-Null
        $expected = Format-WtDirectionCounts -ApplyCount 1 -RemoveCount 1
        $prompts[0] | Should -Match ([regex]::Escape('  ' + (Get-Translation 'Telemetry') + ': ' + $expected))
        $prompts[0] | Should -Match ([regex]::Escape((Get-Translation 'ApplyNowPrompt') -f $expected))
        @($seenPlan.Sections[0].RemoveNames) | Should -Be @('on')
        @($seenPlan.Sections[0].ApplyNames) | Should -Be @('off')
    }
    It 'an engine result with one Apply row and one Remove row shows ApplyDoneSummary before ApplySummaryDone, after the reboot note' {
        $sections = @([PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; StageOnly = $false })
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        'on', 'off' | ForEach-Object { $sel.Add($_) | Out-Null }
        $meta = @{
            on  = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'on'; DisplayLabel = 'On'; Risk = 'SAFE' }; Data = $null }
            off = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'off'; DisplayLabel = 'Off'; Risk = 'SAFE' }; Data = $null }
        }
        $items = @(
            New-WtListItem -Kind 'Check' -Name 'on' -Label 'On' -Applied $true -Removable $true
            New-WtListItem -Kind 'Check' -Name 'off' -Label 'Off'
        )
        $engine = {
            param($Plan)
            [PSCustomObject]@{
                Aborted = $false; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@('off')
                Sections = @(
                    [PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; Outcome = 'Applied'; Results = @(
                        [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'off'; CatalogEntry = 'off' }; Applied = $true; Error = $null; Direction = 'Apply' }
                        [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'on'; CatalogEntry = 'on' }; Applied = $true; Error = $null; Direction = 'Remove' }
                    ) }
                )
            }
        }
        $script:lastLines = @()
        $reader = { param($Lines, $Prompt, $Risk) $script:lastLines = @($Lines); '' }
        Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Items $items -Sections $sections `
            -ReadAnswer $reader -ShowMessage { param($Lines, $Footer) } -Engine $engine | Out-Null
        $lines = @($script:lastLines)
        $summaryIdx = [array]::IndexOf($lines, ((Get-Translation 'ApplyDoneSummary') -f 1, 1, 0))
        $summaryIdx | Should -BeGreaterThan -1
        $rebootIdx = [array]::IndexOf($lines, ((Get-Translation 'RebootRequiredNote') -f 'off'))
        $rebootIdx | Should -BeGreaterThan -1
        $doneIdx = [array]::IndexOf($lines, (Get-Translation 'ApplySummaryDone'))
        $doneIdx | Should -BeGreaterThan -1
        $rebootIdx | Should -BeLessThan $summaryIdx
        $summaryIdx | Should -BeLessThan $doneIdx
    }
    It 'a zero-row result does not contain the ApplyDoneSummary line' {
        $sections = @([PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; StageOnly = $false })
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $sel.Add('on') | Out-Null
        $meta = @{ on = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'on'; DisplayLabel = 'On'; Risk = 'SAFE' }; Data = $null } }
        $items = @(New-WtListItem -Kind 'Check' -Name 'on' -Label 'On')
        $engine = { param($Plan) [PSCustomObject]@{ Aborted = $false; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@(); Sections = @(
            [PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; Outcome = 'NothingToApply'; Results = @() }
        ) } }
        $script:lastLines = @()
        $reader = { param($Lines, $Prompt, $Risk) $script:lastLines = @($Lines); '' }
        Invoke-WtApplySelection -Breadcrumb 'B' -Selection $sel -Meta $meta -Items $items -Sections $sections `
            -ReadAnswer $reader -ShowMessage { param($Lines, $Footer) } -Engine $engine | Out-Null
        @($script:lastLines) | Should -Not -Contain ((Get-Translation 'ApplyDoneSummary') -f 0, 0, 0)
    }
}

Describe 'Invoke-WtApplyScreen' {
    BeforeEach {
        $script:groupCalls = 0
        $script:listCalls = 0
        $script:lastItems = @()
        $script:lastCounter = ''
        $script:groupSource = {
            $script:groupCalls++
            @(@{ SectionKey = 'S'; HeaderKey = $null
                 GetCatalog = { param($g) @([PSCustomObject]@{ Name = 'a'; DisplayLabel = 'A'; Risk = 'SAFE' }) }
                 GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } } })
        }
    }
    It 're-resolves a scriptblock -Groups on every rebuild' {
        Mock Invoke-WtListScreen {
            $script:listCalls++
            $script:lastItems = $Items
            $emit = if ($script:listCalls -eq 1) { 'Global' } else { 'Back' }
            @{ Emit = $emit; Char = 'p'; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        $r = Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $script:groupSource -OnHotkey { param($c) $true }
        $r.Nav | Should -Be 'Back'
        $script:listCalls | Should -Be 2
        $script:groupCalls | Should -Be 2
        @($script:lastItems).Count | Should -Be 1
    }
    It 'paints the loading panel before every build of the rows, with its own breadcrumb' {
        $script:order = New-Object System.Collections.Generic.List[string]
        Mock Show-WtListLoading { $script:order.Add('loading:' + $Breadcrumb) }
        Mock Invoke-WtListScreen {
            $script:order.Add('list')
            $emit = if ($script:order.Count -le 2) { 'Global' } else { 'Back' }
            @{ Emit = $emit; Char = 'p'; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'Ana Menu > Servisler' -Groups $script:groupSource -OnHotkey { param($c) $true } | Out-Null
        @($script:order) | Should -Be @('loading:Ana Menu > Servisler', 'list', 'loading:Ana Menu > Servisler', 'list')
    }
    It 'Show-WtListLoading paints the one-line panel in key mode only, and its text exists in both languages' {
        $script:panels = New-Object System.Collections.Generic.List[object]
        Mock Show-WtPanelMessage { $script:panels.Add(@{ Breadcrumb = $Breadcrumb; Lines = @($Lines); Footer = $FooterText }); @{ Width = 80; Height = 25 } }
        $mode = $script:WtInputMode
        try {
            $script:WtInputMode = 'Line'
            Show-WtListLoading -Breadcrumb 'B'
            $script:panels.Count | Should -Be 0
            $script:WtInputMode = 'Key'
            Show-WtListLoading -Breadcrumb 'Ana Menu > Servisler'
            $script:panels.Count | Should -Be 1
            $script:panels[0].Breadcrumb | Should -Be 'Ana Menu > Servisler'
            $script:panels[0].Lines | Should -Be @((Get-Translation 'ListLoading'))
            $script:panels[0].Footer | Should -Be ''
        }
        finally { $script:WtInputMode = $mode }
        foreach ($lang in 'EN', 'TR') { $script:Translations[$lang]['ListLoading'] | Should -Not -BeNullOrEmpty -Because $lang }
    }
    It 'shows the empty row when the groups are empty and no extras were given' {
        Mock Invoke-WtListScreen {
            $script:lastItems = $Items
            @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'B' -Groups @() | Out-Null
        @($script:lastItems).Count | Should -Be 1
        $script:lastItems[0].Label | Should -Be (Get-Translation 'NoEntriesAvailable')
    }
    It 'puts ExtraItems above the catalog rows and counts only the setting rows' {
        Mock Invoke-WtListScreen {
            $script:lastItems = $Items
            $script:lastCounter = $CounterText
            @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $script:groupSource `
            -ExtraItems { @(New-WtListItem -Kind 'Link' -Name 'L' -Label 'L' -Data @{ Screen = 'X' }) } | Out-Null
        @($script:lastItems | ForEach-Object Kind) | Should -Be @('Link', 'Check')
        $script:lastCounter | Should -Be ((Get-Translation 'SettingsCount') -f 1)
    }
    It 'an -ExtraItems call that emits nothing adds no row (the 6 extra-less Privacy screens)' {
        function Get-NoExtras {
            <#
            .SYNOPSIS
                Returns @() PURE, to prove that -ExtraItems never smuggles a null row
                into the list: "return @()" from a function collapses to nothing in
                argument position, so a naive parameter binding would see $null.
            #>
            return @()
        }
        Mock Invoke-WtListScreen {
            $script:lastItems = $Items
            @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $script:groupSource -ExtraItems (Get-NoExtras) | Out-Null
        @($script:lastItems).Count | Should -Be 1
        @($script:lastItems | ForEach-Object Kind) | Should -Be @('Check')
        @($script:lastItems | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }
    It 'returns Push for a Link row and Exit on Q' {
        Mock Invoke-WtListScreen {
            $link = New-WtListItem -Kind 'Link' -Name 'L' -Label 'L' -Data @{ Screen = 'Packages' }
            @{ Emit = 'Activate'; Char = ''; Item = $link; Selection = $Selection; CursorIndex = 0 }
        }
        $push = Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $script:groupSource
        $push.Nav | Should -Be 'Push'
        $push.Target | Should -Be 'Packages'
        Mock Invoke-WtListScreen { @{ Emit = 'Quit'; Char = 'q'; Item = $null; Selection = $Selection; CursorIndex = 0 } }
        (Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $script:groupSource).Nav | Should -Be 'Exit'
    }
    It 'Enter with nothing marked swaps the footer for the mark-first hint and applies nothing' {
        Mock Invoke-WtApplySelection { throw 'must not apply' }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            $script:lastFooter = $FooterText
            $row = New-WtListItem -Kind 'Check' -Name 'a' -Label 'A'
            $emit = if ($script:listCalls -eq 1) { 'Activate' } else { 'Back' }
            @{ Emit = $emit; Char = ''; Item = $row; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'B' -Groups $script:groupSource | Out-Null
        $script:lastFooter | Should -Be (Get-Translation 'MarkFirstHint')
        Should -Invoke Invoke-WtApplySelection -Times 0 -Exactly
    }
}

Describe 'Invoke-WtPerAppScreen (the app rows re-read live state on every rebuild)' {
    BeforeEach {
        $script:perAppSelectable = $true
        $script:perAppCapCalls = 0
        $script:perAppAppCalls = 0
        $script:perAppRows = New-Object 'System.Collections.Generic.List[object]'
        Mock Get-WtConsoleUserSid { 'S-1-5-21-1-2-3-1001' }
        Mock Get-WtAppsForCapability {
            return , @([PSCustomObject]@{
                Name         = 'Contoso.Camera_8wekyb3d8bbwe'
                DisplayLabel = 'Contoso Camera'
                Risk         = 'SAFE'
                Selectable   = $script:perAppSelectable
            })
        }
        Mock Invoke-WtApplySelection { $script:perAppSelectable = -not $script:perAppSelectable; @{ Applied = $true } }
        Mock Invoke-WtListScreen {
            if (-not $MultiSelect) {
                $script:perAppCapCalls++
                if ($script:perAppCapCalls -eq 1) {
                    return @{ Emit = 'Activate'; Char = ''; Item = @($Items)[0]; Selection = $Selection; CursorIndex = 0 }
                }
                return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
            }
            $script:perAppAppCalls++
            $row = @($Items | Where-Object { $_.Kind -eq 'Check' })[0]
            $script:perAppRows.Add($row)
            if ($script:perAppAppCalls -eq 1) {
                $null = $Selection.Add([string]$row.Name)
                return @{ Emit = 'Activate'; Char = ''; Item = $row; Selection = $Selection; CursorIndex = 0 }
            }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
    }
    It 'a row denied by the apply comes back Applied and Removable, not the stale snapshot' {
        $script:perAppSelectable = $true
        Invoke-WtPerAppScreen | Out-Null
        $script:perAppRows.Count | Should -Be 2
        $script:perAppRows[0].Applied | Should -BeFalse
        $script:perAppRows[0].Removable | Should -BeFalse
        $script:perAppRows[1].Applied | Should -BeTrue
        $script:perAppRows[1].Removable | Should -BeTrue
    }
    It 'a row allowed again by the removal comes back Not applied and unremovable' {
        $script:perAppSelectable = $false
        Invoke-WtPerAppScreen | Out-Null
        $script:perAppRows.Count | Should -Be 2
        $script:perAppRows[0].Applied | Should -BeTrue
        $script:perAppRows[0].Removable | Should -BeTrue
        $script:perAppRows[1].Applied | Should -BeFalse
        $script:perAppRows[1].Removable | Should -BeFalse
    }
    It 're-enumerates the capability with the group Data, once per rebuild' {
        Invoke-WtPerAppScreen | Out-Null
        Should -Invoke Get-WtAppsForCapability -Times 3 -Exactly -ParameterFilter { $Sid -eq 'S-1-5-21-1-2-3-1001' }
    }
}

Describe 'Invoke-WtMainLoop (navigation stack machine)' {
    It 'pushes a child, pops back to it and leaves from the root' {
        $script:verdicts = New-Object 'System.Collections.Generic.Queue[object]'
        @{ Nav = 'Push'; Target = 'BasicTools'; Char = ''; HasMarks = $false },
        @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false },
        @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } | ForEach-Object { $script:verdicts.Enqueue($_) }
        Mock Invoke-WtScreenByKey { $script:verdicts.Dequeue() }
        Invoke-WtMainLoop
        $script:verdicts.Count | Should -Be 0
        Should -Invoke Invoke-WtScreenByKey -Times 3 -Exactly
        Should -Invoke Invoke-WtScreenByKey -Times 2 -Exactly -ParameterFilter { $Key -eq 'Main' }
        Should -Invoke Invoke-WtScreenByKey -Times 1 -Exactly -ParameterFilter { $Key -eq 'BasicTools' }
    }
    It 'Exit consults Confirm-WtExit with the screen marks and stays until it agrees' {
        Mock Invoke-WtScreenByKey { @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $true } }
        $script:confirmCalls = 0
        $script:seenMarks = @()
        Mock Confirm-WtExit { $script:confirmCalls++; $script:seenMarks += [bool]$HasMarks; return ($script:confirmCalls -ge 2) }
        Invoke-WtMainLoop
        Should -Invoke Invoke-WtScreenByKey -Times 2 -Exactly
        $script:confirmCalls | Should -Be 2
        @($script:seenMarks) | Should -Be @($true, $true)
    }
    It 'survives a bridged screen that leaks Read-Host output into its verdict' {
        Mock Invoke-WtScreenByKey { 'stray read-host output'; @{ Nav = 'Exit'; Target = ''; Char = '' } }
        {
            $ErrorActionPreference = 'Stop'
            Invoke-WtMainLoop
        } | Should -Not -Throw
        Should -Invoke Invoke-WtScreenByKey -Times 1 -Exactly
    }
}

Describe 'Test-WtDiskCleanupConfigured' {
    It 'is true when any VolumeCaches subkey carries StateFlags0065' {
        Test-WtDiskCleanupConfigured -GetStateFlags { @(1, $null) } | Should -BeTrue
        Test-WtDiskCleanupConfigured -GetStateFlags { @($null, $null) } | Should -BeFalse
        Test-WtDiskCleanupConfigured -GetStateFlags { @() } | Should -BeFalse
    }
}

Describe 'winget bootstrap' {
    It 'Test-WingetInstalled enables TLS 1.2 and repairs for all users' {
        $src = (Get-Command Test-WingetInstalled).Definition
        $src | Should -Match 'Tls12'
        $src | Should -Match 'Repair-WinGetPackageManager -AllUsers -Force -Latest'
    }
    It 'the winget upgrade action passes the agreement flags' {
        $src = (Get-Command Invoke-WtWingetUpgradeAction).Definition
        $src | Should -Match '--include-unknown'
        $src | Should -Match '--accept-source-agreements'
        $src | Should -Match '--accept-package-agreements'
    }
}

Describe 'Get-WtWindowsVersionLines' {
    It 'formats caption, display version + build, architecture' {
        $lines = @(Get-WtWindowsVersionLines -GetOs { [PSCustomObject]@{ Caption = 'Microsoft Windows 10 IoT Enterprise LTSC'; BuildNumber = '19044'; OSArchitecture = '64-bit' } } -GetDisplayVersion { '21H2' })
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match 'Microsoft Windows 10 IoT Enterprise LTSC'
        $lines[1] | Should -Match '21H2'
        $lines[1] | Should -Match '19044'
        $lines[2] | Should -Match '64-bit'
    }
    It 'tolerates a missing DisplayVersion' {
        $lines = @(Get-WtWindowsVersionLines -GetOs { [PSCustomObject]@{ Caption = 'W'; BuildNumber = '22631'; OSArchitecture = 'x' } } -GetDisplayVersion { $null })
        $lines[1] | Should -Match '22631'
    }
}

Describe 'Get-WtStorageLines' {
    It 'reports free/size/percent per lettered volume' {
        $vols = @([PSCustomObject]@{ DriveLetter = 'C'; FileSystemLabel = 'OS'; FileSystem = 'NTFS'; SizeRemaining = 50GB; Size = 200GB })
        $lines = @(Get-WtStorageLines -GetVolumes { $vols })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^C: '
        $lines[0] | Should -Match '25%'
        $lines[0] | Should -Match 'NTFS'
    }
    It 'returns a not-available line when no volumes are readable' {
        @(Get-WtStorageLines -GetVolumes { @() })[0] | Should -Be (Get-Translation 'StorageNotAvailable')
    }
}

Describe 'System Settings follows the live firewall state after an apply' {
    It 'passes a scriptblock so the groups are re-resolved on every rebuild' {
        Mock Invoke-WtApplyScreen { $script:passedGroups = $Groups; @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false } }
        Invoke-WtSystemSettingsScreen | Out-Null
        $script:passedGroups -is [scriptblock] | Should -BeTrue -Because 'an array freezes the firewall state at screen build'
    }

    It 're-resolving after the firewall goes off flips the row and its label' {
        $script:fwEnabled = $true
        Mock Get-WtFirewallLiveState { @{ Enabled = $script:fwEnabled; Known = $true } }
        Mock Test-WtGpuSchedulingSupported { $true }
        Mock Test-WtDohSupported { $true }

        $firewallGroup = { @(Get-WtSystemSettingsGroups) | Where-Object SectionKey -eq 'Firewall' }

        $before = & $firewallGroup
        @(& $before.GetCatalog $before)[0].Name | Should -Be 'DisableFirewall'
        (& $before.GetEntryState $null $before).StateLabel | Should -Be (Get-Translation 'FirewallCurrentlyOn')

        $script:fwEnabled = $false
        $after = & $firewallGroup
        @(& $after.GetCatalog $after)[0].Name | Should -Be 'EnableFirewall'
        (& $after.GetEntryState $null $after).StateLabel | Should -Be (Get-Translation 'FirewallCurrentlyOff')
    }
}

Describe 'Get-WtSystemSettingsGroups' {
    It 'offers Enable when the firewall is off and nothing when its state is unknown' {
        $g = @(Get-WtSystemSettingsGroups -GpuSupported $true -FirewallState @{ Enabled = $false; Known = $true } -DohSupported $true) | Where-Object SectionKey -eq 'Firewall'
        (@(& $g.GetCatalog $g))[0].Name | Should -Be 'EnableFirewall'
        (& $g.GetEntryState (@(& $g.GetCatalog $g))[0] $g).StateLabel | Should -Be (Get-Translation 'FirewallCurrentlyOff')
        $u = @(Get-WtSystemSettingsGroups -GpuSupported $true -FirewallState @{ Enabled = $false; Known = $false } -DohSupported $true) | Where-Object SectionKey -eq 'Firewall'
        @(& $u.GetCatalog $u).Count | Should -Be 0
    }
    It 'marks GPU scheduling unavailable when WDDM does not support it' {
        $g = @(Get-WtSystemSettingsGroups -GpuSupported $false -FirewallState @{ Enabled = $true; Known = $true } -DohSupported $true) | Where-Object SectionKey -eq 'GamingTweaks'
        $entry = @(& $g.GetCatalog $g) | Where-Object Name -eq 'EnableGpuScheduling'
        (& $g.GetEntryState $entry $g).Available | Should -BeFalse
    }
    It 'DNS is a radio group with the DoH info line and blank state labels' {
        $g = @(Get-WtSystemSettingsGroups -GpuSupported $true -FirewallState @{ Enabled = $true; Known = $true } -DohSupported $false) | Where-Object SectionKey -eq 'DnsPreset'
        $g.Radio | Should -BeTrue
        $g.InfoKey | Should -Be 'DohNotSupportedDisclosure'
        (& $g.GetEntryState (@(& $g.GetCatalog $g))[0] $g).StateLabel | Should -Be ''
    }
    It 'every group header key exists in both languages' {
        foreach ($key in 'GroupPowerPerformance', 'GroupGaming', 'GroupStartup', 'GroupFirewall', 'GroupContextMenu', 'GroupExplorerView', 'GroupDns', 'GroupBlocklist', 'FirewallCurrentlyOn', 'FirewallCurrentlyOff') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
}

Describe 'Get-WtPackagesGroups' {
    It 'hides not-installed packages by default and shows all with the toggle' {
        $installedNames = @(@(Get-WtPackageCatalog) | Select-Object -First 12 | ForEach-Object Name)
        $fakeState = { param($name) [PSCustomObject]@{ Installed = ($installedNames -contains $name) } }
        $g = Get-WtPackagesGroups -ShowAll $false -GetState $fakeState
        @(& $g.GetCatalog $g | ForEach-Object Name | Sort-Object) | Should -Be @($installedNames | Sort-Object)
        $all = Get-WtPackagesGroups -ShowAll $true -GetState $fakeState
        @(& $all.GetCatalog $all).Count | Should -BeGreaterOrEqual 120
    }
    It 'falls back to the full list when fewer than 10 packages are installed' {
        $g = Get-WtPackagesGroups -ShowAll $false -GetState { param($name) [PSCustomObject]@{ Installed = $false } }
        @(& $g.GetCatalog $g).Count | Should -BeGreaterOrEqual 120
    }
    It 'still falls back at exactly 9 installed, and stops falling back at 10' {
        $nineNames = @(@(Get-WtPackageCatalog) | Select-Object -First 9 | ForEach-Object Name)
        $nine = Get-WtPackagesGroups -ShowAll $false -GetState { param($name) [PSCustomObject]@{ Installed = ($nineNames -contains $name) } }
        @(& $nine.GetCatalog $nine).Count | Should -BeGreaterOrEqual 120
        $tenNames = @(@(Get-WtPackageCatalog) | Select-Object -First 10 | ForEach-Object Name)
        $ten = Get-WtPackagesGroups -ShowAll $false -GetState { param($name) [PSCustomObject]@{ Installed = ($tenNames -contains $name) } }
        @(& $ten.GetCatalog $ten | ForEach-Object Name | Sort-Object) | Should -Be @($tenNames | Sort-Object)
    }
    It 'takes exactly one machine-wide package snapshot per build, not one lookup per row' {
        $script:snapshotCalls = 0
        $fakeSnapshot = {
            $script:snapshotCalls++
            @([PSCustomObject]@{ Name = 'Microsoft.BingWeather'; PackageFullName = 'Microsoft.BingWeather_1_x64__8wekyb3d8bbwe' })
        }
        $g = Get-WtPackagesGroups -ShowAll $true -GetSnapshot $fakeSnapshot
        $script:snapshotCalls | Should -Be 1
        @($g.Data.States.Keys).Count | Should -BeGreaterOrEqual 120
        $g.Data.States['Microsoft.BingWeather'].Installed | Should -BeTrue
        $g.Data.States['Microsoft.BingNews'].Installed | Should -BeFalse
    }
    It 'uses the Group field as sub-headers' { (Get-WtPackagesGroups -ShowAll $true -GetState { param($name) [PSCustomObject]@{ Installed = $true } }).HeaderField | Should -Be 'Group' }
}

Describe 'Get-WtPackageStatesFromSnapshot (one dictionary, not a pipeline per row)' {
    BeforeAll {
        $script:fakeSnap = @(
            [PSCustomObject]@{ Name = 'microsoft.bingweather'; PackageFullName = 'x' }
            [PSCustomObject]@{ Name = 'Microsoft.BingWeather'; PackageFullName = 'y' }
            [PSCustomObject]@{ Name = 'Facebook.Instagram'; PackageFullName = 'z' }
            [PSCustomObject]@{ Name = 'Clipchamp.Clipchamp'; PackageFullName = 'w' }
        )
        $script:fakeCatalog = @(
            [PSCustomObject]@{ Name = 'Microsoft.BingWeather'; RemovalMethod = 'Appx' }
            [PSCustomObject]@{ Name = 'Facebook'; RemovalMethod = 'Appx' }
            [PSCustomObject]@{ Name = '*Clipchamp*'; RemovalMethod = 'Appx' }
            [PSCustomObject]@{ Name = 'Microsoft.BingNews'; RemovalMethod = 'Appx' }
            [PSCustomObject]@{ Name = 'Microsoft.OneDrive'; RemovalMethod = 'WinGet' }
        )
    }
    It 'agrees with the per-row Get-WtPackageLiveInstalled on every entry: exact (case-insensitive, first hit wins), wildcard, near-miss, WinGet' {
        $present = { param($p) $true }
        $fast = Get-WtPackageStatesFromSnapshot -Catalog $script:fakeCatalog -Snapshot $script:fakeSnap -TestPathAction $present
        $snapshot = $script:fakeSnap
        foreach ($e in $script:fakeCatalog) {
            $slow = Get-WtPackageLiveInstalled -Entry $e -GetPackageAction { $snapshot } -TestPathAction $present
            $fast[$e.Name].Installed | Should -Be $slow.Installed -Because $e.Name
            $fast[$e.Name].Name | Should -Be $slow.Name -Because $e.Name
        }
        $fast['Microsoft.BingWeather'].Name | Should -Be 'microsoft.bingweather'
        $fast['Facebook'].Installed | Should -BeFalse
        $fast['*Clipchamp*'].Installed | Should -BeTrue
        $fast['Microsoft.OneDrive'].Installed | Should -BeTrue
        @($fast.Keys).Count | Should -Be 5
    }
    It 'Get-WtPackagesGroups builds its states through it from the one snapshot' {
        (Get-Command Get-WtPackagesGroups).Definition | Should -Match 'Get-WtPackageStatesFromSnapshot'
        $g = Get-WtPackagesGroups -ShowAll $true -GetSnapshot { $script:fakeSnap }
        $g.Data.States['Microsoft.BingWeather'].Installed | Should -BeTrue
        $g.Data.States['Microsoft.BingNews'].Installed | Should -BeFalse
    }
}

Describe 'Get-WtPrivacyGroups' {
    It 'puts existing sections first (with headers) and the hardening section last with Category sub-headers' {
        $groups = @(Get-WtPrivacyGroups -Key 'PrivacyTelemetry' -IsWindows11 $true)
        @($groups | ForEach-Object SectionKey) | Should -Be @('Telemetry', 'ActivityAdvertising', 'HardeningPrivacy')
        $groups[0].HeaderKey | Should -Be 'Telemetry'
        $groups[1].HeaderKey | Should -Be 'ActivityAndAdvertising'
        $groups[-1].HeaderKey | Should -Be 'HardeningMoreSettings'
        $groups[-1].HeaderField | Should -Be 'Category'
    }
    It 'reads the existing sections through the apply section catalog, so state stays single-sourced' {
        $fake = @([PSCustomObject]@{
            Key = 'Telemetry'; TitleKey = 'FakeTitle'
            GetCatalog = { @([PSCustomObject]@{ Name = 'Fake' }) }
            GetState = { param($Entry) if ($Entry.Name -eq 'Fake') { 'Applied' } else { 'NotApplied' } }
        })
        $groups = @(Get-WtPrivacyGroups -Key 'PrivacyTelemetry' -IsWindows11 $true -Sections $fake)
        @($groups | ForEach-Object SectionKey) | Should -Be @('Telemetry', 'HardeningPrivacy')
        $groups[0].HeaderKey | Should -Be 'FakeTitle'
        $entry = @(& $groups[0].GetCatalog $groups[0])[0]
        $entry.Name | Should -Be 'Fake'
        (& $groups[0].GetEntryState $entry $groups[0]).Applied | Should -BeTrue
        (& $groups[0].GetEntryState ([PSCustomObject]@{ Name = 'Other' }) $groups[0]).Applied | Should -BeFalse
    }
    It 'hosts the Security group on the Windows Update screen under its own header' {
        $groups = @(Get-WtPrivacyGroups -Key 'PrivacyUpdate' -IsWindows11 $true)
        @($groups | ForEach-Object SectionKey) | Should -Be @('HardeningUpdate', 'HardeningSecurity')
        $groups[0].HeaderKey | Should -BeNullOrEmpty
        $groups[1].HeaderKey | Should -Be 'PrivacySecuritySection'
        $groups[1].HeaderField | Should -Be 'Category'
    }
    It 'resolves every hardening catalog once into Data - never inside the row delegate' {
        foreach ($g in @(Get-WtPrivacyGroups -Key 'PrivacyUpdate' -IsWindows11 $true)) {
            @($g.Data.Catalog).Count | Should -BeGreaterThan 0
            $g.GetCatalog.ToString() | Should -Not -Match 'Get-WtHardeningCatalog' -Because 'the delegate runs once per rebuild and must not re-scan the rows'
        }
    }
    It 'honours the OS filter it is given' {
        $w11 = @(Get-WtPrivacyGroups -Key 'PrivacyAi' -IsWindows11 $true)[-1]
        $w10 = @(Get-WtPrivacyGroups -Key 'PrivacyAi' -IsWindows11 $false)[-1]
        @(& $w11.GetCatalog $w11).Count | Should -BeGreaterThan @(& $w10.GetCatalog $w10).Count
    }
    It 'rejects an unknown screen key' {
        { Get-WtPrivacyGroups -Key 'PrivacyNope' } | Should -Throw
    }
    It 'App Permissions adds the per-app link above the rows' {
        $extra = @(Get-WtPrivacyExtraItems -Key 'PrivacyAppPermissions')
        $extra[0].Kind | Should -Be 'Link'
        $extra[0].Data.Screen | Should -Be 'PerApp'
        @(Get-WtPrivacyExtraItems -Key 'PrivacyAi').Count | Should -Be 0
    }
    It 'screen title keys exist in both languages' {
        foreach ($s in @(Get-WtPrivacyScreenCatalog)) {
            $script:Translations['EN'].ContainsKey($s.TitleKey) | Should -BeTrue -Because "EN needs '$($s.TitleKey)'"
            $script:Translations['TR'].ContainsKey($s.TitleKey) | Should -BeTrue -Because "TR needs '$($s.TitleKey)'"
        }
        foreach ($key in 'PrivacySecurityScreen', 'PrivacySecuritySection', 'HardeningMoreSettings') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
    It 'the screen registry dispatches every Privacy link and keeps no Security case' {
        $src = (Get-Command Invoke-WtScreenByKey).Definition
        foreach ($t in @((Get-WtPrivacyMenuItems) | ForEach-Object { $_.Data.Screen })) { $src | Should -Match ([regex]::Escape("'$t'")) }
        $src | Should -Not -Match ([regex]::Escape("'PrivacySecurity'"))
        $src | Should -Match ([regex]::Escape("'Privacy' { return Invoke-WtPrivacyMenuScreen }"))
    }
}

Describe 'Get-WtUndoScreenItems' {
    It 'lists entries newest first as actions carrying the entry path' {
        $entries = @(
            [PSCustomObject]@{ Path = 'C:\u\2.json'; Timestamp = '2026-08-20T10:00:00'; Action = 'Disable Services'; Items = @(1, 2) }
            [PSCustomObject]@{ Path = 'C:\u\1.json'; Timestamp = '2026-08-19T10:00:00'; Action = 'Apply Telemetry Settings'; Items = @(1) }
        )
        $items = @(Get-WtUndoScreenItems -Entries $entries)
        $items.Count | Should -Be 2
        $items[0].Kind | Should -Be 'Action'
        $items[0].Data.EntryPath | Should -Be 'C:\u\2.json'
        $items[0].Label | Should -Match 'Disable Services'
    }
    It 'shows an info row when the log is empty' {
        $items = @(Get-WtUndoScreenItems -Entries @())
        $items.Count | Should -Be 1
        $items[0].Kind | Should -Be 'Info'
    }
    It 'hides entries that were already restored (RestoredAt set), keeping the others in order' {
        $entries = @(
            [PSCustomObject]@{ Path = 'C:\u\3.json'; Timestamp = '2026-08-21T10:00:00'; Action = 'Disable Services'; Items = @(1); RestoredAt = '2026-08-21T11:00:00' }
            [PSCustomObject]@{ Path = 'C:\u\2.json'; Timestamp = '2026-08-20T10:00:00'; Action = 'Remove Packages'; Items = @(1, 2) }
            [PSCustomObject]@{ Path = 'C:\u\1.json'; Timestamp = '2026-08-19T10:00:00'; Action = 'Apply Telemetry Settings'; Items = @(1); RestoredAt = $null }
        )
        $items = @(Get-WtUndoScreenItems -Entries $entries)
        @($items | ForEach-Object { $_.Data.EntryPath }) | Should -Be @('C:\u\2.json', 'C:\u\1.json')
        ($items | ForEach-Object Label) -join "`n" | Should -Not -Match 'previously restored'
    }
    It 'falls back to the empty-log info row when every entry was restored' {
        $entries = @([PSCustomObject]@{ Path = 'C:\u\1.json'; Timestamp = '2026-08-19T10:00:00'; Action = 'X'; Items = @(1); RestoredAt = '2026-08-19T12:00:00' })
        $items = @(Get-WtUndoScreenItems -Entries $entries)
        $items.Count | Should -Be 1
        $items[0].Kind | Should -Be 'Info'
        $items[0].Label | Should -Be (Get-Translation 'UndoMenuEmpty')
    }
}

Describe 'Get-WtProfilesMenuItems' {
    It 'offers export and import as inline panel flows, not console actions' {
        $items = @(Get-WtProfilesMenuItems)
        @($items | ForEach-Object Name) | Should -Be @('ExportProfile', 'ImportProfile')
        foreach ($i in $items) { $i.Data.Console | Should -BeNullOrEmpty; $i.Data.Action | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Undo / Profiles translations' {
    It 'defines the undo screen keys in both languages, and the old line-prompt is gone' {
        foreach ($lang in 'EN', 'TR') { $script:Translations[$lang].ContainsKey('UndoRestorePrompt') | Should -BeFalse -Because "$lang - Esc cancels now, there is no typed answer" }
        foreach ($key in @('UndoFooter', 'UndoConfirmFooter', 'UndoDetailHeader', 'UndoDetailRestoreNote', 'UndoDetailService', 'UndoDetailDns', 'UndoDetailDnsDhcp', 'UndoDetailHosts', 'UndoDetailFirewallBlock')) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
}

Describe 'Services screen: a row picks its start type' {
    It 'every catalog row offers the three start types' {
        $screen = (Get-Command Invoke-WtServicesScreen).ScriptBlock.ToString()
        $screen | Should -Match 'CycleTargets'
        $screen | Should -Match "FooterKey 'ServicesFooter'"
    }
    It 'takes one Get-Service snapshot per build and reads every row from it' {
        $screen = (Get-Command Invoke-WtServicesScreen).ScriptBlock.ToString()
        $screen | Should -Match 'Data = @\{ Services = @\(\); ByName = @\{\} \}'
        $screen | Should -Match '\$g\.Data\.Services = @\(Get-Service -ErrorAction SilentlyContinue\)'
        $screen | Should -Match '\$g\.Data\.ByName = \$byName'
        $screen | Should -Match '-GetServiceAction \{ if \(\$null -ne \$hit\)'
    }
    It 'the per-build index resolves a plain name and a per-user template exactly as Get-WtServiceState does' {
        $src = (Get-Command Invoke-WtServicesScreen).ScriptBlock.ToString()
        $code = $src.Substring($src.IndexOf('$group = @{'), $src.IndexOf('return Invoke-WtApplyScreen') - $src.IndexOf('$group = @{'))
        Mock Get-Service { @(
            [PSCustomObject]@{ Name = 'DiagTrack'; Status = 'Running'; StartType = 'Automatic' }
            [PSCustomObject]@{ Name = 'BcastDVRUserService_1a2b3'; Status = 'Stopped'; StartType = 'Manual' }
        ) }
        Invoke-Expression $code
        $rows = @(& $group.GetCatalog $group)
        $rows.Count | Should -BeGreaterThan 40
        $diag = $rows | Where-Object Name -eq 'DiagTrack' | Select-Object -First 1
        $dvr = $rows | Where-Object Name -eq 'BcastDVRUserService' | Select-Object -First 1
        $other = $rows | Where-Object { $_.Name -ne 'DiagTrack' -and -not $_.IsPerUser } | Select-Object -First 1
        (& $group.GetEntryState $diag $group).Available | Should -BeTrue
        (& $group.GetEntryState $diag $group).StateLabel | Should -Be (Format-WtServiceStateLabel -Status 'Running' -StartType 'Automatic')
        (& $group.GetEntryState $dvr $group).Available | Should -BeTrue
        (& $group.GetEntryState $other $group).Available | Should -BeFalse
    }
    It 'the cycle labels reuse the words the live state column already prints' {
        $labels = Get-WtServiceCycleLabels
        foreach ($target in (Get-WtServiceCycleTargets)) {
            $labels[$target] | Should -Be ([string](Get-Translation ('SvcStart.' + $target)))
        }
    }
    It 'the Turkish labels are the ones the user picked' {
        $script:Translations['TR']['SvcStart.Disabled'] | Should -Be 'Devre disi'
        $script:Translations['TR']['SvcStart.Manual'] | Should -Be 'El ile'
        $script:Translations['TR']['SvcStart.Automatic'] | Should -Be 'Otomatik'
    }
    It 'the screen footer says the arrows move and Space picks the start type' {
        $script:Translations['EN']['ServicesFooter'] | Should -Match 'Up/Down'
        $script:Translations['EN']['ServicesFooter'] | Should -Match 'Space:'
        $script:Translations['TR']['ServicesFooter'] | Should -Match 'Yukari/Asagi'
        $script:Translations['TR']['ServicesFooter'] | Should -Match 'Bosluk:'
    }
    It 'the apply screen lets a caller name its own footer' {
        (Get-Command Invoke-WtApplyScreen).Parameters['FooterKey'] | Should -Not -BeNullOrEmpty
        (Get-Command Invoke-WtApplyScreen).Parameters['CycleLabels'] | Should -Not -BeNullOrEmpty
    }
}

Describe 'The user is told why nothing was applied' {
    BeforeEach {
        $script:nSections = @(
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false
                               GetCatalog = { @([PSCustomObject]@{ Name = 'Risky'; Risk = 'ADVANCED' }, [PSCustomObject]@{ Name = 'Safe'; Risk = 'SAFE' }) }
                               Apply = { param([string[]]$Names, $Data) @{ Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = $true } }) } }
            }
        )
        $script:nMeta = @{
            Risky = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Risky'; DisplayLabel = 'Risky row'; Risk = 'ADVANCED' }; Data = $null }
            Safe  = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Safe'; DisplayLabel = 'Safe row'; Risk = 'SAFE' }; Data = $null }
        }
        $script:nEngine = { param($Plan) [PSCustomObject]@{ Aborted = $false; Sections = @(); NeedsExplorerRestart = $false; RebootEntryNames = @() } }
        $script:nSel = { param([string[]]$Names) $s = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($n in $Names) { $null = $s.Add($n) }; return $s }
    }
    It 'refusing the only gate names the word and the row instead of a bare "nothing left"' {
        $script:nShown = New-Object 'System.Collections.Generic.List[string]'
        $reader = { param($Lines, $Prompt, $Risk) foreach ($l in @($Lines)) { $script:nShown.Add([string]$l) }; 'oops' }
        $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection (& $nSel @('Risky')) -Meta $nMeta -Sections $nSections -ReadAnswer $reader -Engine $nEngine -ShowMessage { }
        $r.Applied | Should -BeFalse
        $script:nShown | Should -Contain ((Get-Translation 'GateRefusedTyped') -f (Get-WtTypedWord -Kind 'Confirm'))
        $script:nShown | Should -Contain '  - Risky row'
        $script:nShown | Should -Contain (Get-WtGateWordHint -Kind 'Confirm')
        $script:nShown | Should -Contain (Get-Translation 'ApplyNothingLeft')
    }
    It 'the reworded "nothing left" no longer sounds like the screen broke' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['ApplyNothingLeft'] | Should -Not -Match '^(Nothing left to apply after|Onaylardan sonra)'
        }
    }
    It 'a refusal is still reported when the OTHER rows survive and get applied' {
        $script:nShown = New-Object 'System.Collections.Generic.List[string]'
        $answers = New-Object 'System.Collections.Generic.Queue[string]'
        $answers.Enqueue('nope')
        $answers.Enqueue('')
        $answers.Enqueue('')
        $reader = { param($Lines, $Prompt, $Risk) foreach ($l in @($Lines)) { $script:nShown.Add([string]$l) }; $answers.Dequeue() }
        Invoke-WtApplySelection -Breadcrumb 'B' -Selection (& $nSel @('Risky', 'Safe')) -Meta $nMeta -Sections $nSections -ReadAnswer $reader -Engine $nEngine -ShowMessage { } | Out-Null
        $script:nShown | Should -Contain '  - Risky row'
        $script:nShown | Should -Contain (Get-Translation 'CommitSummaryTitle')
    }
    It 'typing the gate word in lower case still applies straight away, with no refusal shown' {
        $script:nShown = New-Object 'System.Collections.Generic.List[string]'
        $script:nPrompts = New-Object 'System.Collections.Generic.List[string]'
        $reader = { param($Lines, $Prompt, $Risk) foreach ($l in @($Lines)) { $script:nShown.Add([string]$l) }; $script:nPrompts.Add([string]$Prompt); 'confirm' }
        $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection (& $nSel @('Risky')) -Meta $nMeta -Sections $nSections -ReadAnswer $reader -Engine $nEngine -ShowMessage { }
        $r.Applied | Should -BeFalse
        $script:nShown | Should -Not -Contain ((Get-Translation 'GateRefusedTyped') -f (Get-WtTypedWord -Kind 'Confirm'))
        @($script:nPrompts | Where-Object { $_ -like ((Get-Translation 'ApplyNowPrompt') -replace '\{0\}', '*') }).Count | Should -Be 0
    }
    It 'the Turkish word works on the English screen and the English word on the Turkish one' {
        foreach ($pair in @(@{ Lang = 'EN'; Word = 'onayla' }, @{ Lang = 'TR'; Word = 'confirm' })) {
            $script:Language = $pair.Lang
            try {
                $r = Invoke-WtApplySelection -Breadcrumb 'B' -Selection (& $nSel @('Risky')) -Meta $nMeta -Sections $nSections `
                    -ReadAnswer { param($Lines, $Prompt, $Risk) $pair.Word }.GetNewClosure() -Engine $nEngine -ShowMessage { }
                $r | Should -Not -BeNullOrEmpty
            }
            finally { $script:Language = 'EN' }
        }
        Test-WtTypedConfirmation -Answer 'onayla' -Kind 'Confirm' | Should -BeTrue
        Test-WtTypedConfirmation -Answer 'EVET' -Kind 'Yes' | Should -BeTrue
    }
}

Describe 'Invoke-WtMainLoop -InitialScreens' {
    It 'starts on the last of the given screens and pops back through the rest' {
        $script:Visited = @()
        Mock Invoke-WtScreenByKey { $script:Visited += @($Key); @{ Nav = $(if ($Key -eq 'Main') { 'Exit' } else { 'Back' }); Target = ''; Char = ''; HasMarks = $false } }
        Invoke-WtMainLoop -InitialScreens @('Main', 'Assistant')
        $script:Visited | Should -Be @('Assistant', 'Main')
    }
}

Describe 'Invoke-WtMainLoop contains a screen that throws' {
    It 'logs and shows the error, pops the failed screen and continues with its parent' {
        $script:verdicts = New-Object 'System.Collections.Generic.Queue[object]'
        @{ Nav = 'Push'; Target = 'SystemSettings'; Char = ''; HasMarks = $false },
        'THROW',
        @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false },
        @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } | ForEach-Object { $script:verdicts.Enqueue($_) }
        $script:visited = New-Object 'System.Collections.Generic.List[string]'
        Mock Invoke-WtScreenByKey { $script:visited.Add($Key); $v = $script:verdicts.Dequeue(); if ($v -eq 'THROW') { throw 'settings screen blew up' }; $v }
        $script:reported = @()
        Invoke-WtMainLoop -InitialScreens @('Main', 'Assistant') -OnScreenError { param($Key, $Record) $script:reported += @(@{ Key = $Key; Message = [string]$Record.Exception.Message }) }
        @($script:visited) | Should -Be @('Assistant', 'SystemSettings', 'Assistant', 'Main')
        @($script:reported).Count | Should -Be 1
        $script:reported[0].Key | Should -Be 'SystemSettings'
        $script:reported[0].Message | Should -Be 'settings screen blew up'
    }
    It 'retries a root screen that throws once and gives up when it throws twice in a row' {
        $script:rootCalls = 0
        Mock Invoke-WtScreenByKey { $script:rootCalls++; throw 'main menu cannot paint' }
        $script:rootReports = 0
        { Invoke-WtMainLoop -OnScreenError { param($Key, $Record) $script:rootReports++ } } | Should -Not -Throw
        $script:rootCalls | Should -Be 2
        $script:rootReports | Should -Be 2
    }
    It 'a root that recovers after one failure keeps running' {
        $script:rootCalls2 = 0
        Mock Invoke-WtScreenByKey { $script:rootCalls2++; if ($script:rootCalls2 -eq 1) { throw 'once' }; @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
        Invoke-WtMainLoop -OnScreenError { param($Key, $Record) }
        $script:rootCalls2 | Should -Be 2
    }
    It 'never lets the error reporter itself take the loop down' {
        Mock Invoke-WtScreenByKey { throw 'x' }
        { Invoke-WtMainLoop -OnScreenError { param($Key, $Record) throw 'reporter broke too' } } | Should -Not -Throw
    }
}

Describe 'Show-WtScreenError / Show-WtFatalError' {
    It 'Show-WtScreenError logs with the screen key, leaves REPL mode and shows the message, the log path and the way back' {
        $script:logged = $null
        $script:shown = $null
        $script:WtReplMode = $true
        Mock Exit-WtReplMode { $script:WtReplMode = $false }
        try { throw 'kaboom' } catch { $record = $_ }
        Show-WtScreenError -Key 'SystemSettings' -ErrorRecord $record -Log { param($R, $C) $script:logged = $C; 'C:\log\errors.log' } -ReadAnswer { param($Lines, $Prompt) $script:shown = @($Lines); $script:shownPrompt = $Prompt; '' }
        $script:logged | Should -Be 'Screen: SystemSettings'
        $script:WtReplMode | Should -BeFalse
        Should -Invoke Exit-WtReplMode -Times 1 -Exactly
        $script:shown[0] | Should -Be ((Get-Translation 'ErrScreenFailed') -f 'SystemSettings')
        ($script:shown -join "`n") | Should -Match 'kaboom'
        ($script:shown -join "`n") | Should -Match ([regex]::Escape('C:\log\errors.log'))
        $script:shown[-1] | Should -Be (Get-Translation 'ErrReturning')
        $script:shownPrompt | Should -Be (Get-Translation 'PressEnterContinue')
    }
    It 'Show-WtScreenError survives a log and a panel that both fail' {
        try { throw 'kaboom' } catch { $record = $_ }
        { Show-WtScreenError -Key 'Main' -ErrorRecord $record -Log { throw 'no disk' } -ReadAnswer { throw 'no console' } } | Should -Not -Throw
    }
    It 'Show-WtFatalError prints the error and the log path in the normal buffer and waits for Enter on an interactive console' {
        $script:printed = @()
        $script:waited = 0
        Mock Restore-WtTui { $script:restored = $true }
        try { throw 'fatal one' } catch { $record = $_ }
        Show-WtFatalError -ErrorRecord $record -Log { param($R, $C) $script:fatalContext = $C; 'C:\log\errors.log' } -Write { param($Text, $Fg) $script:printed += @([string]$Text) } -WaitEnter { $script:waited++ } -IsInteractive { $true }
        $script:fatalContext | Should -Be 'Main'
        Should -Invoke Restore-WtTui -Times 1 -Exactly
        ($script:printed -join "`n") | Should -Match 'fatal one'
        ($script:printed -join "`n") | Should -Match ([regex]::Escape('C:\log\errors.log'))
        $script:printed | Should -Contain (Get-Translation 'ErrFatal')
        $script:printed | Should -Contain (Get-Translation 'ErrPressEnterClose')
        $script:waited | Should -Be 1
    }
    It 'Show-WtFatalError does not wait when input is redirected' {
        $script:waited2 = 0
        Mock Restore-WtTui { }
        try { throw 'fatal two' } catch { $record = $_ }
        Show-WtFatalError -ErrorRecord $record -Log { param($R, $C) '' } -Write { param($Text, $Fg) } -WaitEnter { $script:waited2++ } -IsInteractive { $false }
        $script:waited2 | Should -Be 0
    }
    It 'the entry point catches what escapes the loop before its finally can close the console' {
        $main = Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'src/90-main/20-main.ps1') -Raw
        $main | Should -Match '(?s)catch\s*\{.*Show-WtFatalError -ErrorRecord \$_.*\}\s*finally'
    }
}

Describe 'Invoke-WtNavScreen drains queued keys after an action row' {
    It 'clears the queue after a captured row returns and before the list reads again' {
        $script:order = @()
        $script:listCalls = 0
        $row = New-WtCapturedActionItem -Name 'InstallVCRedist' -LabelKey 'InstallVCRedist' -Action { 'never runs, mocked' }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            $script:order += "list$($script:listCalls)"
            if ($script:listCalls -eq 1) { return @{ Emit = 'Activate'; Char = ''; Item = $Items[0]; Selection = $Selection; CursorIndex = 0 } }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Mock Invoke-WtCapturedAction { $script:order += 'action' }
        Mock Clear-WtPendingInput { $script:order += 'drain'; 0 }
        (Invoke-WtNavScreen -Breadcrumb 'B' -Items @($row)).Nav | Should -Be 'Back'
        $script:order | Should -Be @('list1', 'action', 'drain', 'list2')
    }
    It 'clears the queue after a native row and after an inline row too' {
        $script:listCalls = 0
        $native = New-WtToolRow -Name 'RepairWindowsSystemFiles' -Kind 'Native' -FilePath 'sfc.exe' -Arguments '/scannow'
        $inline = New-WtToolRow -Name 'FreeMemory' -Kind 'Inline' -Action { }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            if ($script:listCalls -eq 1) { return @{ Emit = 'Activate'; Char = ''; Item = $Items[0]; Selection = $Selection; CursorIndex = 0 } }
            if ($script:listCalls -eq 2) { return @{ Emit = 'Activate'; Char = ''; Item = $Items[1]; Selection = $Selection; CursorIndex = 1 } }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 1 }
        }
        Mock Invoke-WtCapturedNativeAction { }
        Mock Clear-WtPendingInput { 0 }
        $null = Invoke-WtNavScreen -Breadcrumb 'B' -Items @($native, $inline)
        Should -Invoke Invoke-WtCapturedNativeAction -Times 1 -Exactly
        Should -Invoke Clear-WtPendingInput -Times 2 -Exactly
    }
    It 'does not drain on a Link row - nothing ran, nothing could have queued' {
        Mock Invoke-WtListScreen { @{ Emit = 'Activate'; Char = ''; Item = $Items[0]; Selection = $Selection; CursorIndex = 0 } }
        Mock Clear-WtPendingInput { 0 }
        (Invoke-WtNavScreen -Breadcrumb 'B' -Items @(New-WtListItem -Kind 'Link' -Name 'X' -Label 'x' -Data @{ Screen = 'X' })).Nav | Should -Be 'Push'
        Should -Invoke Clear-WtPendingInput -Times 0 -Exactly
    }
}

Describe 'Esc never closes the app: the main menu stays, only Q / Exit / exhausted input leave' {
    BeforeEach { $script:savedExhausted = $script:WtInputExhausted; $script:WtInputExhausted = $false }
    AfterEach { $script:WtInputExhausted = $script:savedExhausted }
    It 'Invoke-WtNavScreen -RootMenu turns a Back into a one-frame footer hint and keeps the menu open' {
        $script:footers = @()
        $script:listCalls = 0
        Mock Invoke-WtListScreen {
            $script:footers += @([string]$FooterText)
            $script:listCalls++
            if ($script:listCalls -le 2) { return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 3 } }
            return @{ Emit = 'Quit'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 3 }
        }
        $r = Invoke-WtNavScreen -Breadcrumb 'Main' -Items (Get-WtMainMenuItems) -FooterText 'normal footer' -RootMenu $true
        $r.Nav | Should -Be 'Exit'
        $script:listCalls | Should -Be 3
        $script:footers[0] | Should -Be 'normal footer'
        $script:footers[1] | Should -Be (Get-Translation 'MainEscHint')
        $script:footers[2] | Should -Be (Get-Translation 'MainEscHint')
        Should -Invoke Invoke-WtListScreen -Times 2 -ParameterFilter { $InitialCursor -eq 3 }
    }
    It 'a sub-menu still returns Back on Esc, and so does the root once input is exhausted' {
        Mock Invoke-WtListScreen { @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 } }
        (Invoke-WtNavScreen -Breadcrumb 'Sub' -Items (Get-WtBasicToolsItems)).Nav | Should -Be 'Back'
        $script:WtInputExhausted = $true
        (Invoke-WtNavScreen -Breadcrumb 'Main' -Items (Get-WtMainMenuItems) -RootMenu $true).Nav | Should -Be 'Back'
        Should -Invoke Invoke-WtListScreen -Times 2 -Exactly
    }
    It 'Invoke-WtMainScreen is the root menu' {
        Mock Invoke-WtNavScreen { $script:rootFlag = $RootMenu; @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
        $null = Invoke-WtMainScreen
        $script:rootFlag | Should -BeTrue
    }
    It 'Invoke-WtMainLoop stays at the root on Back until Exit, and leaves on Back only when input is exhausted' {
        $script:loopCalls = 0
        Mock Invoke-WtScreenByKey { $script:loopCalls++; if ($script:loopCalls -lt 3) { @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false } } else { @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } } }
        Invoke-WtMainLoop
        $script:loopCalls | Should -Be 3
        $script:WtInputExhausted = $true
        $script:loopCalls = 0
        Invoke-WtMainLoop
        $script:loopCalls | Should -Be 1
    }

    It 'Read-WtInputBatch raises the exhausted flag when Read-Host hands back nothing' {
        $oldMode = $script:WtInputMode
        try {
            $script:WtInputMode = 'Line'
            Mock Read-Host { $null }
            @(Read-WtInputBatch) | Should -Be @('Eof')
            $script:WtInputExhausted | Should -BeTrue
        }
        finally { $script:WtInputMode = $oldMode }
    }
}

Describe 'Get-WtUndoItemLabel: what one undo record item changed' {
    BeforeAll {
        $script:undoLbl = {
            param($Item)
            $names = $Item.PSObject.Properties.Name
            if (($names -contains 'CatalogEntry') -and $Item.CatalogEntry -eq 'ShowFileExtensions') { return 'Show file extensions' }
            if ($Item.ItemType -eq 'Service' -and $Item.Name -eq 'DiagTrack') { return 'DiagTrack - Telemetry' }
            if ($Item.ItemType -eq 'Package' -and $Item.Name -eq 'Microsoft.Windows.DevHome') { return 'Dev Home' }
            return ''
        }
    }
    It 'names a registry item by its catalog label' {
        $item = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'ShowFileExtensions'; Path = 'HKCU:\Software\X'; Name = 'HideFileExt'; RegType = 'DWord'; PreviousPresent = $true; PreviousValue = 1 }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be 'Show file extensions'
    }
    It 'falls back to Path\Name when the catalog no longer knows the entry' {
        $item = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'Gone'; Path = 'HKCU:\Software\X'; Name = 'HideFileExt'; RegType = 'DWord'; PreviousPresent = $true; PreviousValue = 1 }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be 'HKCU:\Software\X\HideFileExt'
    }
    It 'names an unlabelled registry key item by Hive\SubKey' {
        $item = [PSCustomObject]@{ ItemType = 'RegistryKey'; CatalogEntry = 'Gone'; Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\Directory\shell\WtX'; CreatedRoot = 'SOFTWARE\Classes\Directory\shell\WtX'; PreviousValues = @() }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be 'LocalMachine\SOFTWARE\Classes\Directory\shell\WtX'
    }
    It 'shows a service as "label: previous -> target" with both start types localized' {
        $item = [PSCustomObject]@{ ItemType = 'Service'; Name = 'DiagTrack'; Template = 'DiagTrack'; IsPerUser = $false; TargetStartType = 'Automatic'; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual' }
        $expected = (Get-Translation 'UndoDetailService') -f 'DiagTrack - Telemetry', (Get-Translation 'SvcStart.Manual'), (Get-Translation 'SvcStart.Automatic')
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be $expected
    }
    It 'reads an old Disable Services record (no TargetStartType) as -> Disabled, and falls back to the raw service name' {
        $item = [PSCustomObject]@{ ItemType = 'Service'; Name = 'XblAuthManager'; Template = 'XblAuthManager'; IsPerUser = $false; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual' }
        $expected = (Get-Translation 'UndoDetailService') -f 'XblAuthManager', (Get-Translation 'SvcStart.Manual'), (Get-Translation 'SvcStart.Disabled')
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be $expected
    }
    It 'names a package by its catalog label, else by the package name' {
        $known = [PSCustomObject]@{ ItemType = 'Package'; Name = 'Microsoft.Windows.DevHome'; PackageFullName = 'Microsoft.Windows.DevHome_1_x64__8wekyb3d8bbwe'; InstallLocation = 'C:\x'; IsProvisioned = $true; RemovalMethod = 'Appx' }
        $unknown = [PSCustomObject]@{ ItemType = 'Package'; Name = 'Contoso.Thing'; PackageFullName = 'Contoso.Thing_1_x64__abc'; InstallLocation = 'C:\y'; IsProvisioned = $false; RemovalMethod = 'Appx' }
        Get-WtUndoItemLabel -Item $known -CatalogLabel $script:undoLbl | Should -Be 'Dev Home'
        Get-WtUndoItemLabel -Item $unknown -CatalogLabel $script:undoLbl | Should -Be 'Contoso.Thing'
    }
    It 'describes a DNS item by adapter index and the servers restore puts back' {
        $item = [PSCustomObject]@{ ItemType = 'DnsConfig'; InterfaceIndex = 9; PreviousIPv4 = @('1.1.1.1', '1.0.0.1'); PreviousIPv6 = @('2606:4700:4700::1111'); PreviousDohEntries = @(); AddedDohAddresses = @{}; ModifiedDohAddresses = @{} }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be ((Get-Translation 'UndoDetailDns') -f 9, '1.1.1.1, 1.0.0.1, 2606:4700:4700::1111')
    }
    It 'says DHCP for a DNS item that had no servers of its own' {
        $item = [PSCustomObject]@{ ItemType = 'DnsConfig'; InterfaceIndex = 34; PreviousIPv4 = @(); PreviousIPv6 = @(); PreviousDohEntries = @(); AddedDohAddresses = @{}; ModifiedDohAddresses = @{} }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be ((Get-Translation 'UndoDetailDns') -f 34, (Get-Translation 'UndoDetailDnsDhcp'))
    }
    It 'describes hosts and firewall blocklist items by tier and count' {
        $hosts = [PSCustomObject]@{ ItemType = 'HostsBlock'; Tier = 'Spy'; Lines = @('0.0.0.0 a', '0.0.0.0 b', '0.0.0.0 c') }
        $fw = [PSCustomObject]@{ ItemType = 'FirewallBlock'; Tier = 'Extra'; RuleNames = @('WinToolify-Block-Extra-0', 'WinToolify-Block-Extra-1'); Chunks = @() }
        Get-WtUndoItemLabel -Item $hosts -CatalogLabel $script:undoLbl | Should -Be ((Get-Translation 'UndoDetailHosts') -f 'Spy', 3)
        Get-WtUndoItemLabel -Item $fw -CatalogLabel $script:undoLbl | Should -Be ((Get-Translation 'UndoDetailFirewallBlock') -f 'Extra', 2)
    }
    It 'adds the profile name to a firewall profile item so the three profiles read differently' {
        $lbl = { param($Item) 'Turn the firewall on' }
        $item = [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Domain'; ProfileName = 'Domain'; WasEnabled = $false; TargetEnabled = $true; CatalogEntry = 'EnableFirewall' }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $lbl | Should -Be 'Turn the firewall on (Domain)'
    }
    It 'uses the catalog label for power plan, power setting and hibernation items' {
        $lbl = { param($Item) 'Label for ' + $Item.CatalogEntry }
        $plan = [PSCustomObject]@{ ItemType = 'PowerPlan'; CatalogEntry = 'UltimatePerformance'; PreviousActiveScheme = 'a'; TargetScheme = 'b'; CreatedScheme = 'b' }
        $setting = [PSCustomObject]@{ ItemType = 'PowerSetting'; CatalogEntry = 'DisableCoreParking'; SchemeGuid = 'b'; SubGroupGuid = 'c'; SettingGuid = 'd'; SettingLabel = 'CPMINCORES'; PreviousAc = 100; PreviousDc = 25 }
        $hib = [PSCustomObject]@{ ItemType = 'HibernationState'; Name = 'Hibernation'; WasEnabled = $false; CatalogEntry = 'DisableFastStartup' }
        Get-WtUndoItemLabel -Item $plan -CatalogLabel $lbl | Should -Be 'Label for UltimatePerformance'
        Get-WtUndoItemLabel -Item $setting -CatalogLabel $lbl | Should -Be 'Label for DisableCoreParking'
        Get-WtUndoItemLabel -Item $hib -CatalogLabel $lbl | Should -Be 'Label for DisableFastStartup'
    }
    It 'falls back to the item type for a shape it does not know' {
        $item = [PSCustomObject]@{ ItemType = 'Mystery'; Foo = 1 }
        Get-WtUndoItemLabel -Item $item -CatalogLabel $script:undoLbl | Should -Be 'Mystery'
    }
}

Describe 'Get-WtUndoEntryDetailLines: the confirm panel says what the record changed' {
    It 'opens with the entry label, lists one line per open item under the header, and ends with the restore note' {
        $entry = [PSCustomObject]@{
            Path = 'C:\u\1.json'; Timestamp = '2026-09-05T10:19:47'; Action = 'Set Service Start Type'
            Items = @(
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'WbioSrvc'; Template = 'WbioSrvc'; IsPerUser = $false; TargetStartType = 'Automatic'; PreviousStatus = 'Stopped'; PreviousStartType = 'Disabled' }
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'Done'; Template = 'Done'; IsPerUser = $false; TargetStartType = 'Manual'; PreviousStatus = 'Stopped'; PreviousStartType = 'Disabled'; RestoredAt = '2026-09-05T11:00:00' }
            )
        }
        $lbl = { param($Item) $Item.Name + ' - svc' }
        $lines = @(Get-WtUndoEntryDetailLines -Entry $entry -CatalogLabel $lbl)
        $lines[0] | Should -Be (Format-WtUndoEntryLabel -Entry $entry)
        $lines[1] | Should -Be ''
        $lines[2] | Should -Be (Get-Translation 'UndoDetailHeader')
        $lines[3] | Should -Be ('  - ' + ((Get-Translation 'UndoDetailService') -f 'WbioSrvc - svc', (Get-Translation 'SvcStart.Disabled'), (Get-Translation 'SvcStart.Automatic')))
        $lines[4] | Should -Be ''
        $lines[5] | Should -Be (Get-Translation 'UndoDetailRestoreNote')
        $lines.Count | Should -Be 6
        ($lines -join "`n") | Should -Not -Match 'Done'
    }
    It 'lists a catalog entry once even when the record holds one item per registry value' {
        $entry = [PSCustomObject]@{
            Path = 'C:\u\2.json'; Timestamp = '2026-08-30T17:34:41'; Action = 'Apply Edge Settings'
            Items = @(
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\A'; Name = 'V1'; RegType = 'DWord'; PreviousPresent = $false; PreviousValue = $null }
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\B'; Name = 'V2'; RegType = 'DWord'; PreviousPresent = $false; PreviousValue = $null }
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E002'; Path = 'HKLM:\C'; Name = 'V3'; RegType = 'DWord'; PreviousPresent = $false; PreviousValue = $null }
            )
        }
        $lbl = { param($Item) 'Label ' + $Item.CatalogEntry }
        $lines = @(Get-WtUndoEntryDetailLines -Entry $entry -CatalogLabel $lbl)
        @($lines | Where-Object { $_ -like '  - *' }) | Should -Be @('  - Label HD_E001', '  - Label HD_E002')
    }
    It 'lists exactly as many lines as the row counter says, for a mixed record' {
        $entry = [PSCustomObject]@{
            Path = 'C:\u\3.json'; Timestamp = '2026-08-23T17:34:44'; Action = 'Set Firewall State'
            Items = @(
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\A'; Name = 'V1' }
                [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\B'; Name = 'V2' }
                [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Domain'; ProfileName = 'Domain'; WasEnabled = $false; TargetEnabled = $true; CatalogEntry = 'EnableFirewall' }
                [PSCustomObject]@{ ItemType = 'FirewallProfile'; Name = 'Firewall Public'; ProfileName = 'Public'; WasEnabled = $false; TargetEnabled = $true; CatalogEntry = 'EnableFirewall' }
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'DiagTrack'; Template = 'DiagTrack'; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual' }
                [PSCustomObject]@{ ItemType = 'Service'; Name = 'PcaSvc'; Template = 'PcaSvc'; PreviousStatus = 'Running'; PreviousStartType = 'Manual'; RestoredAt = '2026-08-24T10:00:00' }
            )
        }
        $lbl = { param($Item) '' }
        $lines = @(Get-WtUndoEntryDetailLines -Entry $entry -CatalogLabel $lbl)
        $lines[0] | Should -Match '\(4 (items|oge)\)'
        @($lines | Where-Object { $_ -like '  - *' }).Count | Should -Be 4
    }
}

Describe 'Get-WtUndoCatalogLabel: the record item -> catalog label lookup' {
    BeforeEach { $script:WtUndoLabelMemo = @{} }
    It 'looks a service up in the Services catalog by template name, and a package in the Packages catalog' {
        $script:catalogCalls = @{}
        $sections = @(
            [PSCustomObject]@{ Key = 'Services'; GetCatalog = { $script:catalogCalls['Services'] = 1 + [int]$script:catalogCalls['Services']; @([PSCustomObject]@{ Name = 'BcastDVRUserService'; DisplayLabel = 'BcastDVRUserService - Game DVR' }) } }
            [PSCustomObject]@{ Key = 'Packages'; GetCatalog = { $script:catalogCalls['Packages'] = 1 + [int]$script:catalogCalls['Packages']; @([PSCustomObject]@{ Name = 'Microsoft.Windows.DevHome'; DisplayLabel = 'Dev Home' }) } }
            [PSCustomObject]@{ Key = 'ExplorerView'; GetCatalog = { $script:catalogCalls['ExplorerView'] = 1 + [int]$script:catalogCalls['ExplorerView']; @([PSCustomObject]@{ Name = 'ShowFileExtensions'; DisplayLabel = 'Show file extensions' }) } }
        )
        $svc = [PSCustomObject]@{ ItemType = 'Service'; Name = 'BcastDVRUserService_48486de'; Template = 'BcastDVRUserService'; IsPerUser = $true; PreviousStatus = 'Stopped'; PreviousStartType = 'Manual' }
        $pkg = [PSCustomObject]@{ ItemType = 'Package'; Name = 'Microsoft.Windows.DevHome'; PackageFullName = 'x' }
        Get-WtUndoCatalogLabel -Item $svc -Sections $sections | Should -Be 'BcastDVRUserService - Game DVR'
        Get-WtUndoCatalogLabel -Item $pkg -Sections $sections | Should -Be 'Dev Home'
        [int]$script:catalogCalls['ExplorerView'] | Should -Be 0
    }
    It 'finds a CatalogEntry in whichever other section owns it, skipping Services and Packages, and remembers the answer' {
        $script:catalogCalls = @{}
        $sections = @(
            [PSCustomObject]@{ Key = 'Services'; GetCatalog = { $script:catalogCalls['Services'] = 1 + [int]$script:catalogCalls['Services']; @() } }
            [PSCustomObject]@{ Key = 'Telemetry'; GetCatalog = { $script:catalogCalls['Telemetry'] = 1 + [int]$script:catalogCalls['Telemetry']; @([PSCustomObject]@{ Name = 'Other'; DisplayLabel = 'Other' }) } }
            [PSCustomObject]@{ Key = 'ExplorerView'; GetCatalog = { $script:catalogCalls['ExplorerView'] = 1 + [int]$script:catalogCalls['ExplorerView']; @([PSCustomObject]@{ Name = 'ShowFileExtensions'; DisplayLabel = 'Show file extensions' }) } }
        )
        $item = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'ShowFileExtensions'; Path = 'HKCU:\X'; Name = 'HideFileExt' }
        Get-WtUndoCatalogLabel -Item $item -Sections $sections | Should -Be 'Show file extensions'
        Get-WtUndoCatalogLabel -Item $item -Sections $sections | Should -Be 'Show file extensions'
        [int]$script:catalogCalls['ExplorerView'] | Should -Be 1
        [int]$script:catalogCalls['Services'] | Should -Be 0
    }
    It 'answers blank for an item nobody labels and for a catalog that throws' {
        $sections = @(
            [PSCustomObject]@{ Key = 'Broken'; GetCatalog = { throw 'no OS here' } }
            [PSCustomObject]@{ Key = 'Dns'; GetCatalog = { @([PSCustomObject]@{ Name = 'Cloudflare' }) } }
        )
        $item = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'Cloudflare'; Path = 'HKCU:\X'; Name = 'V' }
        Get-WtUndoCatalogLabel -Item $item -Sections $sections | Should -Be ''
        $dns = [PSCustomObject]@{ ItemType = 'DnsConfig'; InterfaceIndex = 9; PreviousIPv4 = @(); PreviousIPv6 = @() }
        Get-WtUndoCatalogLabel -Item $dns -Sections $sections | Should -Be ''
    }
}

Describe 'Confirm-WtUndoRestore: Enter restores, Esc cancels' {
    BeforeEach { $script:confirmSeen = New-Object System.Collections.Generic.List[object] }
    It 'returns true on Enter, having shown the detail lines as a read-only compact panel with the confirm footer' {
        Mock Invoke-WtListScreen {
            $script:confirmSeen.Add(@{ Items = @($Items); Footer = $FooterText; Layout = $Layout; Crumb = $Breadcrumb })
            @{ Emit = 'Activate'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = -1 }
        }
        Confirm-WtUndoRestore -Breadcrumb 'Ana Menu > Geri Al' -Lines @('head', '', 'detail') | Should -BeTrue
        $script:confirmSeen.Count | Should -Be 1
        $seen = $script:confirmSeen[0]
        $seen.Footer | Should -Be (Get-Translation 'UndoConfirmFooter')
        $seen.Layout | Should -Be 'Compact'
        $seen.Crumb | Should -Be 'Ana Menu > Geri Al'
        @($seen.Items | ForEach-Object Kind) | Should -Be @('Info', 'Info', 'Info')
        @($seen.Items | ForEach-Object Label) | Should -Be @('head', '', 'detail')
        $seen.Items[0].Risk | Should -Be 'CAUTION'
        $seen.Items[0].RiskTag | Should -BeTrue
        $seen.Items[1].RiskTag | Should -BeFalse
    }
    It 'returns false on Esc and on Q - only Enter restores' {
        foreach ($emit in 'Back', 'Quit') {
            $script:confirmEmit = $emit
            Mock Invoke-WtListScreen { @{ Emit = $script:confirmEmit; Char = ''; Item = $null; Selection = $Selection; CursorIndex = -1 } }
            Confirm-WtUndoRestore -Breadcrumb 'B' -Lines @('x') | Should -BeFalse -Because $emit
        }
    }
    It 'ignores an unbound letter and keeps asking' {
        $script:confirmCalls = 0
        Mock Invoke-WtListScreen {
            $script:confirmCalls++
            $emit = if ($script:confirmCalls -eq 1) { 'Global' } else { 'Back' }
            @{ Emit = $emit; Char = 'x'; Item = $null; Selection = $Selection; CursorIndex = -1 }
        }
        Confirm-WtUndoRestore -Breadcrumb 'B' -Lines @('x') | Should -BeFalse
        $script:confirmCalls | Should -Be 2
    }
}

Describe 'Invoke-WtUndoScreen: restore only after the confirm panel said yes' {
    BeforeEach {
        $script:undoEntry = [PSCustomObject]@{
            Path = 'C:\u\1.json'; Timestamp = '2026-09-05T10:19:47'; Action = 'Set Service Start Type'
            Items = @([PSCustomObject]@{ ItemType = 'Service'; Name = 'WbioSrvc'; Template = 'WbioSrvc'; IsPerUser = $false; TargetStartType = 'Automatic'; PreviousStatus = 'Stopped'; PreviousStartType = 'Disabled' })
        }
        Mock Get-WtUndoEntries { @($script:undoEntry) }
        Mock Get-WtUndoCatalogLabel { 'WbioSrvc - Biometric' }
        Mock Show-WtListLoading { }
        Mock Restore-WtUndoEntry { $script:restoredPath = $EntryPath; @([PSCustomObject]@{ ItemType = 'Service'; Name = 'WbioSrvc'; Outcome = 'Restored'; Item = $script:undoEntry.Items[0] }) }
        Mock Read-WtPanelAnswer { $script:resultLines = @($Lines); '' }
        $script:restoredPath = $null
        $script:resultLines = @()
        $script:listCalls = 0
    }
    It 'restores the chosen entry when the confirm panel returns true, and reports the item by its label' {
        Mock Confirm-WtUndoRestore { $script:confirmLines = @($Lines); $true }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            if ($script:listCalls -eq 1) { return @{ Emit = 'Activate'; Char = ''; Item = $Items[0]; Selection = $Selection; CursorIndex = 0 } }
            @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        $r = Invoke-WtUndoScreen
        $r.Nav | Should -Be 'Back'
        $script:restoredPath | Should -Be 'C:\u\1.json'
        $script:confirmLines[0] | Should -Be (Format-WtUndoEntryLabel -Entry $script:undoEntry)
        ($script:confirmLines -join "`n") | Should -Match 'WbioSrvc - Biometric'
        $script:resultLines[1] | Should -Be ('  ' + (Get-WtUndoItemLabel -Item $script:undoEntry.Items[0] -CatalogLabel { 'WbioSrvc - Biometric' }) + ': ' + (Get-Translation 'UndoResultRestored'))
        Should -Invoke Show-WtListLoading -Times 1 -Exactly
    }
    It 'reports two registry values of one catalog entry as a single result line when they ended alike' {
        $a = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\A'; Name = 'V1' }
        $b = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\B'; Name = 'V2' }
        $c = [PSCustomObject]@{ ItemType = 'Registry'; CatalogEntry = 'HD_E001'; Path = 'HKLM:\C'; Name = 'V3' }
        Mock Get-WtUndoCatalogLabel { 'Turn off SmartScreen' }
        Mock Restore-WtUndoEntry { @(
            [PSCustomObject]@{ ItemType = 'Registry'; Name = 'HKLM:\C\V3'; Outcome = 'Failed'; Item = $c }
            [PSCustomObject]@{ ItemType = 'Registry'; Name = 'HKLM:\B\V2'; Outcome = 'Restored'; Item = $b }
            [PSCustomObject]@{ ItemType = 'Registry'; Name = 'HKLM:\A\V1'; Outcome = 'Restored'; Item = $a }
        ) }
        Mock Confirm-WtUndoRestore { $true }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            if ($script:listCalls -eq 1) { return @{ Emit = 'Activate'; Char = ''; Item = $Items[0]; Selection = $Selection; CursorIndex = 0 } }
            @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtUndoScreen | Out-Null
        @($script:resultLines | Select-Object -Skip 1) | Should -Be @(
            ('  Turn off SmartScreen: ' + (Get-Translation 'UndoResultFailed')),
            ('  Turn off SmartScreen: ' + (Get-Translation 'UndoResultRestored'))
        )
    }
    It 'leaves the record alone when the confirm panel returns false' {
        Mock Confirm-WtUndoRestore { $false }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            if ($script:listCalls -eq 1) { return @{ Emit = 'Activate'; Char = ''; Item = $Items[0]; Selection = $Selection; CursorIndex = 0 } }
            @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtUndoScreen | Out-Null
        $script:restoredPath | Should -BeNullOrEmpty
        Should -Invoke Restore-WtUndoEntry -Times 0 -Exactly
    }
}
