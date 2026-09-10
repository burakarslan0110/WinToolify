# Console user SID, apps per capability, per-app apply.
# Covered by: tests/PerAppPermission.Tests.ps1

function Get-WtConsoleUserSid {
    <#
    .SYNOPSIS
        Resolves the SID of the interactively logged-on console user,
        never $env:USERNAME (which under Start-Process -Verb RunAs can be
        a different administrator's identity than the person actually
        using the machine). Returns $null, never a throw and never a
        fallback to $env:USERNAME, if the console-user lookup is empty,
        the translate step throws, or the resolved SID fails to validate
        against a real ConsentStore hive. The translate step is
        injectable because even the NTAccount constructor - not just
        .Translate() - throws on macOS.
    #>
    param(
        [scriptblock]$GetConsoleUserAction = {
            (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        },

        [scriptblock]$TranslateSidAction = {
            param($account)
            (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        },

        [scriptblock]$ValidateSidAction = {
            param($sid)
            Test-Path -LiteralPath "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
        }
    )

    $consoleUser = & $GetConsoleUserAction
    if ([string]::IsNullOrWhiteSpace($consoleUser)) {
        return $null
    }

    $sid = $null
    try {
        $sid = & $TranslateSidAction $consoleUser
    }
    catch {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($sid)) {
        return $null
    }

    if (-not (& $ValidateSidAction $sid)) {
        return $null
    }

    return $sid
}

function Get-WtAppsForCapability {
    <#
    .SYNOPSIS
        Enumerates the apps that have actually requested one capability
        under the console user's own ConsentStore hive - Windows only
        creates a per-app subkey once an app has asked, so a capability
        nobody has asked for returns an empty list, not an error. Each
        entry resolves a friendly DisplayLabel via Get-AppxPackage,
        falling back to the raw package family name when resolution fails
        (an app that requested access and was later uninstalled still
        needs to show up so its stale grant is visible). Registry paths
        are built by string concatenation, not Join-Path, which throws
        against a Registry:: path when no Registry PSProvider is present.
        Shaped for Show-WtSelector: Name/DisplayLabel/Risk/Selectable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Capability,

        [Parameter(Mandatory)]
        [string]$Sid,

        [scriptblock]$GetChildItemAction = {
            param($path)
            Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue
        },

        [scriptblock]$GetAppxPackageAction = {
            param($pfn)
            Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object PackageFamilyName -eq $pfn | Select-Object -First 1
        },

        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    $basePath = "Registry::HKEY_USERS\$Sid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability"
    $children = @(& $GetChildItemAction $basePath)

    $apps = foreach ($child in $children) {
        $pfn = $child.PSChildName
        $package = & $GetAppxPackageAction $pfn
        $displayLabel = if ($package -and $package.DisplayName) { $package.DisplayName } else { $pfn }
        $current = Get-WtRegistryValue -Path "$basePath\$pfn" -Name 'Value' -GetPropertyAction $GetPropertyAction

        [PSCustomObject]@{
            Name         = $pfn
            DisplayLabel = $displayLabel
            Risk         = 'SAFE'
            Selectable   = -not ($current.Present -and $current.Value -eq 'Deny')
        }
    }

    return @($apps)
}

function Invoke-WtApplyPerAppPermissionSelection {
    <#
    .SYNOPSIS
        Wires the App Permissions selector to Invoke-WtGuardedChange:
        writes -Value ('Deny' by default) to each selected app's per-app
        ConsentStore Value under the console user's own hive, one
        Registry undo item per app. -Value 'Allow' (with a Revert action
        name) is the TurnOff path - the same undo item shape, so
        Restore-WtUndoEntry writes Deny back.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Capability,

        [Parameter(Mandatory)]
        [string]$Sid,

        [Parameter(Mandatory)]
        [string[]]$SelectedNames,

        [ValidateSet('Deny', 'Allow')]
        [string]$Value = 'Deny',

        [string]$ActionName = 'Apply Per-App Permission'
    )

    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($appName in $SelectedNames) {
            $path = "Registry::HKEY_USERS\$Sid\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability\$appName"
            $current = Get-WtRegistryValue -Path $path -Name 'Value'
            $items.Add([PSCustomObject]@{
                ItemType        = 'Registry'
                Path            = $path
                Name            = 'Value'
                RegType         = 'String'
                PreviousPresent = $current.Present
                PreviousValue   = $current.Value
            })
        }
        return $items.ToArray()
    }

    $apply = {
        param($Item)
        Set-WtRegistryValue -Path $Item.Path -Name $Item.Name -RegType 'String' -Value $Value
    }

    $reReadState = {
        param($Item)
        $current = Get-WtRegistryValue -Path $Item.Path -Name $Item.Name
        return ($current.Present -and $current.Value -eq $Value)
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope User -ActionName $ActionName
}
