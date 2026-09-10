# Legacy page selector (Show-WtSelector).
# Covered by: tests/Selector.Tests.ps1

function Get-WtSelectorPage {
    <#
    .SYNOPSIS
        Catalog-agnostic paging: slices $Items into pages of $PageSize and
        returns the requested page, clamped into range. No empty trailing
        page when Count is an exact multiple of PageSize (uses ceiling, not
        floor+1), and no out-of-range index on a partial last page.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Items,

        [Parameter(Mandatory)]
        [int]$PageIndex,

        [int]$PageSize = 10
    )

    if ($Items.Count -eq 0) {
        return [PSCustomObject]@{ Items = @(); PageIndex = 0; TotalPages = 1; StartIndex = 0; EndIndex = 0 }
    }

    $totalPages = [Math]::Max(1, [int][Math]::Ceiling($Items.Count / [double]$PageSize))
    $clampedIndex = [Math]::Max(0, [Math]::Min($PageIndex, $totalPages - 1))
    $start = $clampedIndex * $PageSize
    $end = [Math]::Min($start + $PageSize, $Items.Count)

    return [PSCustomObject]@{
        Items      = @($Items[$start..($end - 1)])
        PageIndex  = $clampedIndex
        TotalPages = $totalPages
        StartIndex = $start
        EndIndex   = $end
    }
}

function Set-WtSelectionToggle {
    <#
    .SYNOPSIS
        Toggles $Item.Name in/out of $SelectionSet, keyed by name (not
        page-relative index) so a selection survives paging away and back.
        Refuses to add an item whose .Selectable is $false (already in the
        target state - e.g. an absent service or a removed package).
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$SelectionSet,

        [Parameter(Mandatory)]
        [PSCustomObject]$Item
    )

    if ($SelectionSet.Contains($Item.Name)) {
        $SelectionSet.Remove($Item.Name) | Out-Null
    }
    elseif ($Item.Selectable) {
        $SelectionSet.Add($Item.Name) | Out-Null
    }

    return $SelectionSet
}

function Test-WtSelectionNeedsAdvancedConfirm {
    <#
    .SYNOPSIS
        True when the selected names include at least one catalog entry
        tagged ADVANCED.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SelectionSet
    )

    $selectedNames = @($SelectionSet)
    if ($selectedNames.Count -eq 0) {
        return $false
    }

    $advancedSelected = $Catalog | Where-Object { $selectedNames -contains $_.Name -and $_.Risk -eq 'ADVANCED' }
    return @($advancedSelected).Count -gt 0
}

function Get-WtSelectorDisplayLabel {
    <#
    .SYNOPSIS
        What Show-WtSelector should render for one catalog entry: its own
        DisplayLabel when the catalog supplies a non-empty one, falling
        back to Name otherwise. The existing Services/Packages catalogs
        supply no DisplayLabel and render exactly as before this function
        existed - purely additive.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry
    )

    if ($Entry.PSObject.Properties.Name -contains 'DisplayLabel' -and $Entry.DisplayLabel) {
        return $Entry.DisplayLabel
    }
    return $Entry.Name
}

function Show-WtSelector {
    <#
    .SYNOPSIS
        Interactive multi-select over a catalog on the arrow-key TUI
        engine: Up/Down move, Space toggles, digits jump-toggle the
        visible row, A/C select/clear all on the viewport, Enter
        confirms, Left/Esc/q cancels. An ADVANCED item in the selection
        requires typing CONFIRM; anything else drops the ADVANCED items
        and keeps the rest. Returns the confirmed names, empty if the
        user quit. -PageSize is unused - kept only for signature
        stability; the TUI engine paginates by viewport height instead.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [Parameter(Mandatory)]
        [array]$StateItems,

        [string]$Title = 'Select items',

        [int]$PageSize = 10,

        [string]$UnselectableNote = (Get-Translation 'AlreadyInTargetState'),

        [string[]]$InfoLines = @()
    )

    $stateByName = @{}
    foreach ($state in $StateItems) { $stateByName[$state.Name] = $state }

    $infoItems = @($InfoLines | Where-Object { $_ } | ForEach-Object { [PSCustomObject]@{ Kind = 'Info'; Name = ('Info:' + $_); Label = $_; Risk = $null; StateLabel = ''; Selectable = $false; Data = $null } })
    $selectorItems = foreach ($entry in $Catalog) {
        $state = $stateByName[$entry.Name]
        $selectable = if ($state) { [bool]$state.Selectable } else { $true }
        $stateLabel = if ($state) { [string]$state.StateLabel } else { Get-Translation 'StateUnknown' }
        if (-not $selectable) { $stateLabel = $stateLabel + $UnselectableNote }
        [PSCustomObject]@{
            Kind = 'Check'; Name = $entry.Name
            Label = (Get-WtSelectorDisplayLabel -Entry $entry)
            Risk = $entry.Risk; StateLabel = $stateLabel
            Selectable = $selectable; Data = $entry
        }
    }

    $selection = New-Object 'System.Collections.Generic.HashSet[string]'
    while ($true) {
        $r = Invoke-WtListScreen -Breadcrumb $Title -Items @($infoItems + @($selectorItems)) -MultiSelect $true `
            -Selection $selection -FooterText (Get-Translation 'SelectorFooter') -CounterText ((Get-Translation 'SettingsCount') -f $Catalog.Count)
        if ($r.Emit -eq 'Back' -or $r.Emit -eq 'Quit') { return @() }
        if ($r.Emit -eq 'Activate') {
            if (Test-WtSelectionNeedsAdvancedConfirm -Catalog $Catalog -SelectionSet @($selection)) {
                $advancedEntries = $Catalog | Where-Object { $selection.Contains($_.Name) -and $_.Risk -eq 'ADVANCED' }
                $advancedTag = Get-WtRiskLabel -Risk 'ADVANCED'
                $lines = @(((Get-Translation 'SelectorAdvancedHeader') -f $advancedTag)) + @($advancedEntries | ForEach-Object { "  - $($_.Name): $($_.Consequence)" })
                $typed = Read-WtPanelAnswer -Breadcrumb $Title -Lines $lines -Prompt ((Get-Translation 'SelectorAdvancedPrompt') -f $advancedTag, (Get-WtTypedWord -Kind 'Confirm')) -Risk 'ADVANCED'
                if (-not (Test-WtTypedConfirmation -Answer $typed -Kind 'Confirm')) {
                    foreach ($advancedEntry in $advancedEntries) { $selection.Remove($advancedEntry.Name) | Out-Null }
                }
            }
            return @($selection)
        }
    }
}
