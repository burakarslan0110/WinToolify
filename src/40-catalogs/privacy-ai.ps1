# AI privacy catalog.
# Covered by: tests/AiAndPermissionCatalogs.Tests.ps1

function Get-WtAiPrivacyCatalog {
    <#
    .SYNOPSIS
        The individually-selectable AI & Copilot catalog: Copilot, Recall,
        and Click to Do, each writing one or more registry values.
        All three are SAFE - disabling any of them has no
        functional downside for the vast majority of users. ShowCopilotButton
        uses OffAction Delete rather than Set 1, because the key does not
        exist by default).
    #>
    return Resolve-WtCatalogText -KeyPrefix 'AiPrivacy' -Catalog @(
        [PSCustomObject]@{
            Name            = 'DisableCopilot'
            LabelKey        = 'CatAiPrivacyDisableCopilotLabel'
            Risk            = 'SAFE'
            Consequence     = $null
            RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; RegType = 'DWord'; Value = 0; OffAction = 'Delete' }
            )
        }
        [PSCustomObject]@{
            Name            = 'DisableRecall'
            LabelKey        = 'CatAiPrivacyDisableRecallLabel'
            Risk            = 'SAFE'
            Consequence     = $null
            RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; RegType = 'DWord'; Value = 0; OffAction = 'Delete' }
            )
        }
        [PSCustomObject]@{
            Name            = 'DisableClickToDo'
            LabelKey        = 'CatAiPrivacyDisableClickToDoLabel'
            Risk            = 'SAFE'
            Consequence     = $null
            RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
            )
        }
    )
}
