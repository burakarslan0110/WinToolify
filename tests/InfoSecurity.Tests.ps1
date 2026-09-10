#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the Security rows on the Information Tools screen
    (Defender status, Secure Boot + TPM, local administrators, security
    posture) and their pure line builders. Every Windows source is
    behind an injectable scriptblock, so no test here touches
    Get-MpComputerStatus, Confirm-SecureBootUEFI, Get-Tpm,
    Get-LocalGroupMember, Get-Service or the WSMan drive.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function script:New-WtSecTime {
        param([Parameter(Mandatory)][string]$Text)
        return [datetime]::ParseExact($Text, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    function script:New-FakeDefenderStatus {
        param(
            $RealTimeProtectionEnabled = $true,
            $AntivirusEnabled = $true,
            $BehaviorMonitorEnabled = $true,
            $IsTamperProtected = $true,
            $AntivirusSignatureVersion = '1.457.306.0',
            $AntispywareSignatureLastUpdated = $null,
            $QuickScanEndTime = $null,
            $FullScanEndTime = $null
        )
        return [PSCustomObject]@{
            RealTimeProtectionEnabled       = $RealTimeProtectionEnabled
            AMRunningMode                   = 'Normal'
            AntivirusEnabled                = $AntivirusEnabled
            BehaviorMonitorEnabled          = $BehaviorMonitorEnabled
            IsTamperProtected               = $IsTamperProtected
            AntivirusSignatureVersion       = $AntivirusSignatureVersion
            AntispywareSignatureLastUpdated = $AntispywareSignatureLastUpdated
            QuickScanEndTime                = $QuickScanEndTime
            FullScanEndTime                 = $FullScanEndTime
        }
    }
}

Describe 'Get-WtDefenderStatusLines' {
    It 'reports protection, signature age and both scan times when Defender answers' {
        $script:MpStatus = New-FakeDefenderStatus -AntispywareSignatureLastUpdated (New-WtSecTime '2026-08-20 12:25:51') -QuickScanEndTime (New-WtSecTime '2026-08-21 19:59:35')
        $lines = @(Get-WtDefenderStatusLines -GetStatus { $script:MpStatus } -Now (New-WtSecTime '2026-08-23 12:00:00'))

        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'DefenderRealTimeProtection')))
        (@($lines | Where-Object { $_ -cmatch '^Real-time protection' }))[0] | Should -Match (Get-Translation 'SecStateOn')
        (@($lines | Where-Object { $_ -cmatch '^Signature age' }))[0] | Should -Match '3 days'
        (@($lines | Where-Object { $_ -cmatch '^Signature age' }))[0] | Should -Match '2026-08-20 12:25:51'
        (@($lines | Where-Object { $_ -cmatch '^Last quick scan' }))[0] | Should -Match '2026-08-21 19:59:35'
    }

    It 'prints the running mode only when the platform exposes AMRunningMode' {
        $withMode = New-FakeDefenderStatus
        @(Get-WtDefenderStatusLines -GetStatus { $withMode }) | Where-Object { $_ -cmatch '^Running mode' } | Should -Not -BeNullOrEmpty

        $noMode = [PSCustomObject]@{
            RealTimeProtectionEnabled       = $true
            AntivirusEnabled                = $true
            BehaviorMonitorEnabled          = $true
            IsTamperProtected               = $false
            AntivirusSignatureVersion       = '1.1.1.1'
            AntispywareSignatureLastUpdated = $null
            QuickScanEndTime                = $null
            FullScanEndTime                 = $null
        }
        @(Get-WtDefenderStatusLines -GetStatus { $noMode }) | Where-Object { $_ -cmatch '^Running mode' } | Should -BeNullOrEmpty
    }

    It 'says "never" for a scan that has not run instead of printing a blank date' {
        $script:MpStatus = New-FakeDefenderStatus
        $lines = @(Get-WtDefenderStatusLines -GetStatus { $script:MpStatus })
        (@($lines | Where-Object { $_ -cmatch '^Last full scan' }))[0] | Should -Match (Get-Translation 'SecStateNever')
    }

    It 'returns the single unavailable line when the call itself throws' {
        $lines = @(Get-WtDefenderStatusLines -GetStatus { throw 'The service cannot be started' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'DefenderStatusUnavailable')
    }
}

Describe 'Get-WtSecureBootTpmLines' {
    It 'reports firmware, Secure Boot, TPM and the system disk layout when everything answers' {
        $lines = @(Get-WtSecureBootTpmLines `
                -GetFirmwareType { 'UEFI' } `
                -GetSecureBoot { $true } `
                -GetSecureBootRegistry { 1 } `
                -GetTpm { [PSCustomObject]@{ TpmPresent = $true; TpmReady = $true; TpmEnabled = $true } } `
                -GetTpmCim { [PSCustomObject]@{ IsEnabled_InitialValue = $true; IsActivated_InitialValue = $true; SpecVersion = '2.0, 0, 1.38' } } `
                -GetSystemDisk { [PSCustomObject]@{ IsSystem = $true; PartitionStyle = 'GPT'; FriendlyName = 'INTEL SSDPEKNU512GZ' } })

        (@($lines | Where-Object { $_ -cmatch '^Firmware type' }))[0] | Should -Match 'UEFI'
        (@($lines | Where-Object { $_ -cmatch '^Secure Boot' }))[0] | Should -Match (Get-Translation 'SecStateOn')
        (@($lines | Where-Object { $_ -cmatch '^TPM chip' }))[0] | Should -Match (Get-Translation 'SecStateOn')
        (@($lines | Where-Object { $_ -cmatch '^TPM version' }))[0] | Should -Match '2\.0'
        (@($lines | Where-Object { $_ -cmatch '^System disk layout' }))[0] | Should -Match 'GPT'
    }

    It 'says "not supported" on a legacy BIOS machine where Confirm-SecureBootUEFI throws' {
        $lines = @(Get-WtSecureBootTpmLines `
                -GetFirmwareType { 'Legacy' } `
                -GetSecureBoot { throw (New-Object System.PlatformNotSupportedException 'Cmdlet not supported on this platform.') } `
                -GetSecureBootRegistry { throw (New-Object System.Management.Automation.ItemNotFoundException 'no SecureBoot key') } `
                -GetTpm { throw 'no tpm' } `
                -GetTpmCim { @() } `
                -GetSystemDisk { [PSCustomObject]@{ IsSystem = $true; PartitionStyle = 'MBR' } })

        (@($lines | Where-Object { $_ -cmatch '^Secure Boot' }))[0] | Should -Match ([regex]::Escape((Get-Translation 'SecureBootNotSupported')))
        (@($lines | Where-Object { $_ -cmatch '^TPM chip' }))[0] | Should -Match ([regex]::Escape((Get-Translation 'TpmNotAvailable')))
        @($lines | Where-Object { $_ -cmatch '^TPM version' }).Count | Should -Be 0
        (@($lines | Where-Object { $_ -cmatch '^System disk layout' }))[0] | Should -Match 'MBR'
    }

    It 'falls back to the registry value when Confirm-SecureBootUEFI is denied' {
        $lines = @(Get-WtSecureBootTpmLines `
                -GetFirmwareType { 'UEFI' } `
                -GetSecureBoot { throw (New-Object System.UnauthorizedAccessException 'Unable to set proper privileges. Access was denied.') } `
                -GetSecureBootRegistry { 0 } `
                -GetTpm { [PSCustomObject]@{ TpmPresent = $null; TpmReady = $null; TpmEnabled = $null } } `
                -GetTpmCim { [PSCustomObject]@{ IsEnabled_InitialValue = $true; SpecVersion = '2.0, 0, 1.38' } } `
                -GetSystemDisk { @() })

        $sb = (@($lines | Where-Object { $_ -cmatch '^Secure Boot' }))[0]
        $sb | Should -Match (Get-Translation 'SecStateOff')
        $sb | Should -Match ([regex]::Escape((Get-Translation 'SecureBootAccessDenied')))
        (@($lines | Where-Object { $_ -cmatch '^TPM chip' }))[0] | Should -Match (Get-Translation 'SecStateOn')
        (@($lines | Where-Object { $_ -cmatch '^System disk layout' }))[0] | Should -Match (Get-Translation 'SecStateUnknown')
    }

    It 'says "not present" when Get-Tpm answers with TpmPresent false' {
        $lines = @(Get-WtSecureBootTpmLines `
                -GetFirmwareType { 'UEFI' } `
                -GetSecureBoot { $false } `
                -GetSecureBootRegistry { 0 } `
                -GetTpm { [PSCustomObject]@{ TpmPresent = $false; TpmReady = $false; TpmEnabled = $false } } `
                -GetTpmCim { @() } `
                -GetSystemDisk { [PSCustomObject]@{ IsSystem = $true; PartitionStyle = 'GPT' } })

        (@($lines | Where-Object { $_ -cmatch '^TPM chip' }))[0] | Should -Match ([regex]::Escape((Get-Translation 'TpmNotPresent')))
    }
}

Describe 'Get-WtLocalAdministratorsLines' {
    It 'lists every member with its object class and principal source' {
        $script:AdminMembers = @(
            [PSCustomObject]@{ Name = 'DESKTOP-0GG23Q3\Administrator'; ObjectClass = 'User'; PrincipalSource = 'Local' }
            [PSCustomObject]@{ Name = 'CONTOSO\Domain Admins'; ObjectClass = 'Group'; PrincipalSource = 'ActiveDirectory' }
        )
        $lines = @(Get-WtLocalAdministratorsLines -GetMembers { $script:AdminMembers } -GetFallbackMembers { throw 'fallback must not run' })

        $lines[0] | Should -Be (Get-Translation 'LocalAdminGroupHeader')
        $lines[1] | Should -Match 'DESKTOP-0GG23Q3\\Administrator'
        $lines[1] | Should -Match 'User'
        $lines[1] | Should -Match 'Local'
        $lines[2] | Should -Match 'Domain Admins'
        $lines[2] | Should -Match 'Domain'
        @($lines | Where-Object { $_ -eq (Get-Translation 'LocalAdminFallbackNote') }).Count | Should -Be 0
    }

    It 'falls back to ADSI and says so when Get-LocalGroupMember throws on an orphaned SID' {
        $fallback = @([PSCustomObject]@{ Name = 'DESKTOP-0GG23Q3\Burak'; ObjectClass = 'User'; PrincipalSource = '' })
        $lines = @(Get-WtLocalAdministratorsLines `
                -GetMembers { throw 'Failed to compare two elements in the array.' } `
                -GetFallbackMembers { $fallback })

        ($lines -join "`n") | Should -Match 'Burak'
        $lines[-1] | Should -Be (Get-Translation 'LocalAdminFallbackNote')
    }

    It 'says the group could not be read when both sources fail' {
        $lines = @(Get-WtLocalAdministratorsLines `
                -GetMembers { throw 'primary failed' } `
                -GetFallbackMembers { throw 'adsi failed' })

        $lines.Count | Should -Be 2
        $lines[1] | Should -Be (Get-Translation 'LocalAdminUnavailable')
    }

    It 'says no member was readable when the group comes back empty' {
        $lines = @(Get-WtLocalAdministratorsLines -GetMembers { @() } -GetFallbackMembers { @() })
        $lines[1] | Should -Be (Get-Translation 'LocalAdminNone')
    }
}

Describe 'Get-WtUacLevelKey' {
    It 'names all four slider positions Windows shows' {
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 2 -PromptOnSecureDesktop 1 | Should -Be 'PostureUacAlwaysNotify'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 5 -PromptOnSecureDesktop 1 | Should -Be 'PostureUacDefault'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 5 -PromptOnSecureDesktop 0 | Should -Be 'PostureUacNoDim'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 0 -PromptOnSecureDesktop 0 | Should -Be 'PostureUacNeverNotify'
    }

    It 'reports EnableLUA=0 as turned off no matter what the prompt behaviour says' {
        Get-WtUacLevelKey -EnableLua 0 -ConsentPromptBehaviorAdmin 2 -PromptOnSecureDesktop 1 | Should -Be 'PostureUacDisabled'
    }

    It 'names the credential and consent prompt behaviours' {
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 1 -PromptOnSecureDesktop 1 | Should -Be 'PostureUacCredentials'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 3 -PromptOnSecureDesktop 0 | Should -Be 'PostureUacCredentials'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 4 -PromptOnSecureDesktop 0 | Should -Be 'PostureUacConsent'
    }

    It 'is Unknown when either value is missing, never a guessed level' {
        Get-WtUacLevelKey -EnableLua $null -ConsentPromptBehaviorAdmin 5 -PromptOnSecureDesktop 1 | Should -Be 'SecStateUnknown'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin $null -PromptOnSecureDesktop 1 | Should -Be 'SecStateUnknown'
        Get-WtUacLevelKey -EnableLua 1 -ConsentPromptBehaviorAdmin 9 -PromptOnSecureDesktop 1 | Should -Be 'SecStateUnknown'
    }

    It 'returns keys that both dictionaries resolve' {
        foreach ($key in @('PostureUacAlwaysNotify', 'PostureUacDefault', 'PostureUacNoDim', 'PostureUacNeverNotify', 'PostureUacDisabled', 'PostureUacCredentials', 'PostureUacConsent', 'SecStateUnknown')) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
}

Describe 'Get-WtSecurityPostureLines' {
    It 'reports UAC in words, Remote Desktop, WinRM and the password policy' {
        $lines = @(Get-WtSecurityPostureLines `
                -GetUacPolicy { [PSCustomObject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 5; PromptOnSecureDesktop = 1 } } `
                -GetTerminalServerPolicy { [PSCustomObject]@{ fDenyTSConnections = 0 } } `
                -GetRdpTcpPolicy { [PSCustomObject]@{ UserAuthentication = 1 } } `
                -GetRemoteDesktopUsers { @([PSCustomObject]@{ Name = 'DESKTOP-0GG23Q3\Burak' }) } `
                -GetWinrmService { [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } } `
                -GetWinrmListeners { @([PSCustomObject]@{ Name = 'Listener_1084132640'; Keys = @('Transport=HTTP', 'Address=*') }) } `
                -GetPasswordPolicy { @('Minimum password length:  0', 'Lockout threshold:  Never', 'The command completed successfully.') })

        $text = $lines -join "`n"
        (@($lines | Where-Object { $_ -cmatch '^UAC level' }))[0] | Should -Match ([regex]::Escape((Get-Translation 'PostureUacDefault')))
        (@($lines | Where-Object { $_ -cmatch '^Remote Desktop:' }))[0] | Should -Match (Get-Translation 'SecStateOn')
        (@($lines | Where-Object { $_ -cmatch '^Network Level Authentication' }))[0] | Should -Match (Get-Translation 'SecStateOn')
        (@($lines | Where-Object { $_ -cmatch '^Remote Desktop Users group' }))[0] | Should -Match 'Burak'
        (@($lines | Where-Object { $_ -cmatch '^WinRM service' }))[0] | Should -Match 'Running'
        $text | Should -Match 'Transport=HTTP'
        $text | Should -Match 'Minimum password length'
    }

    It 'says Off for Remote Desktop when fDenyTSConnections is 1' {
        $lines = @(Get-WtSecurityPostureLines `
                -GetUacPolicy { [PSCustomObject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 5; PromptOnSecureDesktop = 1 } } `
                -GetTerminalServerPolicy { [PSCustomObject]@{ fDenyTSConnections = 1 } } `
                -GetRdpTcpPolicy { [PSCustomObject]@{ UserAuthentication = 1 } } `
                -GetRemoteDesktopUsers { @() } `
                -GetWinrmService { [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Manual' } } `
                -GetWinrmListeners { throw (New-Object System.Management.Automation.ItemNotFoundException "Cannot find path 'localhost\Listener' because it does not exist.") } `
                -GetPasswordPolicy { @('Lockout threshold:  Never') })

        (@($lines | Where-Object { $_ -cmatch '^Remote Desktop:' }))[0] | Should -Match (Get-Translation 'SecStateOff')
        (@($lines | Where-Object { $_ -cmatch '^Remote Desktop Users group' }))[0] | Should -Match ([regex]::Escape((Get-Translation 'PostureRdpUsersEmpty')))
        (@($lines | Where-Object { $_ -cmatch '^WinRM listeners' }))[0] | Should -Match ([regex]::Escape((Get-Translation 'PostureWinrmNoListener')))
    }

    It 'degrades to Unknown on every axis when nothing can be read' {
        $lines = @(Get-WtSecurityPostureLines `
                -GetUacPolicy { throw 'no policy key' } `
                -GetTerminalServerPolicy { throw 'no terminal server key' } `
                -GetRdpTcpPolicy { throw 'no RDP-Tcp key' } `
                -GetRemoteDesktopUsers { throw 'group unreadable' } `
                -GetWinrmService { throw 'service missing' } `
                -GetWinrmListeners { throw 'no WSMan drive' } `
                -GetPasswordPolicy { @() })

        (@($lines | Where-Object { $_ -cmatch '^UAC level' }))[0] | Should -Match (Get-Translation 'SecStateUnknown')
        (@($lines | Where-Object { $_ -cmatch '^Remote Desktop:' }))[0] | Should -Match (Get-Translation 'SecStateUnknown')
        (@($lines | Where-Object { $_ -cmatch '^WinRM service' }))[0] | Should -Match (Get-Translation 'SecStateUnknown')
        ($lines | Where-Object { $_ -eq (Get-Translation 'PosturePasswordPolicyUnavailable') }).Count | Should -Be 1
    }
}

Describe 'Information Tools > Security group wiring' {
    BeforeAll {
        $script:SecurityGroup = @(Get-WtInfoToolGroups) | Where-Object { $_.HeaderKey -ceq 'InfoGroupSecurity' }
        $script:SecurityRows = @(& $script:SecurityGroup.GetRows)
    }

    AfterEach { $script:Language = 'EN' }

    It 'holds the five catalogue rows in order' {
        @($script:SecurityRows | ForEach-Object { $_.Name }) | Should -Be @(
            'DefenderStatusInfo'
            'SecureBootTpmStatus'
            'LocalAdministrators'
            'ListUserAccounts'
            'SecurityPostureInfo'
        )
    }

    It 'builds every row as a captured action' {
        foreach ($row in $script:SecurityRows) {
            $row.Kind | Should -Be 'Action'
            $row.Data.Captured | Should -BeTrue -Because "$($row.Name) must render inside the panel"
        }
    }

    It 'never calls Read-Host from a captured scriptblock' {
        foreach ($row in $script:SecurityRows) {
            ([string]$row.Data.Action.ToString() -cmatch 'Read-Host') | Should -BeFalse -Because "$($row.Name) would deadlock behind the capture"
        }
    }

    It 'contains no state-changing verb in any information scriptblock' {
        $denied = '(?:Set|Remove|Stop|Start|Restart|New|Clear|Disable|Enable)-'
        foreach ($row in $script:SecurityRows) {
            ([string]$row.Data.Action.ToString() -cmatch $denied) | Should -BeFalse -Because "$($row.Name) is an information row"
        }
    }

    It 'resolves all four new labels in both languages, ASCII only and at most 45 characters' {
        foreach ($key in @('DefenderStatusInfo', 'SecureBootTpmStatus', 'LocalAdministrators', 'SecurityPostureInfo')) {
            foreach ($lang in 'EN', 'TR') {
                $script:Translations[$lang].ContainsKey($key) | Should -BeTrue -Because "$lang needs '$key'"
                $value = [string]$script:Translations[$lang][$key]
                $value.Length | Should -BeLessOrEqual 45 -Because "$lang '$key' must not be truncated in the panel"
                ($value -cmatch '[^\x00-\x7F]') | Should -BeFalse -Because "$lang '$key' must be ASCII-folded"
            }
        }
    }

    It 'renders the Defender row in Turkish too' {
        $script:Language = 'TR'
        $script:MpStatus = New-FakeDefenderStatus
        $lines = @(Get-WtDefenderStatusLines -GetStatus { $script:MpStatus })
        ($lines -join "`n") | Should -Match 'Gercek zamanli koruma'
        ($lines -join "`n") | Should -Match 'Acik'
    }

    It 'uses no Get-WmiObject and no Win32_Product anywhere in the new functions' {
        $region = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/70-info/security.ps1') -Raw
        ($region -cmatch 'Get-WmiObject') | Should -BeFalse
        ($region -cmatch 'Win32_Product') | Should -BeFalse
    }
}
