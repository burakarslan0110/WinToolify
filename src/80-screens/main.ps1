# Invoke-WtScreenByKey, Confirm-WtExit, Invoke-WtMainLoop, Get-WtMainScreenFrame, Show-Menu.
# Covered by: tests/Guard.Tests.ps1, tests/Screens.Tests.ps1

function Invoke-WtScreenByKey {
    <#
    .SYNOPSIS
        The screen registry: one switch from a screen key to the function
        that runs it. Every Data.Screen value emitted by any item builder
        must have a case here; an unmapped key falls through to the
        placeholder screen.
    #>
    param([Parameter(Mandatory)][string]$Key)
    switch ($Key) {
        'Main' { return Invoke-WtMainScreen }
        'BasicTools' { return Invoke-WtBasicToolsScreen }
        'ActionTools' { return Invoke-WtActionToolsScreen }
        'InfoTools' { return Invoke-WtInfoToolsScreen }
        'SystemSettings' { return Invoke-WtSystemSettingsScreen }
        'Services' { return Invoke-WtServicesScreen }
        'Privacy' { return Invoke-WtPrivacyMenuScreen }
        'PrivacyTelemetry' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacyTelemetry' }
        'PrivacyAppPermissions' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacyAppPermissions' }
        'PrivacyAi' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacyAi' }
        'PrivacySearchUi' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacySearchUi' }
        'PrivacyEdge' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacyEdge' }
        'PrivacyOffice' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacyOffice' }
        'PrivacyUpdate' { return Invoke-WtPrivacyGroupScreen -Key 'PrivacyUpdate' }
        'PerApp' { return Invoke-WtPerAppScreen }
        'Packages' { return Invoke-WtPackagesScreen }
        'WingetStore' { return Invoke-WtWingetStoreScreen }
        'Assistant' { return Invoke-WtAssistantScreen }
        'Language' { return Invoke-WtLanguageScreen }
        'Undo' { return Invoke-WtUndoScreen }
        'Profiles' { return Invoke-WtProfilesScreen }
        default { return Invoke-WtPlaceholderScreen -Key $Key }
    }
}

function Confirm-WtExit {
    <#
    .SYNOPSIS
        Exit gate: nothing marked -> leave at once. Marks on the current
        screen would be lost -> ask in the panel (Enter leaves, anything
        else stays, exhausted input leaves).
    #>
    param(
        [bool]$HasMarks = $false,
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt) Read-WtPanelAnswer -Breadcrumb (Get-Translation 'Exit') -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' }
    )
    if (-not $HasMarks) { return $true }
    $answer = & $ReadAnswer @((Get-Translation 'MarksWillBeLost')) (Get-Translation 'ExitConfirmPrompt')
    if ($null -eq $answer) { return $true }
    return (([string]$answer).Trim() -eq '')
}

function Show-WtScreenError {
    <#
    .SYNOPSIS
        What the navigation loop does with an exception a screen let
        escape: log it, make sure the REPL no longer owns the console (a
        throw out of Enter-WtReplMode itself never reaches the assistant
        screen's own cleanup, so this is a second safety net), and say
        so in a panel - which screen, the message, where the log is, and
        that the previous screen comes back. Nothing here may throw; the
        panel itself is guarded.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$ErrorRecord,
        [scriptblock]$Log = { param($R, $C) Write-WtErrorLog -ErrorRecord $R -Context $C },
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt) Read-WtPanelAnswer -Breadcrumb (Get-Translation 'MainMenu') -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' -Layout 'Compact' }
    )
    $logPath = ''
    try { $logPath = [string](& $Log $ErrorRecord ('Screen: ' + $Key)) } catch { $logPath = '' }
    try { if ($script:WtReplMode) { Exit-WtReplMode } } catch { $null = $_ }
    Reset-WtFrameCache
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'ErrScreenFailed') -f $Key))
    foreach ($l in @(Get-WtErrorSummaryLines -ErrorRecord $ErrorRecord)) { $lines.Add('  ' + [string]$l) }
    if ($logPath) { $lines.Add(''); $lines.Add(((Get-Translation 'ErrLogSaved') -f $logPath)) }
    $lines.Add('')
    $lines.Add((Get-Translation 'ErrReturning'))
    try { $null = & $ReadAnswer $lines.ToArray() (Get-Translation 'PressEnterContinue') } catch { $null = $_ }
    Reset-WtFrameCache
}

function Show-WtFatalError {
    <#
    .SYNOPSIS
        The entry point's last word when an exception escapes even the
        navigation loop: log it, leave the alternate buffer so the text
        lands where the user can read it, print what happened and where
        the log is, and - on an interactive console - wait for Enter.
        The finally that follows may Stop-Process the spawned console;
        without this wait the window closed with the error still in it.
    #>
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [scriptblock]$Log = { param($R, $C) Write-WtErrorLog -ErrorRecord $R -Context $C },
        [scriptblock]$Write = { param($Text, $Fg) Write-Host -ForegroundColor ([ConsoleColor]$Fg) ([string]$Text) },
        [scriptblock]$WaitEnter = { $null = Read-Host },
        [scriptblock]$IsInteractive = { -not [Console]::IsInputRedirected }
    )
    $logPath = ''
    try { $logPath = [string](& $Log $ErrorRecord 'Main') } catch { $logPath = '' }
    try { if ($script:WtReplMode) { Exit-WtReplMode } } catch { $null = $_ }
    try { Restore-WtTui } catch { $null = $_ }
    try {
        & $Write '' 'Gray'
        & $Write (Get-Translation 'ErrFatal') 'Red'
        foreach ($l in @(Get-WtErrorSummaryLines -ErrorRecord $ErrorRecord)) { & $Write ('  ' + [string]$l) 'Red' }
        if ($logPath) { & $Write ('  ' + ((Get-Translation 'ErrLogSaved') -f $logPath)) 'Gray' }
        $interactive = $false
        try { $interactive = [bool](& $IsInteractive) } catch { $interactive = $false }
        if ($interactive) {
            & $Write (Get-Translation 'ErrPressEnterClose') 'Yellow'
            try { & $WaitEnter } catch { $null = $_ }
        }
    }
    catch { $null = $_ }
}

function Invoke-WtMainLoop {
    <#
    .SYNOPSIS
        The navigation stack machine: Push adds a child, Back pops (or
        stays at the root, so no run of Esc closes the app), Exit asks
        Confirm-WtExit. Returns rather than exiting, so the dot-source
        guard and Guard.Tests' no-exit rule hold. A screen that throws
        is contained here - logged, shown, and popped as if it had said
        Back - rather than reaching the entry point's finally, whose
        Stop-Process would take the window and error text with it. The
        root screen gets one retry; throwing twice ends the loop, the
        only way to leave a menu that cannot paint at all. The verdict
        is read defensively ($result -is [hashtable]) since a bridged
        legacy screen can leak raw Read-Host output into its return value.
    #>
    param(
        [AllowEmptyCollection()][string[]]$InitialScreens = @('Main'),
        [scriptblock]$OnScreenError = { param($Key, $Record) Show-WtScreenError -Key $Key -ErrorRecord $Record }
    )
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($screen in @($InitialScreens)) { if ($screen) { $stack.Add([string]$screen) } }
    if ($stack.Count -eq 0) { $stack.Add('Main') }
    $rootFailures = 0
    while ($stack.Count -gt 0) {
        $key = [string]$stack[$stack.Count - 1]
        $result = $null
        $failed = $false
        try { $result = Invoke-WtScreenByKey -Key $key }
        catch {
            $failed = $true
            try { & $OnScreenError $key $_ } catch { $null = $_ }
        }
        if ($failed) {
            if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1); continue }
            $rootFailures++
            if ($rootFailures -ge 2) { return }
            continue
        }
        $rootFailures = 0
        $hasMarks = [bool](($result -is [hashtable]) -and $result.ContainsKey('HasMarks') -and $result.HasMarks)
        switch ([string]$result.Nav) {
            'Push' { $stack.Add([string]$result.Target) }
            'Back' {
                if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
                elseif ($script:WtInputExhausted) { return }
            }
            'Exit' { if (Confirm-WtExit -HasMarks $hasMarks) { return } }
            default { if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) } else { return } }
        }
    }
}

function Get-WtMainScreenFrame {
    <#
    .SYNOPSIS
        One static frame of the main screen (no input) - what Show-Menu
        prints. Resolves glyphs itself so it also works before
        Initialize-WtTui has run (dot-sourced / tests). The cursor
        starts on the first row that can take it, not row 0, which is
        the title rule and would leave the description band blank.
    #>
    param(
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )
    $glyphs = $script:WtGlyphs
    if ($null -eq $glyphs) { $glyphs = Get-WtGlyphSet -Unicode (Test-WtUnicodeGlyphSupport) }
    $items = Get-WtMainMenuItems
    $state = @{ CursorIndex = (Get-WtValidListCursor -Items $items); WindowStart = 0; Selection = (New-Object 'System.Collections.Generic.HashSet[string]') }
    return Get-WtFrameRows -Breadcrumb (Get-Translation 'MainMenu') -Items $items -State $state -Width $Width -Height $Height `
        -Glyphs $glyphs -FooterText (Get-Translation 'MainFooter') -ShowBanner $true -Layout 'Compact' -DescriptionRows 2
}

function Show-Menu {
    <#
    .SYNOPSIS
        Renders one static frame of the main screen (no input, no loop).
        The name is pinned by Guard.Tests; the interactive loop is
        Invoke-WtMainLoop.
    #>
    $width = 100
    $height = 40
    try {
        $size = $Host.UI.RawUI.WindowSize
        if ($size.Width -gt 0 -and $size.Height -gt 0) { $width = $size.Width; $height = $size.Height }
    }
    catch { $null = $_ }
    Write-WtFrame -FrameLines (Get-WtMainScreenFrame -Width $width -Height $height) -Width $width
}
