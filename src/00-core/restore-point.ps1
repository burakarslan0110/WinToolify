# System Restore point detection, creation and the on-demand action.
# Covered by: tests/RestorePoint.Tests.ps1

function Test-WtUsesCimRestorePointApi {
    <#
    .SYNOPSIS
        True when the running PowerShell major version should use the CIM
        restore-point API (6+) instead of Checkpoint-Computer (5.1 and
        below); PS7 does not ship Checkpoint-Computer or Get-ComputerRestorePoint.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$PSMajorVersion
    )
    return ($PSMajorVersion -ge 6)
}

function Test-WtSystemProtectionEnabled {
    <#
    .SYNOPSIS
        True when System Protection is enabled for the system drive
        (RPGlobalInterval is 0 when disabled, on Vista and later - one
        check, no version branch needed).
    #>
    $config = Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestoreConfig' -ErrorAction SilentlyContinue
    return ($null -ne $config -and $config.RPGlobalInterval -ne 0)
}

function Test-WtRestorePointRecent {
    <#
    .SYNOPSIS
        Returns the age in hours of the most recent restore point, or $null
        if none exists; branches on Test-WtUsesCimRestorePointApi between
        Get-ComputerRestorePoint (5.1) and Get-CimInstance (7).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-ComputerRestorePoint only executes in the PS5.1 branch, guarded by Test-WtUsesCimRestorePointApi; PSScriptAnalyzer cannot see the runtime version guard.')]
    param()

    if (Test-WtUsesCimRestorePointApi -PSMajorVersion $PSVersionTable.PSVersion.Major) {
        $points = Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue
    }
    else {
        $points = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
    }

    $latest = $points | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
    if (-not $latest) {
        return $null
    }

    $creationTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($latest.CreationTime)
    return (New-TimeSpan -Start $creationTime -End (Get-Date)).TotalHours
}

function Get-WtRestorePointRecords {
    <#
    .SYNOPSIS
        Every restore point, with the read outcome kept separate from the
        result (Succeeded/Points/Error), since an unelevated session makes
        Get-ComputerRestorePoint throw rather than return nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-ComputerRestorePoint only executes in the PS5.1 branch, guarded by Test-WtUsesCimRestorePointApi; PSScriptAnalyzer cannot see the runtime version guard.')]
    param()

    try {
        if (Test-WtUsesCimRestorePointApi -PSMajorVersion $PSVersionTable.PSVersion.Major) {
            $points = @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop)
        }
        else {
            $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        }
        return [PSCustomObject]@{ Succeeded = $true; Points = @($points); Error = '' }
    }
    catch {
        return [PSCustomObject]@{ Succeeded = $false; Points = @(); Error = [string]$_.Exception.Message }
    }
}

function New-WtRestorePoint {
    <#
    .SYNOPSIS
        Creates a System Restore point with the API matching the running
        PowerShell version. Silently no-ops within 24h of the last point
        (callers must check Test-WtRestorePointRecent), and reads the CIM
        call's HRESULT directly since Invoke-CimMethod never throws on failure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Checkpoint-Computer only executes in the PS5.1 branch, guarded by Test-WtUsesCimRestorePointApi; PSScriptAnalyzer cannot see the runtime version guard.')]
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [int]$PSMajorVersion = $PSVersionTable.PSVersion.Major,

        [scriptblock]$InvokeCimAction = {
            param($Arguments)
            Invoke-CimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -MethodName 'CreateRestorePoint' -Arguments $Arguments -ErrorAction Stop
        }
    )

    try {
        if (Test-WtUsesCimRestorePointApi -PSMajorVersion $PSMajorVersion) {
            $arguments = @{
                Description      = $Description
                RestorePointType = 12
                EventType        = 100
            }
            $cimResult = & $InvokeCimAction $arguments
            if ($null -ne $cimResult -and $cimResult.PSObject.Properties.Name -contains 'ReturnValue' -and [int64]$cimResult.ReturnValue -ne 0) {
                throw "CreateRestorePoint returned $($cimResult.ReturnValue) (0x$([Convert]::ToString([int64]$cimResult.ReturnValue, 16)))"
            }
        }
        else {
            Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Warning ([string](Get-Translation 'RpCreateFailed') + ' ' + $_.Exception.Message)
        return $false
    }
}

function Invoke-WtCreateRestorePointAction {
    <#
    .SYNOPSIS
        The main menu's "Create System Restore Point" row: creates one on
        demand with no confirmation, or states why not (24h throttle or
        Windows' failure reason) - all rendered inside the panel since
        nothing may write to the raw host behind the painted frame.
    #>
    param(
        [scriptblock]$GetProtectionEnabled = { Test-WtSystemProtectionEnabled },
        [scriptblock]$GetLastPointAgeHours = { Test-WtRestorePointRecent },
        [scriptblock]$CreatePoint = {
            param($Description)
            $captured = $null
            $ok = New-WtRestorePoint -Description $Description -WarningAction SilentlyContinue -WarningVariable captured
            [PSCustomObject]@{ Created = [bool]$ok; Reason = ((@($captured) | ForEach-Object { [string]$_ }) -join ' ') }
        },
        [scriptblock]$ShowMessage = { param($Lines) Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Risk 'CAUTION' -Layout 'Compact' },
        [scriptblock]$Acknowledge = { param($Lines) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt (Get-Translation 'PressEnterToReturn') -Risk 'CAUTION' -Layout 'Compact' },
        [int]$WrapWidth = 66
    )
    if (-not (& $GetProtectionEnabled)) {
        & $Acknowledge @((Get-Translation 'RpProtectionDisabled')) | Out-Null
        return $false
    }
    $age = & $GetLastPointAgeHours
    if ($null -ne $age -and $age -lt 24) {
        & $Acknowledge @((Get-Translation 'RpThrottled')) | Out-Null
        return $false
    }
    & $ShowMessage @((Get-Translation 'RpCreating'))
    $result = & $CreatePoint ('WinToolify: ' + [string](Get-Translation 'RpManualDescription'))
    if ($result -and $result.Created) {
        & $Acknowledge @((Get-Translation 'RpCreated')) | Out-Null
        return $true
    }
    $reason = if ($result) { [string]$result.Reason } else { '' }
    $lines = @(Split-WtWrappedLines -Text $reason -Width $WrapWidth)
    if ($lines.Count -eq 0) { $lines = @((Get-Translation 'RpCreateFailed')) }
    & $Acknowledge $lines | Out-Null
    return $false
}
