# New-WtListItem and group spacers.
# Covered by: tests/Screens.Tests.ps1, tests/MenuTree.Tests.ps1

function New-WtListItem {
    <#
    .SYNOPSIS
        The one constructor for list rows, so every screen builder emits
        the shape Get-WtListRowSegments / Update-WtListState expect. Desc
        drives the description band under the cursor's row (empty shows
        nothing); RiskTag prints the "[CAUTION]"-style tag while Risk
        still drives the row's colour even when the tag is off.
        CycleTargets turns Space from a two-state toggle into a walk
        through those targets and back to unmarked. Header, Info and
        Spacer rows are never focusable; Applied means the live state
        already matches the target, Removable means it may also be
        marked back to the Windows default.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Link', 'Action', 'Check', 'Radio', 'Header', 'Info', 'Spacer', 'Rule')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Risk = $null,
        [string]$StateLabel = '',
        [string]$PendingVerbKey = '',
        [string]$Desc = '',
        [bool]$Selectable = $true,
        [object]$Data = $null,
        [string]$Group = '',
        [bool]$Applied = $false,
        [bool]$Removable = $false,
        [bool]$RiskTag = $true,
        [AllowEmptyCollection()][string[]]$CycleTargets = @()
    )
    if (@('Header', 'Info', 'Spacer', 'Rule') -contains $Kind) { $Selectable = $false }
    return [PSCustomObject]@{
        Kind       = $Kind
        Name       = $Name
        Label      = $Label
        Risk       = $Risk
        StateLabel = $StateLabel
        PendingVerbKey = $PendingVerbKey
        Desc       = $Desc
        Selectable = $Selectable
        Data       = $Data
        Group      = $Group
        Applied      = $Applied
        Removable    = $Removable
        RiskTag      = $RiskTag
        CycleTargets = [string[]]@($CycleTargets)
    }
}

function Add-WtListGroupSpacers {
    <#
    .SYNOPSIS
        PURE: returns the list with one blank Spacer row in front of
        every Header that is not already the first row of the list, so
        long screens breathe between their groups instead of running
        together. Adjacent headers (a group header immediately followed
        by its first sub-header) get no spacer between them - the pair
        reads as one heading.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items
    )
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        if ($item.Kind -eq 'Header' -and $i -gt 0 -and $Items[$i - 1].Kind -ne 'Header') {
            $n++
            $out.Add((New-WtListItem -Kind 'Spacer' -Name ('Spacer:' + $n) -Label ''))
        }
        $out.Add($item)
    }
    return $out.ToArray()
}
