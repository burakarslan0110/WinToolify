#Requires -Modules Pester

<#
.SYNOPSIS
    Disk & System Health bundle coverage: the eight-category cleanup
    catalog built from an injected environment, the preview that walks
    every category up front, the selector state label, and the delete
    engine - which removes exactly the previewed files, tolerates a
    locked file, stops/restarts the update services around the one
    category that needs it, and never touches an unselected category.

    The walker and the default remove action run for real against temp
    trees on this host; Stop-Service/Start-Service are injected fakes
    (no Windows services on macOS).
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
        param($Path, [int]$Length)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Length))
    }

    function script:New-FakeEnvironment {
        param($Root)
        return @{
            LOCALAPPDATA = Join-Path $Root 'la'
            WinDir       = Join-Path $Root 'win'
            SystemDrive  = Join-Path $Root 'sys'
            ProgramData  = Join-Path $Root 'pd'
        }
    }
}

Describe 'Get-WtCleanupCatalog' {
    BeforeAll {
        $script:Catalog = @(Get-WtCleanupCatalog -Environment @{ LOCALAPPDATA = 'X:\la'; WinDir = 'X:\win'; SystemDrive = 'X:'; ProgramData = 'X:\pd' } -FixedDriveRoots @('X:\', 'Y:\'))
    }

    It 'has the eight categories in their defined order with the exact risk tags' {
        @($Catalog | Select-Object -ExpandProperty Name) | Should -Be @('UserTemp', 'WindowsTemp', 'SystemDriveLeftovers', 'CrashDumps', 'ErrorReports', 'WindowsUpdateCache', 'Prefetch', 'RecycleBin')
        foreach ($entry in $Catalog) {
            $expectedRisk = if ($entry.Name -in @('WindowsUpdateCache', 'Prefetch', 'RecycleBin')) { 'CAUTION' } else { 'SAFE' }
            $entry.Risk | Should -Be $expectedRisk
        }
    }

    It 'builds path specs from the injected environment' {
        ($Catalog | Where-Object Name -eq 'UserTemp').PathSpecs[0].Path | Should -Be ([System.IO.Path]::Combine('X:\la', 'Temp'))
        ($Catalog | Where-Object Name -eq 'WindowsUpdateCache').PathSpecs[0].Path | Should -Be ([System.IO.Path]::Combine('X:\win', 'SoftwareDistribution', 'Download'))

        $leftovers = $Catalog | Where-Object Name -eq 'SystemDriveLeftovers'
        $leftovers.PathSpecs[0].Recurse | Should -BeFalse
        @($leftovers.PathSpecs[0].Patterns) | Should -Be @('*.tmp', '*.bak', '*.old', '*.log', '*.chk', '*.gid', '*._mp')

        $prefetch = $Catalog | Where-Object Name -eq 'Prefetch'
        $prefetch.PathSpecs[0].Recurse | Should -BeFalse
        @($prefetch.PathSpecs[0].Patterns) | Should -Be @('*.pf')

        $dumps = $Catalog | Where-Object Name -eq 'CrashDumps'
        @($dumps.PathSpecs).Count | Should -Be 2
        @($dumps.PathSpecs[0].Patterns) | Should -Be @('MEMORY.DMP')
        @($dumps.PathSpecs[1].Patterns) | Should -Be @('*.dmp')

        @(($Catalog | Where-Object Name -eq 'ErrorReports').PathSpecs).Count | Should -Be 4
    }

    It 'gives RecycleBin one recursive spec per fixed drive' {
        $bin = $Catalog | Where-Object Name -eq 'RecycleBin'
        @($bin.PathSpecs | ForEach-Object Path) | Should -Be @(([System.IO.Path]::Combine('X:\', '$Recycle.Bin')), ([System.IO.Path]::Combine('Y:\', '$Recycle.Bin')))
        foreach ($spec in $bin.PathSpecs) { $spec.Recurse | Should -BeTrue }
    }

    It 'stops wuauserv and bits only for the Windows Update cache, and carries consequences on the CAUTION entries and CrashDumps' {
        foreach ($entry in $Catalog) {
            if ($entry.Name -eq 'WindowsUpdateCache') {
                @($entry.ServicesToStop) | Should -Be @('wuauserv', 'bits')
            }
            else {
                @($entry.ServicesToStop).Count | Should -Be 0
            }

            if ($entry.Name -in @('WindowsUpdateCache', 'Prefetch', 'RecycleBin', 'CrashDumps')) {
                $entry.Consequence | Should -Not -BeNullOrEmpty
            }
            else {
                $entry.Consequence | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Get-WtCleanupPreview and Format-WtCleanupPreviewLabel' {
    BeforeEach {
        $script:Root = New-Tree
        $script:Env = New-FakeEnvironment -Root $Root
        Write-Bytes -Path (Join-Path (Join-Path $Env.LOCALAPPDATA 'Temp') 'one.tmp') -Length 100
        Write-Bytes -Path (Join-Path (Join-Path (Join-Path $Env.LOCALAPPDATA 'Temp') 'nested') 'two.tmp') -Length 200
        $script:Catalog = @(Get-WtCleanupCatalog -Environment $Env -FixedDriveRoots @())
    }

    It 'sums bytes and counts per category and reports zero for a missing path' {
        $preview = @(Get-WtCleanupPreview -Catalog $Catalog)

        $userTemp = $preview | Where-Object Name -eq 'UserTemp'
        $userTemp.Bytes | Should -Be 300
        $userTemp.Count | Should -Be 2
        $userTemp.DisplayLabel | Should -Be 'User temporary files'
        $userTemp.Risk | Should -Be 'SAFE'
        @($userTemp.Directories | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('nested')

        $windowsTemp = $preview | Where-Object Name -eq 'WindowsTemp'
        $windowsTemp.Bytes | Should -Be 0
        $windowsTemp.Count | Should -Be 0

        @($preview).Count | Should -Be 8
        ($preview | Where-Object Name -eq 'WindowsUpdateCache').ServicesToStop | Should -Be @('wuauserv', 'bits')
    }

    It 'renders the selector label with size and an invariant-culture count' {
        Format-WtCleanupPreviewLabel -Bytes 257238630 -Count 1204 | Should -Be '245.3 MB (1,204 files)'
        Format-WtCleanupPreviewLabel -Bytes 0 -Count 0 | Should -Be '0 B (0 files)'
        $script:Language = 'TR'
        try { Format-WtCleanupPreviewLabel -Bytes 257238630 -Count 1204 | Should -Be '245.3 MB (1,204 dosya)' }
        finally { $script:Language = 'EN' }
    }
}

Describe 'Invoke-WtCleanup' {
    BeforeEach {
        $script:Root = New-Tree
        $script:Env = New-FakeEnvironment -Root $Root
        $script:UserTempDir = Join-Path $Env.LOCALAPPDATA 'Temp'
        $script:One = Join-Path $UserTempDir 'one.tmp'
        $script:Two = Join-Path (Join-Path $UserTempDir 'nested') 'two.tmp'
        $script:Other = Join-Path (Join-Path $Env.WinDir 'Temp') 'other.tmp'
        $script:Update = Join-Path (Join-Path (Join-Path $Env.WinDir 'SoftwareDistribution') 'Download') 'pkg.cab'
        Write-Bytes -Path $One -Length 100
        Write-Bytes -Path $Two -Length 200
        Write-Bytes -Path $Other -Length 50
        Write-Bytes -Path $Update -Length 70
        $script:Catalog = @(Get-WtCleanupCatalog -Environment $Env -FixedDriveRoots @())
        $script:Preview = @(Get-WtCleanupPreview -Catalog $Catalog)
    }

    It 'deletes exactly the previewed files of the selected category, prunes empty subdirectories, keeps the root and other categories' {
        $result = Invoke-WtCleanup -Preview $Preview -SelectedNames @('UserTemp')

        Test-Path -LiteralPath $One | Should -BeFalse
        Test-Path -LiteralPath $Two | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $UserTempDir 'nested') | Should -BeFalse
        Test-Path -LiteralPath $UserTempDir | Should -BeTrue
        Test-Path -LiteralPath $Other | Should -BeTrue
        Test-Path -LiteralPath $Update | Should -BeTrue

        @($result.Results).Count | Should -Be 1
        $result.Results[0].Name | Should -Be 'UserTemp'
        $result.Results[0].FreedBytes | Should -Be 300
        $result.Results[0].DeletedCount | Should -Be 2
        $result.Results[0].SkippedCount | Should -Be 0
        $result.TotalFreedBytes | Should -Be 300
        $result.TotalDeletedCount | Should -Be 2
        $result.TotalSkippedCount | Should -Be 0
    }

    It 'counts a file whose removal throws as skipped and does not count its bytes as freed' {
        $result = Invoke-WtCleanup -Preview $Preview -SelectedNames @('UserTemp') -RemoveFileAction {
            param($Path)
            if ($Path -like '*two.tmp') { throw 'in use' }
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }

        Test-Path -LiteralPath $One | Should -BeFalse
        Test-Path -LiteralPath $Two | Should -BeTrue
        $result.Results[0].FreedBytes | Should -Be 100
        $result.Results[0].DeletedCount | Should -Be 1
        $result.Results[0].SkippedCount | Should -Be 1
        @($result.Results[0].Errors).Count | Should -Be 1
        $result.Results[0].Errors[0] | Should -Match 'in use'
    }

    It 'stops the update services before deleting and restarts only the ones it found running' {
        $script:StopCalls = @()
        $script:StartCalls = @()
        $result = Invoke-WtCleanup -Preview $Preview -SelectedNames @('UserTemp', 'WindowsUpdateCache') `
            -StopServiceAction { param($Name) $script:StopCalls += $Name; return ($Name -eq 'wuauserv') } `
            -StartServiceAction { param($Name) $script:StartCalls += $Name }

        @($script:StopCalls) | Should -Be @('wuauserv', 'bits')
        @($script:StartCalls) | Should -Be @('wuauserv')
        Test-Path -LiteralPath $Update | Should -BeFalse
        ($result.Results | Where-Object Name -eq 'WindowsUpdateCache').FreedBytes | Should -Be 70
    }

    It 'restarts a stopped service even when every removal throws, and never touches services for a category without ServicesToStop' {
        $script:StopCalls = @()
        $script:StartCalls = @()
        Invoke-WtCleanup -Preview $Preview -SelectedNames @('WindowsUpdateCache') `
            -RemoveFileAction { param($Path) throw 'locked' } `
            -StopServiceAction { param($Name) $script:StopCalls += $Name; return $true } `
            -StartServiceAction { param($Name) $script:StartCalls += $Name } | Out-Null

        @($script:StartCalls) | Should -Be @('wuauserv', 'bits')
        Test-Path -LiteralPath $Update | Should -BeTrue

        $script:StopCalls = @()
        $script:StartCalls = @()
        Invoke-WtCleanup -Preview $Preview -SelectedNames @('UserTemp') `
            -StopServiceAction { param($Name) $script:StopCalls += $Name; return $true } `
            -StartServiceAction { param($Name) $script:StartCalls += $Name } | Out-Null

        @($script:StopCalls).Count | Should -Be 0
        @($script:StartCalls).Count | Should -Be 0
    }
}
