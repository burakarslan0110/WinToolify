# Cleanup catalog, preview, Invoke-WtCleanup and the preview action.
# Covered by: tests/CleanupPreview.Tests.ps1

# ---------------------------------------------------------------------------
# Disk & System Health bundle - Cleanup Preview
# ---------------------------------------------------------------------------

function Get-WtCleanupCatalog {
    <#
    .SYNOPSIS
        The eight cleanup categories: five SAFE entries, then three
        CAUTION ones. Each carries path specs (@{ Path; Recurse; Patterns
        }) and the services to stop around the delete. Every path is
        built from -Environment so the catalog is testable without real
        Windows environment variables. Paths use [System.IO.Path]::Combine
        instead of Join-Path, since Join-Path fails when the drive letter
        does not exist (the dev host, a detached drive).
    #>
    param(
        [hashtable]$Environment = @{
            LOCALAPPDATA = $env:LOCALAPPDATA
            WinDir       = $env:WinDir
            SystemDrive  = $env:SystemDrive
            ProgramData  = $env:ProgramData
        },

        [AllowEmptyCollection()]
        [string[]]$FixedDriveRoots = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.RootDirectory.FullName })
    )

    $localAppData = "$($Environment.LOCALAPPDATA)"
    $winDir = "$($Environment.WinDir)"
    $systemDrive = "$($Environment.SystemDrive)"
    $programData = "$($Environment.ProgramData)"

    $systemDriveRoot = if ($systemDrive -match '^[A-Za-z]:$') { "$systemDrive\" } else { $systemDrive }

    $werPaths = @(
        ([System.IO.Path]::Combine($programData, 'Microsoft', 'Windows', 'WER')),
        ([System.IO.Path]::Combine($localAppData, 'Microsoft', 'Windows', 'WER'))
    )

    $recycleSpecs = @(foreach ($root in @($FixedDriveRoots)) {
        [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($root, '$Recycle.Bin')); Recurse = $true; Patterns = $null }
    })

    return Resolve-WtCatalogText -KeyPrefix 'Cleanup' -Catalog @(
        [PSCustomObject]@{
            Name           = 'UserTemp'
            DisplayLabel   = 'User temporary files'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($localAppData, 'Temp')); Recurse = $true; Patterns = $null })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'WindowsTemp'
            DisplayLabel   = 'Windows temporary files'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'Temp')); Recurse = $true; Patterns = $null })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'SystemDriveLeftovers'
            DisplayLabel   = 'System-drive root leftovers (*.tmp, *.bak, *.old, *.log, *.chk, *.gid, *._mp)'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @([PSCustomObject]@{ Path = $systemDriveRoot; Recurse = $false; Patterns = @('*.tmp', '*.bak', '*.old', '*.log', '*.chk', '*.gid', '*._mp') })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'CrashDumps'
            DisplayLabel   = 'Crash dumps (MEMORY.DMP, Minidump)'
            Risk           = 'SAFE'
            Consequence    = 'Only needed to debug a past crash'
            PathSpecs      = @(
                [PSCustomObject]@{ Path = $winDir; Recurse = $false; Patterns = @('MEMORY.DMP') }
                [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'Minidump')); Recurse = $false; Patterns = @('*.dmp') }
            )
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'ErrorReports'
            DisplayLabel   = 'Windows Error Reporting queues'
            Risk           = 'SAFE'
            Consequence    = $null
            PathSpecs      = @(foreach ($wer in $werPaths) {
                [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($wer, 'ReportQueue')); Recurse = $true; Patterns = $null }
                [PSCustomObject]@{ Path = ([System.IO.Path]::Combine($wer, 'ReportArchive')); Recurse = $true; Patterns = $null }
            })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'WindowsUpdateCache'
            DisplayLabel   = 'Windows Update download cache'
            Risk           = 'CAUTION'
            Consequence    = 'Windows Update stops briefly; pending update downloads start over'
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'SoftwareDistribution', 'Download')); Recurse = $true; Patterns = $null })
            ServicesToStop = @('wuauserv', 'bits')
        }
        [PSCustomObject]@{
            Name           = 'Prefetch'
            DisplayLabel   = 'Prefetch (*.pf)'
            Risk           = 'CAUTION'
            Consequence    = 'Windows rebuilds it; first launches are slower for a few days'
            PathSpecs      = @([PSCustomObject]@{ Path = ([System.IO.Path]::Combine($winDir, 'Prefetch')); Recurse = $false; Patterns = @('*.pf') })
            ServicesToStop = @()
        }
        [PSCustomObject]@{
            Name           = 'RecycleBin'
            DisplayLabel   = 'Recycle Bin (all users, all fixed drives)'
            Risk           = 'CAUTION'
            Consequence    = 'Permanently deletes recycled files for every user on every fixed drive'
            PathSpecs      = $recycleSpecs
            ServicesToStop = @()
        }
    )
}

function Get-WtCleanupPreview {
    <#
    .SYNOPSIS
        Walks every category's path specs up front and reports the exact
        files, byte total, and count per category - the list the delete
        engine acts on verbatim. Catalog metadata (label, risk,
        consequence, services) is copied onto each preview object so
        neither the engine nor the menu needs a second catalog lookup.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Catalog,

        [scriptblock]$InventoryAction = {
            param($Spec)
            if ($Spec.Patterns) {
                Get-WtFileInventory -Root $Spec.Path -Recurse $Spec.Recurse -Patterns $Spec.Patterns
            }
            else {
                Get-WtFileInventory -Root $Spec.Path -Recurse $Spec.Recurse
            }
        }
    )

    $preview = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Catalog) {
        $files = New-Object System.Collections.Generic.List[object]
        $directories = New-Object System.Collections.Generic.List[string]
        $skipped = 0

        foreach ($spec in @($entry.PathSpecs)) {
            $inventory = & $InventoryAction $spec
            foreach ($file in @($inventory.Files)) { $files.Add($file) }
            if ($spec.Recurse) {
                foreach ($directory in @($inventory.Directories)) { $directories.Add($directory) }
            }
            $skipped += [int]$inventory.SkippedDirectories
        }

        $bytes = 0L
        foreach ($file in $files) { $bytes += [long]$file.Length }

        $preview.Add([PSCustomObject]@{
            Name               = $entry.Name
            DisplayLabel       = $entry.DisplayLabel
            Risk               = $entry.Risk
            Consequence        = $entry.Consequence
            ServicesToStop     = @($entry.ServicesToStop)
            Files              = $files.ToArray()
            Directories        = $directories.ToArray()
            Bytes              = $bytes
            Count              = $files.Count
            SkippedDirectories = $skipped
        })
    }

    return $preview.ToArray()
}

function Format-WtCleanupPreviewLabel {
    <#
    .SYNOPSIS
        The selector state label for one preview row: "245.3 MB (1,204
        files)" / "245.3 MB (1.204 dosya)" - size via Format-WtByteSize,
        count in invariant culture, the sentence itself localized.
    #>
    param(
        [Parameter(Mandatory)]
        [long]$Bytes,

        [Parameter(Mandatory)]
        [int]$Count
    )

    $countText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $Count)
    return (Get-Translation 'CleanupPreviewLabel') -f (Format-WtByteSize -Bytes $Bytes), $countText
}

function Invoke-WtCleanup {
    <#
    .SYNOPSIS
        Deletes exactly the files the preview captured for each selected
        category - per file, -LiteralPath, never -Recurse (on PS 5.1,
        Remove-Item -Recurse through a junction deletes the target's
        contents). A file that cannot be removed counts as skipped, not
        freed. Empty subdirectories the walk entered are pruned
        afterwards; the category root stays. The Windows Update category
        stops wuauserv/bits first and restarts, in a finally block, only
        the services it found running.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Preview,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedNames,

        [scriptblock]$RemoveFileAction = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop },

        [scriptblock]$RemoveDirectoryAction = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop },

        [scriptblock]$StopServiceAction = {
            param($Name)
            $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Stop-Service -Name $Name -Force -ErrorAction Stop
                return $true
            }
            return $false
        },

        [scriptblock]$StartServiceAction = { param($Name) Start-Service -Name $Name -ErrorAction Stop },

        [scriptblock]$ReportProgressAction = {
            param($Category, $Done, $Total)
            Write-Progress -Activity "Cleaning $Category" -Status "$Done of $Total files" -PercentComplete ([math]::Min(100, [int](100 * $Done / [math]::Max(1, $Total))))
        }
    )

    $results = New-Object System.Collections.Generic.List[object]
    $selected = @($Preview | Where-Object { $SelectedNames -contains $_.Name })

    foreach ($category in $selected) {
        $freed = 0L
        $deleted = 0
        $skipped = 0
        $errors = New-Object System.Collections.Generic.List[string]
        $stopped = New-Object System.Collections.Generic.List[string]

        foreach ($serviceName in @($category.ServicesToStop)) {
            try {
                if (& $StopServiceAction $serviceName) { $stopped.Add($serviceName) }
            }
            catch {
                if ($errors.Count -lt 5) { $errors.Add("Stop $serviceName - $($_.Exception.Message)") }
            }
        }

        try {
            $files = @($category.Files)
            $done = 0
            foreach ($file in $files) {
                try {
                    & $RemoveFileAction $file.Path
                    $freed += [long]$file.Length
                    $deleted++
                }
                catch {
                    $skipped++
                    if ($errors.Count -lt 5) { $errors.Add("$($file.Path) - $($_.Exception.Message)") }
                }
                $done++
                if (($done % 100) -eq 0) { & $ReportProgressAction $category.DisplayLabel $done $files.Count }
            }

            $directories = @($category.Directories | Sort-Object -Property { $_.Length } -Descending)
            foreach ($directory in $directories) {
                try {
                    if ((Test-Path -LiteralPath $directory -PathType Container) -and @([System.IO.Directory]::EnumerateFileSystemEntries($directory)).Count -eq 0) {
                        & $RemoveDirectoryAction $directory
                    }
                }
                catch { }
            }
        }
        finally {
            foreach ($serviceName in $stopped) {
                try {
                    & $StartServiceAction $serviceName
                }
                catch {
                    if ($errors.Count -lt 5) { $errors.Add("Start $serviceName - $($_.Exception.Message)") }
                }
            }
        }

        $results.Add([PSCustomObject]@{
            Name         = $category.Name
            DisplayLabel = $category.DisplayLabel
            FreedBytes   = $freed
            DeletedCount = $deleted
            SkippedCount = $skipped
            Errors       = $errors.ToArray()
        })
    }
    Write-Progress -Activity 'Cleaning' -Completed

    $totalFreed = 0L
    $totalDeleted = 0
    $totalSkipped = 0
    foreach ($result in $results) {
        $totalFreed += $result.FreedBytes
        $totalDeleted += $result.DeletedCount
        $totalSkipped += $result.SkippedCount
    }

    return [PSCustomObject]@{
        Results           = $results.ToArray()
        TotalFreedBytes   = $totalFreed
        TotalDeletedCount = $totalDeleted
        TotalSkippedCount = $totalSkipped
    }
}


function Invoke-WtCleanupPreviewAction {
    <#
    .SYNOPSIS
        Cleanup Preview screen: shows sizes, requires the typed
        confirmation gate, then deletes exactly the previewed files. Not
        a guarded change - nothing deleted here is restorable, so there
        is no undo entry.
    #>
    $cleanupCatalog = @(Get-WtCleanupCatalog)
    $cleanupPreview = @(Get-WtCleanupPreview -Catalog $cleanupCatalog)
    $cleanupStateItems = foreach ($previewEntry in $cleanupPreview) {
        [PSCustomObject]@{
            Name       = $previewEntry.Name
            Selectable = ($previewEntry.Count -gt 0)
            StateLabel = Format-WtCleanupPreviewLabel -Bytes $previewEntry.Bytes -Count $previewEntry.Count
        }
    }
    if (@($cleanupPreview | Where-Object { $_.Count -gt 0 }).Count -eq 0) {
        Wait-WtEnter -Lines @((Get-Translation 'NothingToClean'))
        return
    }
    $selectedCleanup = @(Show-WtSelector -Catalog $cleanupCatalog -StateItems $cleanupStateItems -Title (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CleanUnnecessaryFiles') -UnselectableNote '')
    if ($selectedCleanup.Count -eq 0) { return }
    $selectedPreview = @($cleanupPreview | Where-Object { $selectedCleanup -contains $_.Name })
    $reclaimable = 0L
    $detail = New-Object System.Collections.Generic.List[string]
    foreach ($previewEntry in $selectedPreview) {
        $reclaimable += [long]$previewEntry.Bytes
        $detail.Add("  $($previewEntry.DisplayLabel) [$(Get-WtRiskLabel -Risk ([string]$previewEntry.Risk))]: $(Format-WtCleanupPreviewLabel -Bytes $previewEntry.Bytes -Count $previewEntry.Count)")
        if ($previewEntry.Consequence) { $detail.Add("      $($previewEntry.Consequence)") }
    }
    $detail.Add('')
    $detail.Add("$(Get-Translation 'ReclaimableTotal'): $(Format-WtByteSize -Bytes $reclaimable)")
    if (Confirm-WtDestructiveAction -Consequence (Get-Translation 'CleanupConfirmConsequence') -Lines $detail.ToArray() -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CleanUnnecessaryFiles')) {
        $cleanupResult = Invoke-WtCleanup -Preview $cleanupPreview -SelectedNames $selectedCleanup
        Show-WtOutputScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'CleanUnnecessaryFiles') `
            -Lines (Format-WtCleanupResultLines -Result $cleanupResult) | Out-Null
    }
    else {
        Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
    }
}

function Format-WtCleanupResultLines {
    <#
    .SYNOPSIS
        PURE: the cleanup outcome - a line per category with freed size,
        deleted and skipped counts, each category's errors indented under
        it, then the total.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'CleanupResultTitle') + ':')
    $lines.Add('')
    foreach ($category in @($Result.Results)) {
        $lines.Add(('  {0}: {1} {2}, {3} {4}, {5} {6}' -f $category.DisplayLabel,
            (Format-WtByteSize -Bytes $category.FreedBytes), (Get-Translation 'FreedSpace'),
            $category.DeletedCount, (Get-Translation 'FilesDeleted'),
            $category.SkippedCount, (Get-Translation 'FilesSkipped')))
        foreach ($err in @($category.Errors)) { $lines.Add('      ' + $err) }
    }
    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-Translation 'FreedSpace'), (Format-WtByteSize -Bytes $Result.TotalFreedBytes)))
    return [string[]]$lines.ToArray()
}
