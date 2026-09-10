# AI privacy state and apply.
# Covered by: tests/AiAndPermissionCatalogs.Tests.ps1

function Get-WtAiPrivacyState {
    <#
    .SYNOPSIS
        Live state of one AI privacy catalog entry - delegates to the
        shared Get-WtRegistryEntryState.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,

        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    return Get-WtRegistryEntryState -Entry $Entry -GetPropertyAction $GetPropertyAction
}

function Invoke-WtApplyAiPrivacySelection {
    <#
    .SYNOPSIS
        Wires the AI & Copilot selector to Invoke-WtGuardedChange via the
        shared Invoke-WtApplyRegistryEntrySelection, with a fixed
        ActionName so undo entries keep a stable label.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames
    )

    return Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtAiPrivacyCatalog) -SelectedNames $SelectedNames -ActionName 'Apply AI Privacy Settings'
}
