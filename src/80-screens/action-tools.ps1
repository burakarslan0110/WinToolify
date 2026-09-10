# Action tools screen. The group table lives in 40-catalogs/tool-rows.ps1.
# Covered by: tests/ToolScreenStructure.Tests.ps1

function Get-WtActionToolsItems {
    <#
    .SYNOPSIS
        Basic Tools > Actions: the group list, flattened into Header rows
        plus their rows with blank lines between groups.
    #>
    return Get-WtToolScreenItems -Groups (Get-WtActionToolGroups)
}

function Invoke-WtActionToolsScreen {
    return Invoke-WtNavScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools') -Items (Get-WtActionToolsItems) -Searchable $true
}

# --- screens still to come (placeholder) -----------------------------------
