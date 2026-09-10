#Requires -Modules Pester

<#
.SYNOPSIS
    Actions > Cleanup and disk: the browser cache catalog/measurer/clearer,
    the DISM component-store row, the per-volume TRIM-or-defragment picker,
    the boot-time disk repair plan, and the restore-point delete loop that
    always leaves the newest point standing. Every Windows data source is
    injected: no test touches a real disk, a real process list, or a real
    shadow copy.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtBrowserCacheCatalog' {
    BeforeAll {
        $script:BrowserCatalog = @(Get-WtBrowserCacheCatalog -Environment @{ LOCALAPPDATA = 'X:\la' })
    }

    It 'lists Edge, Chrome and Firefox, built from the injected LOCALAPPDATA' {
        @($BrowserCatalog | ForEach-Object { $_.Name }) | Should -Be @('Edge', 'Chrome', 'Firefox')
        ($BrowserCatalog | Where-Object { $_.Name -ceq 'Edge' }).ProfileRoot | Should -Be 'X:\la\Microsoft\Edge\User Data'
        ($BrowserCatalog | Where-Object { $_.Name -ceq 'Chrome' }).ProfileRoot | Should -Be 'X:\la\Google\Chrome\User Data'
        ($BrowserCatalog | Where-Object { $_.Name -ceq 'Firefox' }).ProfileRoot | Should -Be 'X:\la\Mozilla\Firefox\Profiles'
    }

    It 'names only cache folders - never a profile root that holds logins or bookmarks' {
        ($BrowserCatalog | Where-Object { $_.Name -ceq 'Chrome' }).CacheSubPaths | Should -Be @('Cache\Cache_Data', 'Code Cache', 'GPUCache')
        ($BrowserCatalog | Where-Object { $_.Name -ceq 'Firefox' }).CacheSubPaths | Should -Be @('cache2')
    }
}

Describe 'Get-WtBrowserCacheTargets' {
    It 'measures every profile cache folder and sees a running browser whatever the case' {
        $catalog = @([PSCustomObject]@{
            Name = 'Edge'; DisplayLabel = 'Microsoft Edge'; Risk = 'CAUTION'; Consequence = $null
            ProcessNames = @('msedge'); ProfileRoot = 'X:\la\Edge'
            CacheSubPaths = @('Cache\Cache_Data', 'GPUCache')
        })
        $targets = @(Get-WtBrowserCacheTargets -Catalog $catalog `
            -GetProfileNames { param($Entry) @('Default', 'Profile 1') } `
            -MeasureAction {
                param($Path)
                if ($Path.EndsWith('GPUCache', [System.StringComparison]::Ordinal)) { [PSCustomObject]@{ Bytes = 0L; Count = 0 } }
                else { [PSCustomObject]@{ Bytes = 1024L; Count = 2 } }
            } `
            -GetRunningNames { @('explorer', 'MSEDGE') })

        $targets.Count | Should -Be 1
        $targets[0].Running | Should -BeTrue
        $targets[0].Bytes | Should -Be 2048
        $targets[0].Count | Should -Be 4
        @($targets[0].Paths | ForEach-Object { $_.Path }) | Should -Be @('X:\la\Edge\Default\Cache\Cache_Data', 'X:\la\Edge\Profile 1\Cache\Cache_Data')
    }

    It 'reports a browser that is not running and drops every empty cache folder' {
        $catalog = @([PSCustomObject]@{
            Name = 'Firefox'; DisplayLabel = 'Mozilla Firefox'; Risk = 'CAUTION'; Consequence = $null
            ProcessNames = @('firefox'); ProfileRoot = 'X:\la\ff'; CacheSubPaths = @('cache2')
        })
        $targets = @(Get-WtBrowserCacheTargets -Catalog $catalog `
            -GetProfileNames { param($Entry) @('abc.default-release') } `
            -MeasureAction { param($Path) [PSCustomObject]@{ Bytes = 0L; Count = 0 } } `
            -GetRunningNames { @('explorer') })

        $targets[0].Running | Should -BeFalse
        $targets[0].Bytes | Should -Be 0
        @($targets[0].Paths).Count | Should -Be 0
    }
}

Describe 'Invoke-WtBrowserCacheClear' {
    BeforeAll {
        function script:New-Target {
            param($Name, $Running, $Bytes)
            [PSCustomObject]@{
                Name = $Name; DisplayLabel = $Name; ProcessNames = @($Name.ToLowerInvariant())
                Running = $Running
                Paths = @([PSCustomObject]@{ ProfileName = 'Default'; Path = "X:\$Name\Default\Cache"; Bytes = [long]$Bytes; Count = 3 })
                Bytes = [long]$Bytes; Count = 3
            }
        }
    }

    It 'deletes the measured folders of a browser that is not running' {
        $removed = New-Object System.Collections.Generic.List[string]
        $result = Invoke-WtBrowserCacheClear -Targets @((New-Target -Name 'Chrome' -Running $false -Bytes 4096)) `
            -StopAction { param($ProcessNames) throw 'must not be called' } `
            -IsRunningAction { param($ProcessNames) $false } `
            -RemoveAction { param($Path) $removed.Add([string]$Path) }

        @($removed) | Should -Be @('X:\Chrome\Default\Cache')
        $result.TotalFreedBytes | Should -Be 4096
        $result.Results[0].SkippedReasonKey | Should -Be ''
    }

    It 'skips a running browser the user did not agree to close, and deletes nothing' {
        $removed = New-Object System.Collections.Generic.List[string]
        $result = Invoke-WtBrowserCacheClear -Targets @((New-Target -Name 'Edge' -Running $true -Bytes 8192)) `
            -StopAction { param($ProcessNames) throw 'must not be called' } `
            -IsRunningAction { param($ProcessNames) $true } `
            -RemoveAction { param($Path) $removed.Add([string]$Path) }

        @($removed).Count | Should -Be 0
        $result.TotalFreedBytes | Should -Be 0
        $result.Results[0].SkippedReasonKey | Should -Be 'BrowserCacheSkipped'
    }

    It 'closes a browser named in -CloseNames, then deletes its caches' {
        $stopped = New-Object System.Collections.Generic.List[string]
        $removed = New-Object System.Collections.Generic.List[string]
        $result = Invoke-WtBrowserCacheClear -Targets @((New-Target -Name 'Edge' -Running $true -Bytes 8192)) -CloseNames @('Edge') `
            -StopAction { param($ProcessNames) foreach ($n in @($ProcessNames)) { $stopped.Add([string]$n) } } `
            -IsRunningAction { param($ProcessNames) $false } `
            -RemoveAction { param($Path) $removed.Add([string]$Path) }

        @($stopped) | Should -Be @('edge')
        @($removed) | Should -Be @('X:\Edge\Default\Cache')
        $result.TotalFreedBytes | Should -Be 8192
    }

    It 'says the close failed when the process survives - Edge outlives its last window' {
        $result = Invoke-WtBrowserCacheClear -Targets @((New-Target -Name 'Edge' -Running $true -Bytes 8192)) -CloseNames @('Edge') `
            -StopAction { param($ProcessNames) } `
            -IsRunningAction { param($ProcessNames) $true } `
            -RemoveAction { param($Path) throw 'must not be called' }

        $result.Results[0].SkippedReasonKey | Should -Be 'BrowserCacheCloseFailed'
        $result.TotalFreedBytes | Should -Be 0
    }

    It 'records a delete error per path instead of throwing' {
        $result = Invoke-WtBrowserCacheClear -Targets @((New-Target -Name 'Chrome' -Running $false -Bytes 4096)) `
            -StopAction { param($ProcessNames) } `
            -IsRunningAction { param($ProcessNames) $false } `
            -RemoveAction { param($Path) throw 'locked' }

        @($result.Results[0].Errors).Count | Should -Be 1
        $result.TotalFreedBytes | Should -Be 0
    }
}

Describe 'Browser cache report lines' {
    It 'sums a browser once per profile and always prints the untouched line' {
        $targets = @([PSCustomObject]@{
            Name = 'Edge'; DisplayLabel = 'Microsoft Edge'; ProcessNames = @('msedge'); Running = $false
            Paths = @(
                [PSCustomObject]@{ ProfileName = 'Default'; Path = 'X:\a'; Bytes = 1024L; Count = 1 }
                [PSCustomObject]@{ ProfileName = 'Default'; Path = 'X:\b'; Bytes = 1024L; Count = 1 }
                [PSCustomObject]@{ ProfileName = 'Profile 1'; Path = 'X:\c'; Bytes = 2048L; Count = 1 }
            )
            Bytes = 4096L; Count = 3
        })
        $lines = @(Format-WtBrowserCacheLines -Targets $targets)
        @($lines | Where-Object { $_ -clike '*Default*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -clike '*Profile 1*' }).Count | Should -Be 1
        $lines[-1] | Should -Be (Get-Translation 'BrowserCacheUntouched')
    }

    It 'renders a skipped browser by its reason key and totals the freed bytes' {
        $result = [PSCustomObject]@{
            TotalFreedBytes = 4096L
            Results = @(
                [PSCustomObject]@{ Name = 'Edge'; DisplayLabel = 'Microsoft Edge'; FreedBytes = 0L; SkippedReasonKey = 'BrowserCacheSkipped'; Errors = @() }
                [PSCustomObject]@{ Name = 'Chrome'; DisplayLabel = 'Google Chrome'; FreedBytes = 4096L; SkippedReasonKey = ''; Errors = @() }
            )
        }
        $lines = @(Format-WtBrowserCacheResultLines -Result $result)
        @($lines | Where-Object { $_ -clike ('*' + (Get-Translation 'BrowserCacheSkipped') + '*') }).Count | Should -Be 1
        @($lines | Where-Object { $_ -clike '*4.0 KB*' }).Count | Should -BeGreaterThan 0
        $lines[-1] | Should -Be (Get-Translation 'BrowserCacheUntouched')
    }
}

Describe 'ActionGroupCleanupDisk rows' {
    BeforeAll {
        $script:CleanupGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -ceq 'ActionGroupCleanupDisk' }
        $script:CleanupRows = @(& $CleanupGroup.GetRows)
    }

    It 'carries the ClearBrowserCaches row as a plain inline Action' {
        $row = @($CleanupRows | Where-Object { $_.Name -ceq 'ClearBrowserCaches' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.Data.Captured | Should -BeNullOrEmpty
        $row.Data.Action.ToString().IndexOf('Invoke-WtClearBrowserCachesAction', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'resolves the ClearBrowserCaches label in both languages, ASCII only, under 45 characters' {
        foreach ($lang in @('EN', 'TR')) {
            $label = [string]$script:Translations[$lang]['ClearBrowserCaches']
            $label | Should -Not -BeNullOrEmpty
            $label.Length | Should -BeLessOrEqual 45
            ($label -cmatch '[^\x00-\x7F]') | Should -BeFalse
        }
    }

    It 'runs DISM /StartComponentCleanup and never /ResetBase' {
        $row = @($CleanupRows | Where-Object { $_.Name -ceq 'CleanComponentStore' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.Data.Captured | Should -BeTrue
        $row.Risk | Should -Be 'CAUTION'
        $text = $row.Data.Action.ToString()
        $text.IndexOf('/StartComponentCleanup', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        $text.IndexOf('/ResetBase', [System.StringComparison]::Ordinal) | Should -Be -1
    }

    It 'prints a line BEFORE DISM starts, so the captured panel is never a frozen box' {
        $row = @($CleanupRows | Where-Object { $_.Name -ceq 'CleanComponentStore' })[0]
        $text = $row.Data.Action.ToString()
        $announce = $text.IndexOf('ComponentCleanupStarting', [System.StringComparison]::Ordinal)
        $dism = $text.IndexOf('/StartComponentCleanup', [System.StringComparison]::Ordinal)
        $announce | Should -BeGreaterThan -1
        $announce | Should -BeLessThan $dism
    }

    It 'says how long it takes in the LABEL, in both languages' {
        foreach ($lang in @('EN', 'TR')) {
            $label = [string]$script:Translations[$lang]['CleanComponentStore']
            $label.IndexOf('10-30', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
            $label.Length | Should -BeLessOrEqual 45
        }
    }

    It 'says the up-to-an-hour defragment cost in the OptimizeVolumes LABEL, in both languages' {
        $enLabel = [string]$script:Translations['EN']['OptimizeVolumes']
        $enLabel.IndexOf('1 h', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        $enLabel.Length | Should -BeLessOrEqual 45
        $trLabel = [string]$script:Translations['TR']['OptimizeVolumes']
        $trLabel.IndexOf('1 sa', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        $trLabel.Length | Should -BeLessOrEqual 45
    }

    It 'carries the OptimizeVolumes row as an inline picker, not a blind loop' {
        $row = @($CleanupRows | Where-Object { $_.Name -ceq 'OptimizeVolumes' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.Data.Captured | Should -BeNullOrEmpty
        $row.Data.Action.ToString().IndexOf('Invoke-WtOptimizeVolumesAction', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'gates the ADVANCED ScheduleDiskRepair row behind a typed confirmation' {
        $row = @($CleanupRows | Where-Object { $_.Name -ceq 'ScheduleDiskRepair' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.Risk | Should -Be 'ADVANCED'
        $source = Get-Content -LiteralPath $script:TargetPath -Raw
        $body = $source.Substring($source.IndexOf('function Invoke-WtScheduleDiskRepairAction', [System.StringComparison]::Ordinal))
        $body.IndexOf('Confirm-WtDestructiveAction', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'holds the eight catalogue rows in catalogue order' {
        @($CleanupRows | ForEach-Object { $_.Name }) | Should -Be @(
            'WindowsDiskCleanup', 'CleanUnnecessaryFiles', 'ClearBrowserCaches', 'CleanComponentStore',
            'DuplicateFinder', 'OptimizeVolumes', 'ScheduleDiskRepair', 'DeleteOldRestorePoints'
        )
    }

    It 'gates the ADVANCED DeleteOldRestorePoints row behind a typed confirmation' {
        $row = @($CleanupRows | Where-Object { $_.Name -ceq 'DeleteOldRestorePoints' })[0]
        $row.Risk | Should -Be 'ADVANCED'
        $source = Get-Content -LiteralPath $script:TargetPath -Raw
        $body = $source.Substring($source.IndexOf('function Invoke-WtDeleteOldRestorePointsAction', [System.StringComparison]::Ordinal))
        $body.IndexOf('Confirm-WtDestructiveAction', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'never asks vssadmin to delete every shadow copy - only the oldest, one at a time' {
        $source = Get-Content -LiteralPath $script:TargetPath -Raw
        $deleteLines = @([regex]::Matches($source, 'delete\s+shadows[^\r\n]*') | ForEach-Object { $_.Value })
        @($deleteLines).Count | Should -BeGreaterThan 0
        @($deleteLines | Where-Object { $_.IndexOf('/all', [System.StringComparison]::Ordinal) -ge 0 }) | Should -BeNullOrEmpty
        @($deleteLines | Where-Object { $_.IndexOf('/oldest', [System.StringComparison]::Ordinal) -ge 0 }).Count | Should -BeGreaterThan 0
    }

    It 'resolves every new row label in both languages, ASCII only, under 45 characters' {
        foreach ($name in @('ClearBrowserCaches', 'CleanComponentStore', 'OptimizeVolumes', 'ScheduleDiskRepair', 'DeleteOldRestorePoints')) {
            foreach ($lang in @('EN', 'TR')) {
                $label = [string]$script:Translations[$lang][$name]
                $label | Should -Not -BeNullOrEmpty
                $label.Length | Should -BeLessOrEqual 45
                ($label -cmatch '[^\x00-\x7F]') | Should -BeFalse
            }
        }
    }

    It 'calls no Read-Host from any captured scriptblock in this group' {
        foreach ($row in $CleanupRows) {
            if (-not $row.Data.Captured) { continue }
            $row.Data.Action.ToString().IndexOf('Read-Host', [System.StringComparison]::Ordinal) | Should -Be -1
        }
    }
}

Describe 'Get-WtVolumeOptimizeMode' {
    It 'returns Defrag only when Windows says HDD in those exact three characters' {
        Get-WtVolumeOptimizeMode -MediaType 'HDD' | Should -Be 'Defrag'
    }

    It 'gives every flash and unknown media type ReTrim, never an hour-long defragment' {
        foreach ($mediaType in @('SSD', 'SCM', 'Unspecified', 'Unknown', '')) {
            Get-WtVolumeOptimizeMode -MediaType $mediaType | Should -Be 'ReTrim'
        }
        Get-WtVolumeOptimizeMode -MediaType $null | Should -Be 'ReTrim'
    }

    It 'does not accept a differently cased hdd - the comparison is ordinal on purpose' {
        Get-WtVolumeOptimizeMode -MediaType 'hdd' | Should -Be 'ReTrim'
    }
}

Describe 'Get-WtOptimizeVolumeCatalog' {
    BeforeAll {
        $script:FakeVolumes = @(
            [PSCustomObject]@{ DriveLetter = 'C'; DriveType = 'Fixed'; FileSystem = 'NTFS'; FileSystemLabel = 'System' }
            [PSCustomObject]@{ DriveLetter = 'D'; DriveType = 'Fixed'; FileSystem = 'NTFS'; FileSystemLabel = 'Data' }
            [PSCustomObject]@{ DriveLetter = 'E'; DriveType = 'Removable'; FileSystem = 'FAT32'; FileSystemLabel = 'Stick' }
            [PSCustomObject]@{ DriveLetter = 'F'; DriveType = 'Fixed'; FileSystem = 'exFAT'; FileSystemLabel = 'Media' }
            [PSCustomObject]@{ DriveLetter = ''; DriveType = 'Fixed'; FileSystem = 'NTFS'; FileSystemLabel = 'Reserved' }
        )
    }

    It 'keeps only fixed NTFS/ReFS volumes that have a drive letter' {
        $catalog = @(Get-WtOptimizeVolumeCatalog -GetVolumes { $FakeVolumes } -GetMediaType { param($DriveLetter) 'SSD' })
        @($catalog | ForEach-Object { $_.Name }) | Should -Be @('C', 'D')
    }

    It 'passes -Defrag only to the volume Windows calls HDD' {
        $catalog = @(Get-WtOptimizeVolumeCatalog -GetVolumes { $FakeVolumes } `
            -GetMediaType { param($DriveLetter) if ($DriveLetter -ceq 'D') { 'HDD' } else { 'SSD' } })
        ($catalog | Where-Object { $_.Name -ceq 'C' }).Mode | Should -Be 'ReTrim'
        ($catalog | Where-Object { $_.Name -ceq 'D' }).Mode | Should -Be 'Defrag'
        ($catalog | Where-Object { $_.Name -ceq 'D' }).ModeLabel | Should -Be (Get-Translation 'OptimizeModeDefrag')
    }

    It 'falls back to ReTrim and an Unknown label when the physical disk cannot be read (RAID, VM)' {
        $catalog = @(Get-WtOptimizeVolumeCatalog -GetVolumes { $FakeVolumes } -GetMediaType { param($DriveLetter) '' })
        ($catalog | Where-Object { $_.Name -ceq 'C' }).Mode | Should -Be 'ReTrim'
        ($catalog | Where-Object { $_.Name -ceq 'C' }).DisplayLabel | Should -BeLike ('*' + (Get-Translation 'StateUnknown') + '*')
    }

    It 'reads FileSystemType when FileSystem is empty' {
        $volumes = @([PSCustomObject]@{ DriveLetter = 'G'; DriveType = 'Fixed'; FileSystem = ''; FileSystemType = 'ReFS'; FileSystemLabel = 'Pool' })
        $catalog = @(Get-WtOptimizeVolumeCatalog -GetVolumes { $volumes } -GetMediaType { param($DriveLetter) 'SSD' })
        @($catalog | ForEach-Object { $_.Name }) | Should -Be @('G')
    }
}

Describe 'Get-WtDiskRepairPlan' {
    It 'sets the dirty bit for the system drive - chkdsk own question is a localized E/H that cannot be answered' {
        $plan = Get-WtDiskRepairPlan -DriveLetter 'C' -IsSystemDrive $true
        $plan.Method | Should -Be 'DirtyBit'
        $plan.ScheduleText | Should -Be 'fsutil dirty set C:'
        $plan.NoteKey | Should -Be 'DiskRepairSystemDrive'
    }

    It 'uses Repair-Volume -OfflineScanAndFix for any other volume' {
        $plan = Get-WtDiskRepairPlan -DriveLetter 'd' -IsSystemDrive $false
        $plan.DriveLetter | Should -Be 'D'
        $plan.Method | Should -Be 'OfflineScanAndFix'
        $plan.ScheduleText | Should -Be 'Repair-Volume -DriveLetter D -OfflineScanAndFix'
        $plan.NoteKey | Should -Be 'DiskRepairOfflineScan'
    }

    It 'always names the real cancel command' {
        (Get-WtDiskRepairPlan -DriveLetter 'C' -IsSystemDrive $true).CancelCommand | Should -Be 'chkntfs /x C:'
        (Get-WtDiskRepairPlan -DriveLetter 'D' -IsSystemDrive $false).CancelCommand | Should -Be 'chkntfs /x D:'
    }
}

Describe 'Get-WtDiskRepairCatalog' {
    BeforeAll {
        $script:RepairVolumes = @(
            [PSCustomObject]@{ DriveLetter = 'C'; DriveType = 'Fixed'; FileSystem = 'NTFS'; FileSystemLabel = 'System' }
            [PSCustomObject]@{ DriveLetter = 'D'; DriveType = 'Fixed'; FileSystem = 'NTFS'; FileSystemLabel = 'Data' }
            [PSCustomObject]@{ DriveLetter = 'E'; DriveType = 'Removable'; FileSystem = 'NTFS'; FileSystemLabel = 'Stick' }
        )
    }

    It 'flags the system drive from the injected SystemDrive and keeps fixed NTFS volumes only' {
        $catalog = @(Get-WtDiskRepairCatalog -GetVolumes { $RepairVolumes } -SystemDrive 'C:')
        @($catalog | ForEach-Object { $_.Name }) | Should -Be @('C', 'D')
        ($catalog | Where-Object { $_.Name -ceq 'C' }).IsSystemDrive | Should -BeTrue
        ($catalog | Where-Object { $_.Name -ceq 'D' }).IsSystemDrive | Should -BeFalse
        ($catalog | Where-Object { $_.Name -ceq 'C' }).Plan.Method | Should -Be 'DirtyBit'
        ($catalog | Where-Object { $_.Name -ceq 'D' }).Plan.Method | Should -Be 'OfflineScanAndFix'
    }

    It 'follows the system drive when Windows is not on C:' {
        $catalog = @(Get-WtDiskRepairCatalog -GetVolumes { $RepairVolumes } -SystemDrive 'D:')
        ($catalog | Where-Object { $_.Name -ceq 'D' }).IsSystemDrive | Should -BeTrue
        ($catalog | Where-Object { $_.Name -ceq 'C' }).Plan.Method | Should -Be 'OfflineScanAndFix'
    }

    It 'marks every row ADVANCED and carries the consequence the picker shows' {
        $catalog = @(Get-WtDiskRepairCatalog -GetVolumes { $RepairVolumes } -SystemDrive 'C:')
        @($catalog | ForEach-Object { $_.Risk }) | Should -Be @('ADVANCED', 'ADVANCED')
        ($catalog | Where-Object { $_.Name -ceq 'C' }).Consequence | Should -Be (Get-Translation 'DiskRepairSystemDrive')
    }
}

Describe 'Get-WtRestorePointEntries' {
    It 'normalizes a WMI datetime string and sorts newest first' {
        $entries = @(Get-WtRestorePointEntries -GetPoints {
            @(
                [PSCustomObject]@{ SequenceNumber = 1; Description = 'Old one'; CreationTime = '20260810103000.000000+180' }
                [PSCustomObject]@{ SequenceNumber = 3; Description = 'Newest'; CreationTime = '20260820103000.000000+180' }
                [PSCustomObject]@{ SequenceNumber = 2; Description = 'Middle'; CreationTime = '20260815103000.000000+180' }
            )
        })
        @($entries | ForEach-Object { $_.Description }) | Should -Be @('Newest', 'Middle', 'Old one')
        $entries[0].CreationTime | Should -Be ([System.Management.ManagementDateTimeConverter]::ToDateTime('20260820103000.000000+180'))
        $entries[0].SequenceNumber | Should -Be 3
    }

    It 'takes a real [datetime] straight through - the CIM class already hands one back' {
        $when = Get-Date -Year 2026 -Month 8 -Day 1 -Hour 9 -Minute 0 -Second 0
        $entries = @(Get-WtRestorePointEntries -GetPoints { @([PSCustomObject]@{ SequenceNumber = 7; Description = 'CIM'; CreationTime = $when }) })
        $entries[0].CreationTime | Should -Be $when
    }

    It 'returns nothing when System Protection is off - honest degradation, not a fake success' {
        @(Get-WtRestorePointEntries -GetPoints { @() }).Count | Should -Be 0
        @(Get-WtRestorePointEntries -GetPoints { $null }).Count | Should -Be 0
    }
}

Describe 'Get-WtShadowStorageEntries' {
    It 'joins Win32_ShadowStorage to its volume and reports used and allocated bytes' {
        $storage = @([PSCustomObject]@{
            UsedSpace = 12884901888L; AllocatedSpace = 21474836480L
            Volume = [PSCustomObject]@{ DeviceID = '\?\Volume{aaa}\' }
        })
        $volumes = @([PSCustomObject]@{ DeviceID = '\?\Volume{aaa}\'; DriveLetter = 'C:' })
        $entries = @(Get-WtShadowStorageEntries -GetStorage { $storage } -GetVolumes { $volumes })
        $entries.Count | Should -Be 1
        $entries[0].DriveLetter | Should -Be 'C:'
        $entries[0].UsedBytes | Should -Be 12884901888
        $entries[0].AllocatedBytes | Should -Be 21474836480
    }

    It 'says Unknown for a shadow volume with no drive letter, and nothing at all when nothing is protected' {
        $storage = @([PSCustomObject]@{ UsedSpace = 10L; AllocatedSpace = 20L; Volume = [PSCustomObject]@{ DeviceID = '\?\Volume{zzz}\' } })
        $entries = @(Get-WtShadowStorageEntries -GetStorage { $storage } -GetVolumes { @() })
        $entries[0].DriveLetter | Should -Be (Get-Translation 'StateUnknown')
        @(Get-WtShadowStorageEntries -GetStorage { @() } -GetVolumes { @() }).Count | Should -Be 0
    }
}

Describe 'Get-WtShadowCopyCount' {
    It 'counts only the shadow copies that live on the asked-for drive letter' {
        $volumes = @(
            [PSCustomObject]@{ DeviceID = '\?\Volume{c}\'; DriveLetter = 'C:' }
            [PSCustomObject]@{ DeviceID = '\?\Volume{d}\'; DriveLetter = 'D:' }
        )
        $copies = @(
            [PSCustomObject]@{ VolumeName = '\?\Volume{c}\' }
            [PSCustomObject]@{ VolumeName = '\?\Volume{c}\' }
            [PSCustomObject]@{ VolumeName = '\?\Volume{d}\' }
        )
        Get-WtShadowCopyCount -DriveLetter 'C' -GetCopies { $copies } -GetVolumes { $volumes } | Should -Be 2
        Get-WtShadowCopyCount -DriveLetter 'd' -GetCopies { $copies } -GetVolumes { $volumes } | Should -Be 1
        Get-WtShadowCopyCount -DriveLetter 'E' -GetCopies { $copies } -GetVolumes { $volumes } | Should -Be 0
    }
}

Describe 'Invoke-WtShadowOldestLoop' {
    It 'deletes oldest-first until exactly one shadow copy is left' {
        $state = @{ Count = 5 }
        $calls = New-Object System.Collections.Generic.List[string]
        $result = Invoke-WtShadowOldestLoop -DriveLetter 'C' `
            -CountAction { param($Drive) $state.Count } `
            -DeleteAction { param($Drive) $calls.Add([string]$Drive); $state.Count = $state.Count - 1 }

        $result.Remaining | Should -Be 1
        $result.Deleted | Should -Be 4
        @($calls).Count | Should -Be 4
    }

    It 'deletes nothing when only one point is left - the newest is the safety net' {
        $calls = New-Object System.Collections.Generic.List[string]
        $result = Invoke-WtShadowOldestLoop -DriveLetter 'C' `
            -CountAction { param($Drive) 1 } `
            -DeleteAction { param($Drive) $calls.Add([string]$Drive) }

        $result.Deleted | Should -Be 0
        $result.Remaining | Should -Be 1
        @($calls).Count | Should -Be 0
    }

    It 'stops instead of spinning when a delete changes nothing' {
        $calls = New-Object System.Collections.Generic.List[string]
        $result = Invoke-WtShadowOldestLoop -DriveLetter 'C' `
            -CountAction { param($Drive) 4 } `
            -DeleteAction { param($Drive) $calls.Add([string]$Drive) }

        @($calls).Count | Should -Be 1
        $result.Deleted | Should -Be 0
        $result.Remaining | Should -Be 4
    }
}

Describe 'Format-WtRestorePointDeleteLines' {
    It 'marks the newest point KEPT and marks nothing else' {
        $points = @(
            [PSCustomObject]@{ SequenceNumber = 3; Description = 'Newest'; CreationTime = (Get-Date -Year 2026 -Month 8 -Day 20 -Hour 10 -Minute 30 -Second 0) }
            [PSCustomObject]@{ SequenceNumber = 2; Description = 'Middle'; CreationTime = (Get-Date -Year 2026 -Month 8 -Day 15 -Hour 10 -Minute 30 -Second 0) }
            [PSCustomObject]@{ SequenceNumber = 1; Description = 'Oldest'; CreationTime = $null }
        )
        $lines = @(Format-WtRestorePointDeleteLines -Points $points)
        $kept = Get-Translation 'RestorePointKept'
        @($lines | Where-Object { $_ -clike ('*' + $kept + '*') }).Count | Should -Be 1
        @($lines | Where-Object { $_ -clike ('*Newest*' + $kept + '*') }).Count | Should -Be 1
        @($lines | Where-Object { $_ -clike '*2026-08-15 10:30*' }).Count | Should -Be 1
    }

    It 'lists shadow storage per drive and repeats the raw vssadmin block underneath' {
        $points = @([PSCustomObject]@{ SequenceNumber = 1; Description = 'One'; CreationTime = (Get-Date) })
        $storage = @([PSCustomObject]@{ DriveLetter = 'C:'; UsedBytes = 1073741824L; AllocatedBytes = 2147483648L })
        $lines = @(Format-WtRestorePointDeleteLines -Points $points -Storage $storage -RawLines @('Shadow Copy Storage volume: C:'))
        @($lines | Where-Object { $_ -ceq ((Get-Translation 'ShadowStorageHeader') + ':') }).Count | Should -Be 1
        @($lines | Where-Object { $_ -clike '*1.0 GB*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -ceq 'vssadmin list shadowstorage' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -clike '*Shadow Copy Storage volume*' }).Count | Should -Be 1
    }
}

Describe 'Invoke-WtOptimizeVolumesAction gate' {
    <#
    .SYNOPSIS
        This row has no Confirm-WtDestructiveAction gate - the per-volume
        picker (-SelectAction) is its only gate, since a defragment cannot
        be cancelled once it starts (Invoke-WtCapturedAction has no cancel
        key). "Declining to pick a volume" is this row's equivalent of a
        refused confirmation: it must produce zero destructive calls for
        that volume. -Run replaces Invoke-WtCapturedAction so the test
        never drives the real result screen, which reads the keyboard.
    #>
    It 'runs OptimizeAction only for the volume the user actually picked - the unpicked one gets none' {
        $script:OptimizeCalls = New-Object System.Collections.Generic.List[string]
        $catalog = @(
            [PSCustomObject]@{ Name = 'C'; DisplayLabel = 'C: System [SSD]'; Risk = 'CAUTION'; Consequence = $null; DriveLetter = 'C'; MediaType = 'SSD'; Mode = 'ReTrim'; ModeLabel = 'TRIM' }
            [PSCustomObject]@{ Name = 'D'; DisplayLabel = 'D: Data [HDD]'; Risk = 'CAUTION'; Consequence = $null; DriveLetter = 'D'; MediaType = 'HDD'; Mode = 'Defrag'; ModeLabel = 'Defragment' }
        )
        Invoke-WtOptimizeVolumesAction -GetCatalog { $catalog } `
            -SelectAction { param($Catalog, $StateItems, $Title) @('D') } `
            -OptimizeAction { param($DriveLetter, $Mode) $script:OptimizeCalls.Add("$DriveLetter/$Mode") } `
            -Run { param($Chosen, $Crumb) foreach ($entry in $Chosen) { & $OptimizeAction $entry.DriveLetter $entry.Mode } }

        @($script:OptimizeCalls) | Should -Be @('D/Defrag')
    }
}

Describe 'Invoke-WtScheduleDiskRepairAction gate' {
    BeforeAll {
        $script:RepairCatalog = @(
            [PSCustomObject]@{
                Name = 'C'; DisplayLabel = 'C: System (NTFS)'; Risk = 'ADVANCED'; Consequence = 'x'
                DriveLetter = 'C'; IsSystemDrive = $true
                Plan = [PSCustomObject]@{ DriveLetter = 'C'; Method = 'DirtyBit'; ScheduleText = 'fsutil dirty set C:'; CancelCommand = 'chkntfs /x C:'; NoteKey = 'DiskRepairSystemDrive' }
            }
        )
    }

    It 'calls neither SetDirtyBit nor RepairVolume when the confirmation is refused' {
        $script:DirtyBitCalls = New-Object System.Collections.Generic.List[string]
        $script:RepairVolumeCalls = New-Object System.Collections.Generic.List[string]
        $script:ShownCancelled = $null

        Invoke-WtScheduleDiskRepairAction -GetCatalog { $script:RepairCatalog } `
            -SelectAction { param($Catalog, $StateItems, $Title) @('C') } `
            -Confirm { param($ConsequenceText, $Lines, $Crumb) $false } `
            -SetDirtyBit { param($DriveLetter) $script:DirtyBitCalls.Add([string]$DriveLetter) } `
            -RepairVolume { param($DriveLetter) $script:RepairVolumeCalls.Add([string]$DriveLetter) } `
            -ShowCancelled { param($Lines) $script:ShownCancelled = @($Lines) }

        @($script:DirtyBitCalls).Count | Should -Be 0
        @($script:RepairVolumeCalls).Count | Should -Be 0
        @($script:ShownCancelled) | Should -Be @((Get-Translation 'ActionCancelled'))
    }
}

Describe 'Invoke-WtDeleteOldRestorePointsAction gate' {
    BeforeAll {
        $script:TwoPoints = @(
            [PSCustomObject]@{ SequenceNumber = 2; Description = 'Newest'; CreationTime = (Get-Date) }
            [PSCustomObject]@{ SequenceNumber = 1; Description = 'Oldest'; CreationTime = (Get-Date).AddDays(-10) }
        )
        $script:OneStorageEntry = @([PSCustomObject]@{ DriveLetter = 'C:'; UsedBytes = 1073741824L; AllocatedBytes = 2147483648L })
    }

    It 'never calls vssadmin delete when the confirmation is refused' {
        $script:DeleteCalls = New-Object System.Collections.Generic.List[string]
        $script:ShownCancelled = $null

        Invoke-WtDeleteOldRestorePointsAction -GetPoints { $script:TwoPoints } `
            -GetStorage { $script:OneStorageEntry } `
            -GetRawShadowStorageLines { @() } `
            -Confirm { param($ConsequenceText, $Lines, $Crumb) $false } `
            -DeleteShadow { param($DriveLetter) $script:DeleteCalls.Add([string]$DriveLetter) } `
            -ShowCancelled { param($Lines) $script:ShownCancelled = @($Lines) }

        @($script:DeleteCalls).Count | Should -Be 0
        @($script:ShownCancelled) | Should -Be @((Get-Translation 'ActionCancelled'))
    }
}
