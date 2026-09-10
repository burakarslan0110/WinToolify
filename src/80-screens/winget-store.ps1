# The winget store screen: the winget gate, tab projections and the loop.
# Covered by: tests/WingetStoreScreen.Tests.ps1

function Get-WtWingetStoreLabels {
    <#
    .SYNOPSIS
        Every user-visible label the store frame needs, resolved through
        the active language in one place so the composers stay pure.
    #>
    $categories = @{}
    foreach ($c in (Get-WtWingetStoreCategories)) { $categories[[string]$c.Key] = Get-Translation ([string]$c.LabelKey) }
    return @{
        Categories = $categories
        Tabs       = @{
            Store     = Get-Translation 'WsTabStore'
            Installed = Get-Translation 'WsTabInstalled'
        }
        Headers    = @{
            Name      = Get-Translation 'WsColName'
            Id        = Get-Translation 'WsColId'
            Version   = Get-Translation 'WsColVersion'
            Available = Get-Translation 'WsColAvailable'
        }
    }
}

function Test-WtWingetStoreGate {
    <#
    .SYNOPSIS
        Whether the store may open. winget present -> yes. Absent -> a
        panel explains why (Windows 10 / LTSC often ships without App
        Installer) and ASKS. Never a silent install: the rest of this
        tool asks before it reaches the network, and so does this.
        Returns [bool]; $false means go back to the menu. If the user
        agrees but the install itself fails, that failure is shown
        before returning $false, since a silent return would read as
        the keypress having done nothing. Both panels are injected, the
        failure notice through its own -ReadFailure: it is a different
        panel from the question, and a caller (a test, or any host with
        no console) that replaced only the question would still have hit
        the real console here.
    #>
    param(
        [bool]$HasWinget = $true,
        [scriptblock]$ReadAnswer = {
            param($Lines, $Prompt)
            Read-WtPanelAnswer -Breadcrumb (Get-Translation 'WsMissingTitle') -Lines $Lines -Prompt $Prompt -Risk 'CAUTION'
        },
        [scriptblock]$ReadFailure = {
            $null = Read-WtPanelAnswer -Breadcrumb (Get-Translation 'WsMissingTitle') `
                -Lines @((Get-Translation 'WsMissingFailed')) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
        },
        [scriptblock]$Install = {
            $null = Test-WingetInstalled
            [bool](Get-Command winget -ErrorAction SilentlyContinue)
        }
    )
    if ($HasWinget) { return $true }
    $answer = & $ReadAnswer @((Get-Translation 'WsMissingLines')) (Get-Translation 'WsMissingPrompt')
    if (-not (Test-WtAffirmativeAnswer -Answer ([string]$answer))) { return $false }
    $ok = [bool](& $Install)
    if (-not $ok) {
        $null = & $ReadFailure
        Reset-WtFrameCache
    }
    return $ok
}

function Get-WtWingetStoreTabRows {
    <#
    .SYNOPSIS
        The rows the table composer draws for the page on screen: the
        installed tab, or the store page showing winget results. The store
        page's CATALOG is a grid, not a table, so it projects to nothing.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State
    )
    if ([string]$State.Tab -eq 'Installed') {
        return , @(Select-WtWingetStoreApps -Apps @($State.Installed) -Query ([string]$State.InstalledQuery))
    }
    if ([string]$State.Tab -eq 'Store' -and [string]$State.Mode -eq 'Results') { return , @($State.Results) }
    return @()
}

function Invoke-WtWingetStoreScreen {
    <#
    .SYNOPSIS
        The store's interactive loop: frame -> key batch -> reducer
        until the reducer emits Back, returning @{ Nav; Target; Char;
        HasMarks } for Invoke-WtMainLoop; everything testable lives in
        Update-WtStoreState / Get-WtStoreFrameRows / Invoke-WtWingetBatch.
        A bare pipeline call unwraps empty/single results, so callers
        wrap in @() - except a source already returning "return , $list",
        which must be assigned bare or @() re-wraps the whole list into
        one element. An unlabeled 'break' in a switch nested in a
        foreach exits only the switch, so the stop condition rides a
        variable checked after it.
    #>
    $back = @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
    if (-not (Test-WtWingetStoreGate -HasWinget ([bool](Get-Command winget -ErrorAction SilentlyContinue)))) {
        Reset-WtFrameCache
        return $back
    }

    $labels = Get-WtWingetStoreLabels
    $breadcrumb = Get-WtBreadcrumb -Keys 'MainMenu', 'WingetStore'
    $apps = @(Get-WtWingetStoreCatalog)
    $categoryKeys = @((Get-WtWingetStoreCategories).Key)
    $state = New-WtStoreState -Query ([string]$script:WtWingetStoreInitialQuery)
    $script:WtWingetStoreInitialQuery = ''
    $converter = { param($Key, $KeyChar) ConvertTo-WtGridKeyToken -Key $Key -KeyChar $KeyChar }
    $waiting = { param([string]$Text)
        Show-WtPanelMessage -Breadcrumb (Get-Translation 'WingetStore') -Lines @($Text) -FooterText '' | Out-Null
    }
    $reloadInstalled = {
        & $waiting (Get-Translation 'WsLoadingInstalled')
        $state.Installed = @(Get-WtWingetInstalledPackages)
        Reset-WtFrameCache
    }

    & $reloadInstalled

    $gridKey = ''
    $gridRows = @()
    while ($true) {
        $size = Get-WtConsoleSize
        $installedIds = [string[]]@(foreach ($installedPkg in @($state.Installed)) { [string]$installedPkg.Id })
        $onStore = ([string]$state.Tab -eq 'Store')
        $isResults = ($onStore -and [string]$state.Mode -eq 'Results')
        $isCatalog = ($onStore -and -not $isResults)
        $visible = @(Select-WtWingetStoreApps -Apps $apps -Query $(if ($isCatalog) { [string]$state.Query } else { '' }))
        $geo = Get-WtGridGeometry -Inner ([Math]::Max(20, $size.Width - 1) - 4)
        $nextGridKey = [string]$isCatalog + '|' + [string]$state.Query + '|' + [string]$geo.ColumnCount + '|' + [string]$visible.Count
        if ($nextGridKey -ne $gridKey) {
            $gridRows = Get-WtStoreGridRows -Apps $visible -CategoryKeys $categoryKeys -CellsPerRow $geo.ColumnCount `
                -CategoryLabels $labels.Categories
            $gridKey = $nextGridKey
        }
        $tableRows = Get-WtWingetStoreTabRows -State $state
        $chromeLayout = 'Table'
        if ($isCatalog) { $chromeLayout = 'Grid' }
        elseif ($isResults) { $chromeLayout = 'Results' }
        $viewHeight = [Math]::Max(1, $size.Height - (Get-WtStoreChromeHeight -Layout $chromeLayout -Width $size.Width))

        $navRows = @()
        if ($isCatalog) { $navRows = $gridRows }
        else { $navRows = Get-WtStoreListRows -Rows $tableRows }
        $state.Cursor = Get-WtStoreValidCursor -Rows $navRows -Cursor $state.Cursor
        $state.WindowStart = Get-WtViewportWindow -ItemCount (Get-WtGridRowCount -Rows $navRows) `
            -CursorIndex ([int]$state.Cursor.Row) -ViewHeight $viewHeight -WindowStart ([int]$state.WindowStart)

        $onInstalled = ([string]$state.Tab -eq 'Installed')
        $installedFiltered = ($onInstalled -and ([string]$state.InstalledQuery).Trim() -ne '')
        $footer = switch ([string]$state.Focus) {
            'Input' { if ($onInstalled) { Get-Translation 'WsFooterInputInstalled' } else { Get-Translation 'WsFooterInput' } }
            default {
                if ($onInstalled) { Get-Translation 'WsFooterInstalled' }
                elseif ($isResults) { Get-Translation 'WsFooterResults' }
                else { Get-Translation 'WsFooterStore' }
            }
        }
        if ($state.Hint) { $footer = [string]$state.Hint }
        $counter = if ($state.Marks.Count -gt 0) { (Get-Translation 'WsMarked') -f $state.Marks.Count } else { '' }
        $searchCount = (Get-Translation 'WsCountApps') -f $(if ($onInstalled) { @($state.Installed).Count } else { $apps.Count })
        if ($onStore -and ([string]$state.Query).Trim() -ne '') {
            $matchCount = if ($isResults) { @($state.Results).Count } else { $visible.Count }
            $searchCount += ' - ' + ((Get-Translation 'WsCountMatches') -f $matchCount)
        }
        elseif ($installedFiltered) {
            $searchCount += ' - ' + ((Get-Translation 'WsCountMatches') -f @($tableRows).Count)
        }

        if ($isCatalog) {
            $frame = Get-WtStoreFrameRows -State $state -Rows $gridRows -Width $size.Width -Height $size.Height `
                -Glyphs $script:WtGlyphs -Breadcrumb $breadcrumb -TabLabels $labels.Tabs `
                -FooterText $footer -CounterText $counter -SearchCountText $searchCount -InstalledIds $installedIds
        }
        else {
            $empty = if ($isResults -or $installedFiltered) { Get-Translation 'WsEmptySearch' } else { Get-Translation 'WsEmptyInstalled' }
            $heading = if ($isResults) { (Get-Translation 'WsResultsHeading') -f [string]$state.Query } else { '' }
            $frame = Get-WtStoreTableRows -State $state -Rows $tableRows -Width $size.Width -Height $size.Height `
                -Glyphs $script:WtGlyphs -Breadcrumb $breadcrumb -Headers $labels.Headers -TabLabels $labels.Tabs `
                -FooterText $footer -CounterText $counter -SearchCountText $searchCount `
                -HeadingText $heading -EmptyText $empty
        }
        Write-WtFrame -FrameLines $frame -Width $size.Width -Height $size.Height

        foreach ($token in (Read-WtInputBatch -Converter $converter)) {
            $r = Update-WtStoreState -State $state -Token $token -Rows $navRows `
                -ViewHeight $viewHeight -InstalledIds $installedIds
            $state = $r.State
            $stop = $false
            switch ($r.Emit) {
                'Back' { Reset-WtFrameCache; return $back }
                'Refused' { $state.Hint = Get-Translation 'WsHintInstalled' }
                'Refresh' {
                    Clear-WtWingetCache
                    if ([string]$state.Mode -eq 'Results') {
                        if ([string]$state.Query) {
                            & $waiting ((Get-Translation 'WsSearching') -f [string]$state.Query)
                            $state.Results = @(Get-WtWingetSearchResults -Query ([string]$state.Query))
                            Reset-WtFrameCache
                        }
                    }
                    else { & $reloadInstalled }
                    $stop = $true
                }
                'Search' {
                    if ([string]$state.Mode -eq 'Results') {
                        & $waiting ((Get-Translation 'WsSearching') -f [string]$state.Query)
                        $state.Results = @(Get-WtWingetSearchResults -Query ([string]$state.Query))
                        Reset-WtFrameCache
                    }
                    $stop = $true
                }
                'Install'   { Invoke-WtWingetStoreRun -State $state -Operation 'Install'; $stop = $true }
                'Upgrade'   { Invoke-WtWingetStoreRun -State $state -Operation 'Upgrade'; $stop = $true }
                'Uninstall' {
                    if (Confirm-WtWingetUninstall -Ids ([string[]]@($state.Marks))) {
                        Invoke-WtWingetStoreRun -State $state -Operation 'Uninstall'
                    }
                    else { Reset-WtFrameCache }
                    $stop = $true
                }
            }
            if ($stop) { break }
        }
    }
}

function Confirm-WtWingetUninstall {
    <#
    .SYNOPSIS
        The typed-word gate in front of a bulk uninstall, naming every
        package it is about to remove. Returns [bool]; $false means do
        nothing at all. Uninstall is the only irreversible, hence the
        only gated, operation on this screen - install and upgrade only
        add software. The ids are listed, not counted, since "3
        packages will be removed" is not something anyone can check,
        and a mark can outlive the screen that set it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids,
        [scriptblock]$Confirm = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines -Breadcrumb (Get-Translation 'WingetStore')
        }
    )
    $ids = @($Ids)
    if ($ids.Count -eq 0) { return $false }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($id in $ids) { $lines.Add('  - ' + [string]$id) }
    $consequence = (Get-Translation 'WsUninstallConsequence') -f $ids.Count
    return [bool](& $Confirm $consequence ([string[]]$lines.ToArray()))
}

function Invoke-WtWingetStoreRun {
    <#
    .SYNOPSIS
        Runs the marked packages through Invoke-WtWingetBatch with the
        live output panel attached, prints the summary, then clears the
        marks and re-reads the installed list. A partial output line is
        committed before the next package's header so it can't merge
        into that line. A user-scope package can't be touched from this
        elevated session (0x8A15007D); that case retries via a scheduled
        task at medium integrity, tailing its output since it can't be
        streamed, with a start failure returned as $null rather than an
        invented exit code. LastSummary on State lets the assistant's
        digit path report the result without opening this screen.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('Install', 'Upgrade', 'Uninstall')][string]$Operation
    )
    $ids = [string[]]@($State.Marks)
    if ($ids.Count -eq 0) { return }
    $script:WtPanelBreadcrumb = Get-Translation 'WingetStore'
    $output = New-WtNativeOutputState
    $header = ''
    $paint = {
        $size = Get-WtConsoleSize
        $view = [Math]::Max(1, $size.Height - (Get-WtFrameChromeHeight -Width $size.Width))
        $lines = @($output.Lines.ToArray())
        if ([string]$output.Current -ne '') { $lines += [string]$output.Current }
        Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb `
            -Lines (Get-WtOutputTail -Lines $lines -Count $view) -FooterText $header | Out-Null
    }
    $runOne = {
        param($Id, $Arguments, $Index, $Total)
        $header = (Get-Translation 'WsRunning') -f $Index, $Total, $Id
        if ([string]$output.Current -ne '') {
            $output.Lines.Add([string]$output.Current)
            $output.Current = ''
            $output.Column = 0
        }
        $output.Lines.Add('')
        $output.Lines.Add('> winget ' + ($Arguments -join ' '))
        & $paint
        Invoke-WtStreamedProcess -FilePath 'winget.exe' `
            -Arguments (ConvertTo-WtNativeArgumentLine -Arguments $Arguments) `
            -State $output -OnTick $paint -Encoding ([System.Text.Encoding]::UTF8)
    }
    $runOneAsUser = {
        param($Id, $Arguments, $Index, $Total)
        if ([string]$output.Current -ne '') {
            $output.Lines.Add([string]$output.Current)
            $output.Current = ''
            $output.Column = 0
        }
        $output.Lines.Add('')
        $output.Lines.Add((Get-Translation 'WsRetryAsUser'))
        $output.Lines.Add('> winget ' + ($Arguments -join ' '))
        & $paint
        $tailMark = $output.Lines.Count
        $replaceTail = {
            param($TailLines)
            while ($output.Lines.Count -gt $tailMark) { $output.Lines.RemoveAt($output.Lines.Count - 1) }
            foreach ($tailLine in @($TailLines)) { $output.Lines.Add([string]$tailLine) }
        }
        $asUser = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments ([string[]]@($Arguments)) `
            -OnOutput { param($TailLines) & $replaceTail $TailLines; & $paint }
        & $replaceTail $asUser.Lines
        if (-not $asUser.Ran) {
            $output.Lines.Add((Get-Translation (Get-WtRetryReasonKey -Reason ([string]$asUser.Reason))))
            & $paint
            return $null
        }
        & $paint
        return $asUser.ExitCode
    }
    $results = @(Invoke-WtWingetBatch -Ids $ids -Operation $Operation -RunOne $runOne -RunOneAsUser $runOneAsUser)
    if ([string]$output.Current -ne '') {
        $output.Lines.Add([string]$output.Current)
        $output.Current = ''
        $output.Column = 0
    }
    $summaryLines = [string[]]@(Get-WtWingetSummaryLines -Results $results -Operation $Operation)
    foreach ($line in $summaryLines) { $output.Lines.Add($line) }
    $State.LastSummary = $summaryLines

    $State.Marks.Clear()
    Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb `
        -Lines @((Get-Translation 'WsLoadingInstalled')) -FooterText '' | Out-Null
    $State.Installed = @(Get-WtWingetInstalledPackages)
    Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $output.Lines.ToArray()
    Reset-WtFrameCache
}
