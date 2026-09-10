# Main menu and basic tools items, Invoke-WtNavScreen, placeholder/main/basic screens, breadcrumbs.
# Covered by: tests/MenuTree.Tests.ps1, tests/Screens.Tests.ps1

function Get-WtMainMenuItems {
    <#
    .SYNOPSIS
        The main menu rows, in order, under their titled rules, with the
        assistant's own block near the end and Exit last. A Rule, Info or
        Spacer row never takes a number or the cursor. Every row that does
        carries a Desc, shown in the description band between the rows
        and the navigation guide. Pure - labels resolve through the
        active language.
    #>
    $rows = @(
        New-WtListItem -Kind 'Rule' -Name 'MainToolsRule' -Label (Get-Translation 'MainToolsRule')
        New-WtListItem -Kind 'Link' -Name 'BasicTools' -Label (Get-Translation 'BasicTools') -Desc (Get-Translation 'MainDescBasicTools') -Data @{ Screen = 'BasicTools' }
        New-WtListItem -Kind 'Link' -Name 'Services' -Label (Get-Translation 'ServicesManagement') -Desc (Get-Translation 'MainDescServices') -Data @{ Screen = 'Services' }
        New-WtListItem -Kind 'Link' -Name 'SystemSettings' -Label (Get-Translation 'SystemSettings') -Desc (Get-Translation 'MainDescSystemSettings') -Data @{ Screen = 'SystemSettings' }
        New-WtListItem -Kind 'Link' -Name 'Privacy' -Label (Get-Translation 'PrivacySettings') -Desc (Get-Translation 'MainDescPrivacy') -Data @{ Screen = 'Privacy' }
        New-WtListItem -Kind 'Link' -Name 'Packages' -Label (Get-Translation 'AppsMenu') -Desc (Get-Translation 'MainDescPackages') -Data @{ Screen = 'Packages' }
        New-WtListItem -Kind 'Link' -Name 'WingetStore' -Label (Get-Translation 'WingetStore') -Desc (Get-Translation 'MainDescWingetStore') -Data @{ Screen = 'WingetStore' }
        New-WtListItem -Kind 'Link' -Name 'Language' -Label (Get-Translation 'Language') -Desc (Get-Translation 'MainDescLanguage') -Data @{ Screen = 'Language' }
        New-WtListItem -Kind 'Action' -Name 'CreateRestorePoint' -Label (Get-Translation 'CreateRestorePoint') -Desc (Get-Translation 'MainDescCreateRestorePoint') -Data @{ Action = { Invoke-WtCreateRestorePointAction } }
        New-WtListItem -Kind 'Link' -Name 'Undo' -Label (Get-Translation 'UndoLastChange') -Desc (Get-Translation 'MainDescUndo') -Data @{ Screen = 'Undo' }
        New-WtListItem -Kind 'Link' -Name 'Profiles' -Label (Get-Translation 'ConfigProfiles') -Desc (Get-Translation 'MainDescProfiles') -Data @{ Screen = 'Profiles' }
    )
    return @($rows) + @(
        New-WtListItem -Kind 'Spacer' -Name 'MainAssistantSpacer' -Label ''
        New-WtListItem -Kind 'Rule' -Name 'MainAssistantRule' -Label (Get-Translation 'Assistant')
        New-WtListItem -Kind 'Link' -Name 'Assistant' -Label (Get-Translation 'MainAssistantRow') -Desc (Get-Translation 'MainDescAssistant') -Data @{ Screen = 'Assistant' }
        New-WtListItem -Kind 'Spacer' -Name 'MainExitSpacer' -Label ''
        New-WtListItem -Kind 'Action' -Name 'Exit' -Label (Get-Translation 'Exit') -Desc (Get-Translation 'MainDescExit') -Data @{ Exit = $true }
    )
}

function Get-WtBasicToolsItems {
    <#
    .SYNOPSIS
        Basic Tools: the pair of sub-menus, Action Tools and Information
        Tools. Pure.
    #>
    return @(
        New-WtListItem -Kind 'Link' -Name 'ActionTools' -Label (Get-Translation 'ActionTools') -Data @{ Screen = 'ActionTools' }
        New-WtListItem -Kind 'Link' -Name 'InfoTools' -Label (Get-Translation 'InformationTools') -Data @{ Screen = 'InfoTools' }
    )
}

function Invoke-WtNavScreen {
    <#
    .SYNOPSIS
        A navigation screen: Link rows push a child screen, Action rows
        run inline and keep the screen open, Exit rows / Q ask to leave.
        Returns @{ Nav = 'Push'|'Back'|'Exit'; Target; Char; HasMarks } for
        Invoke-WtMainLoop. Stray pipeline output from an inline action is
        piped to Out-Null so it cannot leak into the nav verdict, and
        pending input is cleared after a row runs so queued keystrokes
        cannot re-activate it.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [string]$FooterText = '',
        [bool]$ShowBanner = $false,
        [bool]$RememberCursor = $false,
        [bool]$RootMenu = $false,
        [bool]$Searchable = $false,
        [int]$DescriptionRows = 0
    )
    if (-not $FooterText) { $FooterText = Get-Translation 'NavFooter' }
    $cursor = if ($RememberCursor) { Get-WtMainMenuCursor -Items $Items } else { -1 }
    $footerOnce = ''
    while ($true) {
        $footer = $(if ($footerOnce) { $footerOnce } else { $FooterText })
        $footerOnce = ''
        $r = Invoke-WtListScreen -Breadcrumb $Breadcrumb -Items $Items -MultiSelect $false -FooterText $footer -ShowBanner $ShowBanner -InitialCursor $cursor -Layout 'Compact' -Searchable $Searchable -DescriptionRows $DescriptionRows
        $cursor = [int]$r.CursorIndex
        if ($RememberCursor) { Set-WtMainMenuCursor -Items $Items -Index $cursor }
        if ($r.Emit -eq 'Back') {
            if ($RootMenu -and -not $script:WtInputExhausted) { $footerOnce = [string](Get-Translation 'MainEscHint'); continue }
            return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
        }
        if ($r.Emit -eq 'Quit') { return @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
        if ($r.Emit -eq 'Activate' -and $r.Item -and $r.Item.Data) {
            $data = $r.Item.Data
            if ($data.Exit) { return @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
            if ($data.Screen) { return @{ Nav = 'Push'; Target = [string]$data.Screen; Char = ''; HasMarks = $false } }
            if ($data.Native) {
                Invoke-WtCapturedNativeAction -FilePath ([string]$data.FilePath) -Arguments ([string]$data.Arguments) `
                    -Title ([string]$data.Title) -Breadcrumb $Breadcrumb -Encoding $data.Encoding
                Reset-WtFrameCache
            }
            elseif ($data.Action) {
                if ($data.Captured) { Invoke-WtCapturedAction -Title ([string]$data.Title) -Breadcrumb $Breadcrumb -Action $data.Action -Encoding $data.Encoding }
                elseif ($data.Power) { Invoke-WtPowerAction -ConsequenceKey ([string]$data.ConsequenceKey) -Breadcrumb $Breadcrumb -Action $data.Action }
                else { $script:WtPanelBreadcrumb = $Breadcrumb; & $data.Action | Out-Null }
                Reset-WtFrameCache
            }
            if ($data.Native -or $data.Action) { $null = Clear-WtPendingInput }
        }
    }
}


function Invoke-WtPlaceholderScreen {
    <#
    .SYNOPSIS
        Keeps the navigation loop runnable while category screens are
        still being built: shows which screen was requested and returns
        to the parent.
    #>
    param([Parameter(Mandatory)][string]$Key)
    $script:WtPanelBreadcrumb = $Key
    Wait-WtEnter -Lines @((Get-Translation 'ScreenNotReady'))
    return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
}

function Invoke-WtMainScreen {
    return Invoke-WtNavScreen -Breadcrumb (Get-Translation 'MainMenu') -Items (Get-WtMainMenuItems) -FooterText (Get-Translation 'MainFooter') -ShowBanner $true -RememberCursor $true -RootMenu $true -DescriptionRows 2
}

function Invoke-WtBasicToolsScreen {
    return Invoke-WtNavScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools') -Items (Get-WtBasicToolsItems)
}

function Get-WtBreadcrumb {
    <#
    .SYNOPSIS
        "Main Menu > Category > Screen" from translation keys, with an
        optional literal suffix (e.g. a capability's display label).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Keys,
        [string]$Suffix = ''
    )
    $parts = @($Keys | ForEach-Object { [string](Get-Translation $_) })
    if ($Suffix) { $parts += $Suffix }
    return ($parts -join ' > ')
}
