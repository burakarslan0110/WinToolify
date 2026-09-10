# Local users, Defender, Secure Boot/TPM, administrators, security posture.
# Covered by: tests/InfoSecurity.Tests.ps1

function Get-WtLocalUserTable {
    <#
    .SYNOPSIS
        Local accounts: Get-LocalUser when available (Windows PowerShell),
        the CIM Win32_UserAccount fallback under PowerShell 7 where the
        LocalAccounts module is not shipped.
    #>
    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
        return Get-LocalUser | Select-Object Name, Enabled, LastLogon
    }
    return Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | Select-Object Name, @{ Name = 'Enabled'; Expression = { -not $_.Disabled } }, SID
}

# --- Bilgiler > Guvenlik: ortak bicimlendirme --------------------------------

function Format-WtOnOffWord {
    <#
    .SYNOPSIS
        PURE: a boolean-ish value as the active language's On / Off /
        Unknown word. $null or empty is always Unknown, never Off -
        printing Off for "could not read this" is a lie the user acts on.
        String comparison is Ordinal on purpose: a culture-aware compare
        on a tr-TR host folds capital I to the dotless i, so "True" stops
        matching.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return [string](Get-Translation 'SecStateUnknown') }
    if ($Value -is [string]) {
        $text = ([string]$Value).Trim()
        if ($text.Length -eq 0) { return [string](Get-Translation 'SecStateUnknown') }
        if ([string]::Equals($text, 'True', [StringComparison]::Ordinal) -or [string]::Equals($text, '1', [StringComparison]::Ordinal)) { return [string](Get-Translation 'SecStateOn') }
        if ([string]::Equals($text, 'False', [StringComparison]::Ordinal) -or [string]::Equals($text, '0', [StringComparison]::Ordinal)) { return [string](Get-Translation 'SecStateOff') }
        return [string](Get-Translation 'SecStateUnknown')
    }
    if ([bool]$Value) { return [string](Get-Translation 'SecStateOn') }
    return [string](Get-Translation 'SecStateOff')
}

function Format-WtSecurityValueOrUnknown {
    <#
    .SYNOPSIS
        PURE: a value as text, or the Unknown word when it is $null or
        blank. Keeps "Firmware type: " out of the panel.
    #>
    param([AllowNull()]$Value)
    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim() }
    if ($text.Length -eq 0) { return [string](Get-Translation 'SecStateUnknown') }
    return $text
}

function Format-WtSecurityTimestamp {
    <#
    .SYNOPSIS
        PURE: a scan/update timestamp as 'yyyy-MM-dd HH:mm:ss', or the
        Never word. Defender hands back $null for a scan that never ran
        and 1601-01-01 (the FILETIME zero) on some platform versions -
        both mean "never", and neither may reach the panel raw.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return [string](Get-Translation 'SecStateNever') }
    $when = $null
    try { $when = [datetime]$Value }
    catch { return [string](Get-Translation 'SecStateUnknown') }
    if ($when.Year -le 1601) { return [string](Get-Translation 'SecStateNever') }
    return $when.ToString('yyyy-MM-dd HH:mm:ss')
}

function Format-WtDefenderSignatureAge {
    <#
    .SYNOPSIS
        PURE: "N days (timestamp)" for a signature update time. Rounds
        (not floors) to the nearest whole day, away from zero, so a
        signature updated 2 days 23h ago reads "3 days".
    #>
    param(
        [AllowNull()]$LastUpdated,
        [datetime]$Now = (Get-Date)
    )
    if ($null -eq $LastUpdated) { return [string](Get-Translation 'SecStateUnknown') }
    $when = $null
    try { $when = [datetime]$LastUpdated }
    catch { return [string](Get-Translation 'SecStateUnknown') }
    $days = [int][math]::Round(($Now - $when).TotalDays, [MidpointRounding]::AwayFromZero)
    if ($days -lt 0) { $days = 0 }
    return ('{0} ({1})' -f ((Get-Translation 'DefenderSignatureAgeDays') -f $days), $when.ToString('yyyy-MM-dd HH:mm:ss'))
}

function Get-WtDefenderStatusLines {
    <#
    .SYNOPSIS
        PURE: Windows Defender's real-time protection, engine mode,
        signature age and last scans, as printable lines.
        Get-MpComputerStatus is called without a Get-Command guard on
        purpose: the module always resolves, but the CALL throws when
        WinDefend is stopped or another antivirus has taken over -
        exactly the machine this row exists for - and a Get-Command
        guard would report "available" and then blow up in the panel.
    #>
    param(
        [scriptblock]$GetStatus = { Get-MpComputerStatus -ErrorAction Stop },
        [datetime]$Now = (Get-Date)
    )

    $status = $null
    try { $status = & $GetStatus }
    catch { $status = $null }
    if ($null -eq $status) { return [string[]]@([string](Get-Translation 'DefenderStatusUnavailable')) }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderRealTimeProtection'), (Format-WtOnOffWord -Value $status.RealTimeProtectionEnabled)))
    if ($status.PSObject.Properties['AMRunningMode']) {
        $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderRunningMode'), (Format-WtSecurityValueOrUnknown -Value $status.AMRunningMode)))
    }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderAntivirusEnabled'), (Format-WtOnOffWord -Value $status.AntivirusEnabled)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderBehaviorMonitor'), (Format-WtOnOffWord -Value $status.BehaviorMonitorEnabled)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderTamperProtection'), (Format-WtOnOffWord -Value $status.IsTamperProtected)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderSignatureVersion'), (Format-WtSecurityValueOrUnknown -Value $status.AntivirusSignatureVersion)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderSignatureAge'), (Format-WtDefenderSignatureAge -LastUpdated $status.AntispywareSignatureLastUpdated -Now $Now)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderLastQuickScan'), (Format-WtSecurityTimestamp -Value $status.QuickScanEndTime)))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'DefenderLastFullScan'), (Format-WtSecurityTimestamp -Value $status.FullScanEndTime)))
    return [string[]]$lines.ToArray()
}

function Get-WtSecureBootTpmLines {
    <#
    .SYNOPSIS
        PURE: firmware type, Secure Boot, TPM presence + version and the
        system disk's partition style - the Windows 11 eligibility
        question in four lines. Confirm-SecureBootUEFI throws a different
        exception type depending on cause (legacy BIOS vs a non-elevated
        shell); the EXCEPTION TYPE decides which note is printed, never
        the message, since Windows localizes it. Every probe falls back
        to a WMI/registry read on failure, and an empty result prints
        Unknown rather than nothing.
    #>
    param(
        [scriptblock]$GetFirmwareType = { $env:firmware_type },
        [scriptblock]$GetSecureBoot = { Confirm-SecureBootUEFI -ErrorAction Stop },
        [scriptblock]$GetSecureBootRegistry = { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled },
        [scriptblock]$GetTpm = { Get-Tpm -ErrorAction Stop },
        [scriptblock]$GetTpmCim = { Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop },
        [scriptblock]$GetSystemDisk = { Get-Disk -ErrorAction Stop | Where-Object { $_.IsSystem } }
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $firmware = ''
    try { $firmware = [string](& $GetFirmwareType) }
    catch { $firmware = '' }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'SecureBootFirmwareType'), (Format-WtSecurityValueOrUnknown -Value $firmware)))

    $secureWord = $null
    $secureNote = $null
    try {
        $secureWord = Format-WtOnOffWord -Value (& $GetSecureBoot)
    }
    catch {
        $ex = $_.Exception
        if ($ex -is [System.PlatformNotSupportedException]) { $secureNote = [string](Get-Translation 'SecureBootNotSupported') }
        elseif ($ex -is [System.UnauthorizedAccessException]) { $secureNote = [string](Get-Translation 'SecureBootAccessDenied') }
        else { $secureNote = [string](Get-Translation 'SecureBootQueryFailed') }
        try {
            $raw = & $GetSecureBootRegistry
            if ($null -ne $raw) { $secureWord = Format-WtOnOffWord -Value ([int]$raw) }
        }
        catch { $null = $_ }
    }
    if ($secureWord -and $secureNote) { $lines.Add(('{0}: {1} ({2})' -f (Get-Translation 'SecureBootState'), $secureWord, $secureNote)) }
    elseif ($secureWord) { $lines.Add(('{0}: {1}' -f (Get-Translation 'SecureBootState'), $secureWord)) }
    else { $lines.Add(('{0}: {1}' -f (Get-Translation 'SecureBootState'), $secureNote)) }

    $tpmWord = $null
    try {
        $tpm = & $GetTpm
        if ($null -ne $tpm -and $null -ne $tpm.TpmPresent) {
            if ([bool]$tpm.TpmPresent) { $tpmWord = Format-WtOnOffWord -Value $tpm.TpmEnabled }
            else { $tpmWord = [string](Get-Translation 'TpmNotPresent') }
        }
    }
    catch { $tpmWord = $null }

    $tpmVersion = $null
    $cim = @()
    try { $cim = @(& $GetTpmCim) }
    catch { $cim = @() }
    if ($cim.Count -gt 0) {
        if ($null -eq $tpmWord) { $tpmWord = Format-WtOnOffWord -Value $cim[0].IsEnabled_InitialValue }
        $spec = [string]$cim[0].SpecVersion
        if ($spec) { $tpmVersion = $spec.Split(',')[0].Trim() }
    }
    if ($null -eq $tpmWord) { $tpmWord = [string](Get-Translation 'TpmNotAvailable') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'TpmStatusLabel'), $tpmWord))
    if ($tpmVersion) { $lines.Add(('{0}: {1}' -f (Get-Translation 'TpmVersionLabel'), $tpmVersion)) }

    $style = $null
    try {
        $disks = @(& $GetSystemDisk)
        if ($disks.Count -gt 0) { $style = [string]$disks[0].PartitionStyle }
    }
    catch { $style = $null }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'SystemDiskPartitionStyle'), (Format-WtSecurityValueOrUnknown -Value $style)))

    return [string[]]$lines.ToArray()
}

function Get-WtAdsiGroupMemberNames {
    <#
    .SYNOPSIS
        WinNT:// fallback for a local group whose membership
        Get-LocalGroupMember refuses to enumerate. The group is reached
        by translating its well-known SID to this machine's own account
        name, so the localized group name never has to be guessed. Path
        parsing uses -creplace, not -replace: the case-insensitive
        operator is culture-aware and folds the Turkish dotless I.
    #>
    param([Parameter(Mandatory)][string]$GroupSid)

    $sid = New-Object System.Security.Principal.SecurityIdentifier($GroupSid)
    $account = [string]$sid.Translate([System.Security.Principal.NTAccount]).Value
    $groupName = $account.Split([char]'\')[-1]
    $group = [ADSI]("WinNT://./$groupName,group")

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($member in @($group.Invoke('Members'))) {
        $path = [string]$member.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $member, $null)
        $class = [string]$member.GetType().InvokeMember('Class', 'GetProperty', $null, $member, $null)
        $trimmed = $path -creplace '^WinNT://', ''
        $result.Add([PSCustomObject]@{
                Name            = ($trimmed -creplace '/', '\')
                ObjectClass     = $class
                PrincipalSource = ''
            })
    }
    return $result.ToArray()
}

function Get-WtLocalAdministratorsLines {
    <#
    .SYNOPSIS
        PURE: exactly who holds administrator rights on this machine,
        Microsoft and domain accounts included. The group is addressed
        by its well-known SID, so the localized group name never
        matters. A documented Windows PowerShell 5.1 defect makes
        Get-LocalGroupMember throw instead of listing the rest when one
        member's SID no longer resolves (a deleted domain account); this
        falls back to the ADSI WinNT:// enumeration and the row says so.
    #>
    param(
        [scriptblock]$GetMembers = { Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop },
        [scriptblock]$GetFallbackMembers = { Get-WtAdsiGroupMemberNames -GroupSid 'S-1-5-32-544' }
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string](Get-Translation 'LocalAdminGroupHeader'))

    $members = $null
    $usedFallback = $false
    try { $members = @(& $GetMembers) }
    catch {
        $usedFallback = $true
        try { $members = @(& $GetFallbackMembers) }
        catch { $members = $null }
    }

    if ($null -eq $members -or $members.Count -eq 0) {
        if ($usedFallback) { $lines.Add([string](Get-Translation 'LocalAdminUnavailable')) }
        else { $lines.Add([string](Get-Translation 'LocalAdminNone')) }
        return [string[]]$lines.ToArray()
    }

    foreach ($member in $members) {
        $name = Format-WtSecurityValueOrUnknown -Value $member.Name
        $class = [string]$member.ObjectClass
        $source = [string]$member.PrincipalSource
        $classText = [string](Get-Translation ('LocalAdminObject.' + $class))
        if (-not $classText) { $classText = $class }
        $sourceText = [string](Get-Translation ('LocalAdminSource.' + $source))
        if (-not $sourceText) { $sourceText = $source }
        $tags = @(@($classText, $sourceText) | Where-Object { $_ })
        if ($tags.Count -gt 0) { $lines.Add(('  {0}  [{1}]' -f $name, ($tags -join ', '))) }
        else { $lines.Add(('  {0}' -f $name)) }
    }

    if ($usedFallback) { $lines.Add([string](Get-Translation 'LocalAdminFallbackNote')) }
    return [string[]]$lines.ToArray()
}

function Get-WtUacLevelKey {
    <#
    .SYNOPSIS
        PURE: the translation key naming the UAC slider position that
        EnableLUA + ConsentPromptBehaviorAdmin describe.
        PromptOnSecureDesktop only distinguishes the two middle slider
        positions (splitting Default from Do not dim) and is otherwise
        unused. A missing or unrecognised value returns SecStateUnknown
        rather than a guess, since the user reads this line to judge
        exposure.
    #>
    param(
        [AllowNull()]$EnableLua,
        [AllowNull()]$ConsentPromptBehaviorAdmin,
        [AllowNull()]$PromptOnSecureDesktop
    )

    if ($null -eq $EnableLua -or $null -eq $ConsentPromptBehaviorAdmin) { return 'SecStateUnknown' }
    if ([int]$EnableLua -eq 0) { return 'PostureUacDisabled' }

    $secureDesktop = if ($null -eq $PromptOnSecureDesktop) { 1 } else { [int]$PromptOnSecureDesktop }
    switch ([int]$ConsentPromptBehaviorAdmin) {
        0 { return 'PostureUacNeverNotify' }
        1 { return 'PostureUacCredentials' }
        2 { return 'PostureUacAlwaysNotify' }
        3 { return 'PostureUacCredentials' }
        4 { return 'PostureUacConsent' }
        5 {
            if ($secureDesktop -eq 0) { return 'PostureUacNoDim' }
            return 'PostureUacDefault'
        }
    }
    return 'SecStateUnknown'
}

function Get-WtSecurityPostureLines {
    <#
    .SYNOPSIS
        PURE: one answer to "how open is this machine" - UAC in words,
        Remote Desktop, WinRM and the local password policy. Every source
        is separately guarded since each one can be missing on a real
        machine. net accounts is printed verbatim and must NOT get an
        explicit -Encoding: it already arrives OEM-decoded through
        Invoke-WtCapturedAction, and forcing UTF-8 here turns Turkish
        text into question marks.
    #>
    param(
        [scriptblock]$GetUacPolicy = { Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop },
        [scriptblock]$GetTerminalServerPolicy = { Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop },
        [scriptblock]$GetRdpTcpPolicy = { Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop },
        [scriptblock]$GetRemoteDesktopUsers = { Get-LocalGroupMember -SID 'S-1-5-32-555' -ErrorAction Stop },
        [scriptblock]$GetWinrmService = { Get-Service -Name 'WinRM' -ErrorAction Stop },
        [scriptblock]$GetWinrmListeners = { Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction Stop },
        [scriptblock]$GetPasswordPolicy = { net accounts }
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add([string](Get-Translation 'PostureSectionUac'))
    $uac = $null
    try { $uac = & $GetUacPolicy }
    catch { $uac = $null }
    $uacKey = if ($null -eq $uac) { 'SecStateUnknown' } else { Get-WtUacLevelKey -EnableLua $uac.EnableLUA -ConsentPromptBehaviorAdmin $uac.ConsentPromptBehaviorAdmin -PromptOnSecureDesktop $uac.PromptOnSecureDesktop }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureUacLevel'), (Get-Translation $uacKey)))

    $lines.Add([string](Get-Translation 'PostureSectionRemote'))
    $deny = $null
    try { $deny = (& $GetTerminalServerPolicy).fDenyTSConnections }
    catch { $deny = $null }
    $rdpWord = if ($null -eq $deny) { [string](Get-Translation 'SecStateUnknown') }
    elseif ([int]$deny -eq 0) { [string](Get-Translation 'SecStateOn') }
    else { [string](Get-Translation 'SecStateOff') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureRdpLabel'), $rdpWord))

    $nla = $null
    try { $nla = (& $GetRdpTcpPolicy).UserAuthentication }
    catch { $nla = $null }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureRdpNla'), (Format-WtOnOffWord -Value $nla)))

    $rdpUsers = $null
    try { $rdpUsers = @(& $GetRemoteDesktopUsers) }
    catch { $rdpUsers = $null }
    $rdpUsersText = if ($null -eq $rdpUsers) { [string](Get-Translation 'SecStateUnknown') }
    elseif ($rdpUsers.Count -eq 0) { [string](Get-Translation 'PostureRdpUsersEmpty') }
    else { (@($rdpUsers | ForEach-Object { [string]$_.Name }) -join ', ') }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureRdpUsersLabel'), $rdpUsersText))

    $winrm = $null
    try { $winrm = & $GetWinrmService }
    catch { $winrm = $null }
    $winrmText = if ($null -eq $winrm) { [string](Get-Translation 'SecStateUnknown') } else { Format-WtServiceStateLabel -Status ([string]$winrm.Status) -StartType ([string]$winrm.StartType) }
    $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureWinrmLabel'), $winrmText))

    $listeners = $null
    try { $listeners = @(& $GetWinrmListeners) }
    catch { $listeners = $null }
    if ($null -eq $listeners -or $listeners.Count -eq 0) {
        $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureWinrmListeners'), (Get-Translation 'PostureWinrmNoListener')))
    }
    else {
        $lines.Add(('{0}: {1}' -f (Get-Translation 'PostureWinrmListeners'), $listeners.Count))
        foreach ($listener in $listeners) {
            $keys = @(@($listener.Keys) | Where-Object { $_ })
            if ($keys.Count -gt 0) { $lines.Add(('  {0}' -f ($keys -join ', '))) }
            else { $lines.Add(('  {0}' -f (Format-WtSecurityValueOrUnknown -Value $listener.Name))) }
        }
    }

    $lines.Add([string](Get-Translation 'PostureSectionPasswordPolicy'))
    $policy = $null
    try { $policy = @(& $GetPasswordPolicy) }
    catch { $policy = $null }
    $policyLines = @()
    if ($null -ne $policy) { $policyLines = @($policy | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_.Length -gt 0 }) }
    if ($policyLines.Count -eq 0) { $lines.Add([string](Get-Translation 'PosturePasswordPolicyUnavailable')) }
    else { foreach ($policyLine in $policyLines) { $lines.Add($policyLine) } }

    return [string[]]$lines.ToArray()
}

# --- Information > Software and startup --------------------------------
