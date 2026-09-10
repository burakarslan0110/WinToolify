#Requires -Modules Pester

<#
.SYNOPSIS
    The Gaming Tweaks catalog (exact registry values), the generic
    registry-entry state helper that the gaming AND the AI & Copilot
    catalogs now share (the AI functions delegate to it - their own
    tests in tests/AiAndPermissionCatalogs.Tests.ps1 must keep passing
    unchanged), and the WDDM 2.7 gate for GPU scheduling. Everything
    registry-shaped runs against injected fakes, since the Registry
    PSProvider does not exist on the macOS dev host.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-RegistryFake {
        param([hashtable]$Values)
        return {
            param($p, $n)
            $key = "$p|$n"
            if ($Values.ContainsKey($key)) {
                $o = New-Object PSObject
                $o | Add-Member -NotePropertyName $n -NotePropertyValue $Values[$key]
                return $o
            }
            return $null
        }.GetNewClosure()
    }
}

Describe 'Get-WtGamingTweakCatalog' {
    BeforeAll { $script:Gaming = @(Get-WtGamingTweakCatalog) }

    It 'has exactly the three entries in order' {
        @($Gaming | Select-Object -ExpandProperty Name) | Should -Be @('DisableFullscreenOptimizations', 'EnableGpuScheduling', 'ThrottleBackgroundInput')
    }

    It 'DisableFullscreenOptimizations writes its five GameConfigStore values' {
        $entry = $Gaming | Where-Object Name -eq 'DisableFullscreenOptimizations'
        $entry.RegistryChanges.Count | Should -Be 5
        $expected = @{
            GameDVR_FSEBehaviorMode              = 2
            GameDVR_FSEBehavior                  = 2
            GameDVR_HonorUserFSEBehaviorMode     = 1
            GameDVR_DXGIHonorFSEWindowsCompatible = 1
            GameDVR_EFSEFeatureFlags             = 0
        }
        foreach ($name in $expected.Keys) {
            $change = $entry.RegistryChanges | Where-Object Name -eq $name
            $change | Should -Not -BeNullOrEmpty -Because "$name must be present"
            $change.Path | Should -Be 'HKCU:\System\GameConfigStore'
            $change.Value | Should -Be $expected[$name]
        }
    }

    It 'EnableGpuScheduling writes HwSchMode=2 under GraphicsDrivers and is the only CAUTION / RestartRequired entry' {
        $entry = $Gaming | Where-Object Name -eq 'EnableGpuScheduling'
        $entry.RegistryChanges.Count | Should -Be 1
        $entry.RegistryChanges[0].Path | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $entry.RegistryChanges[0].Name | Should -Be 'HwSchMode'
        $entry.RegistryChanges[0].Value | Should -Be 2
        $entry.Risk | Should -Be 'CAUTION'
        $entry.Consequence | Should -Not -BeNullOrEmpty
        $entry.RestartRequired | Should -BeTrue
        foreach ($other in ($Gaming | Where-Object Name -ne 'EnableGpuScheduling')) {
            $other.Risk | Should -Be 'SAFE'
            $other.RestartRequired | Should -BeFalse
        }
    }

    It 'ThrottleBackgroundInput writes RawMouseThrottleEnabled=1 and RawMouseThrottleDuration=20 under Control Panel\Mouse' {
        $entry = $Gaming | Where-Object Name -eq 'ThrottleBackgroundInput'
        $entry.RegistryChanges.Count | Should -Be 2
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKCU:\Control Panel\Mouse' -and $_.Name -eq 'RawMouseThrottleEnabled' -and $_.Value -eq 1 }).Count | Should -Be 1
        @($entry.RegistryChanges | Where-Object { $_.Path -eq 'HKCU:\Control Panel\Mouse' -and $_.Name -eq 'RawMouseThrottleDuration' -and $_.Value -eq 20 }).Count | Should -Be 1
    }

    It 'every change is DWord and every entry has a DisplayLabel' {
        foreach ($entry in $Gaming) {
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty
            foreach ($change in $entry.RegistryChanges) { $change.RegType | Should -Be 'DWord' }
        }
    }
}

Describe 'Get-WtRegistryEntryState (shared by gaming and AI catalogs)' {
    It 'reports NotApplied when only some of a gaming entry''s values match, Applied only when all match' {
        $entry = (Get-WtGamingTweakCatalog) | Where-Object Name -eq 'ThrottleBackgroundInput'
        $partial = New-RegistryFake -Values @{ 'HKCU:\Control Panel\Mouse|RawMouseThrottleEnabled' = 1 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $partial).Applied | Should -BeFalse
        $full = New-RegistryFake -Values @{ 'HKCU:\Control Panel\Mouse|RawMouseThrottleEnabled' = 1; 'HKCU:\Control Panel\Mouse|RawMouseThrottleDuration' = 20 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $full).Applied | Should -BeTrue
        $wrongValue = New-RegistryFake -Values @{ 'HKCU:\Control Panel\Mouse|RawMouseThrottleEnabled' = 1; 'HKCU:\Control Panel\Mouse|RawMouseThrottleDuration' = 8 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $wrongValue).Applied | Should -BeFalse
    }

    It 'Get-WtAiPrivacyState still reports DisableCopilot through the same logic (delegation is behaviour-preserving)' {
        $entry = (Get-WtAiPrivacyCatalog) | Where-Object Name -eq 'DisableCopilot'
        $partial = New-RegistryFake -Values @{ 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot' = 1 }
        (Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $partial).Applied | Should -BeFalse
        $full = New-RegistryFake -Values @{
            'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot'          = 1
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot'          = 1
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowCopilotButton'      = 0
        }
        (Get-WtAiPrivacyState -Entry $entry -GetPropertyAction $full).Applied | Should -BeTrue
    }
}

Describe 'Test-WtGpuSchedulingSupported' {
    It 'returns $false for WddmVersion_Min 2600' {
        $fake = New-RegistryFake -Values @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\FeatureSetUsage|WddmVersion_Min' = 2600 }
        Test-WtGpuSchedulingSupported -GetPropertyAction $fake | Should -BeFalse
    }

    It 'returns $true for 2700 and 3000' {
        foreach ($v in 2700, 3000) {
            $fake = New-RegistryFake -Values @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\FeatureSetUsage|WddmVersion_Min' = $v }
            Test-WtGpuSchedulingSupported -GetPropertyAction $fake | Should -BeTrue
        }
    }

    It 'returns $true when the value is absent (the driver may simply ignore HwSchMode)' {
        Test-WtGpuSchedulingSupported -GetPropertyAction (New-RegistryFake -Values @{}) | Should -BeTrue
    }
}
