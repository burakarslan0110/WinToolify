# Info tools screen. The group table lives in 40-catalogs/tool-rows.ps1.
# Covered by: tests/ToolScreenStructure.Tests.ps1

function Get-WtInfoToolsItems {
    <#
    .SYNOPSIS
        Basic Tools > Information: the group list, flattened into Header
        rows plus their rows with blank lines between groups.
    #>
    return Get-WtToolScreenItems -Groups (Get-WtInfoToolGroups)
}

function Invoke-WtInfoToolsScreen {
    return Invoke-WtNavScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'InformationTools') -Items (Get-WtInfoToolsItems) -Searchable $true
}
