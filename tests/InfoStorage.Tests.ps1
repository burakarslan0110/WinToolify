#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Storage row labels' {
    $storageKeys = @(
        'LargestFoldersReport'
        'LargestFilesReport'
        'ComponentStoreAnalysis'
        'RestorePointShadowStorage'
        'DiskPartitionLayout'
    )

    It 'has "<_>" in both dictionaries, ASCII only, at most 45 characters' -ForEach $storageKeys {
        foreach ($lang in 'EN', 'TR') {
            $value = [string]$script:Translations[$lang][$_]
            $value | Should -Not -BeNullOrEmpty -Because "$lang needs '$_'"
            $value.Length | Should -BeLessOrEqual 45 -Because "$lang '$_' is a list label"
            foreach ($ch in $value.ToCharArray()) {
                [int]$ch | Should -BeLessOrEqual 127 -Because "$lang '$_' must be ASCII-folded"
            }
        }
    }

    It 'actually translates each label instead of copying English' -ForEach $storageKeys {
        $script:Translations['EN'][$_] | Should -Not -Be $script:Translations['TR'][$_]
    }
}

Describe 'Format-WtLeftTruncatedPath' {
    It 'leaves a path that already fits alone' {
        Format-WtLeftTruncatedPath -Path 'C:\Temp\a.iso' -Width 30 | Should -Be 'C:\Temp\a.iso'
    }

    It 'cuts from the LEFT so the file name survives' {
        $long = 'C:\Users\Burak\Desktop\WinToolify\docs\specs\design.md'
        $cut = Format-WtLeftTruncatedPath -Path $long -Width 20
        $cut.Length | Should -Be 20
        $cut | Should -BeLike '...*'
        $cut | Should -BeLike '*design.md'
    }

    It 'survives a width that cannot hold even the ellipsis' {
        Format-WtLeftTruncatedPath -Path 'C:\Temp\a.iso' -Width 2 | Should -Be '..'
        Format-WtLeftTruncatedPath -Path 'C:\Temp\a.iso' -Width 0 | Should -Be ''
    }

    It 'accepts an empty path' {
        Format-WtLeftTruncatedPath -Path '' -Width 10 | Should -Be ''
    }
}

Describe 'Get-WtFolderUsage' {
    BeforeAll {
        $script:Reparse = [System.IO.FileAttributes]::ReparsePoint
        $script:Plain = [System.IO.FileAttributes]::Directory
        $script:Tree = @{
            'C:\Root'          = @{ Files = @(@{ Length = 100L }, @{ Length = 200L }); Directories = @(@{ FullName = 'C:\Root\Sub'; Attributes = $script:Plain }, @{ FullName = 'C:\Root\Link'; Attributes = $script:Reparse }) }
            'C:\Root\Sub'      = @{ Files = @(@{ Length = 700L }); Directories = @(@{ FullName = 'C:\Root\Sub\Deep'; Attributes = $script:Plain }) }
            'C:\Root\Sub\Deep' = @{ Files = @(@{ Length = 4000L }); Directories = @() }
            'C:\Root\Link'     = @{ Files = @(@{ Length = 999999L }); Directories = @() }
        }
        $script:Reader = {
            param($Current)
            if (-not $script:Tree.ContainsKey($Current)) { throw "denied: $Current" }
            return $script:Tree[$Current]
        }
    }

    It 'sums every file in the subtree' {
        $r = Get-WtFolderUsage -Path 'C:\Root' -GetEntries $script:Reader
        $r.Bytes | Should -Be 5000
        $r.Files | Should -Be 4
        $r.Skipped | Should -Be 0
    }

    It 'never descends into a ReparsePoint, so a junction is not counted twice' {
        $r = Get-WtFolderUsage -Path 'C:\Root' -GetEntries $script:Reader
        $r.Bytes | Should -Not -Be 1004999
    }

    It 'counts a directory it cannot read instead of throwing' {
        $reader = { param($Current) if ($Current -ceq 'C:\Root') { return @{ Files = @(@{ Length = 5L }); Directories = @(@{ FullName = 'C:\Root\Locked'; Attributes = [System.IO.FileAttributes]::Directory }) } } throw 'Access is denied' }
        $r = Get-WtFolderUsage -Path 'C:\Root' -GetEntries $reader
        $r.Bytes | Should -Be 5
        $r.Skipped | Should -Be 1
    }

    It 'reports zero for a root it cannot read at all' {
        $r = Get-WtFolderUsage -Path 'C:\Missing' -GetEntries { param($Current) throw 'gone' }
        $r.Bytes | Should -Be 0
        $r.Files | Should -Be 0
        $r.Skipped | Should -Be 1
    }
}

Describe 'Get-WtLargestFoldersReportLines' {
    BeforeAll {
        $script:Plain = [System.IO.FileAttributes]::Directory
        $script:Link = [System.IO.FileAttributes]::ReparsePoint
        $script:TopLevel = {
            param($Path)
            return @{
                Directories = @(
                    @{ Name = 'Downloads'; FullName = 'C:\P\Downloads'; Attributes = $script:Plain }
                    @{ Name = 'AppData'; FullName = 'C:\P\AppData'; Attributes = $script:Plain }
                    @{ Name = 'Recent'; FullName = 'C:\P\Recent'; Attributes = $script:Link }
                )
                Files       = @(@{ Length = 2048L }, @{ Length = 1024L })
            }
        }
        $script:Measure = {
            param($Path)
            switch ($Path) {
                'C:\P\Downloads' { return [PSCustomObject]@{ Bytes = 3000000000L; Files = 12; Skipped = 0 } }
                'C:\P\AppData' { return [PSCustomObject]@{ Bytes = 500000000L; Files = 40; Skipped = 3 } }
            }
            return [PSCustomObject]@{ Bytes = 0L; Files = 0; Skipped = 0 }
        }
    }

    It 'ranks the top-level folders biggest first' {
        $lines = Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:TopLevel -MeasureFolder $script:Measure -WriteLine { param($Text) }
        $ranked = @($lines | Where-Object { $_ -cmatch '^\s*\d+\.' })
        $ranked.Count | Should -Be 2
        $ranked[0] | Should -BeLike '*Downloads*'
        $ranked[1] | Should -BeLike '*AppData*'
    }

    It 'skips a top-level ReparsePoint entirely' {
        $probedPaths = [System.Collections.Generic.List[string]]::new()
        $null = Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:TopLevel -MeasureFolder { param($Path) $probedPaths.Add($Path); [PSCustomObject]@{ Bytes = 1L; Files = 1; Skipped = 0 } } -WriteLine { param($Text) }
        $probedPaths | Should -Not -Contain 'C:\P\Recent'
        $probedPaths.Count | Should -Be 2
    }

    It 'writes one heartbeat line per completed folder, and a header before any of them' {
        $beats = [System.Collections.Generic.List[string]]::new()
        $null = Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:TopLevel -MeasureFolder $script:Measure -WriteLine { param($Text) $beats.Add([string]$Text) }
        @($beats | Where-Object { $_ -clike '*Downloads*' }).Count | Should -Be 1
        @($beats | Where-Object { $_ -clike '*AppData*' }).Count | Should -Be 1
        $beats[0] | Should -BeLike '*C:\P*'
    }

    It 'reports the files sitting directly in the root and the folders it could not read' {
        $text = (Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:TopLevel -MeasureFolder $script:Measure -WriteLine { param($Text) }) -join "`n"
        $text | Should -BeLike ('*' + (Get-Translation 'ScanRootFiles') + '*')
        $text | Should -BeLike ('*' + ((Get-Translation 'ScanSkippedFolders') -f 3) + '*')
        $text | Should -BeLike ('*' + ((Get-Translation 'ScanTotalMeasured') -f '3.3 GB', 2) + '*')
    }

    It 'says so when the path does not exist' {
        $lines = Get-WtLargestFoldersReportLines -Root 'C:\Nope' -TestRoot { param($Path) $false } -GetTopLevel $script:TopLevel -MeasureFolder $script:Measure -WriteLine { param($Text) }
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'FolderNotFound') + '*')
    }

    It 'says so when the path holds nothing to measure' {
        $empty = { param($Path) @{ Directories = @(); Files = @() } }
        $lines = Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $empty -MeasureFolder $script:Measure -WriteLine { param($Text) }
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'LargestFoldersNone') + '*')
    }

    It 'degrades honestly when the root itself cannot be enumerated' {
        $lines = Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel { param($Path) throw 'Access is denied' } -MeasureFolder $script:Measure -WriteLine { param($Text) }
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'LargestFoldersNone') + '*')
    }

    It 'interleaves measure and write per folder rather than batching all measures before any write' {
        $script:FolderTrace = [System.Collections.Generic.List[string]]::new()
        $measure = {
            param($Path)
            switch ($Path) {
                'C:\P\Downloads' { $script:FolderTrace.Add('Measure(Downloads)'); return [PSCustomObject]@{ Bytes = 3000000000L; Files = 12; Skipped = 0 } }
                'C:\P\AppData' { $script:FolderTrace.Add('Measure(AppData)'); return [PSCustomObject]@{ Bytes = 500000000L; Files = 40; Skipped = 3 } }
            }
            return [PSCustomObject]@{ Bytes = 0L; Files = 0; Skipped = 0 }
        }
        $writeLine = {
            param($Text)
            if ($Text -clike '*Downloads*') { $script:FolderTrace.Add('Write(Downloads)') }
            elseif ($Text -clike '*AppData*') { $script:FolderTrace.Add('Write(AppData)') }
        }
        $null = Get-WtLargestFoldersReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:TopLevel -MeasureFolder $measure -WriteLine $writeLine
        $script:FolderTrace | Should -Be @('Measure(Downloads)', 'Write(Downloads)', 'Measure(AppData)', 'Write(AppData)')
    }
}

Describe 'Invoke-WtLargestFoldersReportAction' {
    It 'returns without calling -Run when the panel answer is null' {
        $script:FoldersRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFoldersReportAction -AskPath { param($Crumb, $Lines, $Prompt) $null } -TestRoot { param($Path) $true } -Run { param($Root, $Crumb) $script:FoldersRunCalls.Add($Root) }
        $script:FoldersRunCalls.Count | Should -Be 0
    }

    It 'strips surrounding quotes and whitespace from the answer before using it' {
        $script:FoldersRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFoldersReportAction -AskPath { param($Crumb, $Lines, $Prompt) '  "C:\Some Path"  ' } -TestRoot { param($Path) $true } -Run { param($Root, $Crumb) $script:FoldersRunCalls.Add($Root) }
        $script:FoldersRunCalls | Should -Be @('C:\Some Path')
    }

    It 'falls back to -DefaultRoot when the answer is empty' {
        $script:FoldersRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFoldersReportAction -DefaultRoot 'C:\Default' -AskPath { param($Crumb, $Lines, $Prompt) '' } -TestRoot { param($Path) $true } -Run { param($Root, $Crumb) $script:FoldersRunCalls.Add($Root) }
        $script:FoldersRunCalls | Should -Be @('C:\Default')
    }

    It 'does not call -Run when -TestRoot reports the path missing' {
        Mock Wait-WtEnter { }
        $script:FoldersRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFoldersReportAction -AskPath { param($Crumb, $Lines, $Prompt) 'C:\Nope' } -TestRoot { param($Path) $false } -Run { param($Root, $Crumb) $script:FoldersRunCalls.Add($Root) }
        $script:FoldersRunCalls.Count | Should -Be 0
        Should -Invoke Wait-WtEnter -Times 1 -Exactly
    }
}

Describe 'Get-WtBigFileList' {
    BeforeAll {
        $script:BigTree = @{
            'D:\Vm'      = @{ Files = @(@{ FullName = 'D:\Vm\small.txt'; Length = 1024L }, @{ FullName = 'D:\Vm\disk.vhdx'; Length = 900000000L }); Directories = @(@{ FullName = 'D:\Vm\Iso'; Attributes = [System.IO.FileAttributes]::Directory }, @{ FullName = 'D:\Vm\Mirror'; Attributes = [System.IO.FileAttributes]::ReparsePoint }) }
            'D:\Vm\Iso'  = @{ Files = @(@{ FullName = 'D:\Vm\Iso\win.iso'; Length = 5000000000L }); Directories = @() }
            'D:\Vm\Mirror' = @{ Files = @(@{ FullName = 'D:\Vm\Mirror\win.iso'; Length = 5000000000L }); Directories = @() }
        }
        $script:BigReader = {
            param($Current)
            if (-not $script:BigTree.ContainsKey($Current)) { throw "denied: $Current" }
            return $script:BigTree[$Current]
        }
    }

    It 'keeps only files at or over the threshold' {
        $r = Get-WtBigFileList -Path 'D:\Vm' -MinSizeBytes 104857600 -GetEntries $script:BigReader
        @($r.Files).Count | Should -Be 2
        @($r.Files | ForEach-Object { $_.Path }) | Should -Not -Contain 'D:\Vm\small.txt'
    }

    It 'walks into real subdirectories but not into a ReparsePoint' {
        $r = Get-WtBigFileList -Path 'D:\Vm' -MinSizeBytes 104857600 -GetEntries $script:BigReader
        @($r.Files | ForEach-Object { $_.Path }) | Should -Contain 'D:\Vm\Iso\win.iso'
        @($r.Files | ForEach-Object { $_.Path }) | Should -Not -Contain 'D:\Vm\Mirror\win.iso'
    }

    It 'counts an unreadable directory instead of throwing' {
        $r = Get-WtBigFileList -Path 'D:\Gone' -MinSizeBytes 104857600 -GetEntries $script:BigReader
        @($r.Files).Count | Should -Be 0
        $r.Skipped | Should -Be 1
    }

    It 'pins the -lt filter exactly at the 100 MB threshold (104857600)' {
        $reader = {
            param($Current)
            if ($Current -cne 'D:\Edge') { throw "denied: $Current" }
            return @{
                Files       = @(
                    @{ FullName = 'D:\Edge\at.bin'; Length = 104857600L }
                    @{ FullName = 'D:\Edge\under.bin'; Length = 104857599L }
                    @{ FullName = 'D:\Edge\over.bin'; Length = 104857601L }
                )
                Directories = @()
            }
        }
        $r = Get-WtBigFileList -Path 'D:\Edge' -MinSizeBytes 104857600 -GetEntries $reader
        $paths = @($r.Files | ForEach-Object { $_.Path })
        $paths | Should -Contain 'D:\Edge\at.bin'
        $paths | Should -Contain 'D:\Edge\over.bin'
        $paths | Should -Not -Contain 'D:\Edge\under.bin'
        @($r.Files).Count | Should -Be 2
    }
}

Describe 'Get-WtLargestFilesReportLines' {
    BeforeAll {
        $script:FileTop = {
            param($Path)
            return @{
                Directories = @(
                    @{ Name = 'Vm'; FullName = 'C:\P\Vm'; Attributes = [System.IO.FileAttributes]::Directory }
                    @{ Name = 'Iso'; FullName = 'C:\P\Iso'; Attributes = [System.IO.FileAttributes]::Directory }
                    @{ Name = 'Recent'; FullName = 'C:\P\Recent'; Attributes = [System.IO.FileAttributes]::ReparsePoint }
                )
                Files       = @(@{ FullName = 'C:\P\pagefile.copy'; Length = 8000000000L }, @{ FullName = 'C:\P\notes.txt'; Length = 500L })
            }
        }
        $script:FileScan = {
            param($Path, $MinBytes)
            switch ($Path) {
                'C:\P\Vm' { return [PSCustomObject]@{ Files = @([PSCustomObject]@{ Path = 'C:\P\Vm\machine.vhdx'; Length = 3000000000L }); Skipped = 0 } }
                'C:\P\Iso' { return [PSCustomObject]@{ Files = @([PSCustomObject]@{ Path = 'C:\P\Iso\win11.iso'; Length = 5000000000L }); Skipped = 2 } }
            }
            return [PSCustomObject]@{ Files = @(); Skipped = 0 }
        }
    }

    It 'lists the biggest file first, over every subtree and the root itself' {
        $lines = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles $script:FileScan -WriteLine { param($Text) }
        $ranked = @($lines | Where-Object { $_ -cmatch '^\s*\d+\.' })
        $ranked.Count | Should -Be 3
        $ranked[0] | Should -BeLike '*pagefile.copy'
        $ranked[1] | Should -BeLike '*win11.iso'
        $ranked[2] | Should -BeLike '*machine.vhdx'
    }

    It 'applies the 100 MB prefilter to the files sitting in the root' {
        $lines = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles $script:FileScan -WriteLine { param($Text) }
        ($lines -join "`n") | Should -Not -BeLike '*notes.txt*'
    }

    It 'never scans a top-level ReparsePoint' {
        $scanned = [System.Collections.Generic.List[string]]::new()
        $null = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles { param($Path, $MinBytes) $scanned.Add([string]$Path); [PSCustomObject]@{ Files = @(); Skipped = 0 } } -WriteLine { param($Text) }
        $scanned | Should -Not -Contain 'C:\P\Recent'
        $scanned.Count | Should -Be 2
    }

    It 'writes one heartbeat per subtree so the panel does not look frozen' {
        $beats = [System.Collections.Generic.List[string]]::new()
        $null = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles $script:FileScan -WriteLine { param($Text) $beats.Add([string]$Text) }
        @($beats | Where-Object { $_ -clike '*Vm*' }).Count | Should -Be 1
        @($beats | Where-Object { $_ -clike '*Iso*' }).Count | Should -Be 1
    }

    It 'truncates a long path from the LEFT so the file name survives' {
        $deep = 'C:\P\Vm\a-very-long-directory-name\another-long-one\and-one-more-level\machine.vhdx'
        $scan = { param($Path, $MinBytes) if ($Path -ceq 'C:\P\Vm') { return [PSCustomObject]@{ Files = @([PSCustomObject]@{ Path = $deep; Length = 3000000000L }); Skipped = 0 } } [PSCustomObject]@{ Files = @(); Skipped = 0 } }
        $lines = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles $scan -WriteLine { param($Text) }
        $row = @($lines | Where-Object { $_ -clike '*machine.vhdx*' })[0]
        $row | Should -BeLike '*...*'
        $row | Should -Not -BeLike '*a-very-long-directory-name*'
    }

    It 'reports the folders it could not read' {
        $lines = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles $script:FileScan -WriteLine { param($Text) }
        ($lines -join "`n") | Should -BeLike ('*' + ((Get-Translation 'ScanSkippedFolders') -f 2) + '*')
    }

    It 'says so when nothing is over 100 MB' {
        $lines = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel { param($Path) @{ Directories = @(); Files = @() } } -GetBigFiles $script:FileScan -WriteLine { param($Text) }
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'LargestFilesNone') + '*')
    }

    It 'says so when the path does not exist' {
        $lines = Get-WtLargestFilesReportLines -Root 'C:\Nope' -TestRoot { param($Path) $false } -GetTopLevel $script:FileTop -GetBigFiles $script:FileScan -WriteLine { param($Text) }
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'FolderNotFound') + '*')
    }

    It 'interleaves scan and write per subtree rather than batching all scans before any write' {
        $script:FileTrace = [System.Collections.Generic.List[string]]::new()
        $scan = {
            param($Path, $MinBytes)
            switch ($Path) {
                'C:\P\Vm' { $script:FileTrace.Add('Measure(Vm)'); return [PSCustomObject]@{ Files = @([PSCustomObject]@{ Path = 'C:\P\Vm\machine.vhdx'; Length = 3000000000L }); Skipped = 0 } }
                'C:\P\Iso' { $script:FileTrace.Add('Measure(Iso)'); return [PSCustomObject]@{ Files = @([PSCustomObject]@{ Path = 'C:\P\Iso\win11.iso'; Length = 5000000000L }); Skipped = 2 } }
            }
            return [PSCustomObject]@{ Files = @(); Skipped = 0 }
        }
        $writeLine = {
            param($Text)
            if ($Text -clike '*Vm*') { $script:FileTrace.Add('Write(Vm)') }
            elseif ($Text -clike '*Iso*') { $script:FileTrace.Add('Write(Iso)') }
        }
        $null = Get-WtLargestFilesReportLines -Root 'C:\P' -TestRoot { param($Path) $true } -GetTopLevel $script:FileTop -GetBigFiles $scan -WriteLine $writeLine
        $script:FileTrace | Should -Be @('Measure(Vm)', 'Write(Vm)', 'Measure(Iso)', 'Write(Iso)')
    }
}

Describe 'Invoke-WtLargestFilesReportAction' {
    It 'returns without calling -Run when the panel answer is null' {
        $script:FilesRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFilesReportAction -AskPath { param($Crumb, $Lines, $Prompt) $null } -TestRoot { param($Path) $true } -Run { param($Root, $Crumb) $script:FilesRunCalls.Add($Root) }
        $script:FilesRunCalls.Count | Should -Be 0
    }

    It 'strips surrounding quotes and whitespace from the answer before using it' {
        $script:FilesRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFilesReportAction -AskPath { param($Crumb, $Lines, $Prompt) '  "D:\Some Path"  ' } -TestRoot { param($Path) $true } -Run { param($Root, $Crumb) $script:FilesRunCalls.Add($Root) }
        $script:FilesRunCalls | Should -Be @('D:\Some Path')
    }

    It 'falls back to -DefaultRoot when the answer is empty' {
        $script:FilesRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFilesReportAction -DefaultRoot 'D:\Default' -AskPath { param($Crumb, $Lines, $Prompt) '' } -TestRoot { param($Path) $true } -Run { param($Root, $Crumb) $script:FilesRunCalls.Add($Root) }
        $script:FilesRunCalls | Should -Be @('D:\Default')
    }

    It 'does not call -Run when -TestRoot reports the path missing' {
        Mock Wait-WtEnter { }
        $script:FilesRunCalls = [System.Collections.Generic.List[string]]::new()
        Invoke-WtLargestFilesReportAction -AskPath { param($Crumb, $Lines, $Prompt) 'D:\Nope' } -TestRoot { param($Path) $false } -Run { param($Root, $Crumb) $script:FilesRunCalls.Add($Root) }
        $script:FilesRunCalls.Count | Should -Be 0
        Should -Invoke Wait-WtEnter -Times 1 -Exactly
    }
}

Describe 'Get-WtComponentStoreAnalysisLines' {
    It 'finds DISM where Windows keeps it' {
        Test-WtDismAvailable -DismPath 'X:\Dism.exe' -TestPathAction { param($Path) $true } | Should -BeTrue
    }

    It 'reports DISM as absent instead of throwing when the probe blows up' {
        Test-WtDismAvailable -DismPath 'X:\Dism.exe' -TestPathAction { param($Path) throw 'boom' } | Should -BeFalse
    }

    It 'warns about the cost and the missing cancel key before the run' {
        $lines = Get-WtComponentStoreAnalysisLines -DismAvailable $true -DismPath 'X:\Dism.exe'
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'ComponentStoreRunning') + '*')
    }

    It 'says out loud that the row only reports' {
        $lines = Get-WtComponentStoreAnalysisLines -DismAvailable $true -DismPath 'X:\Dism.exe'
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'ComponentStoreReadOnlyNote') + '*')
    }

    It 'degrades to an explicit line, naming the path, when DISM is not there' {
        $lines = @(Get-WtComponentStoreAnalysisLines -DismAvailable $false -DismPath 'X:\Dism.exe')
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeLike '*X:\Dism.exe*'
    }
}

Describe 'Restore point field conversion' {
    It 'turns a WMI DMTF stamp into a DateTime' {
        $when = ConvertTo-WtRestorePointTime -CreationTime '20260820143000.000000+180'
        $when | Should -BeOfType [datetime]
        $when.Year | Should -Be 2026
        $when.Month | Should -Be 8
        $when.Day | Should -Be 20
    }

    It 'passes a DateTime through untouched' {
        $stamp = [datetime]'2026-01-02T03:04:05'
        ConvertTo-WtRestorePointTime -CreationTime $stamp | Should -Be $stamp
    }

    It 'returns null instead of throwing on a stamp it cannot read' {
        ConvertTo-WtRestorePointTime -CreationTime 'not a date' | Should -BeNullOrEmpty
        ConvertTo-WtRestorePointTime -CreationTime $null | Should -BeNullOrEmpty
    }

    It 'names every documented restore point type' {
        Get-WtRestorePointTypeLabel -Type 0 | Should -Be (Get-Translation 'RestorePointTypeAppInstall')
        Get-WtRestorePointTypeLabel -Type 1 | Should -Be (Get-Translation 'RestorePointTypeAppUninstall')
        Get-WtRestorePointTypeLabel -Type 6 | Should -Be (Get-Translation 'RestorePointTypeRestore')
        Get-WtRestorePointTypeLabel -Type 7 | Should -Be (Get-Translation 'RestorePointTypeCheckpoint')
        Get-WtRestorePointTypeLabel -Type 10 | Should -Be (Get-Translation 'RestorePointTypeDriverInstall')
        Get-WtRestorePointTypeLabel -Type 12 | Should -Be (Get-Translation 'RestorePointTypeModifySettings')
        Get-WtRestorePointTypeLabel -Type 13 | Should -Be (Get-Translation 'RestorePointTypeCancelled')
    }

    It 'prints the raw number for a type it does not know, and never calls a missing type "application install"' {
        Get-WtRestorePointTypeLabel -Type 99 | Should -Be ((Get-Translation 'RestorePointTypeOther') -f 99)
        Get-WtRestorePointTypeLabel -Type $null | Should -Not -Be (Get-Translation 'RestorePointTypeAppInstall')
    }
}

Describe 'Get-WtRestorePointShadowStorageLines' {
    It 'lists each restore point with its converted stamp and its type in words' {
        $result = [PSCustomObject]@{
            Succeeded = $true
            Error     = ''
            Points    = @(
                [PSCustomObject]@{ SequenceNumber = 41; CreationTime = '20260819090000.000000+180'; Description = 'Windows Update'; RestorePointType = 0 }
                [PSCustomObject]@{ SequenceNumber = 42; CreationTime = '20260820143000.000000+180'; Description = 'WinToolify'; RestorePointType = 12 }
            )
        }
        $text = (Get-WtRestorePointShadowStorageLines -Result $result) -join "`n"
        $text | Should -BeLike '*2026-08-20 *'
        $text | Should -BeLike '*WinToolify*'
        $text | Should -BeLike ('*' + (Get-Translation 'RestorePointTypeModifySettings') + '*')
        $text | Should -BeLike ('*' + (Get-Translation 'RestorePointTypeAppInstall') + '*')
    }

    It 'puts the newest point first' {
        $result = [PSCustomObject]@{
            Succeeded = $true
            Error     = ''
            Points    = @(
                [PSCustomObject]@{ SequenceNumber = 41; CreationTime = '20260819090000.000000+180'; Description = 'older'; RestorePointType = 0 }
                [PSCustomObject]@{ SequenceNumber = 42; CreationTime = '20260820143000.000000+180'; Description = 'newer'; RestorePointType = 0 }
            )
        }
        $lines = @(Get-WtRestorePointShadowStorageLines -Result $result)
        $newer = [array]::IndexOf($lines, @($lines | Where-Object { $_ -clike '*newer*' })[0])
        $older = [array]::IndexOf($lines, @($lines | Where-Object { $_ -clike '*older*' })[0])
        $newer | Should -BeLessThan $older
    }

    It 'says the list is genuinely empty when the read succeeded' {
        $result = [PSCustomObject]@{ Succeeded = $true; Error = ''; Points = @() }
        $text = (Get-WtRestorePointShadowStorageLines -Result $result) -join "`n"
        $text | Should -BeLike ('*' + (Get-Translation 'RestorePointListNone') + '*')
        $text | Should -Not -BeLike ('*' + (Get-Translation 'RestorePointsUnknownWarning') + '*')
    }

    It 'NEVER calls a failed read an empty list' {
        $result = [PSCustomObject]@{ Succeeded = $false; Error = 'Access denied'; Points = @() }
        $text = (Get-WtRestorePointShadowStorageLines -Result $result) -join "`n"
        $text | Should -BeLike '*Access denied*'
        $text | Should -BeLike ('*' + (Get-Translation 'RestorePointsUnknownWarning') + '*')
        $text | Should -Not -BeLike ('*' + (Get-Translation 'RestorePointListNone') + '*')
    }

    It 'shows a visibly unknown stamp rather than inventing one' {
        $result = [PSCustomObject]@{ Succeeded = $true; Error = ''; Points = @([PSCustomObject]@{ SequenceNumber = 1; CreationTime = 'rubbish'; Description = 'x'; RestorePointType = 7 }) }
        $text = (Get-WtRestorePointShadowStorageLines -Result $result) -join "`n"
        $text | Should -BeLike '*????-??-??*'
    }

    It 'always ends with the shadow storage header, which the row fills from vssadmin' {
        $result = [PSCustomObject]@{ Succeeded = $true; Error = ''; Points = @() }
        $lines = @(Get-WtRestorePointShadowStorageLines -Result $result)
        $lines[-1] | Should -Be (Get-Translation 'ShadowStorageReportHeader')
    }

    It 'keeps the read outcome separate from the result' {
        $records = Get-WtRestorePointRecords
        $records.PSObject.Properties.Name | Should -Contain 'Succeeded'
        $records.PSObject.Properties.Name | Should -Contain 'Points'
        $records.PSObject.Properties.Name | Should -Contain 'Error'
    }
}

Describe 'Get-WtDiskPartitionLayoutLines' {
    BeforeAll {
        $script:Disks = {
            @([PSCustomObject]@{ Number = 0; FriendlyName = 'INTEL SSDPEKNU512GZ'; BusType = 'NVMe'; PartitionStyle = 'GPT'; Size = 512110190592L; HealthStatus = 'Healthy' })
        }
        $script:Physical = {
            @(
                [PSCustomObject]@{ DeviceId = 0; FriendlyName = 'INTEL SSDPEKNU512GZ'; MediaType = 'SSD'; BusType = 'NVMe'; FirmwareVersion = '002C'; Size = 512110190592L }
                [PSCustomObject]@{ DeviceId = 1; FriendlyName = 'Msft Virtual Disk'; MediaType = 'SSD'; BusType = 'File Backed Virtual'; FirmwareVersion = '1.0'; Size = 8589934592L }
            )
        }
        $script:Partitions = {
            param($Number)
            @(
                [PSCustomObject]@{ PartitionNumber = 1; DriveLetter = [char]0; Type = 'System'; Size = 104857600L; IsBoot = $false; IsSystem = $true; IsHidden = $true }
                [PSCustomObject]@{ PartitionNumber = 3; DriveLetter = [char]'C'; Type = 'Basic'; Size = 511450652160L; IsBoot = $true; IsSystem = $false; IsHidden = $false }
                [PSCustomObject]@{ PartitionNumber = 4; DriveLetter = [char]0; Type = 'Recovery'; Size = 534773760L; IsBoot = $false; IsSystem = $false; IsHidden = $false }
            )
        }
    }

    It 'prints the disk with its bus type, partition style and size' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions $script:Partitions -GetPhysicalDisks $script:Physical) -join "`n"
        $text | Should -BeLike '*INTEL SSDPEKNU512GZ*'
        $text | Should -BeLike '*NVMe*'
        $text | Should -BeLike '*GPT*'
    }

    It 'blends MediaType and FirmwareVersion in from Get-PhysicalDisk' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions $script:Partitions -GetPhysicalDisks $script:Physical) -join "`n"
        $text | Should -BeLike '*SSD*'
        $text | Should -BeLike '*002C*'
    }

    It 'shows the hidden EFI / Reserved / Recovery partitions too' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions $script:Partitions -GetPhysicalDisks $script:Physical) -join "`n"
        $text | Should -BeLike '*System*'
        $text | Should -BeLike '*Recovery*'
        $text | Should -BeLike ('*' + (Get-Translation 'DiskLayoutHiddenTag') + '*')
    }

    It 'never prints a NUL character for a partition with no drive letter' {
        $lines = @(Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions $script:Partitions -GetPhysicalDisks $script:Physical)
        ($lines -join "`n") | Should -BeLike ('*' + (Get-Translation 'DiskLayoutNoLetter') + '*')
        foreach ($line in $lines) {
            $line.IndexOf([char]0) | Should -Be (-1) -Because 'a [char]0 drive letter must never reach the panel'
        }
        ($lines -join "`n") | Should -BeLike '*C:*'
    }

    It 'labels a File Backed Virtual disk that Get-Disk does not list' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions $script:Partitions -GetPhysicalDisks $script:Physical) -join "`n"
        $text | Should -BeLike ('*' + (Get-Translation 'DiskLayoutVirtualHeader') + '*')
        $text | Should -BeLike '*Msft Virtual Disk*'
        $text | Should -BeLike ('*' + (Get-Translation 'DiskLayoutVirtualTag') + '*')
    }

    It 'says so when no disk can be read at all' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks { throw 'Access is denied' } -GetPartitions $script:Partitions -GetPhysicalDisks { @() }) -join "`n"
        $text | Should -BeLike ('*' + (Get-Translation 'DiskLayoutNoDisks') + '*')
    }

    It 'says so when the disk is readable but its partitions are not' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions { param($Number) throw 'Access is denied' } -GetPhysicalDisks $script:Physical) -join "`n"
        $text | Should -BeLike ('*' + (Get-Translation 'DiskLayoutPartitionsNone') + '*')
    }

    It 'still prints the disk when Get-PhysicalDisk gives nothing to blend' {
        $text = (Get-WtDiskPartitionLayoutLines -GetDisks $script:Disks -GetPartitions $script:Partitions -GetPhysicalDisks { throw 'wmi is unhappy' }) -join "`n"
        $text | Should -BeLike '*INTEL SSDPEKNU512GZ*'
        $text | Should -Not -BeLike ('*' + (Get-Translation 'DiskLayoutVirtualHeader') + '*')
    }
}

Describe 'Storage group wiring' {
    BeforeAll {
        $script:StorageGroup = @(Get-WtInfoToolGroups) | Where-Object { $_.HeaderKey -eq 'InfoGroupStorage' } | Select-Object -First 1
        $script:StorageRows = @(& $script:StorageGroup.GetRows)
        $script:StorageNames = @($script:StorageRows | ForEach-Object { [string]$_.Name })
    }

    It 'has a Storage group' {
        $script:StorageGroup | Should -Not -BeNullOrEmpty
    }

    It 'holds the eight rows the catalogue promises' {
        $script:StorageRows.Count | Should -Be 8
    }

    It 'carries the five new rows, in catalogue order, between CheckDiskStatus and ScanHardDisk' {
        $expected = @('LargestFoldersReport', 'LargestFilesReport', 'ComponentStoreAnalysis', 'RestorePointShadowStorage', 'DiskPartitionLayout')
        $indexes = @($expected | ForEach-Object { [array]::IndexOf($script:StorageNames, $_) })
        $indexes | Should -Not -Contain (-1)
        ($indexes | Sort-Object) | Should -Be $indexes
        $indexes[0] | Should -BeGreaterThan ([array]::IndexOf($script:StorageNames, 'CheckDiskStatus'))
        $indexes[4] | Should -BeLessThan ([array]::IndexOf($script:StorageNames, 'ScanHardDisk'))
    }

    It 'gives the two path rows a CAUTION badge and the component store one too' {
        foreach ($name in 'LargestFoldersReport', 'LargestFilesReport', 'ComponentStoreAnalysis') {
            $row = @($script:StorageRows | Where-Object { $_.Name -ceq $name })[0]
            [string]$row.Risk | Should -Be 'CAUTION' -Because "$name"
        }
    }

    It 'labels every row from its own translation key' {
        foreach ($row in $script:StorageRows) {
            [string]$row.Label | Should -Be ([string](Get-Translation ([string]$row.Name)))
        }
    }

    It 'never lets an information row change state' {
        $denied = @('Set-', 'Remove-', 'Stop-', 'Start-', 'Restart-', 'New-', 'Clear-', 'Disable-', 'Enable-', 'vssadmin delete', 'netsh')
        foreach ($row in $script:StorageRows) {
            $text = [string]$row.Data.Action
            foreach ($verb in $denied) {
                $text.IndexOf($verb, [System.StringComparison]::Ordinal) | Should -Be (-1) -Because "$($row.Name) must not carry '$verb'"
            }
        }
    }

    It 'streams vssadmin with the default OEM decoding, never a forced encoding' {
        $row = @($script:StorageRows | Where-Object { $_.Name -ceq 'RestorePointShadowStorage' })[0]
        $row.Data.Encoding | Should -BeNullOrEmpty
        ([string]$row.Data.Action) | Should -CMatch 'vssadmin list shadowstorage'
    }

    It 'never parses the localized DISM output' {
        $row = @($script:StorageRows | Where-Object { $_.Name -ceq 'ComponentStoreAnalysis' })[0]
        $text = [string]$row.Data.Action
        $text | Should -CMatch 'AnalyzeComponentStore'
        $text | Should -Not -CMatch 'Select-String'
        $text | Should -Not -CMatch 'Cleanup Recommended'
    }

    It 'asks for a path in the panel rather than inside a captured action' {
        foreach ($name in 'LargestFoldersReport', 'LargestFilesReport') {
            $row = @($script:StorageRows | Where-Object { $_.Name -ceq $name })[0]
            ([string]$row.Data.Action) | Should -Not -CMatch 'Read-Host' -Because "$name would deadlock behind the capture"
            [bool]$row.Data.Captured | Should -BeFalse -Because "$name asks a question first"
        }
    }
}
