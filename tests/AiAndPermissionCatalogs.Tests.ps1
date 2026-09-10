#Requires -Modules Pester

<#
.SYNOPSIS
    Covers the AI privacy catalog (Copilot/Recall/Click to Do) and its
    live-state check, both pure - the state check's Get-WtRegistryValue
    call is injectable, so tests never touch a real registry cmdlet.
    The apply wrappers are not unit-tested directly; they wire
    already-proven pieces (Invoke-WtGuardedChange, Set-WtRegistryValue/
    Get-WtRegistryValue) together with real cmdlet calls that don't
    exist on macOS. Also covers Get-WtSelectorDisplayLabel: its own
    DisplayLabel when the catalog supplies one, falling back to Name
    when it does not.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtAiPrivacyCatalog' {
    BeforeAll {
        $script:AiCatalog = Get-WtAiPrivacyCatalog
    }

    It 'has exactly 3 entries: DisableCopilot, DisableRecall, DisableClickToDo' {
        $names = $AiCatalog | Select-Object -ExpandProperty Name
        @($names | Sort-Object) | Should -Be @('DisableClickToDo', 'DisableCopilot', 'DisableRecall')
    }

    It 'tags every entry SAFE with a null Consequence' {
        foreach ($entry in $AiCatalog) {
            $entry.Risk | Should -Be 'SAFE'
            $entry.Consequence | Should -BeNullOrEmpty
        }
    }

    It 'gives DisableCopilot exactly its 3 registry changes' {
        $entry = $AiCatalog | Where-Object Name -eq 'DisableCopilot'
        $entry.RegistryChanges.Count | Should -Be 3
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -and $_.Name -eq 'TurnOffWindowsCopilot' -and $_.Value -eq 1 }).Count | Should -Be 1
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -and $_.Name -eq 'TurnOffWindowsCopilot' -and $_.Value -eq 1 }).Count | Should -Be 1
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -and $_.Name -eq 'ShowCopilotButton' -and $_.Value -eq 0 }).Count | Should -Be 1
    }

    It 'gives DisableRecall exactly its 2 registry changes' {
        $entry = $AiCatalog | Where-Object Name -eq 'DisableRecall'
        $entry.RegistryChanges.Count | Should -Be 2
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -and $_.Name -eq 'DisableAIDataAnalysis' -and $_.Value -eq 1 }).Count | Should -Be 1
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -and $_.Name -eq 'AllowRecallEnablement' -and $_.Value -eq 0 }).Count | Should -Be 1
    }

    It 'gives DisableClickToDo exactly its 1 registry change' {
        $entry = $AiCatalog | Where-Object Name -eq 'DisableClickToDo'
        $entry.RegistryChanges.Count | Should -Be 1
        $entry.RegistryChanges[0].Path | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
        $entry.RegistryChanges[0].Name | Should -Be 'DisableClickToDo'
        $entry.RegistryChanges[0].Value | Should -Be 1
    }

    It 'RegistryChanges entries all carry RegType DWord - every AI value is a DWORD' {
        foreach ($entry in $AiCatalog) {
            foreach ($change in $entry.RegistryChanges) {
                $change.RegType | Should -Be 'DWord'
            }
        }
    }

    It 'every AI privacy entry carries a LabelKey present in both languages and a resolved DisplayLabel' {
        foreach ($entry in @(Get-WtAiPrivacyCatalog)) {
            $entry.PSObject.Properties.Name | Should -Contain 'LabelKey' -Because $entry.Name
            $script:Translations['EN'][$entry.LabelKey] | Should -Not -BeNullOrEmpty -Because $entry.Name
            $script:Translations['TR'][$entry.LabelKey] | Should -Not -BeNullOrEmpty -Because $entry.Name
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty -Because $entry.Name
        }
    }
}

Describe 'Get-WtAiPrivacyState' {
    It 'reports Applied only when every RegistryChanges value matches' {
        $entry = (Get-WtAiPrivacyCatalog) | Where-Object Name -eq 'DisableClickToDo'
        $action = { param($p, $n) [PSCustomObject]@{ DisableClickToDo = 1 } }
        (Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $action).Applied | Should -BeTrue
    }

    It 'reports NotApplied when only some of a multi-value entry match (partial application)' {
        $entry = (Get-WtAiPrivacyCatalog) | Where-Object Name -eq 'DisableRecall'
        $action = {
            param($p, $n)
            if ($n -eq 'DisableAIDataAnalysis') { [PSCustomObject]@{ DisableAIDataAnalysis = 1 } }
            else { $null }
        }
        (Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $action).Applied | Should -BeFalse
    }

    It 'reports NotApplied when a value is present but does not match the target' {
        $entry = (Get-WtAiPrivacyCatalog) | Where-Object Name -eq 'DisableClickToDo'
        $action = { param($p, $n) [PSCustomObject]@{ DisableClickToDo = 0 } }
        (Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $action).Applied | Should -BeFalse
    }

    It 'reports NotApplied without throwing when the value is entirely absent' {
        $entry = (Get-WtAiPrivacyCatalog) | Where-Object Name -eq 'DisableClickToDo'
        $action = { param($p, $n) $null }
        { Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $action } | Should -Not -Throw
        (Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $action).Applied | Should -BeFalse
    }
}

Describe 'Get-WtAppPermissionCatalog' {
    BeforeAll {
        $script:PermCatalog = Get-WtAppPermissionCatalog
        $script:ValidRisks = @('SAFE', 'CAUTION', 'ADVANCED')
    }

    It 'has exactly 25 entries' {
        $PermCatalog.Count | Should -Be 25
    }

    It 'has unique capability names' {
        $names = $PermCatalog | Select-Object -ExpandProperty Name
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'has a non-empty DisplayLabel and a valid Risk for every entry' {
        foreach ($entry in $PermCatalog) {
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty
            $entry.Risk | Should -BeIn $ValidRisks
        }
    }

    It 'tags exactly the 8 library/broad-access/screen-capture capabilities CAUTION, nothing ADVANCED' {
        $expectedCaution = @('documentsLibrary', 'picturesLibrary', 'videosLibrary', 'musicLibrary', 'downloadsFolder', 'broadFileSystemAccess', 'graphicsCaptureProgrammatic', 'graphicsCaptureWithoutBorder')
        $actualCaution = @($PermCatalog | Where-Object Risk -eq 'CAUTION' | Select-Object -ExpandProperty Name | Sort-Object)
        $actualCaution | Should -Be @($expectedCaution | Sort-Object)
        @($PermCatalog | Where-Object Risk -eq 'ADVANCED').Count | Should -Be 0
    }

    It 'gives every CAUTION entry a non-empty consequence, and every SAFE entry a null one' {
        foreach ($entry in $PermCatalog) {
            if ($entry.Risk -eq 'CAUTION') { $entry.Consequence | Should -Not -BeNullOrEmpty }
            else { $entry.Consequence | Should -BeNullOrEmpty }
        }
    }

    It 'includes location, webcam, and microphone as SAFE with the correct display labels' {
        (($PermCatalog | Where-Object Name -eq 'location').DisplayLabel) | Should -Be 'Location'
        (($PermCatalog | Where-Object Name -eq 'webcam').DisplayLabel) | Should -Be 'Camera'
        (($PermCatalog | Where-Object Name -eq 'microphone').DisplayLabel) | Should -Be 'Microphone'
    }
}

Describe 'Get-WtAppPermissionState' {
    It 'reports Applied only for a value of exactly Deny' {
        $action = { param($p, $n) [PSCustomObject]@{ Value = 'Deny' } }
        (Get-WtAppPermissionState -Capability 'webcam' -GetPropertyAction $action).Applied | Should -BeTrue
    }

    It 'reports NotApplied for a value of Allow' {
        $action = { param($p, $n) [PSCustomObject]@{ Value = 'Allow' } }
        (Get-WtAppPermissionState -Capability 'webcam' -GetPropertyAction $action).Applied | Should -BeFalse
    }

    It 'reports NotApplied without throwing for a missing key' {
        $action = { param($p, $n) $null }
        { Get-WtAppPermissionState -Capability 'webcam' -GetPropertyAction $action } | Should -Not -Throw
        (Get-WtAppPermissionState -Capability 'webcam' -GetPropertyAction $action).Applied | Should -BeFalse
    }
}

Describe 'Get-WtSelectorDisplayLabel' {
    It 'renders the entry DisplayLabel when the catalog supplies one' {
        $entry = [PSCustomObject]@{ Name = 'webcam'; DisplayLabel = 'Camera' }
        Get-WtSelectorDisplayLabel -Entry $entry | Should -Be 'Camera'
    }

    It 'falls back to Name when the entry has no DisplayLabel property (existing Services/Packages catalogs)' {
        $entry = [PSCustomObject]@{ Name = 'DiagTrack' }
        $entry.PSObject.Properties.Name | Should -Not -Contain 'DisplayLabel'
        Get-WtSelectorDisplayLabel -Entry $entry | Should -Be 'DiagTrack'
    }

    It 'falls back to Name when DisplayLabel is present but empty' {
        $entry = [PSCustomObject]@{ Name = 'DiagTrack'; DisplayLabel = '' }
        Get-WtSelectorDisplayLabel -Entry $entry | Should -Be 'DiagTrack'
    }
}
