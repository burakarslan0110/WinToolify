# Language screen and first-run language choice.
# Covered by: tests/Screens.Tests.ps1

function Get-WtLanguageScreenItems {
    <#
    .SYNOPSIS
        PURE: the two language radios with the active one preselected.
    #>
    $items = @(
        New-WtListItem -Kind 'Radio' -Name 'EN' -Label 'English' -Data @{ Language = 'EN' }
        New-WtListItem -Kind 'Radio' -Name 'TR' -Label 'Turkce' -Data @{ Language = 'TR' }
    )
    $selection = New-Object 'System.Collections.Generic.HashSet[string]'
    if (@('EN', 'TR') -contains $script:Language) { $selection.Add([string]$script:Language) | Out-Null }
    return @{ Items = $items; Selection = $selection }
}

function Set-WtLanguageChoice {
    <#
    .SYNOPSIS
        Switches the UI language for this session and persists it to
        settings.json so the next start skips the first-run screen.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('EN', 'TR')][string]$Language,
        [string]$TestRootOverride
    )
    $script:Language = $Language
    $saveArgs = @{ Settings = ([PSCustomObject]@{ Language = $Language }) }
    if ($TestRootOverride) { $saveArgs['TestRootOverride'] = $TestRootOverride }
    Save-WtSettings @saveArgs
}

function Invoke-WtLanguageScreen {
    <#
    .SYNOPSIS
        Radio pick sets and saves the language (Space or Enter). Also the
        first-run screen when settings hold no language yet.
    #>
    param([switch]$FirstRun)
    $built = Get-WtLanguageScreenItems
    $crumb = if ($FirstRun) { Get-Translation 'Language' } else { Get-WtBreadcrumb -Keys 'MainMenu', 'Language' }
    $applyChoice = {
        $chosen = @($built.Selection) | Select-Object -First 1
        if ($chosen) { Set-WtLanguageChoice -Language $chosen }
    }
    $r = $null
    while ($true) {
        $r = Invoke-WtListScreen -Breadcrumb $crumb -Items $built.Items -MultiSelect $false -Selection $built.Selection `
            -FooterText (Get-Translation 'NavFooter') -OnSelectionChanged $applyChoice -Layout 'Compact'
        if ($r.Emit -ne 'Global') { break }
    }
    if ($r.Emit -eq 'Quit' -and -not $FirstRun) { return @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
    if ($r.Emit -eq 'Activate' -and $r.Item -and $r.Item.Kind -eq 'Radio') {
        $built.Selection.Clear()
        $built.Selection.Add($r.Item.Name) | Out-Null
        & $applyChoice
    }
    elseif ($FirstRun -and $built.Selection.Count -eq 0) {
        Set-WtLanguageChoice -Language $script:Language
    }
    return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
}

function Invoke-WtFirstRunLanguage {
    $null = Invoke-WtLanguageScreen -FirstRun
}

# --- Basic Tools > Actions -------------------------------------------------------
