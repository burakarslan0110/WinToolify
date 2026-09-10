# Tool screen items (header + rows + spacers) and the apply-gate helpers.
# The row constructors and the row tables live in 40-catalogs/tool-rows.ps1.
# Covered by: tests/ToolScreenStructure.Tests.ps1

function Get-WtToolScreenItems {
    <#
    .SYNOPSIS
        PURE: turns a group descriptor list into the rows a tool screen
        shows - one Header row per group, then that group's rows, with a
        blank line between groups. A group whose delegate returns nothing
        is skipped entirely, header included.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Groups
    )
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($group in $Groups) {
        $rows = @(& $group.GetRows)
        if ($rows.Count -eq 0) { continue }
        $items.Add((New-WtListItem -Kind 'Header' -Name ('Header:' + $group.HeaderKey) -Label (Get-Translation $group.HeaderKey)))
        foreach ($row in $rows) { $items.Add($row) }
    }
    return Add-WtListGroupSpacers -Items $items.ToArray()
}

# --- apply-gate helpers ---------------------------------------------------------
