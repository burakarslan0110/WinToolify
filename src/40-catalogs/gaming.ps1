# Gaming tweak catalog and GPU scheduling support check.
# Covered by: tests/GamingTweaks.Tests.ps1

# ---------------------------------------------------------------------------
# Memory & Performance Tuning bundle - Gaming Tweaks
# ---------------------------------------------------------------------------

function Get-WtGamingTweakCatalog {
    <#
    .SYNOPSIS
        The three gaming toggles as a RegistryChanges-shaped catalog:
        disable Fullscreen Optimizations, enable hardware-accelerated GPU
        scheduling (restart required, WDDM 2.7+ - CAUTION), throttle
        background-window input to 50 Hz. HKCU values are written under
        Scope Machine like the AI toggles - an accepted cross-account-
        elevation risk. A few entries keep OffAction=Delete rather than
        Set: a matching OffValue would equal Value (breaking the
        off-differs-from-on invariant) or Windows already ships that
        default.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'GamingTweak' -Catalog @(
        [PSCustomObject]@{
            Name            = 'DisableFullscreenOptimizations'
            DisplayLabel    = 'Disable Fullscreen Optimizations'
            Risk            = 'SAFE'
            Consequence     = $null
            RestartRequired = $false
            RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; RegType = 'DWord'; Value = 2; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehavior'; RegType = 'DWord'; Value = 2; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; RegType = 'DWord'; Value = 1; OffAction = 'Set'; OffValue = 0 }
                [PSCustomObject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_DXGIHonorFSEWindowsCompatible'; RegType = 'DWord'; Value = 1; OffAction = 'Set'; OffValue = 0 }
                [PSCustomObject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_EFSEFeatureFlags'; RegType = 'DWord'; Value = 0; OffAction = 'Delete' }
            )
        }
        [PSCustomObject]@{
            Name            = 'EnableGpuScheduling'
            DisplayLabel    = 'Enable hardware-accelerated GPU scheduling'
            Risk            = 'CAUTION'
            Consequence     = 'Takes effect after a restart; needs a WDDM 2.7+ driver - some older drivers perform worse with it on'
            RestartRequired = $true
            RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; RegType = 'DWord'; Value = 2; OffAction = 'Delete' }
            )
        }
        [PSCustomObject]@{
            Name            = 'ThrottleBackgroundInput'
            DisplayLabel    = 'Throttle background input to 50 Hz'
            Risk            = 'SAFE'
            Consequence     = $null
            RestartRequired = $false
            RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'RawMouseThrottleEnabled'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'RawMouseThrottleDuration'; RegType = 'DWord'; Value = 20; OffAction = 'Delete' }
            )
        }
    )
}


function Test-WtGpuSchedulingSupported {
    <#
    .SYNOPSIS
        Hardware-accelerated GPU scheduling needs a WDDM 2.7+ driver
        (Sophia-Script's check): WddmVersion_Min under GraphicsDrivers\
        FeatureSetUsage reports the version x1000. Returns $false only when
        the value is present and below 2700; when it is absent the entry
        stays selectable (the driver simply may ignore HwSchMode).
    #>
    param(
        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    $current = Get-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\FeatureSetUsage' -Name 'WddmVersion_Min' -GetPropertyAction $GetPropertyAction
    if ($current.Present -and [int]$current.Value -lt 2700) {
        return $false
    }
    return $true
}
