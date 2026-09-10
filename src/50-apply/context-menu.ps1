# Invoke-WtApplyContextMenuSelection.
# Covered by: tests/ContextMenuCatalog.Tests.ps1

function Invoke-WtApplyContextMenuSelection {
    <#
    .SYNOPSIS
        Wires the Context Menu selector to Invoke-WtGuardedChange via the
        shared Invoke-WtApplyShellEntrySelection. Exercised by TS-001 /
        TS-002 on Windows.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames,

        [array]$Catalog = (Get-WtContextMenuCatalog)
    )

    return Invoke-WtApplyShellEntrySelection -Catalog $Catalog -SelectedNames $SelectedNames -ActionName 'Apply Context Menu Entries'
}
