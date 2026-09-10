# Visual C++ runtime installer: catalog, "already installed" detection,
# install/update plan, per-package download, and the narrated action.
# Covered by: tests/VcRedist.Tests.ps1

function Get-WtVcRedistCatalog {
    <#
    .SYNOPSIS
        The twelve installers the repo bundles under
        Visual-C-Runtimes-WinToolify, pure data, in the old install_all.bat's
        order. Size guards against a truncated download. MinVersion is set
        only on the 2015-2022 family, which upgrades in place (an old 14.0
        build is what "VCRUNTIME140_1.dll is missing" comes from); 2005-2013
        are frozen lines where "present" is enough. Major is the
        DisplayVersion major the Programs list carries per family.
    #>
    $passive = '/passive /norestart'
    return @(
        @{ Id = '2005-x86'; Family = '2005'; Arch = 'x86'; Major = 8; File = 'vcredist2005_x86.exe'; Size = 2707352; Args = '/q'; MinVersion = $null }
        @{ Id = '2005-x64'; Family = '2005'; Arch = 'x64'; Major = 8; File = 'vcredist2005_x64.exe'; Size = 3175832; Args = '/q'; MinVersion = $null }
        @{ Id = '2008-x86'; Family = '2008'; Arch = 'x86'; Major = 9; File = 'vcredist2008_x86.exe'; Size = 4479832; Args = '/qb'; MinVersion = $null }
        @{ Id = '2008-x64'; Family = '2008'; Arch = 'x64'; Major = 9; File = 'vcredist2008_x64.exe'; Size = 5207896; Args = '/qb'; MinVersion = $null }
        @{ Id = '2010-x86'; Family = '2010'; Arch = 'x86'; Major = 10; File = 'vcredist2010_x86.exe'; Size = 8990552; Args = $passive; MinVersion = $null }
        @{ Id = '2010-x64'; Family = '2010'; Arch = 'x64'; Major = 10; File = 'vcredist2010_x64.exe'; Size = 10274136; Args = $passive; MinVersion = $null }
        @{ Id = '2012-x86'; Family = '2012'; Arch = 'x86'; Major = 11; File = 'vcredist2012_x86.exe'; Size = 6554576; Args = $passive; MinVersion = $null }
        @{ Id = '2012-x64'; Family = '2012'; Arch = 'x64'; Major = 11; File = 'vcredist2012_x64.exe'; Size = 7186992; Args = $passive; MinVersion = $null }
        @{ Id = '2013-x86'; Family = '2013'; Arch = 'x86'; Major = 12; File = 'vcredist2013_x86.exe'; Size = 6510136; Args = $passive; MinVersion = $null }
        @{ Id = '2013-x64'; Family = '2013'; Arch = 'x64'; Major = 12; File = 'vcredist2013_x64.exe'; Size = 7200744; Args = $passive; MinVersion = $null }
        @{ Id = '2015-2022-x86'; Family = '2015-2022'; Arch = 'x86'; Major = 14; File = 'vcredist2015_2017_2019_2022_x86.exe'; Size = 13957544; Args = $passive; MinVersion = '14.42.34433' }
        @{ Id = '2015-2022-x64'; Family = '2015-2022'; Arch = 'x64'; Major = 14; File = 'vcredist2015_2017_2019_2022_x64.exe'; Size = 25640112; Args = $passive; MinVersion = '14.42.34433' }
    )
}

function Get-WtVcRedistUrl {
    <#
    .SYNOPSIS
        Where one bundled installer is fetched from: the raw GitHub path
        of the repo folder. One file at a time - the old action pulled the
        whole repository as a 120 MB zip for every run.
    #>
    param([Parameter(Mandatory)][string]$File)
    return 'https://raw.githubusercontent.com/burakarslan0110/WinToolify/main/Visual-C-Runtimes-WinToolify/' + $File
}

function Get-WtVcRedistPackageLabel {
    <#
    .SYNOPSIS
        "Visual C++ 2015-2022 (x64)" - the same in both languages, so the
        narration lines only translate the verb around it.
    #>
    param([Parameter(Mandatory)]$Package)
    return 'Visual C++ ' + [string]$Package.Family + ' (' + [string]$Package.Arch + ')'
}

function ConvertTo-WtVcRedistInstalled {
    <#
    .SYNOPSIS
        PURE: the Visual C++ runtimes present in a Programs-list snapshot
        (Get-WtInstalledProgramEntries), as @{ Family; Arch; Version;
        DisplayName }. Family comes from DisplayVersion's major, not a year
        in the name (which varies: "2015", "2017", "2015-2022", "v14" all
        mean the same family), falling back to a year match only when
        DisplayVersion is missing or unparsable. The name must start with
        "Microsoft Visual C++" and contain "Redistributable" (excludes the
        "Minimum/Additional Runtime" MSI halves); x64 is a name marker
        (2005 x86 has none), ARM64 rows are ignored.
    #>
    param([AllowNull()][AllowEmptyCollection()][array]$Entries)
    $families = @{ 8 = '2005'; 9 = '2008'; 10 = '2010'; 11 = '2012'; 12 = '2013'; 14 = '2015-2022' }
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $name = [string]$entry.DisplayName
        if (-not $name.StartsWith('Microsoft Visual C++', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($name.IndexOf('Redistributable', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($name.IndexOf('arm64', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        $arch = if ([regex]::IsMatch($name, '\bx64\b', $ignoreCase)) { 'x64' } else { 'x86' }
        $version = $null
        $parsed = $null
        if ([version]::TryParse([string]$entry.DisplayVersion, [ref]$parsed)) { $version = $parsed }
        $family = $null
        if ($null -ne $version -and $families.ContainsKey($version.Major)) { $family = $families[$version.Major] }
        if (-not $family) {
            $year = [regex]::Match($name, '\b(2005|2008|2010|2012|2013)\b')
            if ($year.Success) { $family = $year.Groups[1].Value }
            elseif ([regex]::IsMatch($name, '\b(2015|2017|2019|2022|v14)\b', $ignoreCase)) { $family = '2015-2022' }
        }
        if (-not $family) { continue }
        $out.Add(@{ Family = $family; Arch = $arch; Version = $version; DisplayName = $name })
    }
    return $out.ToArray()
}

function Get-WtVcRedistPlan {
    <#
    .SYNOPSIS
        PURE: one row per catalog package this machine can take -
        @{ Package; Action = 'Install'|'Update'|'Skip'; InstalledVersion;
        DisplayName } - in catalog order. Present is Skip, unless MinVersion
        says the installed build is older (then Update, upgrading in place);
        an unreadable installed version still counts as present, since
        reinstalling over an unknown build is the wrong default. x64
        packages are dropped entirely on 32-bit Windows; when two rows match
        one family, the higher version wins.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog,
        [AllowNull()][AllowEmptyCollection()][array]$Installed,
        [bool]$Is64Bit = $true
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($package in @($Catalog)) {
        if ([string]$package.Arch -eq 'x64' -and -not $Is64Bit) { continue }
        $hit = $null
        foreach ($item in @($Installed)) {
            if ($null -eq $item) { continue }
            if ([string]$item.Family -ne [string]$package.Family -or [string]$item.Arch -ne [string]$package.Arch) { continue }
            if ($null -eq $hit) { $hit = $item; continue }
            if ($null -ne $item.Version -and ($null -eq $hit.Version -or [version]$item.Version -gt [version]$hit.Version)) { $hit = $item }
        }
        if ($null -eq $hit) {
            $rows.Add(@{ Package = $package; Action = 'Install'; InstalledVersion = ''; DisplayName = '' })
            continue
        }
        $action = 'Skip'
        $installedVersion = if ($null -ne $hit.Version) { [string]$hit.Version } else { '' }
        if ($package.MinVersion -and $null -ne $hit.Version) {
            if ([version]$hit.Version -lt [version]$package.MinVersion) { $action = 'Update' }
        }
        $rows.Add(@{ Package = $package; Action = $action; InstalledVersion = $installedVersion; DisplayName = [string]$hit.DisplayName })
    }
    return $rows.ToArray()
}

function Test-WtVcRedistFileComplete {
    <#
    .SYNOPSIS
        A file exists and has exactly the catalog's byte length. The only
        integrity check the installers get; it catches the one failure
        that actually happens - a download cut short.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Size
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return ((Get-Item -LiteralPath $Path).Length -eq $Size) } catch { return $false }
}

function Get-WtVcRedistLocalDirs {
    <#
    .SYNOPSIS
        Where a bundled copy of the installers might already sit: the repo
        folder next to the script or one level up (a development checkout
        runs dist\WinToolify.ps1). Only directories that exist come back;
        the released single file has none and downloads. -LaunchHome is
        the fallback the elevated relaunch hands down in
        $env:WINTOOLIFY_HOME: that child is built from script TEXT, so it
        has no $PSScriptRoot of its own and would otherwise re-download
        120 MB a development checkout already has on disk.
    #>
    param(
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$LaunchHome = $env:WINTOOLIFY_HOME
    )
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = $LaunchHome }
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { return @() }
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($base in @($ScriptRoot, (Split-Path -Parent $ScriptRoot))) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $candidate = Join-Path $base 'Visual-C-Runtimes-WinToolify'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $dirs.Add($candidate) }
    }
    return $dirs.ToArray()
}

function Invoke-WtVcRedistDownload {
    <#
    .SYNOPSIS
        Streams one installer to disk with HttpWebRequest, reporting 25 /
        50 / 75 percent through -OnProgress so the panel's clock never
        looks frozen on a 25 MB file. The old WebClient.DownloadFile said
        nothing for the whole 120 MB. Progress is called via $null = & ...,
        since a callback's return value must not leak into this function's
        own output.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OnProgress = { param($Percent) }
    )
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { $null = $_ }
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'WinToolify'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $response = $request.GetResponse()
    try {
        $total = [long]$response.ContentLength
        $input = $response.GetResponseStream()
        $output = [System.IO.File]::Create($Path)
        try {
            $buffer = New-Object byte[] 65536
            $done = [long]0
            $nextStep = 25
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $read)
                $done += $read
                if ($total -gt 0) {
                    $percent = [int][Math]::Floor(($done * 100) / $total)
                    while ($nextStep -le 75 -and $percent -ge $nextStep) {
                        $null = & $OnProgress $nextStep
                        $nextStep += 25
                    }
                }
            }
        }
        finally {
            $output.Dispose()
            $input.Dispose()
        }
    }
    finally { $response.Close() }
}

function Get-WtVcRedistPackageFile {
    <#
    .SYNOPSIS
        The installer file for one package, as @{ Path; Source =
        'Local'|'Cache'|'Download' }: a bundled local copy if there is one
        of the right size, else the cached file of the right size, else a
        fresh download into <CacheDir>\<file>.part, renamed only once its
        length matches the catalog. A short download is deleted and
        reported; a .part left by a killed run is never trusted. Throws
        when the file cannot be obtained.
    #>
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$CacheDir,
        [AllowNull()][AllowEmptyCollection()][string[]]$LocalDirs = @(),
        [scriptblock]$Download = { param($Url, $Path, $OnProgress) Invoke-WtVcRedistDownload -Url $Url -Path $Path -OnProgress $OnProgress },
        [scriptblock]$OnProgress = { param($Percent) }
    )
    $file = [string]$Package.File
    $size = [long]$Package.Size
    foreach ($dir in @($LocalDirs)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $local = Join-Path $dir $file
        if (Test-WtVcRedistFileComplete -Path $local -Size $size) { return @{ Path = $local; Source = 'Local' } }
    }
    if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $target = Join-Path $CacheDir $file
    if (Test-WtVcRedistFileComplete -Path $target -Size $size) { return @{ Path = $target; Source = 'Cache' } }
    $part = $target + '.part'
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    $url = Get-WtVcRedistUrl -File $file
    try { $null = & $Download $url $part $OnProgress }
    catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw
    }
    if (-not (Test-WtVcRedistFileComplete -Path $part -Size $size)) {
        $got = [long]0
        try { if (Test-Path -LiteralPath $part) { $got = (Get-Item -LiteralPath $part).Length } } catch { $got = 0 }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw ('size mismatch: expected {0} bytes, got {1}' -f $size, $got)
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $part -Destination $target -Force
    return @{ Path = $target; Source = 'Download' }
}

function Invoke-WtVcRedistAction {
    <#
    .SYNOPSIS
        Action Tools > Software > "Install Visual C++ (VCRedist) Packages":
        reads what is installed, then downloads and runs only the packages
        the plan needs, printing one line per step and summing up at the end.

        Every step prints a line to keep the captured panel's clock moving,
        since a silent download used to invite queued Enter presses that
        replayed (see Clear-WtPendingInput). Exit codes: 0 installed, 3010
        + restart wanted, 1638 a newer build already there (skipped),
        anything else a failure; a cached installer is deleted on success
        or refused-as-older, kept for retry on failure. The -OnProgress
        callback closes over $label through the call stack, not
        GetNewClosure, which breaks once the built file is run.
    #>
    param(
        [scriptblock]$GetInstalled = { Get-WtInstalledProgramEntries },
        [bool]$Is64Bit = [System.Environment]::Is64BitOperatingSystem,
        [AllowNull()][array]$Catalog = $null,
        [string]$CacheDir = '',
        [AllowNull()][string[]]$LocalDirs = $null,
        [scriptblock]$Download = { param($Url, $Path, $OnProgress) Invoke-WtVcRedistDownload -Url $Url -Path $Path -OnProgress $OnProgress },
        [scriptblock]$Install = { param($Path, $Arguments) (Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru).ExitCode }
    )
    if (-not $Catalog) { $Catalog = @(Get-WtVcRedistCatalog) }
    if (-not $CacheDir) { $CacheDir = Get-WtDataPath -Scope User -SubPath 'cache\vcredist' }
    if ($null -eq $LocalDirs) { $LocalDirs = @(Get-WtVcRedistLocalDirs) }

    Write-Host (Get-Translation 'VcRedistChecking')
    $entries = @()
    try { $entries = @(& $GetInstalled) } catch { $entries = @() }
    $installed = @(ConvertTo-WtVcRedistInstalled -Entries $entries)
    $plan = @(Get-WtVcRedistPlan -Catalog $Catalog -Installed $installed -Is64Bit $Is64Bit)

    $todo = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    foreach ($row in $plan) {
        $label = Get-WtVcRedistPackageLabel -Package $row.Package
        switch ([string]$row.Action) {
            'Skip' {
                Write-Host ((Get-Translation 'VcRedistSkip') -f $label, [string]$row.InstalledVersion)
                $skipped++
            }
            'Update' {
                Write-Host ((Get-Translation 'VcRedistToUpdate') -f $label, [string]$row.InstalledVersion, [string]$row.Package.MinVersion)
                $todo.Add($row)
            }
            default {
                Write-Host ((Get-Translation 'VcRedistToInstall') -f $label)
                $todo.Add($row)
            }
        }
    }
    if ($todo.Count -eq 0) {
        Write-Host (Get-Translation 'VcRedistNothingToDo')
        return
    }

    Write-Host ''
    $installedCount = 0
    $updatedCount = 0
    $failed = 0
    $rebootWanted = $false
    foreach ($row in $todo) {
        $package = $row.Package
        $label = Get-WtVcRedistPackageLabel -Package $package
        Write-Host ((Get-Translation 'VcRedistDownloading') -f $label, (Format-WtByteSize -Bytes ([long]$package.Size)))
        $file = $null
        try {
            $file = Get-WtVcRedistPackageFile -Package $package -CacheDir $CacheDir -LocalDirs $LocalDirs -Download $Download `
                -OnProgress { param($Percent) if ([int]$Percent -lt 100) { Write-Host ((Get-Translation 'VcRedistDownloadProgress') -f $label, [int]$Percent) } }
        }
        catch {
            Write-Host ((Get-Translation 'VcRedistDownloadFailed') -f $label, $_.Exception.Message)
            $failed++
            continue
        }
        if ([string]$file.Source -eq 'Local') { Write-Host ((Get-Translation 'VcRedistLocalCopy') -f $label) }
        Write-Host ((Get-Translation 'VcRedistInstalling') -f $label)
        $code = -1
        try { $code = [int](& $Install ([string]$file.Path) ([string]$package.Args)) }
        catch {
            Write-Host $_.Exception.Message
            $code = -1
        }
        $done = $false
        switch ($code) {
            0 {
                if ([string]$row.Action -eq 'Update') { Write-Host ((Get-Translation 'VcRedistUpdated') -f $label); $updatedCount++ }
                else { Write-Host ((Get-Translation 'VcRedistInstalled') -f $label); $installedCount++ }
                $done = $true
            }
            3010 {
                Write-Host ((Get-Translation 'VcRedistInstalledReboot') -f $label)
                if ([string]$row.Action -eq 'Update') { $updatedCount++ } else { $installedCount++ }
                $rebootWanted = $true
                $done = $true
            }
            1638 {
                Write-Host ((Get-Translation 'VcRedistNewerPresent') -f $label)
                $skipped++
                $done = $true
            }
            default {
                Write-Host ((Get-Translation 'VcRedistFailed') -f $label, $code)
                $failed++
            }
        }
        if ($done -and [string]$file.Source -ne 'Local') {
            Remove-Item -LiteralPath ([string]$file.Path) -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host ''
    Write-Host ((Get-Translation 'VcRedistSummary') -f $installedCount, $updatedCount, $skipped, $failed)
    if ($rebootWanted) { Write-Host (Get-Translation 'VcRedistRebootNote') }
}
