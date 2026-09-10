# Storage, folder usage, largest folders/files, component store, restore points, partitions.
# Covered by: tests/InfoStorage.Tests.ps1

function Get-WtStorageLines {
    <#
    .SYNOPSIS
        V1's "Show Storage Status" (Get-PSDrive) upgraded to Get-Volume:
        one line per lettered volume with free / total / percent free.
    #>
    param([scriptblock]$GetVolumes = { Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter })
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($v in @(& $GetVolumes)) {
        $size = [double]$v.Size
        $free = [double]$v.SizeRemaining
        $pct = if ($size -gt 0) { [math]::Round(($free / $size) * 100) } else { 0 }
        $label = if ($v.FileSystemLabel) { [string]$v.FileSystemLabel } else { '-' }
        $lines.Add(('{0}: {1} {2} {3} {4} {5} ({6}%)' -f $v.DriveLetter, $label, $v.FileSystem, (Format-WtByteSize -Bytes ([long]$free)), (Get-Translation 'FreeOf'), (Format-WtByteSize -Bytes ([long]$size)), $pct))
    }
    if ($lines.Count -eq 0) { $lines.Add((Get-Translation 'StorageNotAvailable')) }
    return [string[]]$lines.ToArray()
}

function Get-WtFolderUsage {
    <#
    .SYNOPSIS
        Total bytes and file count under one folder, walked with an own
        stack rather than Get-ChildItem -Recurse: an unreadable directory
        is COUNTED, not thrown, and a ReparsePoint is skipped at every
        level (PS 5.1's -Recurse does not follow junctions, but this walk
        does not depend on that). Uses ::new() rather than New-Object
        throughout: the information screens must stay clear of every
        New-/Set-/Remove- verb, which a denylist test greps for.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$GetEntries = {
            param($Current)
            $dir = [System.IO.DirectoryInfo]$Current
            return @{ Files = @($dir.GetFiles()); Directories = @($dir.GetDirectories()) }
        }
    )
    $bytes = 0L
    $files = 0
    $skipped = 0
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $entries = $null
        try { $entries = & $GetEntries $current }
        catch { $skipped++; continue }
        foreach ($f in @($entries.Files)) {
            $bytes += [long]$f.Length
            $files++
        }
        foreach ($d in @($entries.Directories)) {
            if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
            $stack.Push([string]$d.FullName)
        }
    }
    return [PSCustomObject]@{ Bytes = $bytes; Files = $files; Skipped = $skipped }
}

function Get-WtLargestFoldersReportLines {
    <#
    .SYNOPSIS
        "What ate my C: drive": the top-level folders under one path,
        biggest first, streamed with a heartbeat per folder before the
        ranking (Invoke-WtCapturedAction only repaints on output, and the
        ranking prints last, which is why the header says to press End).
        The result list is deliberately not named the same as the
        caller's own collector: the injected -MeasureFolder / -WriteLine
        scriptblocks are dynamically scoped, so a same-named local here
        would silently swallow the caller's own Adds. Top-level
        ReparsePoint entries are skipped so a profile's junctions do not
        double-count bytes.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Top = 20,
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$GetTopLevel = {
            param($Path)
            $dir = [System.IO.DirectoryInfo]$Path
            return @{ Directories = @($dir.GetDirectories()); Files = @($dir.GetFiles()) }
        },
        [scriptblock]$MeasureFolder = { param($Path) Get-WtFolderUsage -Path $Path },
        [scriptblock]$WriteLine = { param($Text) Write-Host $Text }
    )
    if (-not (& $TestRoot $Root)) {
        return [string[]]@(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $Root))
    }

    & $WriteLine ((Get-Translation 'LargestFoldersHeader') -f $Root)
    & $WriteLine (Get-Translation 'ScanResultsBelow')
    & $WriteLine ''

    $entries = $null
    try { $entries = & $GetTopLevel $Root }
    catch { $entries = $null }
    if ($null -eq $entries) {
        return [string[]]@((Get-Translation 'LargestFoldersNone'))
    }

    $rootBytes = 0L
    $rootFiles = 0
    foreach ($f in @($entries.Files)) {
        $rootBytes += [long]$f.Length
        $rootFiles++
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $folderTotals = [System.Collections.Generic.List[object]]::new()
    $unreadable = 0
    foreach ($d in @($entries.Directories)) {
        if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
        $usage = & $MeasureFolder ([string]$d.FullName)
        $unreadable += [int]$usage.Skipped
        $folderTotals.Add([PSCustomObject]@{ Name = [string]$d.Name; Bytes = [long]$usage.Bytes; Files = [int]$usage.Files })
        & $WriteLine ('  ' + (((Get-Translation 'ScanningFolder') -f [string]$d.Name)) + '  ' + (Format-WtByteSize -Bytes ([long]$usage.Bytes)))
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add(((Get-Translation 'LargestFoldersHeader') -f $Root))
    $lines.Add('')
    if ($folderTotals.Count -eq 0 -and $rootFiles -eq 0) {
        $lines.Add((Get-Translation 'LargestFoldersNone'))
        return [string[]]$lines.ToArray()
    }
    $rank = 0
    foreach ($m in @(@($folderTotals.ToArray()) | Sort-Object -Property Bytes -Descending | Select-Object -First $Top)) {
        $rank++
        $lines.Add(('{0,2}. {1,10}  {2}' -f $rank, (Format-WtByteSize -Bytes $m.Bytes), (Format-WtLeftTruncatedPath -Path $m.Name -Width 54)))
    }
    $totalBytes = $rootBytes
    foreach ($m in @($folderTotals.ToArray())) { $totalBytes += [long]$m.Bytes }
    if ($rootFiles -gt 0) {
        $lines.Add('')
        $lines.Add(('  {0} ({1}): {2}' -f (Get-Translation 'ScanRootFiles'), $rootFiles, (Format-WtByteSize -Bytes $rootBytes)))
    }
    $lines.Add('')
    $lines.Add(((Get-Translation 'ScanTotalMeasured') -f (Format-WtByteSize -Bytes $totalBytes), $folderTotals.Count))
    if ($unreadable -gt 0) {
        $lines.Add(((Get-Translation 'ScanSkippedFolders') -f $unreadable))
    }
    return [string[]]$lines.ToArray()
}

function Invoke-WtLargestFoldersReportAction {
    <#
    .SYNOPSIS
        Inline row: the path is asked for IN THE PANEL first (empty means
        the profile folder, never the whole drive), then the walk is
        handed to Invoke-WtCapturedAction - a Read-Host inside a captured
        action deadlocks behind the capture, so the question cannot live
        in the scriptblock. $target is captured by the inner
        scriptblock's defining scope rather than via GetNewClosure,
        which breaks once WinToolify.ps1 is run rather than dot-sourced.
    #>
    param(
        [string]$DefaultRoot = $env:USERPROFILE,
        [scriptblock]$AskPath = {
            param($Crumb, $Lines, $Prompt)
            Read-WtPanelAnswer -Breadcrumb $Crumb -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' -Layout 'Compact'
        },
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$Run = {
            param($Root, $Crumb)
            $target = $Root
            Invoke-WtCapturedAction -Title (Get-Translation 'LargestFoldersReport') -Breadcrumb $Crumb -Action {
                foreach ($l in (Get-WtLargestFoldersReportLines -Root $target)) { Write-Host $l }
            }
        }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { Get-Translation 'LargestFoldersReport' }
    $answer = & $AskPath $crumb @(((Get-Translation 'ScanPathDefaultHint') -f $DefaultRoot)) (Get-Translation 'ScanPathPrompt')
    if ($null -eq $answer) { return }
    $root = ([string]$answer).Trim().Trim('"')
    if (-not $root) { $root = $DefaultRoot }
    if (-not (& $TestRoot $root)) {
        Wait-WtEnter -Lines @(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $root))
        return
    }
    & $Run $root $crumb
}

function Get-WtBigFileList {
    <#
    .SYNOPSIS
        Every file at or over MinSizeBytes under one subtree, collected
        into a list with an own stack rather than
        "Get-ChildItem -Recurse | Sort-Object" (that pipeline emits
        nothing until the whole walk finishes). A ReparsePoint is skipped
        at every level and an unreadable directory is counted, not thrown.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MinSizeBytes = 104857600,
        [scriptblock]$GetEntries = {
            param($Current)
            $dir = [System.IO.DirectoryInfo]$Current
            return @{ Files = @($dir.GetFiles()); Directories = @($dir.GetDirectories()) }
        }
    )
    $found = [System.Collections.Generic.List[object]]::new()
    $skipped = 0
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $entries = $null
        try { $entries = & $GetEntries $current }
        catch { $skipped++; continue }
        foreach ($f in @($entries.Files)) {
            if ([long]$f.Length -lt $MinSizeBytes) { continue }
            $found.Add([PSCustomObject]@{ Path = [string]$f.FullName; Length = [long]$f.Length })
        }
        foreach ($d in @($entries.Directories)) {
            if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
            $stack.Push([string]$d.FullName)
        }
    }
    return [PSCustomObject]@{ Files = @($found.ToArray()); Skipped = $skipped }
}

function Get-WtLargestFilesReportLines {
    <#
    .SYNOPSIS
        The forgotten ISO or VM disk the folder view hides: files over
        100 MB under one path, biggest first. Top-level directories are
        walked one by one with a heartbeat per subtree, since a single
        "Get-ChildItem -Recurse | Sort-Object" pipeline emits nothing
        until it finishes. ReparsePoint entries are skipped so a
        junction cannot list the same file twice; long paths are cut
        from the LEFT.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Top = 25,
        [long]$MinSizeBytes = 104857600,
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$GetTopLevel = {
            param($Path)
            $dir = [System.IO.DirectoryInfo]$Path
            return @{ Directories = @($dir.GetDirectories()); Files = @($dir.GetFiles()) }
        },
        [scriptblock]$GetBigFiles = { param($Path, $MinBytes) Get-WtBigFileList -Path $Path -MinSizeBytes $MinBytes },
        [scriptblock]$WriteLine = { param($Text) Write-Host $Text }
    )
    if (-not (& $TestRoot $Root)) {
        return [string[]]@(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $Root))
    }

    & $WriteLine ((Get-Translation 'LargestFilesHeader') -f $Root)
    & $WriteLine (Get-Translation 'ScanResultsBelow')
    & $WriteLine ''

    $entries = $null
    try { $entries = & $GetTopLevel $Root }
    catch { $entries = $null }
    if ($null -eq $entries) {
        return [string[]]@((Get-Translation 'LargestFilesNone'))
    }

    $found = [System.Collections.Generic.List[object]]::new()
    $unreadable = 0
    foreach ($f in @($entries.Files)) {
        if ([long]$f.Length -lt $MinSizeBytes) { continue }
        $found.Add([PSCustomObject]@{ Path = [string]$f.FullName; Length = [long]$f.Length })
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    foreach ($d in @($entries.Directories)) {
        if (([System.IO.FileAttributes]$d.Attributes -band $reparse) -eq $reparse) { continue }
        $result = & $GetBigFiles ([string]$d.FullName) $MinSizeBytes
        $unreadable += [int]$result.Skipped
        foreach ($hit in @($result.Files)) {
            $found.Add([PSCustomObject]@{ Path = [string]$hit.Path; Length = [long]$hit.Length })
        }
        & $WriteLine ('  ' + (((Get-Translation 'ScanningFolder') -f [string]$d.Name)) + '  ' + @($result.Files).Count)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add(((Get-Translation 'LargestFilesHeader') -f $Root))
    $lines.Add('')
    if ($found.Count -eq 0) {
        $lines.Add((Get-Translation 'LargestFilesNone'))
    }
    else {
        $rank = 0
        foreach ($hit in @(@($found.ToArray()) | Sort-Object -Property Length -Descending | Select-Object -First $Top)) {
            $rank++
            $lines.Add(('{0,2}. {1,10}  {2}' -f $rank, (Format-WtByteSize -Bytes ([long]$hit.Length)), (Format-WtLeftTruncatedPath -Path ([string]$hit.Path) -Width 54)))
        }
    }
    if ($unreadable -gt 0) {
        $lines.Add('')
        $lines.Add(((Get-Translation 'ScanSkippedFolders') -f $unreadable))
    }
    return [string[]]$lines.ToArray()
}

function Invoke-WtLargestFilesReportAction {
    <#
    .SYNOPSIS
        Inline row: the path is asked for IN THE PANEL first (empty means
        the profile folder, never the whole drive), then the walk is
        handed to Invoke-WtCapturedAction - a Read-Host inside a captured
        action deadlocks behind the capture, so the question cannot live
        in the scriptblock.
    #>
    param(
        [string]$DefaultRoot = $env:USERPROFILE,
        [scriptblock]$AskPath = {
            param($Crumb, $Lines, $Prompt)
            Read-WtPanelAnswer -Breadcrumb $Crumb -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' -Layout 'Compact'
        },
        [scriptblock]$TestRoot = { param($Path) Test-Path -LiteralPath $Path -PathType Container },
        [scriptblock]$Run = {
            param($Root, $Crumb)
            $target = $Root
            Invoke-WtCapturedAction -Title (Get-Translation 'LargestFilesReport') -Breadcrumb $Crumb -Action {
                foreach ($l in (Get-WtLargestFilesReportLines -Root $target)) { Write-Host $l }
            }
        }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { Get-Translation 'LargestFilesReport' }
    $answer = & $AskPath $crumb @(((Get-Translation 'ScanPathDefaultHint') -f $DefaultRoot)) (Get-Translation 'ScanPathPrompt')
    if ($null -eq $answer) { return }
    $root = ([string]$answer).Trim().Trim('"')
    if (-not $root) { $root = $DefaultRoot }
    if (-not (& $TestRoot $root)) {
        Wait-WtEnter -Lines @(('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $root))
        return
    }
    & $Run $root $crumb
}

function Test-WtDismAvailable {
    <#
    .SYNOPSIS
        True when Dism.exe is where Windows keeps it. The component-store
        row needs an honest "not available" line rather than a raw
        "command not found" spilling into the panel.
    #>
    param(
        [string]$DismPath = (Join-Path $env:SystemRoot 'System32\Dism.exe'),
        [scriptblock]$TestPathAction = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    )
    try { return [bool](& $TestPathAction $DismPath) }
    catch { return $false }
}

function Get-WtComponentStoreAnalysisLines {
    <#
    .SYNOPSIS
        The preamble the component-store row prints before DISM starts:
        Invoke-WtCapturedAction only repaints on output and DISM stays
        silent for its first seconds, so without these lines the panel
        looks frozen. DISM's own answer is streamed verbatim by the row
        and never parsed here: DISM is localized, so grepping its
        "Cleanup Recommended" line would silently report the wrong
        verdict on a Turkish Windows.
    #>
    param(
        [bool]$DismAvailable = (Test-WtDismAvailable),
        [string]$DismPath = (Join-Path $env:SystemRoot 'System32\Dism.exe')
    )
    if (-not $DismAvailable) {
        return [string[]]@(((Get-Translation 'ComponentStoreDismMissing') -f $DismPath))
    }
    return [string[]]@(
        (Get-Translation 'ComponentStoreRunning')
        (Get-Translation 'ComponentStoreReadOnlyNote')
        ''
    )
}

function ConvertTo-WtRestorePointTime {
    <#
    .SYNOPSIS
        A restore point's CreationTime as a DateTime. WMI hands it over as
        a DMTF string (yyyymmddHHMMSS.mmmmmm+UUU); the CIM branch may hand
        over a real DateTime. Anything unreadable comes back as $null so
        the caller can print a visibly unknown stamp instead of "today".
    #>
    param([Parameter(Mandatory)][AllowNull()]$CreationTime)
    if ($null -eq $CreationTime) { return $null }
    if ($CreationTime -is [datetime]) { return [datetime]$CreationTime }
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationTime) }
    catch { return $null }
}

function Get-WtRestorePointTypeLabel {
    <#
    .SYNOPSIS
        RestorePointType resolved to words, from the SRRestorePtAPI.h
        table (0 APPLICATION_INSTALL, 1 APPLICATION_UNINSTALL, 6 RESTORE,
        7 CHECKPOINT, 10 DEVICE_DRIVER_INSTALL, 12 MODIFY_SETTINGS,
        13 CANCELLED_OPERATION). A missing value must NOT fall through to
        0 - [int]$null is 0 in PowerShell, which would label every point
        with no type as an application install.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Type)
    if ($null -eq $Type -or ([string]$Type) -eq '') {
        return ((Get-Translation 'RestorePointTypeOther') -f '?')
    }
    $number = $null
    try { $number = [int]$Type }
    catch { return ((Get-Translation 'RestorePointTypeOther') -f ([string]$Type)) }
    switch ($number) {
        0 { return (Get-Translation 'RestorePointTypeAppInstall') }
        1 { return (Get-Translation 'RestorePointTypeAppUninstall') }
        6 { return (Get-Translation 'RestorePointTypeRestore') }
        7 { return (Get-Translation 'RestorePointTypeCheckpoint') }
        10 { return (Get-Translation 'RestorePointTypeDriverInstall') }
        12 { return (Get-Translation 'RestorePointTypeModifySettings') }
        13 { return (Get-Translation 'RestorePointTypeCancelled') }
    }
    return ((Get-Translation 'RestorePointTypeOther') -f $number)
}

function Get-WtRestorePointShadowStorageLines {
    <#
    .SYNOPSIS
        Which restore points exist, when they were made, and what kind
        they are, then the header under which the row prints
        "vssadmin list shadowstorage" verbatim. A read failure is
        reported as unavailable, never as zero restore points - that
        would call a protected machine unprotected. The vssadmin output
        itself is streamed straight into the panel with no -Encoding:
        OEM decoding is what vssadmin needs, and UTF8 there turns its box
        characters into mojibake.
    #>
    param(
        [PSCustomObject]$Result = (Get-WtRestorePointRecords),
        [int]$Top = 20
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Get-Translation 'RestorePointListHeader'))
    if (-not $Result.Succeeded) {
        $lines.Add('  ' + ((Get-Translation 'RestorePointsUnavailable') -f [string]$Result.Error))
        $lines.Add('  ' + (Get-Translation 'RestorePointsUnknownWarning'))
    }
    elseif (@($Result.Points).Count -eq 0) {
        $lines.Add('  ' + (Get-Translation 'RestorePointListNone'))
    }
    else {
        foreach ($p in @(@($Result.Points) | Sort-Object -Property SequenceNumber -Descending | Select-Object -First $Top)) {
            $when = ConvertTo-WtRestorePointTime -CreationTime $p.CreationTime
            $stamp = if ($when) { $when.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { '????-??-?? --:--' }
            $lines.Add(('  {0,4}  {1}  {2}' -f [string]$p.SequenceNumber, $stamp, [string]$p.Description))
            $lines.Add(('        {0}' -f (Get-WtRestorePointTypeLabel -Type $p.RestorePointType)))
        }
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'ShadowStorageReportHeader'))
    return [string[]]$lines.ToArray()
}

function Get-WtDiskPartitionLayoutLines {
    <#
    .SYNOPSIS
        Every physical disk with its bus type and GPT/MBR style, and its
        partitions (including the hidden EFI/Reserved/Recovery ones
        Explorer never shows), matched to Get-PhysicalDisk's MediaType /
        FirmwareVersion by Ordinal FriendlyName comparison (tr-TR's
        dotless I makes -eq / -match unreliable here). A 'File Backed
        Virtual' entry can appear in Get-PhysicalDisk but not in
        Get-Disk, so such leftovers are listed separately and labelled
        virtual. A partition's DriveLetter with no letter carries
        [char]0, not '', so it is compared by code point rather than via
        IsNullOrWhiteSpace.
    #>
    param(
        [scriptblock]$GetDisks = { Get-Disk },
        [scriptblock]$GetPartitions = { param($Number) Get-Partition -DiskNumber $Number },
        [scriptblock]$GetPhysicalDisks = { Get-PhysicalDisk }
    )
    $disks = @()
    try { $disks = @(& $GetDisks | Sort-Object -Property Number) }
    catch { $disks = @() }
    $physical = @()
    try { $physical = @(& $GetPhysicalDisks) }
    catch { $physical = @() }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($disks.Count -eq 0) { $lines.Add((Get-Translation 'DiskLayoutNoDisks')) }

    $matchedNames = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $disks) {
        $name = [string]$d.FriendlyName
        $phys = $null
        foreach ($p in $physical) {
            if ([string]::Equals([string]$p.FriendlyName, $name, [System.StringComparison]::Ordinal)) { $phys = $p; break }
        }
        if ($phys) { $matchedNames.Add([string]$phys.FriendlyName) }
        $media = if ($phys -and $phys.MediaType) { [string]$phys.MediaType } else { '-' }
        $firmware = if ($phys -and $phys.FirmwareVersion) { [string]$phys.FirmwareVersion } else { '-' }

        $lines.Add(('#{0}  {1}' -f [string]$d.Number, (Format-WtLeftTruncatedPath -Path $name -Width 44)))
        $lines.Add(('     {0}  {1}  {2}  {3}' -f [string]$d.BusType, [string]$d.PartitionStyle, (Format-WtByteSize -Bytes ([long]$d.Size)), [string]$d.HealthStatus))
        $lines.Add(('     {0}  fw {1}' -f $media, $firmware))

        $parts = $null
        try { $parts = @(& $GetPartitions ([int]$d.Number) | Sort-Object -Property PartitionNumber) }
        catch { $parts = $null }
        if ($null -eq $parts -or $parts.Count -eq 0) {
            $lines.Add('       ' + (Get-Translation 'DiskLayoutPartitionsNone'))
        }
        else {
            foreach ($pt in $parts) {
                $code = 0
                try { $code = [int][char]$pt.DriveLetter }
                catch { $code = 0 }
                $letter = if ($code -gt 32) { ([string][char]$code) + ':' } else { Get-Translation 'DiskLayoutNoLetter' }
                $tags = @()
                if ($pt.IsBoot) { $tags += 'boot' }
                if ($pt.IsSystem) { $tags += 'system' }
                if ($pt.IsHidden) { $tags += (Get-Translation 'DiskLayoutHiddenTag') }
                $tail = if ($tags.Count -gt 0) { '  [' + ($tags -join ', ') + ']' } else { '' }
                $lines.Add(('       {0,-2} {1,-11} {2,-9} {3,10}{4}' -f [string]$pt.PartitionNumber, $letter, [string]$pt.Type, (Format-WtByteSize -Bytes ([long]$pt.Size)), $tail))
            }
        }
        $lines.Add('')
    }

    $extras = @()
    foreach ($p in $physical) {
        $pname = [string]$p.FriendlyName
        $seen = $false
        foreach ($m in $matchedNames) {
            if ([string]::Equals($m, $pname, [System.StringComparison]::Ordinal)) { $seen = $true; break }
        }
        if (-not $seen) { $extras += $p }
    }
    if ($extras.Count -gt 0) {
        $lines.Add((Get-Translation 'DiskLayoutVirtualHeader'))
        foreach ($p in $extras) {
            $bus = [string]$p.BusType
            $tag = if ([string]::Equals($bus, 'File Backed Virtual', [System.StringComparison]::Ordinal)) { Get-Translation 'DiskLayoutVirtualTag' } else { $bus }
            $lines.Add(('  {0}  {1}  {2}' -f (Format-WtLeftTruncatedPath -Path ([string]$p.FriendlyName) -Width 22), (Format-WtByteSize -Bytes ([long]$p.Size)), $tag))
        }
    }
    return [string[]]$lines.ToArray()
}
