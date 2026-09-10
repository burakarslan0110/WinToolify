# Store updates, winget upgrade, uninstall programs, Store repair. The Visual
# C++ runtime installer lives in vcredist.ps1.
# Covered by: tests/ActionSoftware.Tests.ps1


function Invoke-WtStoreUpdatesAction {
    if (Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue) { Start-Process 'ms-windows-store://downloadsandupdates' }
    else { Write-Host (Get-Translation 'StoreNotAvailable') -ForegroundColor Yellow }
}

function Invoke-WtWingetUpgradeAction {
    $null = Test-WingetInstalled
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements
    }
    else { Write-Host (Get-Translation 'WingetInstallError') -ForegroundColor Red }
}

function ConvertTo-WtWingetExitCode {
    <#
    .SYNOPSIS
        winget's documented result codes (0x8A15....) are UNSIGNED, but
        $LASTEXITCODE is a signed Int32, and in Windows PowerShell 5.1 an
        eight-digit hex literal like 0x8A15002B parses as that SAME
        negative Int32 - so casting either straight to [uint32] throws an
        OverflowException instead of producing the documented value. This
        reinterprets $LASTEXITCODE's 32 bits as a UInt32 through
        BitConverter instead, returning $null when no exit code was
        captured. Never cast a 0x8A15.... literal to [uint32] directly;
        go through this function, or [Convert]::ToUInt32(hex, 16).
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$ExitCode)
    if ($null -eq $ExitCode) { return $null }
    $bytes = [System.BitConverter]::GetBytes([int]$ExitCode)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function Get-WtWingetUpgradeArguments {
    <#
    .SYNOPSIS
        The winget argument list for a SINGLE package upgrade, built as an
        array so nothing the user typed is ever re-parsed as script.
        --silent and --disable-interactivity are required, not optional:
        without them an installer UI or a source-agreement question
        blocks forever inside Invoke-WtCapturedAction, which has no
        cancel key, and the two --accept-* flags turn an unaccepted
        agreement into a hard failure instead of a prompt. The retry pass
        uses --name and deliberately drops --exact.
    #>
    param(
        [Parameter(Mandatory)][string]$Package,
        [switch]$ByName
    )
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add('upgrade')
    if ($ByName) {
        $list.Add('--name')
        $list.Add($Package)
    }
    else {
        $list.Add('--id')
        $list.Add($Package)
        $list.Add('--exact')
    }
    $list.Add('--include-unknown')
    $list.Add('--silent')
    $list.Add('--disable-interactivity')
    $list.Add('--accept-source-agreements')
    $list.Add('--accept-package-agreements')
    return [string[]]$list.ToArray()
}

function Test-WtWingetShouldRetryByName {
    <#
    .SYNOPSIS
        True only for APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
        (0x8A150014) - the code winget returns when --id --exact matched
        nothing, which is exactly when a --name retry can still help.
        Everything else is final. Goes through ConvertTo-WtWingetExitCode,
        since $LASTEXITCODE is signed.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$ExitCode)
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) { return $false }
    return ($code -eq [Convert]::ToUInt32('8A150014', 16))
}

function Get-WtWingetUpgradeResultLines {
    <#
    .SYNOPSIS
        The one-line verdict for a single-package winget run. Pure, so
        the signed/unsigned exit-code handling is testable without
        winget. 0x8A15002B = already current, 0x8A150014 = no match;
        anything else prints as the UNSIGNED hex code, since a negative
        decimal cannot be looked up in Microsoft's table.
    #>
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][AllowNull()][object]$ExitCode
    )
    $code = ConvertTo-WtWingetExitCode -ExitCode $ExitCode
    if ($null -eq $code) {
        return [string[]]@((Get-Translation 'WingetSingleFailed') -f $Package, '????????')
    }
    if ($code -eq [uint32]0) {
        return [string[]]@((Get-Translation 'WingetSingleDone') -f $Package)
    }
    if ($code -eq [Convert]::ToUInt32('8A15002B', 16)) {
        return [string[]]@((Get-Translation 'WingetSingleUpToDate') -f $Package)
    }
    if ($code -eq [Convert]::ToUInt32('8A150014', 16)) {
        return [string[]]@((Get-Translation 'WingetSingleNotFound') -f $Package)
    }
    if ($code -eq [Convert]::ToUInt32('8A15007D', 16)) {
        return [string[]]@((Get-Translation 'WsResultAdminContext') -f $Package)
    }
    return [string[]]@((Get-Translation 'WingetSingleFailed') -f $Package, ('{0:X8}' -f $code))
}

function Invoke-WtWingetUpgradeSinglePackageAction {
    <#
    .SYNOPSIS
        Updates ONE named package instead of everything - the row for a
        metered link or a version-pinned application. Inline, not
        Captured: the id is asked with Read-WtPanelAnswer BEFORE
        Invoke-WtCapturedAction is entered, since a Read-Host behind the
        capture deadlocks. winget presence goes through
        Test-WingetInstalled (which bootstraps App Installer on LTSC),
        never a bare Get-Command. Its captured scriptblocks copy their
        arguments into locals first, since GetNewClosure breaks once
        this file runs unsourced. The args used for the last attempt are
        kept in a variable, not rebuilt, so a de-elevated retry repeats
        the pass that was actually refused.
    #>
    param(
        [scriptblock]$AskPackage = {
            Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb `
                -Lines @((Get-Translation 'WingetSingleHint')) `
                -Prompt (Get-Translation 'WingetSinglePrompt')
        },
        [scriptblock]$EnsureWinget = {
            $null = Test-WingetInstalled
            [bool](Get-Command winget -ErrorAction SilentlyContinue)
        },
        [scriptblock]$RunWinget = {
            param($Arguments, $Notice, $Crumb)
            $wtArgs = $Arguments
            $wtNotice = $Notice
            $script:WtWingetExitCode = $null
            Invoke-WtCapturedAction -Title (Get-Translation 'WingetUpgradeSinglePackage') `
                -Breadcrumb $Crumb -Encoding ([System.Text.Encoding]::UTF8) -Action {
                    Write-Host $wtNotice
                    & winget @wtArgs
                    $script:WtWingetExitCode = $LASTEXITCODE
                }
            return $script:WtWingetExitCode
        },
        [scriptblock]$RunAsUser = {
            param($Arguments, $Notice, $Crumb)
            Show-WtPanelMessage -Breadcrumb $Crumb -Lines @($Notice) -FooterText '' | Out-Null
            return (Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments ([string[]]@($Arguments)))
        },
        [scriptblock]$Show = {
            param($Lines)
            Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null
        }
    )
    $entered = ([string](& $AskPackage)).Trim()
    if (-not $entered) { return }
    if (-not (& $EnsureWinget)) {
        & $Show @((Get-Translation 'WingetInstallError'))
        return
    }
    $crumb = $script:WtPanelBreadcrumb
    $package = $entered
    $wingetArgs = Get-WtWingetUpgradeArguments -Package $package
    $code = & $RunWinget $wingetArgs ((Get-Translation 'WingetSingleRunning') -f $package) $crumb
    if (Test-WtWingetShouldRetryByName -ExitCode $code) {
        $wingetArgs = Get-WtWingetUpgradeArguments -Package $package -ByName
        $code = & $RunWinget $wingetArgs ((Get-Translation 'WingetSingleRetry') -f $package) $crumb
    }
    $extraLines = [string[]]@()
    if (Test-WtWingetAdminContextProhibited -ExitCode $code) {
        $asUser = & $RunAsUser $wingetArgs (Get-Translation 'WsRetryAsUser') $crumb
        if ($asUser -and $asUser.Ran) {
            $code = $asUser.ExitCode
            $extraLines = [string[]]@($asUser.Lines)
        }
        else {
            $reason = if ($asUser) { [string]$asUser.Reason } else { '' }
            $extraLines = [string[]]@((Get-Translation (Get-WtRetryReasonKey -Reason $reason)))
        }
    }
    & $Show @($extraLines + @(Get-WtWingetUpgradeResultLines -Package $package -ExitCode $code))
}

function Get-WtUninstallRegistryRoots {
    <#
    .SYNOPSIS
        Every registry container that holds "Add or remove programs"
        entries: the 64-bit HKLM view, the 32-bit WOW6432Node view, and
        the INTERACTIVE user's two per-user containers reached through
        Registry::HKEY_USERS\<SID>. HKCU is deliberately NOT used, since
        under Start-Process -Verb RunAs it is the ELEVATING
        administrator's hive, not the hive of the person sitting at the
        machine whose per-user installs this row exists to find.
    #>
    param(
        [scriptblock]$GetUserSid = {
            $consoleUser = $null
            try { $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName }
            catch { return $null }
            if ([string]::IsNullOrWhiteSpace($consoleUser)) { return $null }

            $resolvedSid = $null
            try {
                $resolvedSid = (New-Object System.Security.Principal.NTAccount($consoleUser)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
            }
            catch { return $null }
            if ([string]::IsNullOrWhiteSpace($resolvedSid)) { return $null }

            if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$resolvedSid")) { return $null }
            return $resolvedSid
        }
    )
    $roots = New-Object 'System.Collections.Generic.List[object]'
    $roots.Add(@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; ScopeKey = 'UninstallScopeMachine' })
    $roots.Add(@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; ScopeKey = 'UninstallScopeMachine' })
    $sid = & $GetUserSid
    if (-not [string]::IsNullOrWhiteSpace([string]$sid)) {
        $roots.Add(@{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; ScopeKey = 'UninstallScopeUser' })
        $roots.Add(@{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; ScopeKey = 'UninstallScopeUser' })
    }
    return @($roots.ToArray())
}

function Test-WtUninstallUserHiveVisible {
    <#
    .SYNOPSIS
        Whether the interactive user's hive made it into the root list.
        When it did not, the selector has to SAY that only machine-wide
        programs are listed - silently showing a short list would be a lie.
    #>
    param([scriptblock]$GetRoots = { Get-WtUninstallRegistryRoots })
    foreach ($root in @(& $GetRoots)) {
        if ([string]::Equals([string]$root.ScopeKey, 'UninstallScopeUser', [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-WtInstalledProgramEntries {
    <#
    .SYNOPSIS
        The classic Win32 "Add or remove programs" list, read straight
        from the registry. NEVER Win32_Product: querying that class makes
        Windows Installer RECONFIGURE every MSI product on the machine -
        minutes of disk churn and a real chance of breaking an install.
        Keyed on PSChildName, since two vendors can ship the same
        DisplayName, deduplicated with an Ordinal comparer since tr-TR
        would otherwise fold I/i and collapse two distinct keys into one.
    #>
    param(
        [scriptblock]$GetRoots = { Get-WtUninstallRegistryRoots },
        [scriptblock]$GetEntries = {
            param($Path)
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            }
        }
    )
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $skipReleaseTypes = @('Security Update', 'Update', 'Hotfix', 'ServicePack')
    foreach ($root in @(& $GetRoots)) {
        $raws = @()
        try { $raws = @(& $GetEntries $root.Path) }
        catch { $raws = @() }
        foreach ($raw in $raws) {
            if (-not $raw) { continue }
            $key = [string]$raw.PSChildName
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $name = [string]$raw.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($raw.SystemComponent -eq 1) { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.ParentKeyName)) { continue }

            $releaseType = [string]$raw.ReleaseType
            $isUpdate = $false
            foreach ($skip in $skipReleaseTypes) {
                if ([string]::Equals($releaseType, $skip, [System.StringComparison]::OrdinalIgnoreCase)) { $isUpdate = $true; break }
            }
            if ($isUpdate) { continue }

            $uninstallString = [string]$raw.UninstallString
            $quietString = [string]$raw.QuietUninstallString
            if ([string]::IsNullOrWhiteSpace($uninstallString) -and [string]::IsNullOrWhiteSpace($quietString)) { continue }

            if (-not $seen.Add($key)) { continue }
            $out.Add([PSCustomObject]@{
                Key                  = $key
                DisplayName          = $name.Trim()
                DisplayVersion       = [string]$raw.DisplayVersion
                Publisher            = [string]$raw.Publisher
                UninstallString      = $uninstallString
                QuietUninstallString = $quietString
                ScopeKey             = [string]$root.ScopeKey
            })
        }
    }
    return @($out.ToArray() | Sort-Object -Property DisplayName)
}

function Get-WtUninstallCommand {
    <#
    .SYNOPSIS
        Turns one Add/Remove entry into a runnable, NON-interactive
        uninstall command: a product-GUID key becomes msiexec /x <guid>
        /qn /norestart, a QuietUninstallString is split into executable +
        arguments, and anything else returns Kind 'None' rather than the
        vendor's own uninstaller, which would open a UI this panel can
        neither show nor close. The GUID test uses -cmatch with both
        letter cases written into the character class, since a
        case-insensitive match folds I/i under tr-TR and could
        misclassify a key.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Entry)
    $key = [string]$Entry.Key
    if ($key -cmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        return @{ Kind = 'Msi'; FilePath = 'msiexec.exe'; Arguments = "/x $key /qn /norestart" }
    }
    $quiet = [string]$Entry.QuietUninstallString
    if (-not [string]::IsNullOrWhiteSpace($quiet)) {
        $quiet = $quiet.Trim()
        if ($quiet.StartsWith('"', [System.StringComparison]::Ordinal)) {
            $close = $quiet.IndexOf('"', 1)
            if ($close -gt 0) {
                return @{
                    Kind      = 'Quiet'
                    FilePath  = $quiet.Substring(1, $close - 1)
                    Arguments = $quiet.Substring($close + 1).Trim()
                }
            }
        }
        $exeAt = $quiet.IndexOf('.exe', [System.StringComparison]::OrdinalIgnoreCase)
        if ($exeAt -ge 0) {
            return @{
                Kind      = 'Quiet'
                FilePath  = $quiet.Substring(0, $exeAt + 4)
                Arguments = $quiet.Substring($exeAt + 4).Trim()
            }
        }
        $space = $quiet.IndexOf(' ')
        if ($space -lt 0) { return @{ Kind = 'Quiet'; FilePath = $quiet; Arguments = '' } }
        return @{
            Kind      = 'Quiet'
            FilePath  = $quiet.Substring(0, $space)
            Arguments = $quiet.Substring($space + 1).Trim()
        }
    }
    return @{ Kind = 'None'; FilePath = ''; Arguments = '' }
}

function Get-WtUninstallProgramCatalog {
    <#
    .SYNOPSIS
        The Show-WtSelector catalog for the uninstall picker. Name is the
        PSChildName - DisplayName is not unique, two builds of the same
        product sit next to each other and only the key tells them apart.
        Risk is left empty on purpose: the selector's own ADVANCED gate
        would ask a second, vaguer question; the single gate for this row
        is the Confirm-WtDestructiveAction that names the chosen program.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries)
    $catalog = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Entries) {
        $label = [string]$entry.DisplayName
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.DisplayVersion)) { $label = $label + ' ' + [string]$entry.DisplayVersion }
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Publisher)) { $label = $label + ' - ' + [string]$entry.Publisher }
        $catalog.Add([PSCustomObject]@{
            Name         = [string]$entry.Key
            DisplayLabel = $label
            Risk         = ''
            Consequence  = ((Get-Translation 'UninstallConsequence') -f [string]$entry.DisplayName)
        })
    }
    return @($catalog.ToArray())
}

function Get-WtUninstallProgramStateItems {
    <#
    .SYNOPSIS
        The live-state column for the uninstall picker: which hive the
        program lives in, and whether it can be removed without a UI.
        A program with no silent command is shown but NOT selectable -
        listing it and then failing would be worse than saying up front
        that this panel cannot drive its uninstaller.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries)
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Entries) {
        $command = Get-WtUninstallCommand -Entry $entry
        $silent = -not [string]::Equals([string]$command.Kind, 'None', [System.StringComparison]::Ordinal)
        $items.Add([PSCustomObject]@{
            Name       = [string]$entry.Key
            Selectable = $silent
            StateLabel = $(if ($silent) { Get-Translation ([string]$entry.ScopeKey) } else { Get-Translation 'UninstallNoSilentState' })
        })
    }
    return @($items.ToArray())
}

function Invoke-WtUninstallProgramAction {
    <#
    .SYNOPSIS
        Lists the classic Win32 programs and removes the one the user
        picks. Inline: the picker and the typed gate both run BEFORE
        Invoke-WtCapturedAction is entered, since a prompt behind the
        capture deadlocks. Show-WtSelector is MULTI-select, so only the
        FIRST confirmed name is honoured. While the vendor uninstaller
        runs, a periodic heartbeat line doubles as the repaint trigger,
        since it can run for minutes with no output and a silent box
        reads as a crash.
    #>
    param(
        [scriptblock]$GetEntries = { Get-WtInstalledProgramEntries },
        [scriptblock]$GetUserHiveVisible = { Test-WtUninstallUserHiveVisible },
        [scriptblock]$Select = {
            param($Catalog, $StateItems, $Crumb, $InfoLines)
            Show-WtSelector -Catalog $Catalog -StateItems $StateItems -Title $Crumb `
                -UnselectableNote '' -InfoLines $InfoLines
        },
        [scriptblock]$Confirm = {
            param($Consequence, $Lines, $Crumb)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines -Breadcrumb $Crumb
        },
        [scriptblock]$RunUninstall = {
            param($Command, $ProgramName, $Crumb)
            $wtFile = [string]$Command.FilePath
            $wtArguments = [string]$Command.Arguments
            $wtName = [string]$ProgramName
            $script:WtUninstallExitCode = $null
            Invoke-WtCapturedAction -Title (Get-Translation 'UninstallProgram') -Breadcrumb $Crumb -Action {
                Write-Host ((Get-Translation 'UninstallStarting') -f $wtName)
                $startParams = @{ FilePath = $wtFile; PassThru = $true; ErrorAction = 'Stop' }
                if (-not [string]::IsNullOrWhiteSpace($wtArguments)) { $startParams['ArgumentList'] = $wtArguments }
                $proc = Start-Process @startParams
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not $proc.HasExited) {
                    Start-Sleep -Seconds 2
                    Write-Host ((Get-Translation 'UninstallWaiting') -f ([int]$watch.Elapsed.TotalSeconds))
                }
                $watch.Stop()
                $script:WtUninstallExitCode = $proc.ExitCode
            }
            return $script:WtUninstallExitCode
        },
        [scriptblock]$Show = { param($Lines) Wait-WtEnter -Lines @($Lines) }
    )
    $crumb = $script:WtPanelBreadcrumb
    $entries = @(& $GetEntries)
    if ($entries.Count -eq 0) {
        & $Show @((Get-Translation 'UninstallNoPrograms'))
        return
    }
    $infoLines = @()
    if (-not (& $GetUserHiveVisible)) { $infoLines = @((Get-Translation 'UninstallUserHiveMissing')) }

    $catalog = @(Get-WtUninstallProgramCatalog -Entries $entries)
    $stateItems = @(Get-WtUninstallProgramStateItems -Entries $entries)
    $picked = @(& $Select $catalog $stateItems $crumb $infoLines)
    if ($picked.Count -eq 0) {
        & $Show @((Get-Translation 'UninstallCancelled'))
        return
    }
    $key = [string]$picked[0]
    $entry = $entries | Where-Object { [string]::Equals([string]$_.Key, $key, [System.StringComparison]::Ordinal) } | Select-Object -First 1
    if (-not $entry) {
        & $Show @((Get-Translation 'UninstallCancelled'))
        return
    }
    $command = Get-WtUninstallCommand -Entry $entry
    if ([string]::Equals([string]$command.Kind, 'None', [System.StringComparison]::Ordinal)) {
        & $Show @(((Get-Translation 'UninstallNoSilentCommand') -f [string]$entry.DisplayName))
        return
    }
    $consequence = (Get-Translation 'UninstallConsequence') -f [string]$entry.DisplayName
    $detail = @((('{0} {1}' -f [string]$command.FilePath, [string]$command.Arguments)).Trim())
    if (-not (& $Confirm $consequence $detail $crumb)) {
        & $Show @((Get-Translation 'UninstallCancelled'))
        return
    }
    $code = & $RunUninstall $command ([string]$entry.DisplayName) $crumb
    $ok = ($null -ne $code) -and (@(0, 3010) -contains [int]$code)
    if ($ok) { & $Show @(((Get-Translation 'UninstallDone') -f [string]$entry.DisplayName, [string]$code)) }
    else { & $Show @(((Get-Translation 'UninstallFailed') -f [string]$entry.DisplayName, [string]$code)) }
}

function Get-WtResetStoreCacheLines {
    <#
    .SYNOPSIS
        Clears the Microsoft Store cache - the fix for a Store that shows
        a blank page or loops on "Try again". WSReset.exe is started
        WITHOUT -Wait on purpose: it keeps its own window open until the
        Store front-end comes up, so -Wait would hold the panel hostage
        for as long as that window stays on screen; this row returns in
        milliseconds and SAYS it started something in the background
        rather than pretending to have finished. The Store package is
        probed first, since this application's own bloatware screen can
        have removed it.
    #>
    param(
        [scriptblock]$GetStorePackage = { Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue },
        [string]$WsResetPath = '',
        [scriptblock]$TestWsReset = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf },
        [scriptblock]$StartWsReset = { param($Path) Start-Process -FilePath $Path | Out-Null }
    )
    if ([string]::IsNullOrWhiteSpace($WsResetPath)) {
        $WsResetPath = Join-Path $env:SystemRoot 'System32\WSReset.exe'
    }
    $store = $null
    try { $store = & $GetStorePackage }
    catch { $store = $null }
    if (-not $store) { return [string[]]@((Get-Translation 'StoreCacheNoStore')) }
    if (-not (& $TestWsReset $WsResetPath)) { return [string[]]@((Get-Translation 'StoreCacheNoWsReset')) }
    try { & $StartWsReset $WsResetPath }
    catch { return [string[]]@(((Get-Translation 'StoreCacheStartFailed') -f $_.Exception.Message)) }
    return [string[]]@(
        (Get-Translation 'StoreCacheStarted')
        (Get-Translation 'StoreCacheAccountNote')
    )
}

function Get-WtStoreRepairPackageNames {
    <#
    .SYNOPSIS
        EXACTLY two packages. The classic internet fix -
        "Get-AppxPackage -AllUsers | Add-AppxPackage -Register" over every
        package on the machine - is FORBIDDEN here: it would reinstate
        every bloatware package this application's own debloat screen
        removed.
    #>
    return [string[]]@('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller')
}

function Get-WtStoreRepairLines {
    <#
    .SYNOPSIS
        Re-registers the Store and App Installer packages - the fix for
        a vanished Store icon or a winget that stopped working. One OK /
        FAIL / not-installed line per PackageFullName; success is never
        reported silently. -AllUsers returns ONE OBJECT PER USER PROFILE
        for the same package, so results are de-duplicated on
        PackageFullName with an ordinal set before anything is
        registered.
    #>
    param(
        [scriptblock]$GetPackages = { param($Name) Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue },
        [scriptblock]$RegisterPackage = { param($ManifestPath) Add-AppxPackage -DisableDevelopmentMode -Register $ManifestPath -ErrorAction Stop }
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((Get-Translation 'StoreRepairHeader'))
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($name in (Get-WtStoreRepairPackageNames)) {
        $packages = @()
        try { $packages = @(& $GetPackages $name | Where-Object { $_ }) }
        catch { $packages = @() }
        if ($packages.Count -eq 0) {
            $lines.Add(((Get-Translation 'StoreRepairMissing') -f $name))
            continue
        }
        foreach ($package in $packages) {
            $full = [string]$package.PackageFullName
            if ([string]::IsNullOrWhiteSpace($full)) { continue }
            if (-not $seen.Add($full)) { continue }
            $location = [string]$package.InstallLocation
            if ([string]::IsNullOrWhiteSpace($location)) {
                $lines.Add(((Get-Translation 'StoreRepairFail') -f $full, (Get-Translation 'StoreRepairNoLocation')))
                continue
            }
            $manifest = Join-Path $location 'AppXManifest.xml'
            try {
                & $RegisterPackage $manifest
                $lines.Add(((Get-Translation 'StoreRepairOk') -f $full))
            }
            catch {
                $lines.Add(((Get-Translation 'StoreRepairFail') -f $full, $_.Exception.Message))
            }
        }
    }
    return [string[]]@($lines.ToArray())
}
