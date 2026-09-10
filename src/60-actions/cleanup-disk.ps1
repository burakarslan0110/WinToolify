# Disk Cleanup, browser caches, volume optimisation, disk repair, old restore points.
# Covered by: tests/ActionCleanupDisk.Tests.ps1

function Test-WtDiskCleanupConfigured {
    <#
    .SYNOPSIS
        True when cleanmgr /sageset:65 has been run at least once on this
        machine (any VolumeCaches handler carries StateFlags0065).
    #>
    param(
        [scriptblock]$GetStateFlags = {
            $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
                (Get-ItemProperty -LiteralPath $_.PSPath -Name 'StateFlags0065' -ErrorAction SilentlyContinue).StateFlags0065
            }
        }
    )
    foreach ($flag in @(& $GetStateFlags)) { if ($null -ne $flag) { return $true } }
    return $false
}

function Invoke-WtDiskCleanupAction {
    <#
    .SYNOPSIS
        Disk Cleanup: the first run opens cleanmgr's category picker
        (/sageset:65) so the user decides once; every run after that
        executes the saved profile (/sagerun:65).
    #>
    if (-not (Test-WtDiskCleanupConfigured)) {
        Write-Host (Get-Translation 'DiskCleanupFirstRun') -ForegroundColor Yellow
        Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sageset:65' -Wait
    }
    Write-Host (Get-Translation 'DiskCleanupRunning') -ForegroundColor Cyan
    Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:65' -Wait
}


function Get-WtBrowserCacheCatalog {
    <#
    .SYNOPSIS
        The three browsers whose on-disk caches this row clears, in the
        Show-WtSelector catalog shape. Only cache folders are ever named
        here - logins, cookies, history and bookmarks must never appear in
        CacheSubPaths.
    #>
    param(
        [hashtable]$Environment = @{ LOCALAPPDATA = $env:LOCALAPPDATA }
    )

    $localAppData = "$($Environment.LOCALAPPDATA)"
    return @(
        [PSCustomObject]@{
            Name          = 'Edge'
            DisplayLabel  = 'Microsoft Edge'
            Risk          = 'CAUTION'
            Consequence   = $null
            ProcessNames  = @('msedge')
            ProfileRoot   = [System.IO.Path]::Combine($localAppData, 'Microsoft', 'Edge', 'User Data')
            CacheSubPaths = @('Cache\Cache_Data', 'Code Cache', 'GPUCache')
        }
        [PSCustomObject]@{
            Name          = 'Chrome'
            DisplayLabel  = 'Google Chrome'
            Risk          = 'CAUTION'
            Consequence   = $null
            ProcessNames  = @('chrome')
            ProfileRoot   = [System.IO.Path]::Combine($localAppData, 'Google', 'Chrome', 'User Data')
            CacheSubPaths = @('Cache\Cache_Data', 'Code Cache', 'GPUCache')
        }
        [PSCustomObject]@{
            Name          = 'Firefox'
            DisplayLabel  = 'Mozilla Firefox'
            Risk          = 'CAUTION'
            Consequence   = $null
            ProcessNames  = @('firefox')
            ProfileRoot   = [System.IO.Path]::Combine($localAppData, 'Mozilla', 'Firefox', 'Profiles')
            CacheSubPaths = @('cache2')
        }
    )
}

function Get-WtBrowserCacheTargets {
    <#
    .SYNOPSIS
        PURE over injected lookups: turns the browser catalog into one
        entry per browser carrying every cache folder that actually holds
        bytes, the measured total, and whether that browser is running
        right now.
    #>
    param(
        [Parameter(Mandatory)][array]$Catalog,

        [scriptblock]$GetProfileNames = {
            param($Entry)
            if (-not (Test-Path -LiteralPath $Entry.ProfileRoot -PathType Container)) { return @() }
            @(Get-ChildItem -LiteralPath $Entry.ProfileRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 } |
                ForEach-Object { $_.Name })
        },

        [scriptblock]$MeasureAction = {
            param($Path)
            $inventory = Get-WtFileInventory -Root $Path -Recurse $true -ReportProgressAction { param($Scanned, $Found) }
            $bytes = 0L
            foreach ($file in @($inventory.Files)) { $bytes += [long]$file.Length }
            [PSCustomObject]@{ Bytes = $bytes; Count = @($inventory.Files).Count }
        },

        [scriptblock]$GetRunningNames = { @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) }
    )

    $running = @(& $GetRunningNames)
    $targets = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $Catalog) {
        $isRunning = $false
        foreach ($processName in @($entry.ProcessNames)) {
            foreach ($live in $running) {
                if ([string]::Equals([string]$live, [string]$processName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isRunning = $true
                }
            }
        }

        $paths = New-Object System.Collections.Generic.List[object]
        $bytes = 0L
        $count = 0
        foreach ($profileName in @(& $GetProfileNames $entry)) {
            foreach ($sub in @($entry.CacheSubPaths)) {
                $path = [System.IO.Path]::Combine($entry.ProfileRoot, $profileName, $sub)
                $measured = & $MeasureAction $path
                if (([long]$measured.Bytes -le 0) -and ([int]$measured.Count -le 0)) { continue }
                $bytes += [long]$measured.Bytes
                $count += [int]$measured.Count
                $paths.Add([PSCustomObject]@{
                    ProfileName = [string]$profileName
                    Path        = $path
                    Bytes       = [long]$measured.Bytes
                    Count       = [int]$measured.Count
                })
            }
        }

        $targets.Add([PSCustomObject]@{
            Name         = $entry.Name
            DisplayLabel = $entry.DisplayLabel
            ProcessNames = @($entry.ProcessNames)
            Running      = $isRunning
            Paths        = $paths.ToArray()
            Bytes        = $bytes
            Count        = $count
        })
    }

    return $targets.ToArray()
}

function Invoke-WtBrowserCacheClear {
    <#
    .SYNOPSIS
        Deletes the measured cache folders of the browsers it is given and
        reports what each one freed. A browser still running after the
        close attempt is skipped, not refused, since Edge keeps msedge.exe
        alive after its last window closes.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Targets,

        [AllowEmptyCollection()][string[]]$CloseNames = @(),

        [scriptblock]$StopAction = {
            param($ProcessNames)
            foreach ($processName in @($ProcessNames)) { Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 1500
        },

        [scriptblock]$IsRunningAction = {
            param($ProcessNames)
            [bool](@(Get-Process -Name @($ProcessNames) -ErrorAction SilentlyContinue).Count -gt 0)
        },

        [scriptblock]$RemoveAction = { param($Path) Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    )

    $results = New-Object System.Collections.Generic.List[object]
    $totalFreed = 0L

    foreach ($target in @($Targets)) {
        $errors = New-Object System.Collections.Generic.List[string]
        $freed = 0L
        $skippedKey = ''
        $askedToClose = (@($CloseNames) -ccontains [string]$target.Name)

        if ($askedToClose) { & $StopAction @($target.ProcessNames) }

        if ([bool](& $IsRunningAction @($target.ProcessNames))) {
            $skippedKey = if ($askedToClose) { 'BrowserCacheCloseFailed' } else { 'BrowserCacheSkipped' }
        }
        else {
            foreach ($path in @($target.Paths)) {
                try {
                    & $RemoveAction $path.Path
                    $freed += [long]$path.Bytes
                }
                catch {
                    $errors.Add(('{0}: {1}' -f $path.Path, $_.Exception.Message))
                }
            }
        }

        $totalFreed += $freed
        $results.Add([PSCustomObject]@{
            Name             = $target.Name
            DisplayLabel     = $target.DisplayLabel
            FreedBytes       = $freed
            SkippedReasonKey = $skippedKey
            Errors           = $errors.ToArray()
        })
    }

    return [PSCustomObject]@{ Results = $results.ToArray(); TotalFreedBytes = $totalFreed }
}

function Format-WtBrowserCacheLines {
    <#
    .SYNOPSIS
        PURE: what the panel shows before anything is deleted - one line
        per browser with its total, one line per profile under it, the
        grand total, and the sentence that says what was NOT touched.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Targets)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'BrowserCacheTitle') + ':')
    $total = 0L

    foreach ($target in @($Targets)) {
        $lines.Add('')
        $lines.Add(('  {0}: {1}' -f $target.DisplayLabel, (Format-WtByteSize -Bytes ([long]$target.Bytes))))
        $seen = New-Object System.Collections.Generic.List[string]
        foreach ($path in @($target.Paths)) {
            $profileName = [string]$path.ProfileName
            if ($seen -ccontains $profileName) { continue }
            $seen.Add($profileName)
            $profileBytes = 0L
            foreach ($candidate in @($target.Paths)) {
                if (([string]$candidate.ProfileName) -ceq $profileName) { $profileBytes += [long]$candidate.Bytes }
            }
            $lines.Add(('      {0} {1}: {2}' -f (Get-Translation 'BrowserCacheProfile'), $profileName, (Format-WtByteSize -Bytes $profileBytes)))
        }
        $total += [long]$target.Bytes
    }

    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-Translation 'BrowserCacheTotal'), (Format-WtByteSize -Bytes $total)))
    $lines.Add((Get-Translation 'BrowserCacheUntouched'))
    return [string[]]$lines.ToArray()
}

function Format-WtBrowserCacheResultLines {
    <#
    .SYNOPSIS
        PURE: the outcome - freed bytes per browser, the reason for every
        browser that was skipped, its errors indented under it, the total,
        and the "nothing else was touched" line repeated where the user
        actually ends up reading it.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'BrowserCacheTitle') + ':')
    $lines.Add('')

    foreach ($item in @($Result.Results)) {
        if ($item.SkippedReasonKey) {
            $lines.Add(('  {0}: {1}' -f $item.DisplayLabel, (Get-Translation $item.SkippedReasonKey)))
        }
        else {
            $lines.Add(('  {0}: {1} {2}' -f $item.DisplayLabel, (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes ([long]$item.FreedBytes))))
        }
        foreach ($err in @($item.Errors)) { $lines.Add('      ' + $err) }
    }

    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes ([long]$Result.TotalFreedBytes))))
    $lines.Add((Get-Translation 'BrowserCacheUntouched'))
    return [string[]]$lines.ToArray()
}

function Invoke-WtClearBrowserCachesAction {
    <#
    .SYNOPSIS
        The inline flow behind the ClearBrowserCaches row: measure first,
        ask about every running browser, then delete only the folders that
        were measured. Uses a plain scriptblock rather than GetNewClosure(),
        which loses access to this file's functions once the script runs
        standalone.
    #>
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'ClearBrowserCaches'
    $script:WtPanelBreadcrumb = $crumb

    Show-WtPanelMessage -Breadcrumb $crumb -Lines @((Get-Translation 'BrowserCacheMeasuring')) `
        -FooterText ((Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds 0)) | Out-Null

    $found = @(Get-WtBrowserCacheTargets -Catalog (Get-WtBrowserCacheCatalog) | Where-Object { [long]$_.Bytes -gt 0 })
    if ($found.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'BrowserCacheNothing'))
        return
    }

    $measuredLines = @(Format-WtBrowserCacheLines -Targets $found)
    $closeNames = New-Object System.Collections.Generic.List[string]
    foreach ($target in $found) {
        if (-not $target.Running) { continue }
        $answer = Read-WtPanelAnswer -Breadcrumb $crumb -Lines $measuredLines -Risk 'CAUTION' `
            -Prompt (Get-WtYesNoPrompt -Text ((Get-Translation 'BrowserCacheRunningPrompt') -f $target.DisplayLabel))
        if (Test-WtAffirmativeAnswer -Answer $answer) { $closeNames.Add([string]$target.Name) }
    }

    Invoke-WtCapturedAction -Title (Get-Translation 'ClearBrowserCaches') -Breadcrumb $crumb -Action {
        $clearResult = Invoke-WtBrowserCacheClear -Targets $found -CloseNames $closeNames.ToArray()
        foreach ($line in (Format-WtBrowserCacheResultLines -Result $clearResult)) { Write-Host $line }
    }
}

function Get-WtVolumeOptimizeMode {
    <#
    .SYNOPSIS
        PURE: which Optimize-Volume switch a media type earns. 'Defrag' is
        returned only when Windows reports HDD; everything else (SSD, SCM,
        Unspecified, unreadable) gets 'ReTrim'.
    #>
    param([AllowNull()][AllowEmptyString()][string]$MediaType)

    if (([string]$MediaType) -ceq 'HDD') { return 'Defrag' }
    return 'ReTrim'
}

function Get-WtOptimizeVolumeCatalog {
    <#
    .SYNOPSIS
        Every fixed NTFS/ReFS volume that has a drive letter, in the
        Show-WtSelector catalog shape, carrying the media type Windows
        reports and the switch it earns.
    #>
    param(
        [scriptblock]$GetVolumes = { Get-Volume -ErrorAction SilentlyContinue },

        [scriptblock]$GetMediaType = {
            param($DriveLetter)
            try {
                $physical = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop |
                    Get-Disk -ErrorAction Stop |
                    Get-PhysicalDisk -ErrorAction Stop |
                    Select-Object -First 1
                if ($physical) { return [string]$physical.MediaType }
            }
            catch { return '' }
            return ''
        }
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($volume in @(& $GetVolumes)) {
        if (-not $volume.DriveLetter) { continue }
        if (([string]$volume.DriveType) -cne 'Fixed') { continue }
        $fileSystem = [string]$volume.FileSystem
        if (-not $fileSystem) { $fileSystem = [string]$volume.FileSystemType }
        if (($fileSystem -cne 'NTFS') -and ($fileSystem -cne 'ReFS')) { continue }

        $letter = ([string]$volume.DriveLetter).Substring(0, 1).ToUpperInvariant()
        $mediaType = [string](& $GetMediaType $letter)
        $mode = Get-WtVolumeOptimizeMode -MediaType $mediaType
        $modeLabel = if ($mode -ceq 'Defrag') { Get-Translation 'OptimizeModeDefrag' } else { Get-Translation 'OptimizeModeReTrim' }
        $mediaLabel = if ($mediaType) { $mediaType } else { Get-Translation 'StateUnknown' }

        $entries.Add([PSCustomObject]@{
            Name         = $letter
            DisplayLabel = ('{0}: {1} [{2}]' -f $letter, ([string]$volume.FileSystemLabel), $mediaLabel)
            Risk         = 'CAUTION'
            Consequence  = $null
            DriveLetter  = $letter
            MediaType    = $mediaType
            Mode         = $mode
            ModeLabel    = $modeLabel
        })
    }

    return $entries.ToArray()
}

function Invoke-WtOptimizeVolumesAction {
    <#
    .SYNOPSIS
        Per-volume TRIM or defragment, chosen in a picker rather than a
        blind loop over every drive - a defragment on a spinning disk can
        run for an hour with no cancel key, so picking by hand is the only
        guard.
    #>
    param(
        [scriptblock]$GetCatalog = { Get-WtOptimizeVolumeCatalog },
        [scriptblock]$SelectAction = { param($Catalog, $StateItems, $Title) @(Show-WtSelector -Catalog $Catalog -StateItems $StateItems -Title $Title -UnselectableNote '') },
        [scriptblock]$OptimizeAction = {
            param($DriveLetter, $Mode)
            if ($Mode -ceq 'Defrag') {
                Optimize-Volume -DriveLetter $DriveLetter -Defrag -Verbose -ErrorAction Stop
            }
            else {
                Optimize-Volume -DriveLetter $DriveLetter -ReTrim -Verbose -ErrorAction Stop
            }
        },
        [scriptblock]$Run = {
            param($Chosen, $Crumb)
            Invoke-WtCapturedAction -Title (Get-Translation 'OptimizeVolumes') -Breadcrumb $Crumb -Action {
                foreach ($entry in $Chosen) {
                    Write-Host ((Get-Translation 'OptimizeVolumeStarting') -f ($entry.DriveLetter + ':')) -ForegroundColor Cyan
                    try {
                        & $OptimizeAction $entry.DriveLetter $entry.Mode
                    }
                    catch {
                        Write-Host ('{0}: {1} - {2}' -f ($entry.DriveLetter + ':'), (Get-Translation 'OptimizeVolumeFailed'), $_.Exception.Message) -ForegroundColor Red
                    }
                }
                Write-Host (Get-Translation 'ActionCompleted') -ForegroundColor Green
            }
        }
    )
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'OptimizeVolumes'
    $script:WtPanelBreadcrumb = $crumb

    $catalog = @(& $GetCatalog)
    if ($catalog.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NoFixedVolumeFound'))
        return
    }

    $stateItems = foreach ($entry in $catalog) {
        [PSCustomObject]@{ Name = $entry.Name; Selectable = $true; StateLabel = $entry.ModeLabel }
    }
    $selected = @(& $SelectAction $catalog @($stateItems) $crumb)
    if ($selected.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
        return
    }
    $chosen = @($catalog | Where-Object { @($selected) -ccontains $_.Name })

    & $Run $chosen $crumb
}

function Get-WtDiskRepairPlan {
    <#
    .SYNOPSIS
        PURE: how a chkdsk /f repair is scheduled for one drive letter, and
        the command that cancels it. The system drive sets the dirty bit
        directly, since chkdsk's own next-boot prompt is a localized
        yes/no a captured run cannot answer; any other volume uses
        Repair-Volume -OfflineScanAndFix.
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][bool]$IsSystemDrive
    )

    $letter = ([string]$DriveLetter).Substring(0, 1).ToUpperInvariant()

    return [PSCustomObject]@{
        DriveLetter   = $letter
        Method        = $(if ($IsSystemDrive) { 'DirtyBit' } else { 'OfflineScanAndFix' })
        ScheduleText  = $(if ($IsSystemDrive) { "fsutil dirty set ${letter}:" } else { "Repair-Volume -DriveLetter $letter -OfflineScanAndFix" })
        CancelCommand = "chkntfs /x ${letter}:"
        NoteKey       = $(if ($IsSystemDrive) { 'DiskRepairSystemDrive' } else { 'DiskRepairOfflineScan' })
    }
}

function Get-WtDiskRepairCatalog {
    <#
    .SYNOPSIS
        The fixed NTFS/ReFS volumes a boot-time repair can be scheduled
        for, in the Show-WtSelector catalog shape, each carrying its
        Get-WtDiskRepairPlan.
    #>
    param(
        [scriptblock]$GetVolumes = { Get-Volume -ErrorAction SilentlyContinue },
        [string]$SystemDrive = "$env:SystemDrive"
    )

    $systemLetter = ''
    if ($SystemDrive -and $SystemDrive.Length -ge 1) { $systemLetter = $SystemDrive.Substring(0, 1).ToUpperInvariant() }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($volume in @(& $GetVolumes)) {
        if (-not $volume.DriveLetter) { continue }
        if (([string]$volume.DriveType) -cne 'Fixed') { continue }
        $fileSystem = [string]$volume.FileSystem
        if (-not $fileSystem) { $fileSystem = [string]$volume.FileSystemType }
        if (($fileSystem -cne 'NTFS') -and ($fileSystem -cne 'ReFS')) { continue }

        $letter = ([string]$volume.DriveLetter).Substring(0, 1).ToUpperInvariant()
        $isSystem = ($letter -ceq $systemLetter)
        $plan = Get-WtDiskRepairPlan -DriveLetter $letter -IsSystemDrive $isSystem

        $entries.Add([PSCustomObject]@{
            Name          = $letter
            DisplayLabel  = ('{0}: {1} ({2})' -f $letter, ([string]$volume.FileSystemLabel), $fileSystem)
            Risk          = 'ADVANCED'
            Consequence   = (Get-Translation $plan.NoteKey)
            DriveLetter   = $letter
            IsSystemDrive = $isSystem
            Plan          = $plan
        })
    }

    return $entries.ToArray()
}

function Invoke-WtScheduleDiskRepairAction {
    <#
    .SYNOPSIS
        Schedules a real chkdsk /f repair for one volume the user picks:
        the dirty bit on the system drive, Repair-Volume
        -OfflineScanAndFix everywhere else. The repair itself runs only at
        next boot; a volume Windows refuses to dismount is reported
        honestly rather than called scheduled.
    #>
    param(
        [scriptblock]$GetCatalog = { Get-WtDiskRepairCatalog },
        [scriptblock]$SelectAction = { param($Catalog, $StateItems, $Title) @(Show-WtSelector -Catalog $Catalog -StateItems $StateItems -Title $Title -UnselectableNote '') },
        [scriptblock]$Confirm = { param($ConsequenceText, $Lines, $Crumb) Confirm-WtDestructiveAction -Consequence $ConsequenceText -Lines $Lines -Breadcrumb $Crumb },
        [scriptblock]$SetDirtyBit = { param($DriveLetter) fsutil dirty set ('{0}:' -f $DriveLetter) },
        [scriptblock]$RepairVolume = { param($DriveLetter) Repair-Volume -DriveLetter $DriveLetter -OfflineScanAndFix -ErrorAction Stop },
        [scriptblock]$ShowCancelled = { param($Lines) Wait-WtEnter -Lines $Lines }
    )
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'ScheduleDiskRepair'
    $script:WtPanelBreadcrumb = $crumb

    $catalog = @(& $GetCatalog)
    if ($catalog.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NoFixedVolumeFound'))
        return
    }

    $stateItems = foreach ($entry in $catalog) {
        [PSCustomObject]@{ Name = $entry.Name; Selectable = $true; StateLabel = (Get-Translation $entry.Plan.NoteKey) }
    }
    $selected = @(& $SelectAction $catalog @($stateItems) $crumb)
    if ($selected.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
        return
    }
    $entry = @($catalog | Where-Object { $_.Name -ceq ([string]$selected[0]) })[0]
    $plan = $entry.Plan

    $gateLines = @(
        (Get-Translation $plan.NoteKey)
        ('  ' + $plan.ScheduleText)
        ''
        ((Get-Translation 'DiskRepairCancelHint') -f $plan.CancelCommand)
    )
    if (-not (& $Confirm ((Get-Translation 'ConsequenceScheduleDiskRepair') -f ($plan.DriveLetter + ':')) $gateLines $crumb)) {
        & $ShowCancelled @((Get-Translation 'ActionCancelled'))
        return
    }

    Invoke-WtCapturedAction -Title (Get-Translation 'ScheduleDiskRepair') -Breadcrumb $crumb -Action {
        Write-Host $plan.ScheduleText -ForegroundColor Cyan
        if ($plan.Method -ceq 'DirtyBit') {
            & $SetDirtyBit $plan.DriveLetter
            Write-Host ((Get-Translation 'DiskRepairScheduled') -f ($plan.DriveLetter + ':')) -ForegroundColor Green
        }
        else {
            try {
                & $RepairVolume $plan.DriveLetter
                Write-Host ((Get-Translation 'DiskRepairScheduled') -f ($plan.DriveLetter + ':')) -ForegroundColor Green
            }
            catch {
                Write-Host ((Get-Translation 'DiskRepairDismountFailed') -f ($plan.DriveLetter + ':')) -ForegroundColor Red
                Write-Host $_.Exception.Message
            }
        }
        Write-Host ((Get-Translation 'DiskRepairCancelHint') -f $plan.CancelCommand)
    }
}

function Get-WtRestorePointEntries {
    <#
    .SYNOPSIS
        The machine's restore points, newest first, normalized to
        SequenceNumber / Description / CreationTime. Returns an empty
        array when System Protection is off, never reported as a
        successful delete.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-ComputerRestorePoint only executes in the PS5.1 branch, guarded by Test-WtUsesCimRestorePointApi; PSScriptAnalyzer cannot see the runtime version guard.')]
    param(
        [scriptblock]$GetPoints = {
            if (Test-WtUsesCimRestorePointApi -PSMajorVersion $PSVersionTable.PSVersion.Major) {
                Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue
            }
            else {
                Get-ComputerRestorePoint -ErrorAction SilentlyContinue
            }
        }
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($point in @(& $GetPoints)) {
        if (-not $point) { continue }
        $created = $null
        $raw = $point.CreationTime
        if ($raw -is [datetime]) {
            $created = [datetime]$raw
        }
        elseif ($raw) {
            try { $created = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$raw) }
            catch { $created = $null }
        }
        $entries.Add([PSCustomObject]@{
            SequenceNumber = [int]$point.SequenceNumber
            Description    = [string]$point.Description
            CreationTime   = $created
        })
    }

    return @($entries.ToArray() | Sort-Object -Property @{ Expression = { if ($_.CreationTime) { $_.CreationTime } else { [datetime]::MinValue } } } -Descending)
}

function Get-WtShadowStorageEntries {
    <#
    .SYNOPSIS
        Shadow-copy storage per drive: used and allocated bytes, read
        through CIM rather than parsed from "vssadmin list shadowstorage"
        text - that text is localized (Turkish decimal commas), so a byte
        figure taken from it would be wrong on exactly the machines this
        ships for.
    #>
    param(
        [scriptblock]$GetStorage = { Get-CimInstance -ClassName 'Win32_ShadowStorage' -ErrorAction SilentlyContinue },
        [scriptblock]$GetVolumes = { Get-CimInstance -ClassName 'Win32_Volume' -ErrorAction SilentlyContinue }
    )

    $letterByDevice = @{}
    foreach ($volume in @(& $GetVolumes)) {
        if ($volume.DeviceID) { $letterByDevice[[string]$volume.DeviceID] = [string]$volume.DriveLetter }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($storage in @(& $GetStorage)) {
        $deviceId = ''
        if ($storage.Volume) { $deviceId = [string]$storage.Volume.DeviceID }
        $letter = [string]$letterByDevice[$deviceId]
        if (-not $letter) { $letter = Get-Translation 'StateUnknown' }
        $entries.Add([PSCustomObject]@{
            DriveLetter    = $letter
            UsedBytes      = [long]$storage.UsedSpace
            AllocatedBytes = [long]$storage.AllocatedSpace
        })
    }

    return $entries.ToArray()
}

function Get-WtShadowCopyCount {
    <#
    .SYNOPSIS
        How many shadow copies live on one drive letter, counted through
        CIM (Win32_ShadowCopy joined to Win32_Volume) instead of counting
        rows in localized vssadmin output. This is the number the
        oldest-first delete loop stops at.
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [scriptblock]$GetCopies = { Get-CimInstance -ClassName 'Win32_ShadowCopy' -ErrorAction SilentlyContinue },
        [scriptblock]$GetVolumes = { Get-CimInstance -ClassName 'Win32_Volume' -ErrorAction SilentlyContinue }
    )

    $letter = ([string]$DriveLetter).Substring(0, 1).ToUpperInvariant()
    $deviceIds = New-Object System.Collections.Generic.List[string]
    foreach ($volume in @(& $GetVolumes)) {
        $volumeLetter = [string]$volume.DriveLetter
        if (-not $volumeLetter) { continue }
        if ($volumeLetter.Substring(0, 1).ToUpperInvariant() -ceq $letter) { $deviceIds.Add([string]$volume.DeviceID) }
    }

    $count = 0
    foreach ($copy in @(& $GetCopies)) {
        if ($deviceIds -ccontains ([string]$copy.VolumeName)) { $count++ }
    }
    return $count
}

function Invoke-WtShadowOldestLoop {
    <#
    .SYNOPSIS
        Deletes shadow copies on one drive, oldest first, stopping the
        moment one remains or the count stops falling.
    #>
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][scriptblock]$CountAction,
        [Parameter(Mandatory)][scriptblock]$DeleteAction,
        [int]$MaxIterations = 512
    )

    $deleted = 0
    $rounds = 0
    $count = [int](& $CountAction $DriveLetter)
    while (($count -gt 1) -and ($rounds -lt $MaxIterations)) {
        & $DeleteAction $DriveLetter
        $rounds++
        $after = [int](& $CountAction $DriveLetter)
        if ($after -ge $count) { break }
        $deleted += ($count - $after)
        $count = $after
    }

    return [PSCustomObject]@{ Deleted = $deleted; Remaining = $count }
}

function Format-WtRestorePointDeleteLines {
    <#
    .SYNOPSIS
        PURE: what the gate shows before anything is deleted - every
        restore point newest first with the newest one marked KEPT, the
        per-drive shadow storage, and the raw vssadmin block underneath.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Points,
        [AllowEmptyCollection()][array]$Storage = @(),
        [AllowEmptyCollection()][string[]]$RawLines = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'RestorePointsHeader') + ':')

    $isNewest = $true
    foreach ($point in @($Points)) {
        $stamp = ''
        if ($point.CreationTime) {
            $stamp = ([datetime]$point.CreationTime).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $mark = if ($isNewest) { '  [' + (Get-Translation 'RestorePointKept') + ']' } else { '' }
        $lines.Add(('  {0}  {1}{2}' -f $stamp, [string]$point.Description, $mark))
        $isNewest = $false
    }

    if (@($Storage).Count -gt 0) {
        $lines.Add('')
        $lines.Add((Get-Translation 'ShadowStorageHeader') + ':')
        foreach ($item in @($Storage)) {
            $lines.Add(('  {0}  {1}: {2}  {3}: {4}' -f [string]$item.DriveLetter,
                (Get-Translation 'ShadowStorageUsed'), (Format-WtByteSize -Bytes ([long]$item.UsedBytes)),
                (Get-Translation 'ShadowStorageAllocated'), (Format-WtByteSize -Bytes ([long]$item.AllocatedBytes))))
        }
    }

    if (@($RawLines).Count -gt 0) {
        $lines.Add('')
        $lines.Add('vssadmin list shadowstorage')
        foreach ($raw in @($RawLines)) { $lines.Add('  ' + $raw) }
    }

    return [string[]]$lines.ToArray()
}

function Invoke-WtDeleteOldRestorePointsAction {
    <#
    .SYNOPSIS
        Frees the 10-20 GB the shadow store holds while always keeping the
        newest restore point: lists the points and the per-drive shadow
        storage first, gates on the typed word, then deletes oldest-first
        in a loop that stops at one.
    #>
    param(
        [scriptblock]$GetPoints = { Get-WtRestorePointEntries },
        [scriptblock]$GetStorage = { Get-WtShadowStorageEntries },
        [scriptblock]$GetRawShadowStorageLines = {
            try { @(& vssadmin.exe list shadowstorage | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) }
            catch { @() }
        },
        [scriptblock]$Confirm = { param($ConsequenceText, $Lines, $Crumb) Confirm-WtDestructiveAction -Consequence $ConsequenceText -Lines $Lines -Breadcrumb $Crumb },
        [scriptblock]$DeleteShadow = { param($DriveLetter) & vssadmin.exe delete shadows ('/for={0}:' -f $DriveLetter) /oldest /quiet },
        [scriptblock]$ShowCancelled = { param($Lines) Wait-WtEnter -Lines $Lines }
    )
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'DeleteOldRestorePoints'
    $script:WtPanelBreadcrumb = $crumb

    $points = @(& $GetPoints)
    if ($points.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'RestorePointsNone'))
        return
    }
    if ($points.Count -eq 1) {
        Wait-WtEnter -Lines @((Get-Translation 'RestorePointsOnlyOne'))
        return
    }

    $storageBefore = @(& $GetStorage)
    $rawLines = @(& $GetRawShadowStorageLines)

    $newest = $points[0]
    $newestStamp = ''
    if ($newest.CreationTime) {
        $newestStamp = ([datetime]$newest.CreationTime).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $keptText = '{0} ({1})' -f [string]$newest.Description, $newestStamp
    $consequence = (Get-Translation 'ConsequenceDeleteRestorePoints') -f ($points.Count - 1), $keptText

    if (-not (& $Confirm $consequence (Format-WtRestorePointDeleteLines -Points $points -Storage $storageBefore -RawLines $rawLines) $crumb)) {
        & $ShowCancelled @((Get-Translation 'ActionCancelled'))
        return
    }

    $driveLetters = @($storageBefore | ForEach-Object { [string]$_.DriveLetter } |
        Where-Object { $_ -cmatch '^[A-Za-z]:' } | ForEach-Object { $_.Substring(0, 1) })
    if ($driveLetters.Count -eq 0) { $driveLetters = @(([string]$env:SystemDrive).Substring(0, 1)) }

    Invoke-WtCapturedAction -Title (Get-Translation 'DeleteOldRestorePoints') -Breadcrumb $crumb -Action {
        $deletedTotal = 0
        $remainingTotal = 0
        foreach ($letter in $driveLetters) {
            Write-Host ((Get-Translation 'RestorePointsDeleting') -f ($letter + ':')) -ForegroundColor Cyan
            $loop = Invoke-WtShadowOldestLoop -DriveLetter $letter `
                -CountAction { param($Drive) Get-WtShadowCopyCount -DriveLetter $Drive } `
                -DeleteAction { param($Drive) & $DeleteShadow $Drive }
            $deletedTotal += [int]$loop.Deleted
            $remainingTotal += [int]$loop.Remaining
        }
        Write-Host ((Get-Translation 'RestorePointsDeleted') -f $deletedTotal, $remainingTotal) -ForegroundColor Green

        $usedBefore = 0L
        foreach ($item in @($storageBefore)) { $usedBefore += [long]$item.UsedBytes }
        $usedAfter = 0L
        foreach ($item in @(& $GetStorage)) { $usedAfter += [long]$item.UsedBytes }
        $reclaimed = $usedBefore - $usedAfter
        if ($reclaimed -lt 0) { $reclaimed = 0L }
        Write-Host ('{0}: {1}' -f (Get-Translation 'RestorePointsReclaimed'), (Format-WtByteSize -Bytes $reclaimed)) -ForegroundColor Green
    }
}
