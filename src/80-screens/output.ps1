# Output tail, native encoding, output screen, captured actions, savable reports.
# Covered by: tests/Screens.Tests.ps1

function Get-WtOutputTail {
    <#
    .SYNOPSIS
        PURE: the last Count lines, for the live progress panel. A
        running command's newest output is the interesting end, and
        Show-WtPanelMessage paints from the top with no scrolling, so
        the caller hands it a tail that fits instead of the whole log.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][int]$Count
    )
    $all = @($Lines)
    $take = [Math]::Max(1, $Count)
    if ($all.Count -le $take) { return $all }
    return @($all[($all.Count - $take)..($all.Count - 1)])
}

function Get-WtNativeOutputEncoding {
    <#
    .SYNOPSIS
        The encoding a captured native command's stdout must be decoded
        with: the console's REAL OEM code page, not what chcp reports.
        Nothing decoded anything while output went straight to the
        console, so this never mattered before; captured, a Turkish
        machine's ipconfig writes cp857 and decoding it as UTF-8 turns
        "Yerel Ag Baglantisi" into mojibake. Legacy console tools
        (ipconfig, systeminfo, chkdsk, netstat, sfc) write OEM bytes even
        when the console itself is on UTF-8; tools that really emit
        UTF-8 (winget and friends) get an explicit -Encoding from their
        caller instead of being guessed at here.
    #>
    param(
        [int]$OemCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    )
    try { return [System.Text.Encoding]::GetEncoding($OemCodePage) }
    catch { $null = $_ }
    return [Console]::OutputEncoding
}

function Show-WtOutputScreen {
    <#
    .SYNOPSIS
        A command's output inside the box: scrollable, read-only, and
        never a bare console page. Nothing in the list is focusable, so
        Update-WtListState's cursorless branch scrolls the window with
        the arrows / PgUp / PgDn / Home / End, and Enter or Esc closes.
        Wide rows are cut with '~' rather than wrapped, so table output
        keeps its columns. -Hotkeys are extra letters the screen hands
        back instead of closing; anything else closes and returns ''.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$FooterText = '',
        [AllowEmptyCollection()][string[]]$Hotkeys = @()
    )
    $text = @($Lines)
    if ($text.Count -eq 0) { $text = @((Get-Translation 'OutputEmpty')) }
    if (-not $FooterText) { $FooterText = Get-Translation 'OutputFooter' }
    $script:WtPanelBreadcrumb = $Breadcrumb
    $items = @(Get-WtPanelItems -Lines $text)
    $pressed = ''
    while ($true) {
        $r = Invoke-WtListScreen -Breadcrumb $Breadcrumb -Items $items -FooterText $FooterText
        if ($r.Emit -eq 'Global') {
            $char = [string]$r.Char
            if (@($Hotkeys) -contains $char) { $pressed = $char; break }
            continue
        }
        break
    }
    Reset-WtFrameCache
    return $pressed
}

function Invoke-WtCapturedAction {
    <#
    .SYNOPSIS
        Runs an action with every output stream captured and rendered
        INSIDE the box, repainting at most every RefreshMs so a long
        sfc /scannow still visibly progresses; the same output then opens
        in a scrollable Show-WtOutputScreen when the command finishes.
        *>&1 merges every stream into one pipeline, so the action must
        NOT call Read-Host - ask for input in the panel before calling
        this. There is no cancel key while the command runs, matching
        the old console mode: reading the keyboard mid-pipeline would
        need a second runspace, and killing a half-finished sfc/DISM is
        worse than letting it end. Around each repaint, the console's
        encoding is swapped back to the UI encoding and then back to the
        native one, so a box-drawing glyph is never painted under a
        foreign code page.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Title = '',
        [string]$Breadcrumb = '',
        [scriptblock]$ShowProgress = {
            param($Lines, $Footer)
            $size = Get-WtConsoleSize
            $view = [Math]::Max(1, $size.Height - (Get-WtFrameChromeHeight -Width $size.Width))
            Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines (Get-WtOutputTail -Lines $Lines -Count $view) -FooterText $Footer | Out-Null
        },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines },
        [int]$RefreshMs = 120,
        [AllowNull()][System.Text.Encoding]$Encoding = $null,
        [bool]$UseNativeEncoding = $true
    )
    $script:WtPanelBreadcrumb = $(if ($Breadcrumb) { $Breadcrumb } elseif ($Title) { $Title } else { '' })
    $lines = New-Object System.Collections.Generic.List[string]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPaint = [long]-1000
    $footer = { (Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds ([int]$watch.Elapsed.TotalSeconds)) }
    & $ShowProgress @() (& $footer)

    $uiEncoding = $null
    $nativeEncoding = $null
    if ($UseNativeEncoding) {
        try {
            $uiEncoding = [Console]::OutputEncoding
            $nativeEncoding = if ($Encoding) { $Encoding } else { Get-WtNativeOutputEncoding }
            if ($nativeEncoding.CodePage -ne $uiEncoding.CodePage) { [Console]::OutputEncoding = $nativeEncoding }
            else { $uiEncoding = $null }
        }
        catch { $uiEncoding = $null }
    }
    $paint = {
        param($Rows, $Foot)
        if ($uiEncoding) { try { [Console]::OutputEncoding = $uiEncoding } catch { $null = $_ } }
        & $ShowProgress $Rows $Foot
        if ($uiEncoding) { try { [Console]::OutputEncoding = $nativeEncoding } catch { $null = $_ } }
    }
    try {
        & $Action *>&1 | ForEach-Object {
            foreach ($line in (ConvertTo-WtOutputLines -InputObject $_)) { $lines.Add([string]$line) }
            if (($watch.ElapsedMilliseconds - $lastPaint) -ge $RefreshMs) {
                $lastPaint = $watch.ElapsedMilliseconds
                & $paint $lines.ToArray() (& $footer)
            }
        }
    }
    catch { $lines.Add([string]$_.Exception.Message) }
    finally {
        if ($uiEncoding) { try { [Console]::OutputEncoding = $uiEncoding } catch { $null = $_ } }
    }
    $watch.Stop()
    $null = Clear-WtPendingInput
    & $ShowResult $lines.ToArray()
}

function Invoke-WtStreamedProcess {
    <#
    .SYNOPSIS
        Runs one native tool as a child process, draining both pipes
        asynchronously into $State and calling OnTick on a TIMER, then
        returns its exit code. Repaint must be timer- not output-driven:
        sfc goes silent for minutes mid-phase, which would otherwise
        read as a hang. stderr is drained in the SAME loop, never after,
        or a tool that fills its error pipe blocks forever waiting for a
        reader. Decoding rides StandardOutputEncoding on the child, not
        [Console]::OutputEncoding; -Encoding $null means the OEM page
        (sfc needs UTF-16, winget UTF-8). Each tick reasserts the Ctrl+C
        guard and window lock, since the child shares this console and
        can turn Ctrl+C back into a break signal for everyone on it.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][scriptblock]$OnTick,
        [AllowNull()][System.Text.Encoding]$Encoding = $null,
        [int]$RefreshMs = 120,
        [scriptblock]$StartProcess = { param($StartInfo) [System.Diagnostics.Process]::Start($StartInfo) }
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = $(if ($Encoding) { $Encoding } else { Get-WtNativeOutputEncoding })
    $startInfo.StandardErrorEncoding = $startInfo.StandardOutputEncoding

    $process = $null
    try { $process = & $StartProcess $startInfo }
    catch {
        $State.Lines.Add([string]$_.Exception.Message)
        return -1
    }
    if ($null -eq $process) { return -1 }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $outBuffer = New-Object char[] 4096
    $errBuffer = New-Object char[] 4096
    $outRead = $process.StandardOutput.ReadAsync($outBuffer, 0, $outBuffer.Length)
    $errRead = $process.StandardError.ReadAsync($errBuffer, 0, $errBuffer.Length)
    $lastPaint = [long]-1000
    while ($outRead -or $errRead) {
        $moved = $false
        if ($outRead -and $outRead.IsCompleted) {
            $count = [int]$outRead.Result
            if ($count -le 0) { $outRead = $null }
            else {
                Add-WtNativeOutputChunk -State $State -Chunk ([string]::new($outBuffer, 0, $count))
                $outRead = $process.StandardOutput.ReadAsync($outBuffer, 0, $outBuffer.Length)
            }
            $moved = $true
        }
        if ($errRead -and $errRead.IsCompleted) {
            $count = [int]$errRead.Result
            if ($count -le 0) { $errRead = $null }
            else {
                Add-WtNativeOutputChunk -State $State -Chunk ([string]::new($errBuffer, 0, $count))
                $errRead = $process.StandardError.ReadAsync($errBuffer, 0, $errBuffer.Length)
            }
            $moved = $true
        }
        if (-not $moved) { Start-Sleep -Milliseconds 25 }
        if (($watch.ElapsedMilliseconds - $lastPaint) -ge $RefreshMs) {
            $lastPaint = $watch.ElapsedMilliseconds
            $null = Assert-WtTuiCtrlCInput
            $null = Assert-WtWindowMaximized
            & $OnTick
        }
    }
    $process.WaitForExit()
    $exit = [int]$process.ExitCode
    $process.Dispose()
    $watch.Stop()
    return $exit
}

function Invoke-WtCapturedNativeAction {
    <#
    .SYNOPSIS
        The captured-output panel for a long native tool (sfc, DISM):
        runs Invoke-WtStreamedProcess (shared with the winget batch
        runner) so the panel repaints on a TIMER instead of only when a
        line happens to arrive, and ends in the same scrollable
        Show-WtOutputScreen every other captured action ends in. Like
        Invoke-WtCapturedAction there is no cancel key - killing a
        half-finished sfc or DISM is worse than letting it end.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [string]$Title = '',
        [string]$Breadcrumb = '',
        [AllowNull()][System.Text.Encoding]$Encoding = $null,
        [scriptblock]$ShowProgress = {
            param($Lines, $Footer)
            $size = Get-WtConsoleSize
            $view = [Math]::Max(1, $size.Height - (Get-WtFrameChromeHeight -Width $size.Width))
            Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines (Get-WtOutputTail -Lines $Lines -Count $view) -FooterText $Footer | Out-Null
        },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines },
        [int]$RefreshMs = 120,
        [scriptblock]$StartProcess = { param($StartInfo) [System.Diagnostics.Process]::Start($StartInfo) }
    )
    $script:WtPanelBreadcrumb = $(if ($Breadcrumb) { $Breadcrumb } elseif ($Title) { $Title } else { '' })
    $state = New-WtNativeOutputState
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $footer = { (Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds ([int]$watch.Elapsed.TotalSeconds)) }
    $paint = {
        $view = @($state.Lines.ToArray())
        if ([string]$state.Current -ne '') { $view += [string]$state.Current }
        & $ShowProgress $view (& $footer)
    }
    & $paint

    $null = Invoke-WtStreamedProcess -FilePath $FilePath -Arguments $Arguments -State $state `
        -OnTick $paint -Encoding $Encoding -RefreshMs $RefreshMs -StartProcess $StartProcess

    if ([string]$state.Current -ne '') { $state.Lines.Add([string]$state.Current) }
    $watch.Stop()
    $null = Clear-WtPendingInput
    & $ShowResult $state.Lines.ToArray()
}


function Show-WtSavableReport {
    <#
    .SYNOPSIS
        A report in the scrollable box, with "S" on the footer to write
        it to a file. The save confirmation is appended to the same
        report and the screen reopens, so the user sees where it went
        without losing the report.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory)][string]$ReportName,
        [scriptblock]$SaveAction = { param($Name, $Rows) Save-WtReport -Name $Name -Lines $Rows },
        [scriptblock]$ShowResult = { param($Crumb, $Rows, $Footer) Show-WtOutputScreen -Breadcrumb $Crumb -Lines $Rows -FooterText $Footer -Hotkeys @('s') }
    )
    $rows = @($Lines)
    $footer = (Get-Translation 'OutputFooter') + ' - ' + (Get-Translation 'OutputSaveHint')
    while ($true) {
        $key = [string](& $ShowResult $Breadcrumb $rows $footer)
        if ($key -ne 's') { break }
        $saved = & $SaveAction $ReportName $rows
        $rows = @($rows) + @('', ('{0}: {1}' -f (Get-Translation 'ReportSaved'), $saved))
        $footer = Get-Translation 'OutputFooter'
    }
}
