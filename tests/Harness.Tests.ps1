#Requires -Modules Pester

<#
.SYNOPSIS
    Mutation check for the verification harness itself: proves the 5.1/7.0
    compatibility gate actually reports findings for PS7-only syntax and
    reports zero for 5.1-clean syntax, rather than silently always passing.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:SettingsPath = Join-Path (Join-Path $RepoRoot 'tools') 'PSScriptAnalyzerSettings.psd1'

    . (Join-Path (Join-Path $RepoRoot 'tools') 'Invoke-WtChecks.ps1')

    $script:FixtureDir = Join-Path $TestDrive 'fixtures'
    New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null

    $script:BadFixture = Join-Path $FixtureDir 'bad51.ps1'
    Set-Content -LiteralPath $BadFixture -Encoding UTF8 -Value @'
function Test-Bad {
    param($x)
    $y = $x ?? "fallback"
    $z = $true ? "a" : "b"
    return "$y$z"
}
'@

    $script:CleanFixture = Join-Path $FixtureDir 'clean51.ps1'
    Set-Content -LiteralPath $CleanFixture -Encoding UTF8 -Value @'
function Test-Clean {
    param([string]$Name)
    if ($Name) {
        return "hi $Name"
    } else {
        return "hi"
    }
}
'@

    $script:UnparseableFixture = Join-Path $FixtureDir 'unparseable.ps1'
    Set-Content -LiteralPath $UnparseableFixture -Encoding UTF8 -Value 'function Broken( {'
}

Describe 'Test-WtCompatibility' {
    It 'reports findings for PowerShell 7-only syntax (??, ternary)' {
        $findings = Test-WtCompatibility -Path $BadFixture -SettingsPath $SettingsPath
        @($findings).Count | Should -BeGreaterThan 0
    }

    It 'reports zero findings for 5.1-clean syntax' {
        $findings = Test-WtCompatibility -Path $CleanFixture -SettingsPath $SettingsPath
        @($findings).Count | Should -Be 0
    }

    It 'reports zero findings for the current WinToolify.ps1' {
        $target = Join-Path $RepoRoot 'dist/WinToolify.ps1'
        $findings = Test-WtCompatibility -Path $target -SettingsPath $SettingsPath
        @($findings).Count | Should -Be 0
    }
}

Describe 'Test-WtParse' {
    It 'reports zero parse errors for valid syntax' {
        $parseErrors = Test-WtParse -Path $CleanFixture
        @($parseErrors).Count | Should -Be 0
    }

    It 'reports parse errors for invalid syntax' {
        $parseErrors = Test-WtParse -Path $UnparseableFixture
        @($parseErrors).Count | Should -BeGreaterThan 0
    }

    It 'reports zero parse errors for the current WinToolify.ps1' {
        $target = Join-Path $RepoRoot 'dist/WinToolify.ps1'
        $parseErrors = Test-WtParse -Path $target
        @($parseErrors).Count | Should -Be 0
    }
}

Describe 'Invoke-WtChecks.ps1 (run as a script, not dot-sourced)' {
    It 'stamps the -Version it was given, not Build-WinToolify.ps1''s own default' {
        $fixtureTestFile = Join-Path $FixtureDir 'trivial.Tests.ps1'
        Set-Content -LiteralPath $fixtureTestFile -Encoding UTF8 -Value @'
Describe 'trivial' {
    It 'passes' {
        $true | Should -BeTrue
    }
}
'@

        $targetPath = Join-Path $TestDrive 'version-stamp/WinToolify.ps1'
        $runner = Join-Path (Join-Path $RepoRoot 'tools') 'Invoke-WtChecks.ps1'

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Version 'v9.9.9' -TargetPath $targetPath -TestPath $fixtureTestFile | Out-Null
        $LASTEXITCODE | Should -Be 0

        Test-Path -LiteralPath $targetPath | Should -BeTrue
        $headerLine = @(Get-Content -LiteralPath $targetPath | Where-Object { $_ -match '^# Version:' })[0]
        $headerLine.Trim() | Should -Be '# Version: 9.9.9'
    }
}
