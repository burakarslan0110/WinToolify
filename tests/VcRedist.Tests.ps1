#Requires -Modules Pester

<#
.SYNOPSIS
    The Visual C++ runtime installer: a package catalog, "already
    installed" detection from the Programs list, a plan that skips what
    is present, per-package download with a size check, and the action
    that narrates all of it. Everything that touches the machine
    (registry, network, installers) is injected.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    . (Join-Path $RepoRoot 'dist/WinToolify.ps1')

    function New-WtTestProgramEntry {
        param([string]$Name, [string]$Version = '')
        [PSCustomObject]@{ Key = [guid]::NewGuid().ToString(); DisplayName = $Name; DisplayVersion = $Version; Publisher = 'Microsoft'; UninstallString = 'x'; QuietUninstallString = ''; ScopeKey = 'M' }
    }

    $script:RealEntries = @(
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2010  x64 Redistributable - 10.0.40219' '10.0.40219')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2008 Redistributable - x64 9.0.30729.6161' '9.0.30729.6161')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2005 Redistributable (x64)' '8.0.61000')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664' '12.0.40664.0')
        (New-WtTestProgramEntry 'Microsoft Visual C++ v14 Redistributable (x64) - 14.51.36247' '14.51.36247.0')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2012 Redistributable (x86) - 11.0.61030' '11.0.61030.0')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2005 Redistributable' '8.0.61001')
        (New-WtTestProgramEntry 'Microsoft Visual C++ v14 Redistributable (x86) - 14.51.36247' '14.51.36247.0')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2008 Redistributable - x86 9.0.30729.6161' '9.0.30729.6161')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2013 Redistributable (x86) - 12.0.40664' '12.0.40664.0')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2012 Redistributable (x64) - 11.0.61030' '11.0.61030.0')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2010  x86 Redistributable - 10.0.40219' '10.0.40219')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2022 X64 Additional Runtime - 14.51.36247' '14.51.36247')
        (New-WtTestProgramEntry 'Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.51.36247' '14.51.36247')
        (New-WtTestProgramEntry 'Notepad++ (64-bit x64)' '8.6')
    )
}

Describe 'Get-WtVcRedistCatalog' {
    It 'lists the twelve packages of the old batch file, x86 before x64 inside each family, in family order' {
        $c = @(Get-WtVcRedistCatalog)
        @($c | ForEach-Object Id) | Should -Be @('2005-x86', '2005-x64', '2008-x86', '2008-x64', '2010-x86', '2010-x64', '2012-x86', '2012-x64', '2013-x86', '2013-x64', '2015-2022-x86', '2015-2022-x64')
        @($c | ForEach-Object File) | Should -Be @('vcredist2005_x86.exe', 'vcredist2005_x64.exe', 'vcredist2008_x86.exe', 'vcredist2008_x64.exe', 'vcredist2010_x86.exe', 'vcredist2010_x64.exe', 'vcredist2012_x86.exe', 'vcredist2012_x64.exe', 'vcredist2013_x86.exe', 'vcredist2013_x64.exe', 'vcredist2015_2017_2019_2022_x86.exe', 'vcredist2015_2017_2019_2022_x64.exe')
    }
    It 'keeps the switches the batch file proved: 2005 /q, 2008 /qb, the rest /passive /norestart' {
        $c = @(Get-WtVcRedistCatalog)
        ($c | Where-Object Family -eq '2005' | ForEach-Object Args) | Should -Be @('/q', '/q')
        ($c | Where-Object Family -eq '2008' | ForEach-Object Args) | Should -Be @('/qb', '/qb')
        foreach ($p in ($c | Where-Object { $_.Family -notin '2005', '2008' })) { $p.Args | Should -Be '/passive /norestart' -Because $p.Id }
    }
    It 'carries the byte size of every bundled installer, so a half-downloaded file is never run' {
        $c = @(Get-WtVcRedistCatalog)
        foreach ($p in $c) { [long]$p.Size | Should -BeGreaterThan 1000000 -Because $p.Id }
        ($c | Where-Object Id -eq '2015-2022-x64').Size | Should -Be 25640112
        ($c | Where-Object Id -eq '2005-x86').Size | Should -Be 2707352
    }
    It 'matches the exes checked into the repo byte for byte' {
        $dir = Join-Path $RepoRoot 'Visual-C-Runtimes-WinToolify'
        foreach ($p in @(Get-WtVcRedistCatalog)) {
            $f = Join-Path $dir $p.File
            Test-Path -LiteralPath $f | Should -BeTrue -Because $p.File
            (Get-Item -LiteralPath $f).Length | Should -Be $p.Size -Because $p.File
        }
    }
    It 'pins a minimum version only on the 2015-2022 family (the one an old runtime breaks games with)' {
        $c = @(Get-WtVcRedistCatalog)
        foreach ($p in ($c | Where-Object Family -ne '2015-2022')) { $p.MinVersion | Should -BeNullOrEmpty -Because $p.Id }
        foreach ($p in ($c | Where-Object Family -eq '2015-2022')) { $p.MinVersion | Should -Be '14.42.34433' -Because $p.Id }
        foreach ($p in $c) { $p.Major | Should -Be (@{ '2005' = 8; '2008' = 9; '2010' = 10; '2012' = 11; '2013' = 12; '2015-2022' = 14 }[$p.Family]) }
    }
    It 'downloads each file from the raw GitHub path of the repo folder' {
        Get-WtVcRedistUrl -File 'vcredist2010_x64.exe' | Should -Be 'https://raw.githubusercontent.com/burakarslan0110/WinToolify/main/Visual-C-Runtimes-WinToolify/vcredist2010_x64.exe'
    }
    It 'labels a package by family and architecture, the same in both languages' {
        Get-WtVcRedistPackageLabel -Package (@(Get-WtVcRedistCatalog) | Where-Object Id -eq '2015-2022-x64') | Should -Be 'Visual C++ 2015-2022 (x64)'
        Get-WtVcRedistPackageLabel -Package (@(Get-WtVcRedistCatalog) | Where-Object Id -eq '2005-x86') | Should -Be 'Visual C++ 2005 (x86)'
    }
}

Describe 'ConvertTo-WtVcRedistInstalled - reading the Programs list' {
    It 'finds every family and architecture on the real machine list, by version major, not by the year in the name' {
        $found = @(ConvertTo-WtVcRedistInstalled -Entries $RealEntries)
        @($found | ForEach-Object { $_.Family + '/' + $_.Arch } | Sort-Object) | Should -Be @(
            '2005/x64', '2005/x86', '2008/x64', '2008/x86', '2010/x64', '2010/x86', '2012/x64', '2012/x86', '2013/x64', '2013/x86', '2015-2022/x64', '2015-2022/x86')
    }
    It 'reads the "v14 Redistributable" name Windows uses for the current 14.x package as the 2015-2022 family' {
        $found = @(ConvertTo-WtVcRedistInstalled -Entries $RealEntries)
        $v14 = @($found | Where-Object { $_.Family -eq '2015-2022' -and $_.Arch -eq 'x64' })
        $v14.Count | Should -Be 1
        $v14[0].Version | Should -Be ([version]'14.51.36247.0')
        $v14[0].DisplayName | Should -Be 'Microsoft Visual C++ v14 Redistributable (x64) - 14.51.36247'
    }
    It 'takes the 2005 entry without an architecture marker as x86' {
        $found = @(ConvertTo-WtVcRedistInstalled -Entries $RealEntries)
        ($found | Where-Object { $_.Family -eq '2005' -and $_.Arch -eq 'x86' }).Version | Should -Be ([version]'8.0.61001')
        ($found | Where-Object { $_.Family -eq '2005' -and $_.Arch -eq 'x64' }).Version | Should -Be ([version]'8.0.61000')
    }
    It 'ignores the Minimum/Additional Runtime MSI rows, anything that is not Microsoft Visual C++, and ARM64' {
        $entries = $RealEntries + @(
            (New-WtTestProgramEntry 'Microsoft Visual C++ 2022 Redistributable (Arm64) - 14.40.33810' '14.40.33810.0')
            (New-WtTestProgramEntry 'Microsoft Visual Studio Redistributable Thing' '17.0')
        )
        $found = @(ConvertTo-WtVcRedistInstalled -Entries $entries)
        $found.Count | Should -Be 12
        @($found | Where-Object { $_.DisplayName -match 'Runtime|Arm64|Studio' }).Count | Should -Be 0
    }
    It 'falls back to the year in the name when DisplayVersion is missing or unparsable' {
        $entries = @(
            (New-WtTestProgramEntry 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664' '')
            (New-WtTestProgramEntry 'Microsoft Visual C++ 2015-2019 Redistributable (x86) - 14.29.30139' 'garbage')
            (New-WtTestProgramEntry 'Microsoft Visual C++ 2017 Redistributable (x64) - 14.16.27033' '')
        )
        $found = @(ConvertTo-WtVcRedistInstalled -Entries $entries)
        @($found | ForEach-Object { $_.Family + '/' + $_.Arch }) | Should -Be @('2013/x64', '2015-2022/x86', '2015-2022/x64')
        foreach ($f in $found) { $f.Version | Should -BeNullOrEmpty }
    }
    It 'survives an empty list' {
        @(ConvertTo-WtVcRedistInstalled -Entries @()).Count | Should -Be 0
        @(ConvertTo-WtVcRedistInstalled -Entries $null).Count | Should -Be 0
    }
}

Describe 'Get-WtVcRedistPlan - skip what is installed' {
    BeforeAll { $script:Catalog = @(Get-WtVcRedistCatalog) }

    It 'skips every package on a fully provisioned x64 machine' {
        $installed = @(ConvertTo-WtVcRedistInstalled -Entries $RealEntries)
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed $installed -Is64Bit $true)
        $plan.Count | Should -Be 12
        @($plan | ForEach-Object Action | Sort-Object -Unique) | Should -Be @('Skip')
        ($plan | Where-Object { $_.Package.Id -eq '2010-x64' }).InstalledVersion | Should -Be '10.0.40219'
    }
    It 'installs only what is missing, in catalog order' {
        $installed = @(ConvertTo-WtVcRedistInstalled -Entries $RealEntries) | Where-Object { $_.Family -notin '2010', '2013' -or $_.Arch -ne 'x64' }
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed @($installed) -Is64Bit $true)
        @($plan | Where-Object Action -eq 'Install' | ForEach-Object { $_.Package.Id }) | Should -Be @('2010-x64', '2013-x64')
        @($plan | Where-Object Action -eq 'Skip').Count | Should -Be 10
    }
    It 'plans nothing at all when nothing is installed: every package is an Install' {
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed @() -Is64Bit $true)
        @($plan | ForEach-Object Action | Sort-Object -Unique) | Should -Be @('Install')
        $plan.Count | Should -Be 12
    }
    It 'on 32-bit Windows plans only the x86 packages' {
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed @() -Is64Bit $false)
        @($plan | ForEach-Object { $_.Package.Arch } | Sort-Object -Unique) | Should -Be @('x86')
        $plan.Count | Should -Be 6
    }
    It 'updates a 2015-2022 runtime older than the bundled one instead of skipping it (VCRUNTIME140_1.dll missing)' {
        $installed = @(
            @{ Family = '2015-2022'; Arch = 'x64'; Version = [version]'14.0.24215.1'; DisplayName = 'Microsoft Visual C++ 2015 Redistributable (x64) - 14.0.24215' }
            @{ Family = '2015-2022'; Arch = 'x86'; Version = [version]'14.42.34433.0'; DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x86) - 14.42.34433' }
        )
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed $installed -Is64Bit $true)
        ($plan | Where-Object { $_.Package.Id -eq '2015-2022-x64' }).Action | Should -Be 'Update'
        ($plan | Where-Object { $_.Package.Id -eq '2015-2022-x64' }).InstalledVersion | Should -Be '14.0.24215.1'
        ($plan | Where-Object { $_.Package.Id -eq '2015-2022-x86' }).Action | Should -Be 'Skip'
    }
    It 'never re-installs an older 2005-2013 build - present is present' {
        $installed = @(@{ Family = '2008'; Arch = 'x86'; Version = [version]'9.0.30729.17'; DisplayName = 'old 2008' })
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed $installed -Is64Bit $false)
        ($plan | Where-Object { $_.Package.Id -eq '2008-x86' }).Action | Should -Be 'Skip'
    }
    It 'treats a pinned family whose installed version could not be parsed as present (conservative)' {
        $installed = @(@{ Family = '2015-2022'; Arch = 'x64'; Version = $null; DisplayName = 'v14 (x64)' })
        $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed $installed -Is64Bit $true)
        ($plan | Where-Object { $_.Package.Id -eq '2015-2022-x64' }).Action | Should -Be 'Skip'
    }
}

Describe 'Get-WtVcRedistPackageFile - local copy, cache, download' {
    BeforeEach {
        $script:tmp = Join-Path $env:TEMP ('wt_vcredist_' + [guid]::NewGuid().ToString('N'))
        $script:cache = Join-Path $tmp 'cache'
        $script:local = Join-Path $tmp 'local'
        New-Item -ItemType Directory -Path $cache, $local -Force | Out-Null
        $script:pkg = @{ Id = 't-x86'; Family = 't'; Arch = 'x86'; File = 'vcredist_t.exe'; Size = 10; Args = '/q'; MinVersion = $null; Major = 0 }
        $script:downloads = @()
        $script:download = {
            param($Url, $Path, $OnProgress)
            $script:downloads += $Url
            [IO.File]::WriteAllBytes($Path, [byte[]](1..10))
            & $OnProgress 100
        }
    }
    AfterEach { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'uses a local copy of the right size and never downloads' {
        [IO.File]::WriteAllBytes((Join-Path $local 'vcredist_t.exe'), [byte[]](1..10))
        $r = Get-WtVcRedistPackageFile -Package $pkg -CacheDir $cache -LocalDirs @($local) -Download $download
        $r.Path | Should -Be (Join-Path $local 'vcredist_t.exe')
        $r.Source | Should -Be 'Local'
        $script:downloads.Count | Should -Be 0
    }
    It 'ignores a local copy of the wrong size' {
        [IO.File]::WriteAllBytes((Join-Path $local 'vcredist_t.exe'), [byte[]](1..3))
        $r = Get-WtVcRedistPackageFile -Package $pkg -CacheDir $cache -LocalDirs @($local) -Download $download
        $r.Source | Should -Be 'Download'
        $script:downloads.Count | Should -Be 1
    }
    It 'reuses a cached file of the right size' {
        [IO.File]::WriteAllBytes((Join-Path $cache 'vcredist_t.exe'), [byte[]](1..10))
        $r = Get-WtVcRedistPackageFile -Package $pkg -CacheDir $cache -LocalDirs @() -Download $download
        $r.Source | Should -Be 'Cache'
        $r.Path | Should -Be (Join-Path $cache 'vcredist_t.exe')
        $script:downloads.Count | Should -Be 0
    }
    It 'downloads to a .part file from the raw GitHub url and renames it only when the size matches' {
        $progress = @()
        $r = Get-WtVcRedistPackageFile -Package $pkg -CacheDir $cache -LocalDirs @() -Download $download -OnProgress { param($p) $script:progress += $p }
        $script:downloads[0] | Should -Be (Get-WtVcRedistUrl -File 'vcredist_t.exe')
        $r.Path | Should -Be (Join-Path $cache 'vcredist_t.exe')
        Test-Path -LiteralPath (Join-Path $cache 'vcredist_t.exe.part') | Should -BeFalse
        (Get-Item -LiteralPath $r.Path).Length | Should -Be 10
    }
    It 'a short download is deleted and reported, never kept as if it were the installer' {
        $short = { param($Url, $Path, $OnProgress) [IO.File]::WriteAllBytes($Path, [byte[]](1..4)) }
        { Get-WtVcRedistPackageFile -Package $pkg -CacheDir $cache -LocalDirs @() -Download $short } | Should -Throw
        Test-Path -LiteralPath (Join-Path $cache 'vcredist_t.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cache 'vcredist_t.exe.part') | Should -BeFalse
    }
    It 'a stale .part from a killed run is overwritten, not trusted' {
        [IO.File]::WriteAllBytes((Join-Path $cache 'vcredist_t.exe.part'), [byte[]](1..10))
        $r = Get-WtVcRedistPackageFile -Package $pkg -CacheDir $cache -LocalDirs @() -Download $download
        $script:downloads.Count | Should -Be 1
        $r.Source | Should -Be 'Download'
    }
}

Describe 'Get-WtVcRedistLocalDirs' {
    BeforeAll {
        $script:VcHome = Join-Path ([IO.Path]::GetTempPath()) ('wt-vc-home-' + [guid]::NewGuid().ToString('N'))
        $script:VcBundle = Join-Path $VcHome 'Visual-C-Runtimes-WinToolify'
        $null = New-Item -ItemType Directory -Path $VcBundle -Force
    }
    AfterAll { Remove-Item -LiteralPath $script:VcHome -Recurse -Force -ErrorAction SilentlyContinue }

    It 'finds the bundled folder sitting next to the script' {
        @(Get-WtVcRedistLocalDirs -ScriptRoot $VcHome -LaunchHome '') | Should -Be @($VcBundle)
    }

    It 'falls back to the launch folder handed down by the elevated relaunch, which runs from text and has no $PSScriptRoot' {
        @(Get-WtVcRedistLocalDirs -ScriptRoot '' -LaunchHome $VcHome) | Should -Be @($VcBundle)
    }

    It 'prefers the script folder over the handed-down one when both are set' {
        @(Get-WtVcRedistLocalDirs -ScriptRoot $VcHome -LaunchHome 'C:\nowhere') | Should -Be @($VcBundle)
    }

    It 'returns nothing when neither is known - the released single file downloads instead' {
        @(Get-WtVcRedistLocalDirs -ScriptRoot '' -LaunchHome '') | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-WtVcRedistAction - the narrated run' {
    <#
    .SYNOPSIS
        $script:runEntries, not a bare $entries: PowerShell variable names
        are case-insensitive, so a $Entries read inside the -GetInstalled
        delegate would resolve dynamically to Invoke-WtVcRedistAction's
        own local $entries instead of this BeforeEach's variable, even
        though the two differ only in case.
    #>
    BeforeEach {
        $script:tmp = Join-Path $env:TEMP ('wt_vcredist_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $script:installs = @()
        $script:codes = @{}
        $script:install = { param($Path, $Arguments) $script:installs += (Split-Path -Leaf $Path) + ' ' + $Arguments; $code = 0; if ($script:codes.ContainsKey((Split-Path -Leaf $Path))) { $code = $script:codes[(Split-Path -Leaf $Path)] }; $code }
        $script:download = { param($Url, $Path, $OnProgress) $name = Split-Path -Leaf $Path; $name = $name -replace '\.part$', ''; $size = (@(Get-WtVcRedistCatalog) | Where-Object File -eq $name).Size; $fs = [IO.File]::Create($Path); $fs.SetLength($size); $fs.Dispose(); & $OnProgress 50; & $OnProgress 100 }
        $script:run = {
            param($Entries, $Is64 = $true)
            $script:runEntries = $Entries
            @(Invoke-WtVcRedistAction -GetInstalled { $script:runEntries } -Is64Bit $Is64 -CacheDir $script:tmp -LocalDirs @() -Download $script:download -Install $script:install 6>&1 | ForEach-Object { [string]$_ })
        }
    }
    AfterEach { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'on a fully provisioned machine says so and runs no installer and no download' {
        $lines = & $run $RealEntries
        $lines[0] | Should -Be (Get-Translation 'VcRedistChecking')
        @($lines | Where-Object { $_ -like '*Visual C++ 2010 (x64)*' }).Count | Should -Be 1
        $lines[-1] | Should -Be (Get-Translation 'VcRedistNothingToDo')
        $script:installs.Count | Should -Be 0
        @($lines | Where-Object { $_ -eq ((Get-Translation 'VcRedistSkip') -f 'Visual C++ 2010 (x64)', '10.0.40219') }).Count | Should -Be 1
    }
    It 'downloads and installs only the missing packages, with the catalog switches, and sums up' {
        $entries = @($RealEntries | Where-Object { $_.DisplayName -notmatch '2013|2012 Redistributable \(x86\)' })
        $lines = & $run $entries
        $script:installs | Should -Be @('vcredist2012_x86.exe /passive /norestart', 'vcredist2013_x86.exe /passive /norestart', 'vcredist2013_x64.exe /passive /norestart')
        $lines | Should -Contain ((Get-Translation 'VcRedistToInstall') -f 'Visual C++ 2013 (x64)')
        $lines | Should -Contain ((Get-Translation 'VcRedistInstalled') -f 'Visual C++ 2013 (x64)')
        $lines | Should -Contain ((Get-Translation 'VcRedistDownloadProgress') -f 'Visual C++ 2013 (x64)', 50)
        $lines[-1] | Should -Be ((Get-Translation 'VcRedistSummary') -f 3, 0, 9, 0)
        Test-Path -LiteralPath (Join-Path $tmp 'vcredist2013_x64.exe') | Should -BeFalse
    }
    It 'reads 3010 as installed-with-restart, 1638 as a newer version present, anything else as a failure with the code' {
        $entries = @($RealEntries | Where-Object { $_.DisplayName -notmatch '2013|2010' })
        $script:codes = @{ 'vcredist2010_x86.exe' = 3010; 'vcredist2010_x64.exe' = 1638; 'vcredist2013_x86.exe' = 1603 }
        $lines = & $run $entries
        $lines | Should -Contain ((Get-Translation 'VcRedistInstalledReboot') -f 'Visual C++ 2010 (x86)')
        $lines | Should -Contain ((Get-Translation 'VcRedistNewerPresent') -f 'Visual C++ 2010 (x64)')
        $lines | Should -Contain ((Get-Translation 'VcRedistFailed') -f 'Visual C++ 2013 (x86)', 1603)
        $lines | Should -Contain (Get-Translation 'VcRedistRebootNote')
        $lines[-2] | Should -Be ((Get-Translation 'VcRedistSummary') -f 2, 0, 9, 1)
        Test-Path -LiteralPath (Join-Path $tmp 'vcredist2013_x86.exe') | Should -BeTrue
    }
    It 'a failed download is one line and the run carries on with the next package' {
        $entries = @($RealEntries | Where-Object { $_.DisplayName -notmatch '2013' })
        $bad = { param($Url, $Path, $OnProgress) if ($Url -like '*x86*') { throw 'no network' } & $script:download $Url $Path $OnProgress }
        $script:runEntries = $entries
        $lines = @(Invoke-WtVcRedistAction -GetInstalled { $script:runEntries } -Is64Bit $true -CacheDir $script:tmp -LocalDirs @() -Download $bad -Install $script:install 6>&1 | ForEach-Object { [string]$_ })
        $lines | Should -Contain ((Get-Translation 'VcRedistDownloadFailed') -f 'Visual C++ 2013 (x86)', 'no network')
        $script:installs | Should -Be @('vcredist2013_x64.exe /passive /norestart')
        $lines[-1] | Should -Be ((Get-Translation 'VcRedistSummary') -f 1, 0, 10, 1)
    }
    It 'names an update as an update' {
        $entries = @($RealEntries | Where-Object { $_.DisplayName -notmatch 'v14 Redistributable \(x64\)' }) + @(New-WtTestProgramEntry 'Microsoft Visual C++ 2015 Redistributable (x64) - 14.0.24215' '14.0.24215.1')
        $lines = & $run $entries
        $lines | Should -Contain ((Get-Translation 'VcRedistToUpdate') -f 'Visual C++ 2015-2022 (x64)', '14.0.24215.1', '14.42.34433')
        $lines | Should -Contain ((Get-Translation 'VcRedistUpdated') -f 'Visual C++ 2015-2022 (x64)')
        $lines[-1] | Should -Be ((Get-Translation 'VcRedistSummary') -f 0, 1, 11, 0)
    }
    It 'never calls Read-Host, never Win32_Product, and no longer downloads the repository zip' {
        $def = (Get-Command Invoke-WtVcRedistAction).Definition
        $code = [regex]::Replace([regex]::Replace($def, '(?s)<#.*?#>', ''), '(?m)#.*$', '')
        $code | Should -Not -Match 'Read-Host'
        $code | Should -Not -Match 'Win32_Product'
        $code | Should -Not -Match 'archive/refs/heads'
        $code | Should -Not -Match 'Expand-Archive'
        $code | Should -Not -Match 'install_all\.bat'
    }
}

Describe 'The row moved: Action Tools > Software, not Basic Tools' {
    It 'is the 4th row of the Software group, captured, SAFE, and runs Invoke-WtVcRedistAction' {
        $group = @(Get-WtActionToolGroups) | Where-Object HeaderKey -eq 'ActionGroupSoftware'
        $rows = @(& $group.GetRows)
        $rows[3].Name | Should -Be 'InstallVCRedist'
        $rows[3].Data.Captured | Should -BeTrue
        $rows[3].Risk | Should -Be 'SAFE'
        $rows[3].Data.Action.ToString() | Should -Match 'Invoke-WtVcRedistAction'
    }
    It 'Basic Tools is down to its two links' {
        @(Get-WtBasicToolsItems | ForEach-Object Name) | Should -Be @('ActionTools', 'InfoTools')
    }
    It 'the assistant index now files it under Action Tools > Software and still finds it by "vcredist"' {
        Reset-WtAssistantIndexCache
        $index = Get-WtAssistantToolIndex
        $e = Get-WtAssistantIndexEntry -Id 'InstallVCRedist' -Index $index
        $e.Kind | Should -Be 'Action'
        $e.Runnable | Should -BeTrue
        $e.PathEn | Should -Be 'Action Tools > Software'
        @((Find-WtAssistantEntries -Query 'vcredist' -Index $index).Entries | Select-Object -First 5 | ForEach-Object Id) | Should -Contain 'InstallVCRedist'
    }
    It 'the narration keys exist in both languages and carry the package placeholder (the old one-liners had none)' {
        foreach ($lang in 'EN', 'TR') {
            $t = $script:Translations[$lang]
            $t['VcRedistDownloading'] | Should -Match '\{0\}' -Because $lang
            $t['VcRedistInstalling'] | Should -Match '\{0\}' -Because $lang
            foreach ($k in 'VcRedistChecking', 'VcRedistSkip', 'VcRedistToInstall', 'VcRedistToUpdate', 'VcRedistNothingToDo', 'VcRedistDownloading', 'VcRedistDownloadProgress', 'VcRedistLocalCopy', 'VcRedistDownloadFailed', 'VcRedistInstalling', 'VcRedistInstalled', 'VcRedistUpdated', 'VcRedistInstalledReboot', 'VcRedistNewerPresent', 'VcRedistFailed', 'VcRedistSummary', 'VcRedistRebootNote') {
                $t.ContainsKey($k) | Should -BeTrue -Because "$lang $k"
            }
        }
        $script:Translations['TR']['InstallVCRedist'] | Should -Be 'Visual C++ (VCRedist) Paketlerini Kur'
        $script:Translations['EN']['InstallVCRedist'] | Should -Be 'Install Visual C++ (VCRedist) Packages'
    }
}
