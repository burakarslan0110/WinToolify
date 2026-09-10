#Requires -Modules Pester

<#
.SYNOPSIS
    Get-WtConsoleUserSid and Get-WtAppsForCapability.

    Get-WtConsoleUserSid must not fall back to $env:USERNAME - under the
    exact elevation scenario it exists to handle (Start-Process -Verb
    RunAs re-elevating under a DIFFERENT administrator's identity),
    $env:USERNAME IS that wrong identity, so a fallback to it would
    silently reintroduce the defect this design exists to fix.

    Even the System.Security.Principal.NTAccount CONSTRUCTOR throws on
    macOS ("Windows Principal functionality is not supported on this
    platform"), not just .Translate(), so the translate step itself is
    injectable, same as the console-user lookup and the SID validation.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtConsoleUserSid' {
    It 'translates the console user via the injected TranslateSidAction, then validates via ValidateSidAction, before returning it' {
        $seen = @{}
        $getConsoleUser = { 'CONTOSO\alice' }
        $translate = { param($account) $seen.TranslatedAccount = $account; 'S-1-5-21-1-2-3-1001' }.GetNewClosure()
        $validate = { param($sid) $seen.ValidatedSid = $sid; $true }.GetNewClosure()

        $result = Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser -TranslateSidAction $translate -ValidateSidAction $validate

        $seen.TranslatedAccount | Should -Be 'CONTOSO\alice'
        $seen.ValidatedSid | Should -Be 'S-1-5-21-1-2-3-1001'
        $result | Should -Be 'S-1-5-21-1-2-3-1001'
    }

    It 'returns $null (not a throw) when the console-user action returns an empty string' {
        $getConsoleUser = { '' }
        { Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser } | Should -Not -Throw
        Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser | Should -BeNullOrEmpty
    }

    It 'returns $null (not a throw) when the console-user action returns $null' {
        $getConsoleUser = { $null }
        { Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser } | Should -Not -Throw
        Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser | Should -BeNullOrEmpty
    }

    It 'returns $null (not a throw) when TranslateSidAction throws' {
        $getConsoleUser = { 'CONTOSO\alice' }
        $translate = { param($account) throw 'simulated platform failure' }
        { Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser -TranslateSidAction $translate } | Should -Not -Throw
        Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser -TranslateSidAction $translate | Should -BeNullOrEmpty
    }

    It 'returns $null when ValidateSidAction reports the SID has no ConsentStore hive loaded' {
        $getConsoleUser = { 'CONTOSO\alice' }
        $translate = { param($account) 'S-1-5-21-1-2-3-1001' }
        $validate = { param($sid) $false }
        Get-WtConsoleUserSid -GetConsoleUserAction $getConsoleUser -TranslateSidAction $translate -ValidateSidAction $validate | Should -BeNullOrEmpty
    }

    It 'never resolves a SID by any path other than GetConsoleUserAction -> TranslateSidAction -> ValidateSidAction - a broken console-user lookup returns $null regardless of the current process identity' {
        (Get-Command Get-WtConsoleUserSid).Parameters.Keys | Where-Object { $_ -notin @('GetConsoleUserAction', 'TranslateSidAction', 'ValidateSidAction') } |
            Where-Object { $_ -notin ([System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters) } |
            Should -BeNullOrEmpty
    }
}

Describe 'Get-WtAppsForCapability' {
    It 'resolves a DisplayLabel via the injected GetAppxPackageAction when a matching package is found' {
        $getChildItem = { param($path) @([PSCustomObject]@{ PSChildName = 'Contoso.Camera_8wekyb3d8bbwe' }) }
        $getAppxPackage = { param($pfn) [PSCustomObject]@{ Name = $pfn; DisplayName = 'Contoso Camera' } }
        $getValue = { param($p, $n) [PSCustomObject]@{ Value = 'Allow' } }

        $apps = Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem -GetAppxPackageAction $getAppxPackage -GetPropertyAction $getValue

        @($apps).Count | Should -Be 1
        $apps[0].Name | Should -Be 'Contoso.Camera_8wekyb3d8bbwe'
        $apps[0].DisplayLabel | Should -Be 'Contoso Camera'
    }

    It 'falls back to the raw package family name when Appx resolution fails, without throwing' {
        $getChildItem = { param($path) @([PSCustomObject]@{ PSChildName = 'Contoso.Uninstalled_8wekyb3d8bbwe' }) }
        $getAppxPackage = { param($pfn) $null }
        $getValue = { param($p, $n) [PSCustomObject]@{ Value = 'Allow' } }

        { Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem -GetAppxPackageAction $getAppxPackage -GetPropertyAction $getValue } | Should -Not -Throw
        $apps = Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem -GetAppxPackageAction $getAppxPackage -GetPropertyAction $getValue
        $apps[0].DisplayLabel | Should -Be 'Contoso.Uninstalled_8wekyb3d8bbwe'
    }

    It 'returns an empty list, not an error, for a capability with no per-app subkeys' {
        $getChildItem = { param($path) @() }
        { Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem } | Should -Not -Throw
        @(Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem).Count | Should -Be 0
    }

    It 'marks an app already Denied as not Selectable, matching the apply-only selector convention' {
        $getChildItem = { param($path) @([PSCustomObject]@{ PSChildName = 'Contoso.Camera_8wekyb3d8bbwe' }) }
        $getAppxPackage = { param($pfn) $null }
        $getValue = { param($p, $n) [PSCustomObject]@{ Value = 'Deny' } }

        $apps = Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem -GetAppxPackageAction $getAppxPackage -GetPropertyAction $getValue
        $apps[0].Selectable | Should -BeFalse
    }

    It 'queries Registry::HKEY_USERS\<Sid>\... not HKCU:' {
        $seen = @{}
        $getChildItem = { param($path) $seen.Path = $path; @() }.GetNewClosure()
        Get-WtAppsForCapability -Capability 'webcam' -Sid 'S-1-5-21-1-2-3-1001' -GetChildItemAction $getChildItem | Out-Null
        $seen.Path | Should -Match '^Registry::HKEY_USERS\\S-1-5-21-1-2-3-1001\\'
        $seen.Path | Should -Not -Match 'HKCU:'
    }
}

Describe 'Permission writers take the target value (Deny to apply, Allow to remove)' {
    BeforeEach {
        $script:writes = New-Object 'System.Collections.Generic.List[string]'
        $script:actions = New-Object 'System.Collections.Generic.List[string]'
        $script:undoItems = @()
        Mock Write-WtUndoEntry { $script:actions.Add($Action); $script:undoItems = $Items; 'fake.json' }
        Mock Get-WtRegistryValue { [PSCustomObject]@{ Present = $true; Value = 'Deny' } }
        Mock Set-WtRegistryValue { $script:writes.Add("$Path=$Value") }
    }
    It 'capability defaults: Allow + Revert action name on removal, Deny by default' {
        Invoke-WtApplyAppPermissionSelection -SelectedNames @('location') -Value 'Allow' -ActionName 'Revert App Permission Defaults' | Out-Null
        $writes[0] | Should -Match 'ConsentStore\\location=Allow$'
        $actions[0] | Should -Be 'Revert App Permission Defaults'
        Invoke-WtApplyAppPermissionSelection -SelectedNames @('location') | Out-Null
        $writes[1] | Should -Match '=Deny$'
        $actions[1] | Should -Be 'Apply App Permission Defaults'
    }
    It 'capability defaults removal captures the live Deny in the undo item, so Restore writes Deny back' {
        Invoke-WtApplyAppPermissionSelection -SelectedNames @('location') -Value 'Allow' -ActionName 'Revert App Permission Defaults' | Out-Null
        $item = @($script:undoItems)[0]
        $item.ItemType | Should -Be 'Registry'
        $item.PreviousValue | Should -Be 'Deny'
        $item.PreviousPresent | Should -BeTrue
        $item.Path | Should -Match 'ConsentStore\\location$'
    }
    It 'per-app: Allow + Revert action name on removal' {
        Invoke-WtApplyPerAppPermissionSelection -Capability 'webcam' -Sid 'S-1-5-21-1' -SelectedNames @('Some.App_abc') -Value 'Allow' -ActionName 'Revert Per-App Permission' | Out-Null
        $writes[0] | Should -Match 'ConsentStore\\webcam\\Some.App_abc=Allow$'
        $actions[0] | Should -Be 'Revert Per-App Permission'
    }
    It 'the groups adapter forwards -Value to the per-capability writer' {
        $script:seen = @()
        Invoke-WtApplyPerAppPermissionGroups -Names @('webcam|A', 'microphone|B') -Sid 'S-1' -Value 'Allow' `
            -ApplyAction { param($Capability, $Sid, [string[]]$Names, $Value) $script:seen += "$Capability/$Value"; [PSCustomObject]@{ Aborted = $false; Results = @() } } | Out-Null
        @($seen) | Should -Be @('webcam/Allow', 'microphone/Allow')
    }
    It 'CapabilityDefaults and PerAppPermissions sections expose TurnOff that removes with Allow' {
        Mock Invoke-WtApplyAppPermissionSelection { [PSCustomObject]@{ Aborted = $false; Results = @(); V = $Value; A = $ActionName } }
        Mock Invoke-WtApplyPerAppPermissionGroups { [PSCustomObject]@{ Aborted = $false; Results = @(); V = $Value } }
        $cap = (Get-WtProfileSectionCatalog) | Where-Object Key -eq 'CapabilityDefaults'
        $r = & $cap.TurnOff ([string[]]@('location')) $null
        $r.V | Should -Be 'Allow'
        $r.A | Should -Be 'Revert App Permission Defaults'
        $per = (Get-WtApplySectionCatalog) | Where-Object Key -eq 'PerAppPermissions'
        (& $per.TurnOff ([string[]]@('webcam|A')) @{ Sid = 'S-1' }).V | Should -Be 'Allow'
        $script:Translations['TR']['UndoAction.Revert App Permission Defaults'] | Should -Not -BeNullOrEmpty
        $script:Translations['TR']['UndoAction.Revert Per-App Permission'] | Should -Not -BeNullOrEmpty
    }
}
