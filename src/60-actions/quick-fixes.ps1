# Start menu repair, Explorer caches, audio services, hung processes.
# Covered by: tests/ActionQuickFixes.Tests.ps1

function Get-WtStartMenuPackageNames {
    <#
    .SYNOPSIS
        PURE: the Appx packages that make up the Start menu and its search
        surface - the documented repair for a Start button that does
        nothing. The whole package set is deliberately NOT re-registered:
        that takes minutes and touches apps unrelated to the fault.
    #>
    return [string[]]@(
        'Microsoft.Windows.ShellExperienceHost'
        'Microsoft.Windows.StartMenuExperienceHost'
        'Microsoft.Windows.Search'
        'Microsoft.Windows.Cortana'
        'Microsoft.UI.Xaml.CBS'
    )
}

function Select-WtStartMenuPackages {
    <#
    .SYNOPSIS
        PURE: from a Get-AppxPackage -AllUsers listing, the Start menu
        packages to re-register, deduplicated by PackageFullName (the same
        package returns once per profile). Matched OrdinalIgnoreCase, not
        culture-aware -eq, since tr-TR's dotless I changes the comparison.
        A package with no InstallLocation is KEPT with an empty
        ManifestPath so the repair reports it FAILED, not silently dropped.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Packages,
        [string[]]$Names = (Get-WtStartMenuPackageNames)
    )
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Packages)) {
        if (-not $package) { continue }
        $name = [string]$package.Name
        $wanted = $false
        foreach ($candidate in @($Names)) {
            if ([string]::Equals($name, [string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) { $wanted = $true; break }
        }
        if (-not $wanted) { continue }
        $full = [string]$package.PackageFullName
        if (-not $full) { continue }
        if (-not $seen.Add($full)) { continue }
        $location = [string]$package.InstallLocation
        $manifest = if ($location) { Join-Path $location 'AppxManifest.xml' } else { '' }
        $result.Add([PSCustomObject]@{ Name = $name; PackageFullName = $full; ManifestPath = $manifest })
    }
    return @($result.ToArray())
}

function Invoke-WtStartMenuRepair {
    <#
    .SYNOPSIS
        The Start-button-does-nothing repair: stops both shell host
        processes, re-registers the Start menu packages one by one, clears
        StartMenuExperienceHost's TempState, and stops the hosts once more
        so Windows rebuilds them. Hosts are stopped FIRST because Windows
        refuses to re-register a package whose own process is running
        (0x80073D02); a package still failing that way is retried once
        after Windows auto-restarts the host.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-AppxPackage -AllUsers and Add-AppxPackage -Register are Windows-only by design and absent from the static PS 7.0 profile; on Windows they resolve through the Appx module on both 5.1 and 7.')]
    param(
        [scriptblock]$GetPackages = {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Import-Module Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue
            }
            try { Get-AppxPackage -AllUsers -ErrorAction Stop }
            catch { Get-AppxPackage -ErrorAction SilentlyContinue }
        },
        [scriptblock]$TestManifest = { param($Path) Test-Path -LiteralPath $Path },
        [scriptblock]$RegisterPackage = { param($Path) Add-AppxPackage -Register $Path -DisableDevelopmentMode -ErrorAction Stop },
        [scriptblock]$ClearTempState = {
            $path = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState'
            if (-not (Test-Path -LiteralPath $path)) { return $false }
            Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            return $true
        },
        [scriptblock]$StopHosts = {
            $stopped = New-Object System.Collections.Generic.List[string]
            foreach ($hostName in @('StartMenuExperienceHost', 'ShellExperienceHost')) {
                $running = @(Get-Process -Name $hostName -ErrorAction SilentlyContinue)
                if ($running.Count -eq 0) { continue }
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                $stopped.Add($hostName)
            }
            return [string[]]$stopped.ToArray()
        },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'StartMenuRepairStart') 'Cyan'
    $packages = @(Select-WtStartMenuPackages -Packages @(& $GetPackages))
    if ($packages.Count -eq 0) {
        & $Write (Get-Translation 'StartMenuNoPackages') 'Yellow'
        return [PSCustomObject]@{ Registered = 0; Failed = 0; TempStateCleared = $false; StoppedHosts = [string[]]@() }
    }
    $stoppedHosts = New-Object System.Collections.Generic.List[string]
    $recordStopped = {
        foreach ($name in @(& $StopHosts)) { if (-not $stoppedHosts.Contains([string]$name)) { $stoppedHosts.Add([string]$name) } }
    }
    & $recordStopped
    $registered = 0
    $failed = 0
    foreach ($package in $packages) {
        if (-not $package.ManifestPath -or -not (& $TestManifest $package.ManifestPath)) {
            $failed++
            & $Write ('  {0}: {1} ({2})' -f $package.Name, (Get-Translation 'StartMenuPackageFailed'), (Get-Translation 'StartMenuManifestMissing')) 'Red'
            continue
        }
        $error1 = $null
        try { & $RegisterPackage $package.ManifestPath | Out-Null }
        catch { $error1 = $_.Exception.Message }
        if ($error1) {
            & $recordStopped
            try {
                & $RegisterPackage $package.ManifestPath | Out-Null
                $error1 = $null
            }
            catch { $error1 = $_.Exception.Message }
        }
        if ($error1) {
            $failed++
            & $Write ('  {0}: {1} ({2})' -f $package.Name, (Get-Translation 'StartMenuPackageFailed'), $error1) 'Red'
        }
        else {
            $registered++
            & $Write ('  {0}: {1}' -f $package.Name, (Get-Translation 'StartMenuPackageOk')) 'Green'
        }
    }
    $cleared = [bool](& $ClearTempState)
    & $Write $(if ($cleared) { Get-Translation 'StartMenuTempStateCleared' } else { Get-Translation 'StartMenuTempStateMissing' }) $(if ($cleared) { 'Green' } else { 'Yellow' })
    & $recordStopped
    $stopped = @($stoppedHosts.ToArray())
    if ($stopped.Count -gt 0) { & $Write ((Get-Translation 'StartMenuHostsStopped') + ' ' + ($stopped -join ', ')) 'Cyan' }
    else { & $Write (Get-Translation 'StartMenuHostsNotRunning') 'Yellow' }
    & $Write ((Get-Translation 'StartMenuRepairSummary') -f $registered, $failed) $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
    return [PSCustomObject]@{ Registered = $registered; Failed = $failed; TempStateCleared = $cleared; StoppedHosts = [string[]]$stopped }
}

function Get-WtExplorerCacheTargets {
    <#
    .SYNOPSIS
        PURE: the icon / thumbnail cache database globs, as directory +
        wildcard pairs, composed from an injected LOCALAPPDATA so the shape
        is testable. Two locations, not one: iconcache_*.db /
        thumbcache_*.db live under ...\Explorer, the legacy IconCache.db
        directly in LOCALAPPDATA; missing either leaves stale icons.
    #>
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    $explorer = Join-Path $LocalAppData 'Microsoft\Windows\Explorer'
    return @(
        [PSCustomObject]@{ Directory = $explorer; Filter = 'iconcache*.db' }
        [PSCustomObject]@{ Directory = $explorer; Filter = 'thumbcache*.db' }
        [PSCustomObject]@{ Directory = $LocalAppData; Filter = 'IconCache.db' }
    )
}

function Format-WtExplorerCacheLines {
    <#
    .SYNOPSIS
        PURE: the icon-cache report - how many databases went, how many
        bytes that freed, and the full path of every file the shell never
        released. The locked list is printed by name: "done" over a file
        that is still there is the one thing this row must not say.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'IconCacheDeleted'), [int]$Result.DeletedCount))
    $lines.Add(('{0}: {1}' -f (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes ([long]$Result.FreedBytes))))
    $locked = @($Result.Locked)
    if ($locked.Count -eq 0) {
        $lines.Add((Get-Translation 'IconCacheNoneLocked'))
    }
    else {
        $lines.Add((Get-Translation 'IconCacheStillLocked'))
        foreach ($path in $locked) { $lines.Add('  ' + [string]$path) }
    }
    return [string[]]$lines.ToArray()
}

function Remove-WtExplorerCacheFiles {
    <#
    .SYNOPSIS
        Deletes the icon / thumbnail cache databases with a BOUNDED retry
        loop: explorer.exe releases these files only a moment after
        exiting, so one pass deletes almost nothing. Stops at
        BudgetSeconds and reports what is still locked rather than hang.
    #>
    param(
        [array]$Targets = @(Get-WtExplorerCacheTargets),
        [double]$BudgetSeconds = 10,
        [scriptblock]$GetFiles = { param($Directory, $Filter) @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -Force -File -ErrorAction SilentlyContinue) },
        [scriptblock]$RemoveFile = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop },
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$Wait = { Start-Sleep -Milliseconds 500 }
    )
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($target in @($Targets)) {
        foreach ($file in @(& $GetFiles $target.Directory $target.Filter)) {
            if (-not $file) { continue }
            $length = [long]0
            try { $length = [long]$file.Length } catch { $length = [long]0 }
            $pending.Add([PSCustomObject]@{ Path = [string]$file.FullName; Length = $length })
        }
    }
    $deadline = (& $GetNow).AddSeconds($BudgetSeconds)
    $freed = [long]0
    $deleted = 0
    $remaining = $pending
    while ($remaining.Count -gt 0) {
        $still = New-Object System.Collections.Generic.List[object]
        foreach ($file in $remaining) {
            try {
                & $RemoveFile $file.Path | Out-Null
                $freed += [long]$file.Length
                $deleted++
            }
            catch { $still.Add($file) }
        }
        $remaining = $still
        if ($remaining.Count -eq 0) { break }
        if ((& $GetNow) -ge $deadline) { break }
        & $Wait | Out-Null
    }
    $locked = New-Object System.Collections.Generic.List[string]
    foreach ($file in $remaining) { $locked.Add([string]$file.Path) }
    return [PSCustomObject]@{ DeletedCount = $deleted; FreedBytes = $freed; Locked = [string[]]$locked.ToArray() }
}

function Invoke-WtRebuildExplorerCaches {
    <#
    .SYNOPSIS
        Blank or wrong icons and thumbnails, fixed in one shell stop: the
        shell goes down, the cache databases are deleted while it comes
        back, ie4uinit rebuilds the icon cache, and
        Invoke-WtRestartExplorer runs LAST. Order is load-bearing:
        deleting before the stop deletes nothing (files are open);
        restarting before ie4uinit rebuilds from stale state. ie4uinit
        takes -show, the Windows 10/11 switch; -ClearIconCache is
        Windows 8 only.
    #>
    param(
        [scriptblock]$StopExplorer = { Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue },
        [scriptblock]$RemoveCaches = { Remove-WtExplorerCacheFiles },
        [scriptblock]$RefreshIcons = { ie4uinit.exe -show },
        [scriptblock]$RestartShell = { Invoke-WtRestartExplorer },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'IconCacheStopping') 'Cyan'
    & $StopExplorer | Out-Null
    $result = & $RemoveCaches
    foreach ($line in (Format-WtExplorerCacheLines -Result $result)) { & $Write $line '' }
    & $Write (Get-Translation 'IconCacheRefreshing') 'Cyan'
    try { & $RefreshIcons | Out-Null }
    catch { & $Write $_.Exception.Message 'Red' }
    & $Write (Get-Translation 'IconCacheRestartingShell') 'Cyan'
    $restart = & $RestartShell
    $restarted = [bool]($restart -and $restart.Restarted)
    & $Write $(if ($restarted) { Get-Translation 'RestartExplorerDone' } else { Get-Translation 'RestartExplorerFailed' }) $(if ($restarted) { 'Green' } else { 'Red' })
    return $result
}

function Get-WtAudioServiceNames {
    <#
    .SYNOPSIS
        PURE: the two Windows audio services in DEPENDENCY order -
        AudioEndpointBuilder first, Audiosrv second, because Audiosrv
        depends on AudioEndpointBuilder. Starting walks this list as
        written; stopping walks it backwards.
    #>
    return [string[]]@('AudioEndpointBuilder', 'Audiosrv')
}

function Invoke-WtRestartAudioServices {
    <#
    .SYNOPSIS
        Brings sound back after a driver hiccup without a reboot: stops
        Audiosrv, then AudioEndpointBuilder, starts them again in
        dependency order, and reports both. An explicit stop/start pair,
        never Restart-Service -Force on AudioEndpointBuilder: -Force also
        restarts dependent Audiosrv, but only the named service comes back,
        leaving no audio. Status compared Ordinal (tr-TR folds differently).
    #>
    param(
        [string[]]$Names = (Get-WtAudioServiceNames),
        [scriptblock]$StopService = { param($Name) Stop-Service -Name $Name -Force -ErrorAction Stop },
        [scriptblock]$StartService = { param($Name) Start-Service -Name $Name -ErrorAction Stop },
        [scriptblock]$GetStatus = {
            param($Name)
            $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($service) { [string]$service.Status } else { '' }
        },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'AudioRestartStart') 'Cyan'
    $stopOrder = @()
    for ($i = $Names.Count - 1; $i -ge 0; $i--) { $stopOrder += [string]$Names[$i] }
    foreach ($name in $stopOrder) {
        try { & $StopService $name | Out-Null }
        catch { & $Write ('  {0}: {1}' -f $name, $_.Exception.Message) 'Red' }
    }
    foreach ($name in @($Names)) {
        try { & $StartService $name | Out-Null }
        catch { & $Write ('  {0}: {1}' -f $name, $_.Exception.Message) 'Red' }
    }
    $statuses = New-Object System.Collections.Generic.List[object]
    $allRunning = $true
    foreach ($name in @($Names)) {
        $status = [string](& $GetStatus $name)
        if (-not $status) { $status = [string](Get-Translation 'AudioServiceMissing') }
        $running = [string]::Equals($status, 'Running', [System.StringComparison]::Ordinal)
        if (-not $running) { $allRunning = $false }
        $statuses.Add([PSCustomObject]@{ Name = [string]$name; Status = $status })
        & $Write ('  {0}: {1}' -f $name, $status) $(if ($running) { 'Green' } else { 'Red' })
    }
    & $Write $(if ($allRunning) { Get-Translation 'AudioRestartDone' } else { Get-Translation 'AudioRestartIncomplete' }) $(if ($allRunning) { 'Green' } else { 'Yellow' })
    return [PSCustomObject]@{ AllRunning = $allRunning; Services = @($statuses.ToArray()) }
}

function Get-WtHungProcessSample {
    <#
    .SYNOPSIS
        One sample of the windowed processes not answering their message
        loop: Id, Name and window title. Every .Responding /
        .MainWindowTitle read is guarded - a protected or just-exited
        process raises a Win32Exception, and one unhandled throw would
        silently empty the whole list.
    #>
    param(
        [scriptblock]$GetProcesses = { @(Get-Process -ErrorAction SilentlyContinue) },
        [scriptblock]$ReadResponding = { param($Process) [bool]$Process.Responding },
        [scriptblock]$ReadTitle = { param($Process) [string]$Process.MainWindowTitle }
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(& $GetProcesses)) {
        if (-not $process) { continue }
        $handle = [int64]0
        try { $handle = [int64]$process.MainWindowHandle } catch { continue }
        if ($handle -eq 0) { continue }
        $responding = $true
        try { $responding = [bool](& $ReadResponding $process) } catch { continue }
        if ($responding) { continue }
        $title = ''
        try { $title = [string](& $ReadTitle $process) } catch { $title = '' }
        $id = 0
        try { $id = [int]$process.Id } catch { continue }
        $result.Add([PSCustomObject]@{ Id = $id; Name = [string]$process.Name; Title = $title })
    }
    return @($result.ToArray())
}

function Select-WtStillHungProcesses {
    <#
    .SYNOPSIS
        PURE: the processes that looked hung in BOTH samples, three
        seconds apart - a single poll would flag an app merely busy
        writing a large file. Matched on Id AND Name, Ordinal (tr-TR's
        dotless I breaks culture-aware matching), so a recycled process id
        cannot smuggle a healthy app onto the kill list.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$First,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Second
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($later in @($Second)) {
        foreach ($earlier in @($First)) {
            if ([int]$earlier.Id -ne [int]$later.Id) { continue }
            if (-not [string]::Equals([string]$earlier.Name, [string]$later.Name, [System.StringComparison]::Ordinal)) { continue }
            $result.Add($later)
            break
        }
    }
    return @($result.ToArray())
}

function Format-WtHungProcessLines {
    <#
    .SYNOPSIS
        PURE: what the confirmation gate shows before anything is closed -
        one "name (id) - window title" line per process, so the user can
        recognise the application they are about to lose. A process whose
        title could not be read still gets a line, with a phrase in place
        of the title.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Processes)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in @($Processes)) {
        $title = [string]$process.Title
        if (-not $title) { $title = [string](Get-Translation 'HungAppNoTitle') }
        $lines.Add(('  {0} ({1}) - {2}' -f $process.Name, $process.Id, $title))
    }
    if ($lines.Count -eq 0) { $lines.Add([string](Get-Translation 'HungAppNone')) }
    return [string[]]$lines.ToArray()
}

function Invoke-WtCloseHungProcesses {
    <#
    .SYNOPSIS
        Force-closes the processes the user confirmed, one line per
        process, then a closed / failed summary. Runs INSIDE
        Invoke-WtCapturedAction, so it asks nothing: the gate was already
        answered before the capture started.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Processes,
        [scriptblock]$StopProcess = { param($Id) Stop-Process -Id $Id -Force -ErrorAction Stop },
        [scriptblock]$Write = { param($Line, $Color) if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line } }
    )
    & $Write (Get-Translation 'HungAppClosing') 'Cyan'
    $closed = 0
    $failed = 0
    foreach ($process in @($Processes)) {
        try {
            & $StopProcess ([int]$process.Id) | Out-Null
            $closed++
            & $Write ('  {0} ({1}): {2}' -f $process.Name, $process.Id, (Get-Translation 'HungAppClosed')) 'Green'
        }
        catch {
            $failed++
            & $Write ('  {0} ({1}): {2}' -f $process.Name, $process.Id, $_.Exception.Message) 'Red'
        }
    }
    & $Write ((Get-Translation 'HungAppSummary') -f $closed, $failed) $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
    return [PSCustomObject]@{ Closed = $closed; Failed = $failed }
}

function Invoke-WtCloseNotRespondingAppsAction {
    <#
    .SYNOPSIS
        The panel flow behind "Close not-responding apps": sample, wait
        three seconds, sample again, keep only what was hung BOTH times,
        and force-close only what the typed gate confirmed - asked BEFORE
        Invoke-WtCapturedAction starts, since Read-Host inside a capture
        deadlocks. Reads $Processes from the enclosing scope, not
        GetNewClosure(), which misbehaves once the built script runs.
    #>
    param(
        [string]$Breadcrumb = (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CloseNotRespondingApps'),
        [scriptblock]$Sample = { Get-WtHungProcessSample },
        [scriptblock]$Announce = { Show-WtPanelMessage -Breadcrumb $Breadcrumb -Lines @((Get-Translation 'HungAppScanning')) | Out-Null },
        [scriptblock]$Wait = { Start-Sleep -Seconds 3 },
        [scriptblock]$ConfirmGate = { param($Lines) Confirm-WtDestructiveAction -Consequence (Get-Translation 'HungAppConsequence') -Lines $Lines -Breadcrumb $Breadcrumb },
        [scriptblock]$Notify = { param($Lines) Wait-WtEnter -Lines $Lines },
        [scriptblock]$Close = {
            param($Processes)
            Invoke-WtCapturedAction -Title (Get-Translation 'CloseNotRespondingApps') -Breadcrumb $Breadcrumb -Action {
                $null = Invoke-WtCloseHungProcesses -Processes $Processes
            }
        }
    )
    $first = @(& $Sample)
    if ($first.Count -eq 0) {
        & $Notify @([string](Get-Translation 'HungAppNone'))
        return
    }
    & $Announce | Out-Null
    & $Wait | Out-Null
    $second = @(& $Sample)
    $hung = @(Select-WtStillHungProcesses -First $first -Second $second)
    if ($hung.Count -eq 0) {
        & $Notify @([string](Get-Translation 'HungAppRecovered'))
        return
    }
    if (-not (& $ConfirmGate (Format-WtHungProcessLines -Processes $hung))) {
        & $Notify @([string](Get-Translation 'ActionCancelled'))
        return
    }
    & $Close $hung
}
