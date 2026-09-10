#Requires -Modules Pester

<#
.SYNOPSIS
    The assistant's action handlers on top of the existing apply engine:
    run a tool row, apply / revert toggles, restore an undo entry, and
    the synthetic tool turn the digit path leaves for the model.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Ctx = @{ Mask = @{ ComputerName = 'BURAK-PC'; UserName = 'Burak'; Serial = ''; Macs = @() }; OnSuggest = { }; Breadcrumb = 'crumb'; ReadAnswer = { param($L, $P, $R) '' } }
    $script:RowIndex = @(
        (New-WtAssistantIndexEntry -Id 'CapRow' -Kind 'Action' -LabelEn 'Captured row' -LabelTr 'Yakalanan satir' -Risk 'SAFE' -Runnable $true -Item @{ Name = 'CapRow'; Data = @{ Captured = $true; Title = 'Captured row'; Action = { Write-Host 'hello'; Write-Host 'world'; Write-Host 'again' }; Encoding = $null } })
        (New-WtAssistantIndexEntry -Id 'NatRow' -Kind 'Info' -LabelEn 'Native row' -LabelTr 'Yerli satir' -Runnable $true -Item @{ Name = 'NatRow'; Data = @{ Native = $true; Title = 'Native row'; FilePath = 'cmd.exe'; Arguments = '/c echo hi'; Encoding = $null } })
        (New-WtAssistantIndexEntry -Id 'InlineRow' -Kind 'Action' -LabelEn 'Inline row' -LabelTr 'Satir ici' -Runnable $false -Item @{ Name = 'InlineRow'; Data = @{ Action = { } } })
        (New-WtAssistantIndexEntry -Id 'Telemetry:T' -Kind 'Toggle' -SectionKey 'Telemetry' -Section 'Telemetry' -LabelEn 'A toggle' -LabelTr 'Bir anahtar' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'T' }))
    )
}

Describe 'Invoke-WtAssistantToolRow' {
    It 'runs a captured row through the injected runner and returns its lines; a native row through the native runner' {
        $r = Invoke-WtAssistantToolRow -Entry $RowIndex[0] -Breadcrumb 'b' -RunCaptured { param($Data, $Crumb) @('one', 'two') } -RunNative { param($Data, $Crumb) @('never') }
        $r.Ran | Should -BeTrue
        @($r.Lines) | Should -Be @('one', 'two')
        $n = Invoke-WtAssistantToolRow -Entry $RowIndex[1] -Breadcrumb 'b' -RunCaptured { param($Data, $Crumb) @('never') } -RunNative { param($Data, $Crumb) @('hi from ' + $Data.FilePath) }
        @($n.Lines) | Should -Be @('hi from cmd.exe')
    }

    It 'refuses a non-runnable row without invoking anything' {
        $script:Invoked = 0
        $r = Invoke-WtAssistantToolRow -Entry $RowIndex[2] -Breadcrumb 'b' -RunCaptured { param($Data, $Crumb) $script:Invoked++; @() } -RunNative { param($Data, $Crumb) $script:Invoked++; @() }
        $r.Ran | Should -BeFalse
        $script:Invoked | Should -Be 0
    }

    It 'the default captured runner collects the lines the action printed instead of opening the output screen' {
        $r = Invoke-WtAssistantToolRow -Entry $RowIndex[0] -Breadcrumb 'b' -RunCaptured { param($Data, $Crumb)
            $script:WtAssistantRowLines = @()
            Invoke-WtCapturedAction -Title ([string]$Data.Title) -Breadcrumb $Crumb -Action $Data.Action -Encoding $Data.Encoding `
                -ShowProgress { param($Lines, $Footer) } -ShowResult { param($Lines) $script:WtAssistantRowLines = @($Lines) } -UseNativeEncoding $false
            return @($script:WtAssistantRowLines)
        }
        @($r.Lines).Count | Should -Be 3
        @($r.Lines) | Should -Be @('hello', 'world', 'again')
    }

    It 'an empty capture yields zero lines, not one empty string' {
        $emptyEntry = New-WtAssistantIndexEntry -Id 'EmptyRow' -Kind 'Action' -LabelEn 'Empty row' -LabelTr 'Bos satir' -Runnable $true -Item @{ Name = 'EmptyRow'; Data = @{ Captured = $true; Title = 'Empty row'; Action = { }; Encoding = $null } }
        $r = Invoke-WtAssistantToolRow -Entry $emptyEntry -Breadcrumb 'b' -RunCaptured { param($Data, $Crumb)
            $script:WtAssistantRowLines = @()
            Invoke-WtCapturedAction -Title ([string]$Data.Title) -Breadcrumb $Crumb -Action $Data.Action -Encoding $Data.Encoding `
                -ShowProgress { param($Lines, $Footer) } -ShowResult { param($Lines) $script:WtAssistantRowLines = @($Lines) } -UseNativeEncoding $false
            return @($script:WtAssistantRowLines)
        }
        @($r.Lines).Count | Should -Be 0
        $r.Ran | Should -BeTrue
    }

    It 'an injected captured runner returning a single line yields exactly one line' {
        $r = Invoke-WtAssistantToolRow -Entry $RowIndex[0] -Breadcrumb 'b' -RunCaptured { param($Data, $Crumb) @('only') } -RunNative { param($Data, $Crumb) @('never') }
        @($r.Lines).Count | Should -Be 1
        $r.Lines[0] | Should -Be 'only'
    }

    It 'the default captured runner runs in place - no hop - and ticks the spinner from the panel progress seam' {
        $oldVt = $script:WtVt
        try {
            $script:WtVt = $true; $script:WtReplMode = $true; $script:WtReplSpinner = $null
            Mock Invoke-WtReplHop { throw 'must not hop: the chat stays on screen' }
            Mock Invoke-WtCapturedAction { & $ShowProgress @('progress') 'footer'; & $ShowResult @('from-default') }
            Mock Update-WtReplSpinner { }
            Mock Show-WtReplSpinner { }
            Mock Hide-WtReplSpinner { }
            $r = Invoke-WtAssistantToolRow -Entry $RowIndex[0] -Breadcrumb 'b'
            @($r.Lines) | Should -Be @('from-default')
            Should -Invoke Invoke-WtReplHop -Times 0 -Exactly
            Should -Invoke Invoke-WtCapturedAction -Times 1 -Exactly
            Should -Invoke Update-WtReplSpinner -Times 1 -Exactly
            Should -Invoke Show-WtReplSpinner -Times 1 -Exactly
            Should -Invoke Hide-WtReplSpinner -Times 1 -Exactly
        }
        finally { $script:WtVt = $oldVt; $script:WtReplMode = $false; $script:WtReplSpinner = $null }
    }

    It 'the default native runner runs in place too, and relabels a spinner the send path already shows' {
        $oldVt = $script:WtVt
        try {
            $script:WtVt = $true; $script:WtReplMode = $true
            $script:WtReplSpinner = @{ Active = $true; Label = 'Arac calisiyor: run_wintoolify_tool' }
            Mock Invoke-WtReplHop { throw 'must not hop' }
            Mock Invoke-WtCapturedNativeAction { & $ShowProgress @() 'f'; & $ShowResult @('native-default') }
            Mock Update-WtReplSpinner { }
            Mock Show-WtReplSpinner { }
            Mock Hide-WtReplSpinner { }
            $r = Invoke-WtAssistantToolRow -Entry $RowIndex[1] -Breadcrumb 'b'
            @($r.Lines) | Should -Be @('native-default')
            Should -Invoke Invoke-WtReplHop -Times 0 -Exactly
            Should -Invoke Invoke-WtCapturedNativeAction -Times 1 -Exactly
            Should -Invoke Show-WtReplSpinner -Times 0 -Exactly
            Should -Invoke Hide-WtReplSpinner -Times 0 -Exactly
            [string]$script:WtReplSpinner.Label | Should -BeLike (((Get-Translation 'AsSpinRunning') -f '') + '*')
        }
        finally { $script:WtVt = $oldVt; $script:WtReplMode = $false; $script:WtReplSpinner = $null }
    }
}

Describe 'Invoke-WtAssistantApply' {
    BeforeAll {
        $script:ApplySections = @(
            [PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; GetCatalog = { @() }; GetState = { 'NotApplied' }
                Apply = { param([string[]]$Names, $Data) @{ Aborted = $false; Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = $true; Error = $null } }) } }
                TurnOff = { param([string[]]$Names, $Data) @{ Aborted = $false; Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = $true; Error = $null } }) } }
                IsRemovable = $null }
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; GetCatalog = { @() }; GetState = { 'NotApplied' }
                Apply = { param([string[]]$Names, $Data) $script:SeenTargets = $Data.Targets; @{ Aborted = $false; Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = ($_ -ne 'Broken'); Error = $(if ($_ -eq 'Broken') { 'boom' } else { $null }) } }) } }
                TurnOff = $null; IsRemovable = $null }
        )
        $script:ApplyIndex = @(
            (New-WtAssistantIndexEntry -Id 'Telemetry:A' -Kind 'Toggle' -SectionKey 'Telemetry' -Section 'Telemetry' -LabelEn 'Tele A' -LabelTr 'Tele A' -Risk 'SAFE' -Runnable $true -Removable $true -Entry ([PSCustomObject]@{ Name = 'A'; Risk = 'SAFE' }))
            (New-WtAssistantIndexEntry -Id 'Services:Svc' -Kind 'Toggle' -SectionKey 'Services' -Section 'ServicesManagement' -LabelEn 'Svc' -LabelTr 'Svc' -Risk 'SAFE' -Runnable $true -Removable $false -Entry ([PSCustomObject]@{ Name = 'Svc'; Risk = 'SAFE'; RestartRequired = $true }))
            (New-WtAssistantIndexEntry -Id 'Services:Broken' -Kind 'Toggle' -SectionKey 'Services' -Section 'ServicesManagement' -LabelEn 'Broken' -LabelTr 'Broken' -Risk 'SAFE' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'Broken'; Risk = 'SAFE' }))
            (New-WtAssistantIndexEntry -Id 'DnsPreset:Cloudflare' -Kind 'Toggle' -SectionKey 'DnsPreset' -Section 'DnsPreset' -LabelEn 'Cloudflare' -LabelTr 'Cloudflare' -Runnable $false -Entry ([PSCustomObject]@{ Name = 'Cloudflare' }))
            (New-WtAssistantIndexEntry -Id 'CapRow2' -Kind 'Action' -LabelEn 'row' -LabelTr 'row' -Runnable $true -Item @{ Name = 'CapRow2'; Data = @{ Captured = $true; Action = { } } })
            (New-WtAssistantIndexEntry -Id 'Telemetry:Adv' -Kind 'Toggle' -SectionKey 'Telemetry' -Section 'Telemetry' -LabelEn 'Adv' -LabelTr 'Adv' -Risk 'ADVANCED' -Runnable $true -Removable $true -Entry ([PSCustomObject]@{ Name = 'Adv'; Risk = 'ADVANCED' }))
        )
        $script:PassGates = { param($Records) @{ Records = $Records; Plan = (Get-WtCommitPlan -ChangeSet $Records -Sections $script:ApplySections -GetPackageCatalog { @() }); TypedConfirmation = $false; Dropped = @() } }
        $script:RealEngine = { param($Plan) Invoke-WtCommitChangeSet -Plan $Plan -Sections $script:ApplySections }
    }

    It 'applies resolvable toggles through gates and engine, reports failures per id and carries reboot/explorer flags' {
        $script:Applied = $null
        $ctx = @{ Mask = $Ctx.Mask; OnSuggest = { }; Breadcrumb = 'b'; ReadAnswer = { param($L, $P, $R) '' }; OnApplied = { param($Lines) $script:Applied = @($Lines) } }
        $r = Invoke-WtAssistantApply -Ids @('Telemetry:A', 'Services:Svc', 'Services:Broken', 'yok', 'CapRow2') -Context $ctx -Index $ApplyIndex -Sections $ApplySections -Gates $PassGates -Engine $RealEngine -TestRootOverride (Join-Path $TestDrive 'undo-a')
        @($r.applied | ForEach-Object id) | Should -Be @('Telemetry:A', 'Services:Svc')
        @($r.failed | ForEach-Object id) | Should -Contain 'Services:Broken'
        @($r.failed | ForEach-Object id) | Should -Contain 'yok'
        @($r.failed | ForEach-Object id) | Should -Contain 'CapRow2'
        (@($r.failed | Where-Object id -eq 'Services:Broken')[0]).error | Should -Be 'boom'
        $r.reboot_needed | Should -BeTrue
        $r.explorer_restart | Should -BeFalse
        @($script:Applied).Count | Should -BeGreaterThan 0
    }

    It 'refuses remove on a non-removable entry and on a stage-only entry, applies nothing when nothing resolves' {
        $script:EngineRuns = 0
        $engine = { param($Plan) $script:EngineRuns++; & $script:RealEngine $Plan }
        $r = Invoke-WtAssistantApply -Ids @('Services:Svc', 'DnsPreset:Cloudflare') -Direction 'remove' -Context $Ctx -Index $ApplyIndex -Sections $ApplySections -Gates $PassGates -Engine $engine
        @($r.applied).Count | Should -Be 0
        @($r.failed | ForEach-Object id) | Should -Be @('Services:Svc', 'DnsPreset:Cloudflare')
        (@($r.failed)[0]).error | Should -Match 'not removable'
        $script:EngineRuns | Should -Be 0
        $ok = Invoke-WtAssistantApply -Ids @('Telemetry:A') -Direction 'remove' -Context $Ctx -Index $ApplyIndex -Sections $ApplySections -Gates $PassGates -Engine $engine
        @($ok.applied | ForEach-Object id) | Should -Be @('Telemetry:A')
    }

    It 'hands a service target down Data.Target -> plan Data.Targets' {
        $script:SeenTargets = $null
        $null = Invoke-WtAssistantApply -Ids @('Services:Svc') -Targets @{ 'Services:Svc' = 'Manual' } -Context $Ctx -Index $ApplyIndex -Sections $ApplySections -Gates $PassGates -Engine $RealEngine
        $script:SeenTargets['Svc'] | Should -Be 'Manual'
    }

    It 'reports what the gates dropped as skipped and the new undo entry ids' {
        $root = Join-Path $TestDrive 'undo-b'
        $null = Write-WtUndoEntry -Scope 'Machine' -Action 'Older' -Items @() -TestRootOverride $root
        Start-Sleep -Milliseconds 1100
        $gates = { param($Records)
            $kept = @($Records | Where-Object { $_.EntryName -ne 'Svc' })
            @{ Records = $kept; Plan = (Get-WtCommitPlan -ChangeSet $kept -Sections $script:ApplySections -GetPackageCatalog { @() }); TypedConfirmation = $false; Dropped = @([PSCustomObject]@{ Kind = 'Confirm'; Labels = @('Svc') }) }
        }
        $engine = { param($Plan) $null = Write-WtUndoEntry -Scope 'Machine' -Action 'Apply Telemetry Settings' -Items @() -TestRootOverride $root; & $script:RealEngine $Plan }
        $r = Invoke-WtAssistantApply -Ids @('Telemetry:A', 'Services:Svc') -Context $Ctx -Index $ApplyIndex -Sections $ApplySections -Gates $gates -Engine $engine -TestRootOverride $root
        @($r.skipped) | Should -Be @('Svc')
        $r.undo_entry_id | Should -Match 'Apply Telemetry Settings'
        @($r.undo_entry_ids).Count | Should -Be 1
    }

    It 'goes through the REAL apply gates: an ADVANCED toggle asks the typed CONFIRM through Context.ReadAnswer and applies on it' {
        $script:GateRisk = $null
        $ctx = @{ Mask = $Ctx.Mask; OnSuggest = { }; Breadcrumb = 'b'; ReadAnswer = { param($L, $P, $R) $script:GateRisk = $R; 'CONFIRM' } }
        $r = Invoke-WtAssistantApply -Ids @('Telemetry:Adv') -Context $ctx -Index $ApplyIndex -Sections $ApplySections -Engine $RealEngine
        @($r.applied | ForEach-Object id) | Should -Contain 'Telemetry:Adv'
        $script:GateRisk | Should -Be 'ADVANCED'
    }

    It 'the REAL apply gates drop an ADVANCED toggle as skipped when the typed word is wrong, applying nothing' {
        $ctx = @{ Mask = $Ctx.Mask; OnSuggest = { }; Breadcrumb = 'b'; ReadAnswer = { param($L, $P, $R) 'nope' } }
        $r = Invoke-WtAssistantApply -Ids @('Telemetry:Adv') -Context $ctx -Index $ApplyIndex -Sections $ApplySections -Engine $RealEngine
        @($r.applied).Count | Should -Be 0
        @($r.skipped) | Should -Contain 'Adv'
    }
}

Describe 'digit-path helpers' {
    It 'confirm lines: label, what, risk word - in the active language, what cut at 200' {
        $entry = Get-WtAssistantIndexEntry -Id 'HardeningPrivacy:HD_M012'
        $lines = @(Get-WtAssistantDigitConfirmLines -Entry $entry)
        $lines.Count | Should -Be 3
        $lines[0] | Should -Be (Get-WtAssistantIndexLabel -Entry $entry)
        $lines[1].Length | Should -BeLessOrEqual 200
        $lines[2] | Should -Be ([string](Get-Translation 'RiskCAUTION'))
        @(Get-WtAssistantDigitConfirmLines -Entry (Get-WtAssistantIndexEntry -Id 'Blocklist:Spy')).Count | Should -BeGreaterOrEqual 2
    }

    It 'run note: one masked line the next user message will carry, never over 200 chars' {
        $mask = @{ ComputerName = 'MYBOX'; UserName = 'zz-nobody'; Serial = ''; Macs = @() }
        Format-WtAssistantRunNote -Number 2 -Id 'Services:DiagTrack' -Outcome 'applied' -Mask $mask | Should -Be '(note: user ran 2 Services:DiagTrack -> applied)'
        Format-WtAssistantRunNote -Number 1 -Id 'X' -Outcome "failed: MYBOX`nsecond line" -Mask $mask | Should -Be '(note: user ran 1 X -> failed: <pc> second line)'
        (Format-WtAssistantRunNote -Number 1 -Id 'X' -Outcome ('e' * 400)).Length | Should -Be 200
    }
}

Describe 'report turn helpers' {
    BeforeAll { $script:ReportMask = @{ ComputerName = 'MYBOX'; UserName = 'zz-nobody'; Serial = ''; Macs = @() } }

    It 'report lines: CR/tab to spaces, blanks and rule lines dropped, column gaps to " | ", every line masked' {
        $lines = @(Get-WtAssistantReportLines -Lines @("Name     State`t`tLocation", '------------', '', "  CloudflareWARP   Etkin  HKLM Run  C:\Program Files\x`r", 'host MYBOX ok', '===', 'single spaced line') -Mask $ReportMask)
        $lines | Should -Be @('Name | State | Location', 'CloudflareWARP | Etkin | HKLM Run | C:\Program Files\x', 'host <pc> ok', 'single spaced line')
        @(Get-WtAssistantReportLines -Lines @()).Count | Should -Be 0
    }

    It 'run report: the header the prompt keys on, the live numbers, then the lines; "(none)" when nothing was printed' {
        $r = Format-WtAssistantRunReport -Number 1 -Label 'Baslangic programlari' -Lines @('a: 1', 'b: 2') -Numbers @('1 Baslangic programlari', '2 Disk Temizligi')
        $r | Should -Be "(result of 1 Baslangic programlari, 2 lines; explain it, do not repeat it)`nnumbers on screen: 1 Baslangic programlari; 2 Disk Temizligi`na: 1`nb: 2"
        Format-WtAssistantRunReport -Number 2 -Label "Two`nlines" -Lines @() | Should -Be "(result of 2 Two lines, 0 lines; explain it, do not repeat it)`noutput: (none)"
        (Format-WtAssistantRunReport -Number 1 -Label ('L' * 100) -Lines @('x')).Split([char]10)[0] | Should -Match ('^\(result of 1 ' + ('L' * 79) + '~, 1 lines')
    }

    It 'run report: masked, and cut at a line boundary under MaxChars with an omitted line' {
        $r = Format-WtAssistantRunReport -Number 1 -Label 'X' -Lines @('on MYBOX', 'fine') -Mask $ReportMask
        $r | Should -Match "`non <pc>`nfine$"
        $long = @(1..200 | ForEach-Object { 'line number ' + $_ + ' ' + ('z' * 30) })
        $cut = Format-WtAssistantRunReport -Number 3 -Label 'Long' -Lines $long -MaxChars 1000
        $cut.Length | Should -BeLessOrEqual 1000
        $cut | Should -Match "`nomitted: [0-9]+ lines$"
        $parts = $cut.Split([char]10)
        $parts[0] | Should -Be '(result of 3 Long, 200 lines; explain it, do not repeat it)'
        ($parts.Count - 2 + [int]([regex]::Match($cut, 'omitted: ([0-9]+) lines').Groups[1].Value)) | Should -Be 200
        foreach ($p in $parts[1..($parts.Count - 2)]) { $p | Should -Match '^line number [0-9]+ z{30}$' }
        $withCard = Format-WtAssistantRunReport -Number 1 -Label 'L' -Lines $long -Numbers @('1 ' + ('a' * 190)) -MaxChars 1000
        $withCard.Length | Should -BeLessOrEqual 1000
        $withCard.Split([char]10)[1] | Should -Match '^numbers on screen: 1 a{100,}'
        $wide = @(1..60 | ForEach-Object { 'row ' + $_ + ' MYBOX ' + ('y' * 20) })
        $maskedCut = Format-WtAssistantRunReport -Number 1 -Label 'L' -Lines $wide -MaxChars 600 -Mask $ReportMask
        $maskedCut.Length | Should -BeLessOrEqual 600
        $maskedCut | Should -Not -Match 'MYBOX'
        $maskedCut | Should -Match '<pc>'
    }

    It 'apply report lines: applied / failed / skipped / flags, nothing for missing or empty fields' {
        $full = [PSCustomObject]@{ applied = @(@{ id = 'a'; label = 'A' }); failed = @(@{ id = 'b'; label = 'B'; error = 'boom' }); skipped = @('C'); reboot_needed = $true; explorer_restart = $true }
        @(Get-WtAssistantApplyReportLines -Result $full) | Should -Be @(((Get-Translation 'AsApplied') -f 'A'), ((Get-Translation 'AsApplyFailed') -f 'B', 'boom'), 'skipped: C', 'reboot needed: yes', 'explorer restarted: yes')
        @(Get-WtAssistantApplyReportLines -Result ([PSCustomObject]@{ applied = @() })).Count | Should -Be 0
        @(Get-WtAssistantApplyReportLines -Result $null).Count | Should -Be 0
    }

    It 'loose-number note: names the live numbers when there are some, asks for a real suggest call when there are none' {
        $none = Format-WtAssistantLooseNumberNote -Number 4
        $none | Should -Match '^\(note: the user typed 4 but no numbered suggestion list is active'
        $none | Should -Match 'search_wintoolify then suggest_wintoolify'
        $some = Format-WtAssistantLooseNumberNote -Number 4 -Numbers @('1 A', '2 B')
        $some | Should -Match '^\(note: the user typed 4 but the numbers on screen are 1-2: 1 A; 2 B - '
        (Format-WtAssistantLooseNumberNote -Number 9 -Numbers @(('x' * 300))) | Should -Match 'x{199}~'
    }
}

Describe 'save_note' {
    It 'saves through the memory file, tells the screen, and reports the count' {
        $root = Join-Path $TestDrive 'sn'
        $script:Told = @()
        $ctx = @{ TestRootOverride = $root; OnNoteSaved = { param($T) $script:Told += @($T) }; Mask = @{ ComputerName = 'BURAK-PC'; UserName = 'Burak'; Serial = ''; Macs = @() } }
        $r = Invoke-WtAssistantSaveNote -Text ' user prefers Turkish answers ' -Context $ctx
        $r.saved | Should -BeTrue
        $r.Contains('text') | Should -BeFalse
        (ConvertTo-WtAssistantToolText -Value $r) | Should -Be "saved: yes`nnote_count: 1"
        $r.note_count | Should -Be 1
        $r.dropped_oldest | Should -BeFalse
        $script:Told | Should -Be @('user prefers Turkish answers')
        (Invoke-WtAssistantSaveNote -Text '' -Context $ctx).error | Should -Be 'empty note'
        @(Read-WtAssistantNotes -TestRootOverride $root)[0].text | Should -Be 'user prefers Turkish answers'
        $record = Get-WtAssistantToolRecord -Name 'save_note'
        $record.Tier | Should -Be 'read'
        $record.PassContext | Should -BeTrue
        $record.Required | Should -Be @('text')
    }

    It 'the disk copy is masked at save time, using Context.Mask when given, or Get-WtAssistantMaskContext otherwise' {
        $root = Join-Path $TestDrive 'sn-mask'
        $ctx = @{ TestRootOverride = $root; Mask = @{ ComputerName = 'TESTPC'; UserName = 'ali'; Serial = ''; Macs = @() } }
        $r = Invoke-WtAssistantSaveNote -Text 'ali uses TESTPC at C:\Users\ali' -Context $ctx
        $r.saved | Should -BeTrue
        $r.Contains('text') | Should -BeFalse
        $r.note_count | Should -Be 1
        $stored = @(Read-WtAssistantNotes -TestRootOverride $root)[0].text
        $stored | Should -Match '<kullanici>'
        $stored | Should -Match '<pc>'
        $stored | Should -Not -Match 'TESTPC'
        $stored | Should -Not -Match '\\Users\\ali'
    }

    It 'says dropped_oldest only when the eleventh note pushed one out' {
        $root = Join-Path $TestDrive 'sn-drop'
        $ctx = @{ TestRootOverride = $root; Mask = @{ ComputerName = 'PC'; UserName = 'zz-nobody'; Serial = ''; Macs = @() } }
        foreach ($i in 1..10) { $null = Invoke-WtAssistantSaveNote -Text ('note ' + $i) -Context $ctx }
        $r = Invoke-WtAssistantSaveNote -Text 'note 11' -Context $ctx
        $r.dropped_oldest | Should -BeTrue
        (ConvertTo-WtAssistantToolText -Value $r) | Should -Be "saved: yes`nnote_count: 10`ndropped_oldest: yes"
    }
}
