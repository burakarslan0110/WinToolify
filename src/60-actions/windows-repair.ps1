# Windows Update reset, search index, WMI repository, power scheme defaults.
# Covered by: tests/ActionWindowsRepair.Tests.ps1

function Get-WtWindowsUpdateServicePlan {
    <#
    .SYNOPSIS
        PURE: the five services a Windows Update reset has to stop, each
        resolved to StartMode / State through an injectable Win32_Service
        lookup. The returned order is the STOP order; the caller walks it
        backwards to restart, so CryptSvc (catroot2's owner) is up again
        before wuauserv asks it to verify a catalog signature. msiserver
        is deliberately excluded: only UsoSvc and DoSvc actually hold
        handles inside SoftwareDistribution.
    #>
    param(
        [string[]]$Names = @('wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'CryptSvc'),

        [scriptblock]$GetServiceInfo = {
            param($Name)
            Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
        }
    )
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Names) {
        $info = $null
        try { $info = & $GetServiceInfo $name }
        catch { $info = $null }
        $startMode = if ($info) { [string]$info.StartMode } else { '' }
        $state = if ($info) { [string]$info.State } else { '' }
        $plan.Add([PSCustomObject]@{
                Name      = [string]$name
                StartMode = $startMode
                State     = $state
                Missing   = ($null -eq $info)
                Disabled  = [string]::Equals($startMode, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)
                Running   = [string]::Equals($state, 'Running', [System.StringComparison]::OrdinalIgnoreCase)
            })
    }
    return $plan.ToArray()
}

function Invoke-WtResetWindowsUpdateComponentsAction {
    <#
    .SYNOPSIS
        Rebuilds Windows Update's own state: stop the five services, move
        SoftwareDistribution and catroot2 aside under a timestamped name,
        start the services again and - only once every one of them
        reports Running - delete the two renamed trees. Refuses the
        whole reset if any of the five is Disabled, since Start-Service
        on a disabled service throws. This row is Captured, so the
        consequence gate is called explicitly here; that is safe even
        inside Invoke-WtCapturedAction's pipeline because
        Confirm-WtDestructiveAction asks through its own painted panel
        modal, not a bare Read-Host on the captured stream.
    #>
    param(
        [scriptblock]$ConfirmAction = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines
        },

        [scriptblock]$GetPlan = { Get-WtWindowsUpdateServicePlan },

        [scriptblock]$StopServiceAction = { param($Name) Stop-Service -Name $Name -Force -ErrorAction Stop },

        [scriptblock]$StartServiceAction = { param($Name) Start-Service -Name $Name -ErrorAction Stop },

        [scriptblock]$GetServiceRunning = {
            param($Name)
            $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
            return ($null -ne $svc -and [string]::Equals([string]$svc.State, 'Running', [System.StringComparison]::OrdinalIgnoreCase))
        },

        [scriptblock]$TestPathAction = { param($Path) Test-Path -LiteralPath $Path },

        [scriptblock]$RenamePathAction = { param($Path, $NewName) Rename-Item -LiteralPath $Path -NewName $NewName -Force -ErrorAction Stop },

        [scriptblock]$RemovePathAction = { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop },

        [string]$SystemRoot = $env:SystemRoot,

        [string]$Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    )

    $gateLines = [string[]]@((Get-Translation 'WuResetGateLine1'), (Get-Translation 'WuResetGateLine2'))
    if (-not (& $ConfirmAction (Get-Translation 'WuResetConsequence') $gateLines)) {
        Write-Host (Get-Translation 'ActionCancelled') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'WuResetStarting')

    $plan = @(& $GetPlan)

    $disabled = @($plan | Where-Object { $_.Disabled })
    if ($disabled.Count -gt 0) {
        foreach ($svc in $disabled) { Write-Host ((Get-Translation 'WuResetServiceDisabled') -f $svc.Name) -ForegroundColor Red }
        Write-Host (Get-Translation 'WuResetAbortedDisabled') -ForegroundColor Yellow
        return
    }

    foreach ($svc in $plan) {
        if ($svc.Missing) {
            Write-Host ((Get-Translation 'WuResetServiceMissing') -f $svc.Name) -ForegroundColor Yellow
            continue
        }
        Write-Host ((Get-Translation 'WuResetStopping') -f $svc.Name)
        try { & $StopServiceAction $svc.Name }
        catch { Write-Host ((Get-Translation 'WuResetStopFailed') -f $svc.Name, $_.Exception.Message) -ForegroundColor Red }
    }

    $renamed = New-Object System.Collections.Generic.List[string]
    $targets = @(
        (Join-Path $SystemRoot 'SoftwareDistribution')
        (Join-Path (Join-Path $SystemRoot 'System32') 'catroot2')
    )
    foreach ($path in $targets) {
        if (-not (& $TestPathAction $path)) {
            Write-Host ((Get-Translation 'WuResetMissingFolder') -f $path) -ForegroundColor Yellow
            continue
        }
        $newName = '{0}.{1}.bak' -f (Split-Path -Path $path -Leaf), $Stamp
        try {
            & $RenamePathAction $path $newName
            $renamed.Add((Join-Path (Split-Path -Path $path -Parent) $newName))
            Write-Host ((Get-Translation 'WuResetRenamed') -f $path, $newName) -ForegroundColor Green
        }
        catch { Write-Host ((Get-Translation 'WuResetRenameFailed') -f $path, $_.Exception.Message) -ForegroundColor Red }
    }

    $allRunning = $true
    for ($i = $plan.Count - 1; $i -ge 0; $i--) {
        $svc = $plan[$i]
        if ($svc.Missing) { continue }
        Write-Host ((Get-Translation 'WuResetStartingService') -f $svc.Name)
        try { & $StartServiceAction $svc.Name }
        catch { Write-Host ((Get-Translation 'WuResetStartFailed') -f $svc.Name, $_.Exception.Message) -ForegroundColor Red }
        if (-not (& $GetServiceRunning $svc.Name)) {
            $allRunning = $false
            Write-Host ((Get-Translation 'WuResetNotRunning') -f $svc.Name) -ForegroundColor Red
        }
    }

    if (-not $allRunning) {
        Write-Host (Get-Translation 'WuResetKeepingBackups') -ForegroundColor Yellow
        return
    }

    foreach ($backup in $renamed) {
        try {
            & $RemovePathAction $backup
            Write-Host ((Get-Translation 'WuResetDeletedBackup') -f $backup) -ForegroundColor Green
        }
        catch { Write-Host ((Get-Translation 'WuResetDeleteFailed') -f $backup, $_.Exception.Message) -ForegroundColor Red }
    }
    Write-Host (Get-Translation 'WuResetDone') -ForegroundColor Green
}

function Invoke-WtRebuildSearchIndexAction {
    <#
    .SYNOPSIS
        Throws the Windows Search catalog away and lets the service build
        it again: WSearch stopped, SetupCompletedSuccessfully set to 0,
        WSearch started. SetupCompletedSuccessfully is self-clearing -
        Windows Search sets it back to 1 once the rebuild finishes - so
        no undo record is written for it; only a service that fails to
        restart leaves it at 0, which the action then resets by hand.
    #>
    param(
        [scriptblock]$GetServiceInfo = {
            param($Name)
            Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
        },

        [scriptblock]$StopServiceAction = { param($Name) Stop-Service -Name $Name -Force -ErrorAction Stop },

        [scriptblock]$StartServiceAction = { param($Name) Start-Service -Name $Name -ErrorAction Stop },

        [scriptblock]$SetSetupFlagAction = {
            param($Value)
            Set-WtRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name 'SetupCompletedSuccessfully' -RegType 'DWord' -Value $Value
        }
    )

    Write-Host (Get-Translation 'SearchIndexStarting')

    $info = $null
    try { $info = & $GetServiceInfo 'WSearch' }
    catch { $info = $null }

    if ($null -eq $info) {
        Write-Host (Get-Translation 'SearchIndexServiceMissing') -ForegroundColor Yellow
        return
    }
    if ([string]::Equals([string]$info.StartMode, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host (Get-Translation 'SearchIndexServiceDisabled') -ForegroundColor Red
        return
    }

    try { & $StopServiceAction 'WSearch' }
    catch {
        Write-Host ((Get-Translation 'SearchIndexStopFailed') -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    & $SetSetupFlagAction 0
    Write-Host (Get-Translation 'SearchIndexFlagSet') -ForegroundColor Green
    Write-Host (Get-Translation 'SearchIndexNoUndoRecord')

    try { & $StartServiceAction 'WSearch' }
    catch {
        Write-Host ((Get-Translation 'SearchIndexStartFailed') -f $_.Exception.Message) -ForegroundColor Red
        & $SetSetupFlagAction 1
        Write-Host (Get-Translation 'SearchIndexFlagRolledBack') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'SearchIndexRestarted') -ForegroundColor Green
    Write-Host (Get-Translation 'SearchIndexCost') -ForegroundColor Yellow
}

function Get-WtWmiRepositoryVerdict {
    <#
    .SYNOPSIS
        PURE: winmgmt /verifyrepository's exit code plus its output ->
        one of 'Consistent' / 'Inconsistent' / 'CheckFailed'. Exit code 1
        is ambiguous - inconsistent OR the check itself could not run (a
        denied WMI connect also returns 1, with 0x80041003 in the text) -
        so the verdict is decided by matching that hex token with
        -cmatch, never a culture-aware match tr-TR could bend.
    #>
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Output = @()
    )
    if ($ExitCode -eq 0) { return 'Consistent' }
    foreach ($line in @($Output)) {
        if ([string]$line -cmatch '0x[0-9A-Fa-f]{8}') { return 'CheckFailed' }
    }
    if ($ExitCode -ne 1) { return 'CheckFailed' }
    return 'Inconsistent'
}

function Invoke-WtRepairWmiRepositoryAction {
    <#
    .SYNOPSIS
        winmgmt /verifyrepository, its output printed verbatim (Windows'
        own localized text, so a user who searches that exact line
        online finds the same string Microsoft prints) and - only on a
        real inconsistency and behind a typed gate - winmgmt
        /salvagerepository. This row is Captured, so the gate is opened
        explicitly here; that is safe because Confirm-WtDestructiveAction
        asks through its own painted panel modal, not a bare Read-Host on
        the captured stream. /resetrepository is deliberately out of
        scope: it rebuilds the repository from the MOF files and loses
        every third-party class.
    #>
    param(
        [scriptblock]$WinmgmtAction = {
            param($Arguments)
            $out = & winmgmt.exe @Arguments 2>&1
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
        },

        [scriptblock]$ConfirmAction = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines
        }
    )

    Write-Host (Get-Translation 'WmiRepairVerifying')

    $verify = & $WinmgmtAction ([string[]]@('/verifyrepository'))
    foreach ($line in @($verify.Output)) { Write-Host ([string]$line) }

    $verdict = Get-WtWmiRepositoryVerdict -ExitCode ([int]$verify.ExitCode) -Output ([string[]]@($verify.Output))
    if ($verdict -ceq 'Consistent') {
        Write-Host (Get-Translation 'WmiRepairConsistent') -ForegroundColor Green
        return
    }
    if ($verdict -ceq 'CheckFailed') {
        Write-Host (Get-Translation 'WmiRepairCheckFailed') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'WmiRepairInconsistent') -ForegroundColor Red
    $gateLines = [string[]]@((Get-Translation 'WmiRepairGateLine'))
    if (-not (& $ConfirmAction (Get-Translation 'WmiRepairConsequence') $gateLines)) {
        Write-Host (Get-Translation 'ActionCancelled') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'WmiRepairSalvaging')
    $salvage = & $WinmgmtAction ([string[]]@('/salvagerepository'))
    foreach ($line in @($salvage.Output)) { Write-Host ([string]$line) }
    if ([int]$salvage.ExitCode -eq 0) {
        Write-Host (Get-Translation 'WmiRepairSalvageOk') -ForegroundColor Green
    }
    else {
        Write-Host ((Get-Translation 'WmiRepairSalvageFailed') -f ([int]$salvage.ExitCode)) -ForegroundColor Red
    }
}

function Invoke-WtRestorePowerSchemeDefaultsAction {
    <#
    .SYNOPSIS
        powercfg -restoredefaultschemes behind a typed gate: deletes every
        scheme Windows did not ship (Ultimate Performance included) and
        resets processor/core-parking settings to shipped values, then
        reads the plan list back with "powercfg /list" (never /query,
        which wants a scheme GUID). This row is Captured, so the gate is
        opened explicitly here - safe because Confirm-WtDestructiveAction
        asks through its own painted panel modal, not a bare Read-Host.
        Afterwards the PowerPlan undo entries are retired and the count
        printed, since a record that silently stops being offered is a
        lie the Undo screen must not tell.
    #>
    param(
        [scriptblock]$ConfirmAction = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines
        },

        [scriptblock]$PowercfgAction,

        [scriptblock]$RetireUndoAction = {
            param($ActionNames, $RetiredBy)
            Set-WtUndoEntryRetired -ActionNames $ActionNames -RetiredBy $RetiredBy
        }
    )
    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $gateLines = [string[]]@((Get-Translation 'PowerRestoreGateLine1'), (Get-Translation 'PowerRestoreGateLine2'))
    if (-not (& $ConfirmAction (Get-Translation 'PowerRestoreConsequence') $gateLines)) {
        Write-Host (Get-Translation 'ActionCancelled') -ForegroundColor Yellow
        return
    }

    Write-Host (Get-Translation 'PowerRestoreStarting')

    $restore = Invoke-WtPowercfg -Arguments ([string[]]@('-restoredefaultschemes')) @actionArgs
    foreach ($line in @($restore.Output)) { Write-Host ([string]$line) }
    if ([int]$restore.ExitCode -ne 0) {
        Write-Host ((Get-Translation 'PowerRestoreFailed') -f ([int]$restore.ExitCode)) -ForegroundColor Red
        return
    }

    $list = Invoke-WtPowercfg -Arguments ([string[]]@('/list')) @actionArgs
    Write-Host (Get-Translation 'PowerRestoreSchemesHeader')
    foreach ($line in @($list.Output)) { Write-Host ([string]$line) }

    $retired = [int](& $RetireUndoAction @('Apply Power Plan Settings', 'Revert Power Plan Settings') 'RestorePowerSchemeDefaults')
    if ($retired -gt 0) {
        Write-Host ((Get-Translation 'PowerRestoreRetired') -f $retired) -ForegroundColor Yellow
    }
    else {
        Write-Host (Get-Translation 'PowerRestoreRetiredNone')
    }

    Write-Host (Get-Translation 'PowerRestoreDone') -ForegroundColor Green
}
