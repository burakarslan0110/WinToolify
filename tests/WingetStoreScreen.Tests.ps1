#Requires -Modules Pester

<#
.SYNOPSIS
    The store screen's testable edges: the winget-missing gate, the tab
    row projection and the screen's registration in the navigation tree.
    The interactive loop itself is UI and is not unit-tested.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Test-WtWingetStoreGate' {
    <#
    .SYNOPSIS
        Forces Turkish for the whole Describe: 'e' / 'h' are the
        Evet/Hayir yes/no letters this file exercises, but the active
        language defaults to EN at dot-source time (nothing runs the
        real settings load in a test) - without forcing TR, the
        affirmative-answer branch is never actually taken and 'asks
        before installing winget' would silently pass for the wrong
        reason.
    #>
    BeforeAll { $script:PriorLanguage = $script:Language; $script:Language = 'TR' }
    AfterAll { $script:Language = $script:PriorLanguage }

    It 'opens straight away when winget is present' {
        $called = $false
        Test-WtWingetStoreGate -HasWinget $true -ReadAnswer { $script:called = $true; 'e' } -Install { } | Should -BeTrue
    }

    It 'asks before installing winget - never installs silently' {
        $script:Asked = $false
        $script:Installed = $false
        $ok = Test-WtWingetStoreGate -HasWinget $false `
            -ReadAnswer { param($Lines, $Prompt) $script:Asked = $true; 'e' } `
            -Install { $script:Installed = $true; $true }
        $script:Asked | Should -BeTrue
        $script:Installed | Should -BeTrue
        $ok | Should -BeTrue
    }

    It 'returns to the menu when the user declines' {
        $script:Installed = $false
        $ok = Test-WtWingetStoreGate -HasWinget $false `
            -ReadAnswer { param($Lines, $Prompt) 'h' } `
            -Install { $script:Installed = $true; $true }
        $script:Installed | Should -BeFalse
        $ok | Should -BeFalse
    }

    It 'stays closed when the winget install itself failed, and says so first' {
        $script:Told = $false
        Test-WtWingetStoreGate -HasWinget $false `
            -ReadAnswer { param($Lines, $Prompt) 'e' } `
            -ReadFailure { $script:Told = $true } `
            -Install { $false } | Should -BeFalse
        $script:Told | Should -BeTrue
    }

    It 'never announces a failure the user did not hit' {
        $script:Told = $false
        Test-WtWingetStoreGate -HasWinget $false `
            -ReadAnswer { param($Lines, $Prompt) 'h' } `
            -ReadFailure { $script:Told = $true } `
            -Install { $true } | Should -BeFalse
        $script:Told | Should -BeFalse

        Test-WtWingetStoreGate -HasWinget $false `
            -ReadAnswer { param($Lines, $Prompt) 'e' } `
            -ReadFailure { $script:Told = $true } `
            -Install { $true } | Should -BeTrue
        $script:Told | Should -BeFalse
    }
}

Describe 'Get-WtWingetStoreTabRows' {
    <#
    .SYNOPSIS
        Pipeline unrolling is the running theme here: a builder that
        returns a list under a unary comma gets unrolled by a bare
        (non-@()) call site - to $null for zero rows, not @(). Its own
        'return @()' for the default (Store) tab has no protecting
        comma, so a bare assignment collapsing it to $null is the exact
        case that shipped a crash: the old -Rows parameter was Mandatory
        without AllowNull, so passing that $null on threw before the
        screen ever drew a frame.
    #>
    BeforeAll {
        $script:Apps = @([PSCustomObject]@{ Id = 'M.F'; Name = 'Firefox'; Category = 'Browsers'; Tags = 'tarayici' })
        $script:Inst = @(@{ Name = '7-Zip'; Id = '7zip.7zip'; Version = '23.01'; Available = '24.09' })
    }

    It 'projects the installed list on the installed tab' {
        $s = New-WtStoreState; $s.Tab = 'Installed'; $s.Installed = $Inst
        $rows = @(Get-WtWingetStoreTabRows -State $s)
        $rows[0].Id | Should -Be '7zip.7zip'
    }

    It 'filters the installed list by the installed query - name or id, case-insensitive - and blank means everything' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $s.Installed = @(
            @{ Name = '7-Zip'; Id = '7zip.7zip'; Version = '23.01'; Available = '24.09' }
            @{ Name = 'Git'; Id = 'Git.Git'; Version = '2.55'; Available = '' }
            @{ Name = 'Ollama version 0.33.2'; Id = 'Ollama.Ollama'; Version = '0.33.2'; Available = '0.33.3' }
        )
        $s.InstalledQuery = 'GIT'
        $hits = Get-WtWingetStoreTabRows -State $s
        @($hits | ForEach-Object { $_.Id }) | Should -Be @('Git.Git')
        $s.InstalledQuery = 'ollama.'
        $hits = Get-WtWingetStoreTabRows -State $s
        @($hits | ForEach-Object { $_.Id }) | Should -Be @('Ollama.Ollama')
        $s.InstalledQuery = 'zzz'
        $none = Get-WtWingetStoreTabRows -State $s
        @($none).Count | Should -Be 0
        $s.InstalledQuery = '   '
        $all = Get-WtWingetStoreTabRows -State $s
        @($all).Count | Should -Be 3
        $s.InstalledQuery = ''; $s.Query = 'git'
        $all = Get-WtWingetStoreTabRows -State $s
        @($all).Count | Should -Be 3
    }

    It 'projects the winget results when the store page is in Results mode' {
        $s = New-WtStoreState; $s.Mode = 'Results'
        $s.Results = @(@{ Name = 'VLC'; Id = 'VideoLAN.VLC'; Version = '3.0.21'; Available = '' })
        $rows = @(Get-WtWingetStoreTabRows -State $s)
        $rows[0].Id | Should -Be 'VideoLAN.VLC'
    }

    It 'returns nothing for the store page showing its catalog - that one is a grid, not a table' {
        $s = New-WtStoreState
        $s.Mode | Should -Be 'Catalog'
        @(Get-WtWingetStoreTabRows -State $s).Count | Should -Be 0
    }

    It 'ignores stale results while the page is back on the catalog' {
        $s = New-WtStoreState
        $s.Results = @(@{ Name = 'VLC'; Id = 'VideoLAN.VLC'; Version = '3.0.21'; Available = '' })
        @(Get-WtWingetStoreTabRows -State $s).Count | Should -Be 0
    }

    It 'feeds straight into Get-WtStoreListRows without throwing - the real crash on the default tab' {
        $s = New-WtStoreState
        $tableRows = Get-WtWingetStoreTabRows -State $s
        $tableRows | Should -BeNullOrEmpty
        $result = Get-WtStoreListRows -Rows $tableRows
        @($result).Count | Should -Be 0
        $grid = Get-WtStoreGridRows -Apps @([PSCustomObject]@{ Id = 'M.F'; Name = 'Firefox'; Category = 'Browsers' }) `
            -CategoryKeys @('Browsers', 'Dev', 'Media', 'Comms', 'Utilities') -CellsPerRow 5
        @($grid).Count | Should -Be 2
        $grid[1].Cells[0].Id | Should -Be 'M.F'
    }
}

Describe 'Store screen registration' {
    It 'labels every category, tab and table header through a translation key' {
        $labels = Get-WtWingetStoreLabels
        foreach ($c in (Get-WtWingetStoreCategories)) {
            $labels.Categories[$c.Key] | Should -Not -BeNullOrEmpty
        }
        foreach ($t in 'Store', 'Installed') { $labels.Tabs[$t] | Should -Not -BeNullOrEmpty }
        foreach ($h in 'Name', 'Id', 'Version', 'Available') { $labels.Headers[$h] | Should -Not -BeNullOrEmpty }
    }

    It 'offers exactly two tabs and no Search tab anywhere' {
        $labels = Get-WtWingetStoreLabels
        @($labels.Tabs.Keys).Count | Should -Be 2
        $labels.Tabs.ContainsKey('Search') | Should -BeFalse
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang].ContainsKey('WsTabSearch') | Should -BeFalse -Because "the $lang table must not keep a key nothing draws"
        }
    }

    It 'has every string the reworked screen asks for, in both languages' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'WsFooterStore', 'WsFooterResults', 'WsFooterInstalled', 'WsFooterInput',
                'WsCountApps', 'WsCountMatches', 'WsResultsHeading') {
                $script:Translations[$lang][$key] | Should -Not -BeNullOrEmpty -Because "$lang is missing $key"
            }
            foreach ($key in 'WsCountApps', 'WsCountMatches', 'WsResultsHeading') {
                $script:Translations[$lang][$key] | Should -BeLike '*{0}*' -Because "$lang/$key must carry its placeholder"
            }
        }
    }

    It 'writes every store footer as Key: Action pairs on one divider' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'WsFooterStore', 'WsFooterResults', 'WsFooterInstalled', 'WsFooterInput') {
                $text = [string]$script:Translations[$lang][$key]
                $pairs = @($text -split '   ')
                $pairs.Count | Should -BeGreaterThan 2 -Because "$lang/$key must hold several pairs"
                foreach ($pair in $pairs) {
                    $pair.Trim() | Should -Match '^[^:]+: .+$' -Because "$lang/$key pair '$pair' must read 'Key: Action'"
                }
            }
        }
    }

    It 'is reachable from the main menu' {
        @(Get-WtMainMenuItems).Name | Should -Contain 'WingetStore'
    }

    It 'has a case in the screen registry, not the placeholder' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        $src | Should -Match ([regex]::Escape("'WingetStore' { return Invoke-WtWingetStoreScreen }"))
    }
}

Describe 'Confirm-WtWingetUninstall' {
    It 'asks before removing anything - Del alone must not reach winget uninstall' {
        $script:Asked = $false
        $ok = Confirm-WtWingetUninstall -Ids @('Google.Chrome') -Confirm {
            param($Consequence, $Lines)
            $script:Asked = $true
            $false
        }
        $script:Asked | Should -BeTrue
        $ok | Should -BeFalse
    }

    It 'names every package it is about to remove, not just how many' {
        $script:SeenLines = @()
        $script:SeenConsequence = ''
        $null = Confirm-WtWingetUninstall -Ids @('Google.Chrome', 'Mozilla.Firefox', 'Brave.Brave') -Confirm {
            param($Consequence, $Lines)
            $script:SeenLines = @($Lines)
            $script:SeenConsequence = [string]$Consequence
            $false
        }
        foreach ($id in 'Google.Chrome', 'Mozilla.Firefox', 'Brave.Brave') {
            ($script:SeenLines -join "`n") | Should -BeLike "*$id*"
        }
        $script:SeenConsequence | Should -Be ((Get-Translation 'WsUninstallConsequence') -f 3)
    }

    It 'goes ahead when the user types the gate word' {
        Confirm-WtWingetUninstall -Ids @('Google.Chrome') -Confirm { param($C, $L) $true } | Should -BeTrue
    }

    It 'never asks, and never proceeds, with nothing marked' {
        $script:Asked = $false
        $ok = Confirm-WtWingetUninstall -Ids @() -Confirm { param($C, $L) $script:Asked = $true; $true }
        $ok | Should -BeFalse
        $script:Asked | Should -BeFalse
    }

    It 'has the consequence string in both languages, with its count placeholder' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['WsUninstallConsequence'] | Should -Not -BeNullOrEmpty
            $script:Translations[$lang]['WsUninstallConsequence'] | Should -BeLike '*{0}*'
        }
    }
}

Describe 'Store screen loop wiring' {
    <#
    .SYNOPSIS
        The loop itself needs a real console and is not unit-testable,
        so these pin the exact source lines instead of calling a
        function. Two variants of the same pipeline-unrolling trap
        recur here: an if-EXPRESSION unrolls the unary comma protecting
        a builder's row list through the pipeline (so the row builders
        must be assigned with an if STATEMENT), and wrapping an
        already-comma-protected builder call in @(...) re-wraps its
        single list into a one-element array instead of leaving it
        alone (so those calls must stay bare).
    #>
    BeforeAll { $script:LoopSource = Get-Content -LiteralPath $script:TargetPath -Raw }

    It 'gates the uninstall run on the typed-word confirmation, and leaves install one keypress' {
        $LoopSource | Should -Match 'if \(Confirm-WtWingetUninstall -Ids'
        $LoopSource | Should -Match "'Install'\s+\{ Invoke-WtWingetStoreRun -State \`$state -Operation 'Install'"
    }

    It 'clamps the cursor against the rows it is about to draw, every frame' {
        $LoopSource | Should -Match '\$state\.Cursor = Get-WtStoreValidCursor -Rows \$navRows'
    }

    It 'picks the navigation rows with an if STATEMENT, never an inline if-expression' {
        $LoopSource | Should -Match '\$navRows = \$gridRows'
        $LoopSource | Should -Match '\$navRows = Get-WtStoreListRows -Rows \$tableRows'
        $LoopSource | Should -Not -Match '\$navRows = if '
    }

    It 'assigns the row builders BARE, never through @(...)' {
        $LoopSource | Should -Match '\$gridRows = Get-WtStoreGridRows -Apps \$visible'
        $LoopSource | Should -Not -Match '\$gridRows = @\(Get-WtStoreGridRows'
        $LoopSource | Should -Not -Match '\$navRows = @\(Get-WtStoreListRows'
    }

    It 'sizes the viewport with the layout AND the width the active page actually draws' {
        $LoopSource | Should -Match 'Get-WtStoreChromeHeight -Layout \$chromeLayout -Width \$size\.Width'
        $LoopSource | Should -Match "\`$chromeLayout = 'Grid'"
        $LoopSource | Should -Match "\`$chromeLayout = 'Results'"
    }

    It 'refreshes only what the active page shows - R on the catalog must not run a winget search' {
        $refresh = [regex]::Match($LoopSource, "(?s)'Refresh' \{(.*?)\r?\n {16}\}")
        $refresh.Success | Should -BeTrue -Because 'the Refresh emit handler must be findable'
        $refresh.Groups[1].Value | Should -Match "\`$state\.Mode -eq 'Results'"
    }

    It 'flushes a partial output row before the next package header goes down' {
        $runOne = [regex]::Match($LoopSource, "(?s)\`$runOne = \{(.*?)\r?\n {4}\}")
        $runOne.Success | Should -BeTrue -Because 'the per-package runner must be findable'
        $runOne.Groups[1].Value | Should -Match "\`$output\.Current = ''"
    }

    It 'paints a progress panel immediately before every winget call that blocks the loop' {
        $LoopSource | Should -Match (
            '& \$waiting \(Get-Translation ''WsLoadingInstalled''\)\r?\n\s*' +
            '\$state\.Installed = @\(Get-WtWingetInstalledPackages\)'
        ) -Because 'the reloadInstalled scriptblock must paint before it calls winget'

        $searchPairs = [regex]::Matches($LoopSource, (
            '& \$waiting \(\(Get-Translation ''WsSearching''\) -f \[string\]\$state\.Query\)\r?\n\s*' +
            '\$state\.Results = @\(Get-WtWingetSearchResults -Query \(\[string\]\$state\.Query\)\)'
        ))
        $searchPairs.Count | Should -Be 2 -Because 'both the Refresh and Search emit handlers must pair the panel with the search call'

        $LoopSource | Should -Match (
            'Show-WtPanelMessage -Breadcrumb \$script:WtPanelBreadcrumb `\r?\n\s*' +
            '-Lines @\(\(Get-Translation ''WsLoadingInstalled''\)\) -FooterText '''' \| Out-Null\r?\n\s*' +
            '\$State\.Installed = @\(Get-WtWingetInstalledPackages\)'
        ) -Because 'Invoke-WtWingetStoreRun must paint before its post-run reload'
    }
}

Describe 'Invoke-WtWingetStoreScreen (headless smoke test)' {
    <#
    .SYNOPSIS
        No pure-function test caught the crash this guards against -
        every Get-WtStoreListRows test passes a populated Rows list, and
        the loop itself has no executing test - so this spawns a real
        child process and actually enters the screen rather than mocking
        the entry path. Stdin is redirected and closed immediately:
        Read-WtInputBatch then calls Read-Host, gets EOF, and returns
        'Eof', which the reducer maps to 'Back' - the mechanism that
        lets a screen reading real console input run headlessly at all,
        without blocking on a keypress.
    #>
    BeforeAll {
        $script:ProbeScript = Join-Path $TestDrive 'probe-store-screen.ps1'
        Set-Content -LiteralPath $script:ProbeScript -Encoding UTF8 -Value @'
param([Parameter(Mandatory)][string]$TargetPath)
. $TargetPath
try {
    Initialize-WtTui
    $result = Invoke-WtWingetStoreScreen
    if ($null -eq $result) { Write-Output 'PROBE-OK Nav=<null>' }
    else { Write-Output ('PROBE-OK Nav=' + [string]$result.Nav) }
}
catch {
    Write-Output ('PROBE-EXCEPTION ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
    exit 1
}
'@

        <#
        .SYNOPSIS
            Spawns the probe script headless and captures its output.
            Both pipes must be drained CONCURRENTLY via ReadToEndAsync:
            reading one to EOF before the other deadlocks once the child
            writes past the OS's 4 KB pipe buffer while nobody reads it.
            Register-ObjectEvent + BeginOutputReadLine does not work
            here either - PowerShell 5.1 does not service that event
            queue while a plain WaitForExit() blocks the pipeline thread.
        #>
        function Invoke-WtStoreScreenProbe {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:ProbeScript + '" -TargetPath "' + $script:TargetPath + '"'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $process = $null
            try {
                $process = [System.Diagnostics.Process]::Start($psi)
                $process.StandardInput.Close()
                $outTask = $process.StandardOutput.ReadToEndAsync()
                $errTask = $process.StandardError.ReadToEndAsync()
                $exited = $process.WaitForExit(30000)
                if (-not $exited) {
                    try { $process.Kill() } catch { $null = $_ }
                    throw 'probe did not exit within 30s - the screen blocked instead of treating Eof as Back'
                }
                return @{ ExitCode = $process.ExitCode; StdOut = [string]$outTask.Result; StdErr = [string]$errTask.Result }
            }
            finally {
                if ($null -ne $process) { $process.Dispose() }
            }
        }
    }

    It 'enters the store screen on the default (Store) tab and returns cleanly instead of throwing' {
        $r = Invoke-WtStoreScreenProbe
        $because = "stdout: $($r.StdOut)`nstderr: $($r.StdErr)"
        $r.ExitCode | Should -Be 0 -Because $because
        $r.StdOut | Should -Match 'PROBE-OK' -Because $because
        $r.StdOut | Should -Not -Match 'PROBE-EXCEPTION' -Because $because
        $r.StdOut | Should -Not -Match 'Cannot bind argument' -Because $because
        $r.StdErr | Should -BeNullOrEmpty -Because $because
    }
}

Describe 'Invoke-WtWingetStoreRun (State.LastSummary)' {
    It 'keeps the closing summary on the state for a caller that never sees the output screen, and clears the marks' {
        $fake = @(@{ Id = 'X'; Kind = 'Ok'; ExitCode = 0 }, @{ Id = 'Y'; Kind = 'Failed'; ExitCode = 1 })
        Mock Invoke-WtWingetBatch { param($Ids, $Operation, $RunOne) $fake }
        Mock Show-WtPanelMessage { }
        Mock Show-WtOutputScreen { '' }
        Mock Get-WtWingetInstalledPackages { @() }
        Mock Reset-WtFrameCache { }
        $s = @{ Marks = (New-Object 'System.Collections.Generic.List[string]'); Installed = @() }
        $s.Marks.Add('X'); $s.Marks.Add('Y')
        Invoke-WtWingetStoreRun -State $s -Operation 'Install'
        @($s.LastSummary) | Should -Be @(Get-WtWingetSummaryLines -Results $fake -Operation 'Install')
        @($s.LastSummary).Count | Should -BeGreaterThan 2
        $s.Marks.Count | Should -Be 0
    }
}
