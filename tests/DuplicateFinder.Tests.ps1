#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the Disk & System Health bundle: the shared file
    walker Get-WtFileInventory (never enters reparse points, honours
    patterns and minimum size, counts unreadable directories instead
    of throwing), the size -> prehash -> full-hash duplicate grouping,
    the known-folder scan root catalog, and the duplicate report
    renderer. The walker and the hashing run for real against temp
    trees on this host - .NET enumeration, symbolic links, FileStream
    reads, and Get-FileHash all exist here. Only the OneDrive
    placeholder attribute bits cannot be produced on macOS.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function script:New-Tree {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function script:Write-Bytes {
        param($Path, [byte[]]$Bytes)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
    }

    function script:New-Pattern {
        param([int]$Length, [byte]$Seed = 1, [int]$FlipFrom = -1)
        $bytes = New-Object byte[] $Length
        for ($i = 0; $i -lt $Length; $i++) { $bytes[$i] = [byte](($i * 7 + $Seed) % 251) }
        if ($FlipFrom -ge 0) {
            for ($i = $FlipFrom; $i -lt $Length; $i++) { $bytes[$i] = [byte](255 - $bytes[$i]) }
        }
        return $bytes
    }

    $script:IsRootUser = $false
    try { $script:IsRootUser = ((id -u) -eq 0) } catch { }
}

Describe 'Get-WtFileInventory' {
    BeforeEach {
        $script:Tree = New-Tree
        Write-Bytes -Path (Join-Path $Tree 'a\f1') -Bytes (New-Pattern -Length 10)
        Write-Bytes -Path (Join-Path $Tree 'a\b\f2') -Bytes (New-Pattern -Length 20)
        Write-Bytes -Path (Join-Path $Tree 'target\t.txt') -Bytes (New-Pattern -Length 30)
        $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $Tree 'a\link') -Target (Join-Path $Tree 'target') | Out-Null
    }

    It 'never enters a reparse-point directory but still reaches its target through the real path' {
        $result = Get-WtFileInventory -Root (Join-Path $Tree 'a')

        @($result.Files | ForEach-Object { Split-Path -Leaf $_.Path }) | Sort-Object | Should -Be @('f1', 'f2')
        @($result.Directories | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('b')

        $whole = Get-WtFileInventory -Root $Tree
        @($whole.Files | ForEach-Object { Split-Path -Leaf $_.Path }) | Sort-Object | Should -Be @('f1', 'f2', 't.txt')
        @($whole.Files | Where-Object { $_.Path -like '*link*' }).Count | Should -Be 0
    }

    It 'returns Length and LastWriteTime per file' {
        $result = Get-WtFileInventory -Root (Join-Path $Tree 'a')
        $f2 = $result.Files | Where-Object { $_.Path -like '*f2' }
        $f2.Length | Should -Be 20
        $f2.LastWriteTime | Should -BeOfType [datetime]
    }

    It 'applies patterns and no recursion when asked' {
        $flat = New-Tree
        Write-Bytes -Path (Join-Path $flat 'x.pf') -Bytes (New-Pattern -Length 5)
        Write-Bytes -Path (Join-Path $flat 'MEMORY.DMP') -Bytes (New-Pattern -Length 5)
        Write-Bytes -Path (Join-Path $flat 'keep.txt') -Bytes (New-Pattern -Length 5)
        Write-Bytes -Path (Join-Path $flat 'sub\y.pf') -Bytes (New-Pattern -Length 5)

        $result = Get-WtFileInventory -Root $flat -Recurse $false -Patterns @('*.pf', 'MEMORY.DMP')

        @($result.Files | ForEach-Object { Split-Path -Leaf $_.Path }) | Sort-Object | Should -Be @('MEMORY.DMP', 'x.pf')
        @($result.Directories).Count | Should -Be 0
    }

    It 'drops files below MinSizeBytes' {
        $sized = New-Tree
        Write-Bytes -Path (Join-Path $sized 'small') -Bytes (New-Pattern -Length 99)
        Write-Bytes -Path (Join-Path $sized 'big') -Bytes (New-Pattern -Length 100)

        $result = Get-WtFileInventory -Root $sized -MinSizeBytes 100
        @($result.Files | ForEach-Object { Split-Path -Leaf $_.Path }) | Should -Be @('big')
    }

    It 'returns an empty result for a missing root' {
        $result = Get-WtFileInventory -Root (Join-Path $Tree 'does-not-exist')
        @($result.Files).Count | Should -Be 0
        $result.SkippedDirectories | Should -Be 0
    }

    It 'counts an unreadable directory as skipped and still returns its siblings' -Skip:$script:IsRootUser {
        $locked = New-Tree
        Write-Bytes -Path (Join-Path $locked 'open\ok') -Bytes (New-Pattern -Length 5)
        Write-Bytes -Path (Join-Path $locked 'closed\hidden') -Bytes (New-Pattern -Length 5)
        if ($env:OS -eq 'Windows_NT') {
            icacls (Join-Path $locked 'closed') /deny '*S-1-1-0:(RD)' | Out-Null
        } else {
            chmod 000 (Join-Path $locked 'closed')
        }
        try {
            $result = Get-WtFileInventory -Root $locked
            $result.SkippedDirectories | Should -Be 1
            @($result.Files | ForEach-Object { Split-Path -Leaf $_.Path }) | Should -Be @('ok')
            @($result.Directories | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('open')
        }
        finally {
            if ($env:OS -eq 'Windows_NT') {
                icacls (Join-Path $locked 'closed') /remove:d '*S-1-1-0' | Out-Null
            } else {
                chmod 755 (Join-Path $locked 'closed')
            }
        }
    }
}

Describe 'Get-WtDuplicateGroups' {
    BeforeEach {
        $script:Tree = New-Tree
        $script:A = Join-Path $Tree 'A.bin'
        $script:A2 = Join-Path $Tree 'A2.bin'
        $script:B = Join-Path $Tree 'B.bin'
        $script:C = Join-Path $Tree 'C.bin'
        Write-Bytes -Path $A -Bytes (New-Pattern -Length 20480)
        Write-Bytes -Path $A2 -Bytes (New-Pattern -Length 20480)
        Write-Bytes -Path $B -Bytes (New-Pattern -Length 20480 -FlipFrom 8192)
        Write-Bytes -Path $C -Bytes (New-Pattern -Length 12345)
        $script:Files = @((Get-WtFileInventory -Root $Tree).Files)
    }

    It 'groups only byte-identical files and hashes only size-collision candidates' {
        $result = Get-WtDuplicateGroups -Files $Files

        @($result.Groups).Count | Should -Be 1
        $group = $result.Groups[0]
        @($group.Paths | ForEach-Object { Split-Path -Leaf $_ }) | Sort-Object | Should -Be @('A.bin', 'A2.bin')
        $group.Length | Should -Be 20480
        $group.WastedBytes | Should -Be 20480
        $result.TotalWastedBytes | Should -Be 20480
        $result.DuplicateFileCount | Should -Be 2
        $result.FilesConsidered | Should -Be 4
        $result.FilesHashed | Should -Be 3
        $result.UnreadableFiles | Should -Be 0
    }

    It 'drops a file whose full hash throws and counts it unreadable' {
        $result = Get-WtDuplicateGroups -Files $Files -FullHashAction {
            param($Path)
            if ($Path -like '*A2.bin') { throw 'locked' }
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }

        @($result.Groups).Count | Should -Be 0
        $result.UnreadableFiles | Should -Be 1
        $result.TotalWastedBytes | Should -Be 0
    }

    It 'sorts groups by wasted bytes descending' {
        $more = New-Tree
        Write-Bytes -Path (Join-Path $more 'small1') -Bytes (New-Pattern -Length 5000 -Seed 3)
        Write-Bytes -Path (Join-Path $more 'small2') -Bytes (New-Pattern -Length 5000 -Seed 3)
        Write-Bytes -Path (Join-Path $more 'big1') -Bytes (New-Pattern -Length 9000 -Seed 4)
        Write-Bytes -Path (Join-Path $more 'big2') -Bytes (New-Pattern -Length 9000 -Seed 4)
        Write-Bytes -Path (Join-Path $more 'big3') -Bytes (New-Pattern -Length 9000 -Seed 4)

        $result = Get-WtDuplicateGroups -Files @((Get-WtFileInventory -Root $more).Files)

        @($result.Groups).Count | Should -Be 2
        $result.Groups[0].WastedBytes | Should -Be 18000
        $result.Groups[1].WastedBytes | Should -Be 5000
        $result.TotalWastedBytes | Should -Be 23000
    }
}

Describe 'Get-WtDuplicateScanRootCatalog' {
    It 'lists the six known folders as SAFE entries with a path each' {
        $catalog = @(Get-WtDuplicateScanRootCatalog)
        @($catalog | Select-Object -ExpandProperty Name) | Should -Be @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')
        foreach ($entry in $catalog) {
            $entry.Risk | Should -Be 'SAFE'
            $entry.DisplayLabel | Should -Match "^$($entry.Name) \("
        }
    }
}

Describe 'Format-WtDuplicateReportLines' {
    It 'prints the largest-waste group first and notes truncated groups' {
        $result = [PSCustomObject]@{
            Groups             = @(
                [PSCustomObject]@{ Hash = 'H1'; Length = 9000; Paths = @('p\big1', 'p\big2', 'p\big3'); WastedBytes = 18000 }
                [PSCustomObject]@{ Hash = 'H2'; Length = 5000; Paths = @('p\small1', 'p\small2'); WastedBytes = 5000 }
            )
            TotalWastedBytes   = 23000
            FilesConsidered    = 5
            FilesHashed        = 5
            DuplicateFileCount = 5
            UnreadableFiles    = 0
        }

        $lines = @(Format-WtDuplicateReportLines -Result $result -MaxGroups 1)

        $groupLines = @($lines | Where-Object { $_ -match '^\d+\. ' })
        $groupLines.Count | Should -Be 1
        $groupLines[0] | Should -Match '3 copies x 8.8 KB - wasted 17.6 KB'
        @($lines | Where-Object { $_ -match '1 more group' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'p\\big1' }).Count | Should -Be 1

        $all = @(Format-WtDuplicateReportLines -Result $result)
        @($all | Where-Object { $_ -match '^\d+\. ' }).Count | Should -Be 2
        @($all | Where-Object { $_ -match 'more group' }).Count | Should -Be 0
    }

    It 'prints the no-duplicates line for an empty result' {
        $empty = [PSCustomObject]@{ Groups = @(); TotalWastedBytes = 0; FilesConsidered = 3; FilesHashed = 0; DuplicateFileCount = 0; UnreadableFiles = 0 }
        @(Format-WtDuplicateReportLines -Result $empty | Where-Object { $_ -eq 'No duplicate files found.' }).Count | Should -Be 1
    }
}
