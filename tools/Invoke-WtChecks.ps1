<#
.SYNOPSIS
    WinToolify V2 verification runner: build -> parse check -> PowerShell
    5.1/7.0 compatibility gate -> Pester; exits non-zero on any failure.
    -TargetPath is where the build writes the single-file script (default
    dist/WinToolify.ps1); -TestPath scopes Pester to one file (default the
    whole tests/ directory); -Version is stamped into the header (default
    "dev", the release workflow passes the git tag). Dot-source this file
    to load Test-WtParse / Test-WtCompatibility without running the CLI,
    via the same InvocationName guard WinToolify.ps1 uses. Dot-sourcing
    Build-WinToolify.ps1 re-runs its own param() block in this scope, so
    any parameter name the two scripts share is silently overwritten by
    that script's default - $Version is captured into $buildVersion
    before that dot-source for exactly this reason.
#>
[CmdletBinding()]
param(
    [string]$TargetPath,
    [string]$TestPath,
    [string]$Version = 'dev'
)

function Test-WtParse {
    <#
    .SYNOPSIS
        Parses a PowerShell file and returns its parse errors (empty array
        when the file parses cleanly).
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ParseError[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors) | Out-Null
    return @($parseErrors)
}

function Test-WtCompatibility {
    <#
    .SYNOPSIS
        Runs the PSUseCompatibleCommands / PSUseCompatibleSyntax analyzer rules
        against a file using the repo's compatibility settings, and returns the
        findings (empty array when clean). Only these two rules run: a bare
        -Settings hashtable also pulls in the default rule set, which reports
        pre-existing findings (PSAvoidUsingWriteHost is correct and intentional
        for a terminal UI) and would make a zero-gate impossible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SettingsPath
    )

    $settings = Import-PowerShellDataFile -Path $SettingsPath
    return @(Invoke-ScriptAnalyzer -Path $Path -Settings $settings -IncludeRule PSUseCompatibleCommands, PSUseCompatibleSyntax)
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    if (-not $TargetPath) {
        $TargetPath = Join-Path (Join-Path $repoRoot 'dist') 'WinToolify.ps1'
    }
    $settingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

    $exitCode = 0

    $buildVersion = $Version
    . (Join-Path $PSScriptRoot 'Build-WinToolify.ps1')
    try {
        $build = Build-WinToolify -SourceRoot (Join-Path $repoRoot 'src') -OutputPath $TargetPath -Version $buildVersion
        Write-Host ("Build: OK ({0} parts, {1} functions, {2} lines)" -f $build.PartCount, $build.FunctionCount, $build.LineCount) -ForegroundColor Green
    }
    catch {
        Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    $parseErrors = Test-WtParse -Path $TargetPath
    if ($parseErrors.Count -gt 0) {
        Write-Host "PARSE ERRORS: $($parseErrors.Count)" -ForegroundColor Red
        foreach ($parseError in $parseErrors) {
            Write-Host " - Line $($parseError.Extent.StartLineNumber): $($parseError.Message)" -ForegroundColor Red
        }
        $exitCode = 1
    }
    else {
        Write-Host 'Parse check: OK' -ForegroundColor Green
    }

    $compatFindings = Test-WtCompatibility -Path $TargetPath -SettingsPath $settingsPath
    if ($compatFindings.Count -gt 0) {
        Write-Host "COMPATIBILITY FINDINGS: $($compatFindings.Count)" -ForegroundColor Red
        foreach ($finding in $compatFindings) {
            Write-Host " - Line $($finding.Line): [$($finding.RuleName)] $($finding.Message)" -ForegroundColor Red
        }
        $exitCode = 1
    }
    else {
        Write-Host 'Compatibility check (5.1 / 7.0): OK' -ForegroundColor Green
    }

    $pesterModule = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]'5.0.0' -and $_.Version -lt [version]'6.0.0' } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if (-not $pesterModule) {
        Write-Host 'Pester 5.x not found - install with: Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force' -ForegroundColor Yellow
        $exitCode = 1
    }
    else {
        Import-Module Pester -RequiredVersion $pesterModule.Version -Force

        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = if ($TestPath) { $TestPath } else { Join-Path $repoRoot 'tests' }
        $pesterConfig.Run.Exit = $false
        $pesterConfig.Run.PassThru = $true
        $pesterConfig.Output.Verbosity = 'Normal'

        $result = Invoke-Pester -Configuration $pesterConfig
        if ($result.FailedCount -gt 0) {
            Write-Host "PESTER FAILURES: $($result.FailedCount)" -ForegroundColor Red
            $exitCode = 1
        }
        else {
            Write-Host "Pester: OK ($($result.PassedCount) passed)" -ForegroundColor Green
        }
    }

    exit $exitCode
}
