# File inventory, prehash, duplicate groups and the action.
# Covered by: tests/DuplicateFinder.Tests.ps1

# ---------------------------------------------------------------------------
# Disk & System Health bundle - file walker and duplicate finder
# ---------------------------------------------------------------------------

$script:WtDuplicateMinSizeBytes = 16384
$script:WtDuplicatePrehashBytes = 4096

function Get-WtFileInventory {
    <#
    .SYNOPSIS
        Iterative directory walk shared by the duplicate finder and the
        cleanup preview. Skips ReparsePoint directories (junctions, symlinks
        - Get-ChildItem -Recurse follows them on 5.1) and skips files that
        are reparse points, Offline, or OneDrive online-only placeholders
        (RECALL_ON_DATA_ACCESS/RECALL_ON_OPEN bits - hashing them would
        download them); a directory it cannot enumerate is counted, not
        thrown. Returns
        @{ Files = @(@{ Path; Length; LastWriteTime }); Directories = @(...);
        SkippedDirectories; SkippedFiles }.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [bool]$Recurse = $true,

        [string[]]$Patterns,

        [long]$MinSizeBytes = 0,

        [scriptblock]$ReportProgressAction = {
            param($DirectoriesScanned, $FilesFound)
            Write-Progress -Activity 'Scanning' -Status "$FilesFound files in $DirectoriesScanned folders"
        }
    )

    $files = New-Object System.Collections.Generic.List[object]
    $directories = New-Object System.Collections.Generic.List[string]
    $skippedDirectories = 0
    $skippedFiles = 0
    $scanned = 0

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [PSCustomObject]@{ Files = @(); Directories = @(); SkippedDirectories = 0; SkippedFiles = 0 }
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $offline = [System.IO.FileAttributes]::Offline
    $recallBits = 0x400000 -bor 0x40000

    $rootInfo = [System.IO.DirectoryInfo]$Root
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($rootInfo)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $scanned++

        try {
            $entries = @($dir.EnumerateFileSystemInfos())
        }
        catch {
            $skippedDirectories++
            continue
        }

        if ($dir.FullName -ne $rootInfo.FullName) {
            $directories.Add($dir.FullName)
        }

        foreach ($entry in $entries) {
            $attributes = $entry.Attributes
            if ($entry -is [System.IO.DirectoryInfo]) {
                if ($Recurse -and (($attributes -band $reparse) -eq 0)) {
                    $stack.Push($entry)
                }
                continue
            }

            if ((($attributes -band $reparse) -ne 0) -or (($attributes -band $offline) -ne 0) -or (([int]$attributes -band $recallBits) -ne 0)) {
                $skippedFiles++
                continue
            }

            if ($entry.Length -lt $MinSizeBytes) { continue }

            if ($Patterns) {
                $matched = $false
                foreach ($pattern in $Patterns) {
                    if ($entry.Name -like $pattern) { $matched = $true; break }
                }
                if (-not $matched) { continue }
            }

            $files.Add([PSCustomObject]@{
                Path          = $entry.FullName
                Length        = [long]$entry.Length
                LastWriteTime = $entry.LastWriteTime
            })
        }

        if (($scanned % 200) -eq 0) {
            & $ReportProgressAction $scanned $files.Count
        }
    }

    & $ReportProgressAction $scanned $files.Count
    Write-Progress -Activity 'Scanning' -Completed

    return [PSCustomObject]@{
        Files              = $files.ToArray()
        Directories        = $directories.ToArray()
        SkippedDirectories = $skippedDirectories
        SkippedFiles       = $skippedFiles
    }
}

function Get-WtFilePrehash {
    <#
    .SYNOPSIS
        SHA-256 of a file's first $script:WtDuplicatePrehashBytes bytes -
        the cheap discriminator between same-size files before the full
        hash (czkawka's prehash stage).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $script:WtDuplicatePrehashBytes
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($buffer, 0, $read)) -replace '-', '')
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-WtDuplicateGroups {
    <#
    .SYNOPSIS
        Hash-based duplicate grouping: group by size, prehash the
        collisions, full-hash the survivors, keep only groups of two or
        more byte-identical files. A file whose hash throws (locked,
        vanished) is dropped from its group and counted, never fatal.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Files,

        [scriptblock]$PrehashAction = { param($Path) Get-WtFilePrehash -Path $Path },

        [scriptblock]$FullHashAction = { param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash },

        [scriptblock]$ReportProgressAction = {
            param($Done, $Total)
            Write-Progress -Activity 'Hashing' -Status "$Done of $Total files" -PercentComplete ([math]::Min(100, [int](100 * $Done / [math]::Max(1, $Total))))
        }
    )

    $unreadable = 0
    $hashed = 0

    $bySize = @{}
    foreach ($file in $Files) {
        $key = [string][long]$file.Length
        if (-not $bySize.ContainsKey($key)) { $bySize[$key] = New-Object System.Collections.Generic.List[object] }
        $bySize[$key].Add($file)
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($group in $bySize.Values) {
        if ($group.Count -ge 2) { foreach ($file in $group) { $candidates.Add($file) } }
    }

    $byPrehash = @{}
    $done = 0
    foreach ($file in $candidates) {
        try {
            $prehash = & $PrehashAction $file.Path
            $key = '{0}|{1}' -f [long]$file.Length, $prehash
            if (-not $byPrehash.ContainsKey($key)) { $byPrehash[$key] = New-Object System.Collections.Generic.List[object] }
            $byPrehash[$key].Add($file)
        }
        catch {
            $unreadable++
        }
        $done++
        if (($done % 50) -eq 0) { & $ReportProgressAction $done $candidates.Count }
    }

    $byHash = @{}
    $survivors = New-Object System.Collections.Generic.List[object]
    foreach ($group in $byPrehash.Values) {
        if ($group.Count -ge 2) { foreach ($file in $group) { $survivors.Add($file) } }
    }
    $done = 0
    foreach ($file in $survivors) {
        try {
            $hash = & $FullHashAction $file.Path
            $hashed++
            $key = '{0}|{1}' -f [long]$file.Length, $hash
            if (-not $byHash.ContainsKey($key)) { $byHash[$key] = New-Object System.Collections.Generic.List[object] }
            $byHash[$key].Add($file)
        }
        catch {
            $unreadable++
        }
        $done++
        if (($done % 50) -eq 0) { & $ReportProgressAction $done $survivors.Count }
    }
    Write-Progress -Activity 'Hashing' -Completed

    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($key in $byHash.Keys) {
        $group = $byHash[$key]
        if ($group.Count -lt 2) { continue }
        $length = [long]$group[0].Length
        $groups.Add([PSCustomObject]@{
            Hash        = ($key -split '\|', 2)[1]
            Length      = $length
            Paths       = @($group | ForEach-Object { $_.Path })
            WastedBytes = ($group.Count - 1) * $length
        })
    }

    $sorted = @($groups.ToArray() | Sort-Object -Property WastedBytes -Descending)
    $totalWasted = 0L
    $duplicateCount = 0
    foreach ($group in $sorted) {
        $totalWasted += [long]$group.WastedBytes
        $duplicateCount += @($group.Paths).Count
    }

    return [PSCustomObject]@{
        Groups             = $sorted
        TotalWastedBytes   = $totalWasted
        FilesConsidered    = @($Files).Count
        FilesHashed        = $hashed
        DuplicateFileCount = $duplicateCount
        UnreadableFiles    = $unreadable
    }
}

function Get-WtDuplicateScanRootCatalog {
    <#
    .SYNOPSIS
        The known user folders offered as duplicate-scan roots, in the
        Show-WtSelector catalog shape (Name/DisplayLabel/Risk/Consequence)
        plus Path. A folder that does not exist on this machine is still
        listed - the menu marks it unselectable.
    #>
    $downloads = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' } else { '' }
    $entries = @(
        @{ Name = 'Desktop'; Path = [Environment]::GetFolderPath('Desktop') }
        @{ Name = 'Documents'; Path = [Environment]::GetFolderPath('MyDocuments') }
        @{ Name = 'Downloads'; Path = $downloads }
        @{ Name = 'Pictures'; Path = [Environment]::GetFolderPath('MyPictures') }
        @{ Name = 'Videos'; Path = [Environment]::GetFolderPath('MyVideos') }
        @{ Name = 'Music'; Path = [Environment]::GetFolderPath('MyMusic') }
    )

    return Resolve-WtCatalogText -KeyPrefix 'DuplicateScanRoot' -Catalog @($entries | ForEach-Object {
        [PSCustomObject]@{
            Name         = $_.Name
            DisplayLabel = '{0} ({1})' -f $_.Name, $_.Path
            LabelArgs    = @($_.Path)
            Risk         = 'SAFE'
            Consequence  = $null
            Path         = $_.Path
        }
    })
}

function Format-WtDuplicateReportLines {
    <#
    .SYNOPSIS
        Renders a Get-WtDuplicateGroups result as plain string lines:
        totals, then the first -MaxGroups groups (all when omitted) with
        one indented path per copy.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,

        [int]$MaxGroups = 0
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $groups = @($Result.Groups)
    $lines.Add('=== Duplicate files ===')
    $lines.Add("Files considered: $($Result.FilesConsidered), hashed: $($Result.FilesHashed), duplicates: $($Result.DuplicateFileCount) in $($groups.Count) groups")
    $lines.Add("Total wasted space: $(Format-WtByteSize -Bytes $Result.TotalWastedBytes)")
    if ($Result.UnreadableFiles -gt 0) {
        $lines.Add("Unreadable files skipped: $($Result.UnreadableFiles)")
    }

    if ($groups.Count -eq 0) {
        $lines.Add('No duplicate files found.')
        return $lines.ToArray()
    }

    $limit = if ($MaxGroups -gt 0) { [math]::Min($MaxGroups, $groups.Count) } else { $groups.Count }
    for ($i = 0; $i -lt $limit; $i++) {
        $group = $groups[$i]
        $paths = @($group.Paths)
        $lines.Add(('{0}. {1} copies x {2} - wasted {3}' -f ($i + 1), $paths.Count, (Format-WtByteSize -Bytes $group.Length), (Format-WtByteSize -Bytes $group.WastedBytes)))
        foreach ($path in $paths) { $lines.Add("    $path") }
    }

    if ($limit -lt $groups.Count) {
        $lines.Add("... $($groups.Count - $limit) more groups in the saved report")
    }

    return $lines.ToArray()
}


function Invoke-WtDuplicateFinderAction {
    <#
    .SYNOPSIS
        Duplicate File Finder: report only, never deletes.
    #>
    $scanRoots = @(Get-WtDuplicateScanRootCatalog)
    $scanStateItems = foreach ($entry in $scanRoots) {
        $exists = [bool]($entry.Path -and (Test-Path -LiteralPath $entry.Path -PathType Container))
        [PSCustomObject]@{
            Name       = $entry.Name
            Selectable = $exists
            StateLabel = if ($exists) { $entry.Path } else { Get-Translation 'FolderNotFound' }
        }
    }
    $selectedRoots = @(Show-WtSelector -Catalog $scanRoots -StateItems $scanStateItems -Title (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'DuplicateFinder') -UnselectableNote '')
    $rootPaths = @($scanRoots | Where-Object { $selectedRoots -contains $_.Name } | ForEach-Object { $_.Path })
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'DuplicateFinder'
    $script:WtPanelBreadcrumb = $crumb
    $extraFolder = ([string](Read-WtPanelAnswer -Breadcrumb $crumb -Lines @() -Prompt (Get-Translation 'ExtraFolderPrompt') -Layout 'Compact')).Trim()
    if ($extraFolder) {
        if (Test-Path -LiteralPath $extraFolder -PathType Container) { $rootPaths += $extraFolder }
        else { Wait-WtEnter -Lines @('{0}: {1}' -f (Get-Translation 'FolderNotFound'), $extraFolder) }
    }
    if ($rootPaths.Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NoScanRoots'))
        return
    }
    Show-WtPanelMessage -Breadcrumb $crumb -Lines @((Get-Translation 'DuplicateFinder')) -FooterText ((Get-Translation 'OutputRunning') -f (Format-WtElapsed -Seconds 0)) | Out-Null
    $scanFiles = @(foreach ($rootPath in $rootPaths) {
        (Get-WtFileInventory -Root $rootPath -MinSizeBytes $script:WtDuplicateMinSizeBytes).Files
    })
    $duplicateResult = Get-WtDuplicateGroups -Files $scanFiles
    Show-WtSavableReport -Breadcrumb $crumb -ReportName 'duplicates' `
        -Lines (@((Get-Translation 'DuplicateFinder'), '') + @(Format-WtDuplicateReportLines -Result $duplicateResult -MaxGroups 25)) `
        -SaveAction { param($Name, $Rows) Save-WtReport -Name $Name -Lines @(Format-WtDuplicateReportLines -Result $duplicateResult) }
}
