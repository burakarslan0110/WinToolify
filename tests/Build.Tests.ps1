#Requires -Modules Pester

<#
.SYNOPSIS
    tools/Build-WinToolify.ps1: concatenation order, region markers, BOM and
    CRLF normalisation, version stamping, duplicate-function and parse-error
    gates, and the layer-violation report - all against a synthetic src/
    tree under $TestDrive so the tests never depend on the real sources.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    . (Join-Path (Join-Path $RepoRoot 'tools') 'Build-WinToolify.ps1')

    function New-WtFakePart {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$RelativePath,
            [Parameter(Mandatory)][string]$Text,
            [switch]$WithBom,
            [switch]$Lf
        )
        $full = Join-Path $Root ($RelativePath -replace '/', '\')
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $body = if ($Lf) { $Text -replace "`r`n", "`n" } else { $Text -replace "(?<!`r)`n", "`r`n" }
        $enc = New-Object System.Text.UTF8Encoding($WithBom.IsPresent)
        [System.IO.File]::WriteAllText($full, $body, $enc)
    }

    function New-WtFakeTree {
        param([Parameter(Mandatory)][string]$Root)
        New-WtFakePart -Root $Root -RelativePath '00-core/00-header.ps1' -WithBom -Text @'
# WinToolify
# Version: __WT_VERSION__

function Get-FakeCore {
    return 'core'
}
'@
        New-WtFakePart -Root $Root -RelativePath '10-i18n/en.ps1' -Lf -Text @'
$script:FakeTranslations = @{ Hello = 'hi' }
'@
        New-WtFakePart -Root $Root -RelativePath '20-tui/frame.ps1' -Text @'
function Show-FakeFrame {
    return (Get-FakeCore)
}
'@
        New-WtFakePart -Root $Root -RelativePath '80-screens/main.ps1' -Text @'
function Invoke-FakeMain {
    return (Show-FakeFrame)
}
'@
    }
}

Describe 'Get-WtBuildParts' {
    It 'orders parts ordinally by relative path and reads the layer from the directory prefix' {
        $root = Join-Path $TestDrive 'src-order'
        New-WtFakeTree -Root $root
        $parts = @(Get-WtBuildParts -SourceRoot $root)
        $parts.RelativePath | Should -Be @('00-core/00-header.ps1', '10-i18n/en.ps1', '20-tui/frame.ps1', '80-screens/main.ps1')
        $parts.Layer | Should -Be @(0, 10, 20, 80)
    }

    It 'gives a part outside a numbered directory a $null layer' {
        $root = Join-Path $TestDrive 'src-nolayer'
        New-WtFakePart -Root $root -RelativePath 'misc/x.ps1' -Text 'function Get-X { 1 }'
        (Get-WtBuildParts -SourceRoot $root)[0].Layer | Should -BeNullOrEmpty
    }
}

Describe 'Build-WinToolify' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'src-ok'
        New-WtFakeTree -Root $Root
        $script:Out = Join-Path $TestDrive 'out\WinToolify.ps1'
        $script:Result = Build-WinToolify -SourceRoot $Root -OutputPath $Out -Version 'v2.1.0'
        $script:Raw = [System.IO.File]::ReadAllText($Out, [System.Text.Encoding]::UTF8)
        $script:Bytes = [System.IO.File]::ReadAllBytes($Out)
    }

    It 'creates the output directory and file' {
        Test-Path -LiteralPath $Out | Should -BeTrue
        $Result.OutputPath | Should -Be $Out
    }

    It 'wraps every part in region markers in ordinal order' {
        $Raw | Should -Match '(?s)#region src/00-core/00-header\.ps1.*#endregion src/00-core/00-header\.ps1.*#region src/10-i18n/en\.ps1.*#region src/20-tui/frame\.ps1.*#region src/80-screens/main\.ps1'
        $Result.PartCount | Should -Be 4
    }

    It 'writes a single UTF-8 BOM at the start and none inside' {
        $Bytes[0] | Should -Be 0xEF
        $Bytes[1] | Should -Be 0xBB
        $Bytes[2] | Should -Be 0xBF
        ([regex]::Matches($Raw, [string][char]0xFEFF)).Count | Should -Be 0
    }

    It 'normalises every line ending to CRLF' {
        ([regex]::Matches($Raw, '(?<!\r)\n')).Count | Should -Be 0
        ([regex]::Matches($Raw, '\r\n')).Count | Should -BeGreaterThan 5
    }

    It 'stamps the version without the leading v' {
        $Raw | Should -Match '# Version: 2\.1\.0'
        $Raw | Should -Not -Match '__WT_VERSION__'
    }

    It 'defaults the version to dev' {
        $out2 = Join-Path $TestDrive 'out-dev\WinToolify.ps1'
        Build-WinToolify -SourceRoot $Root -OutputPath $out2 | Out-Null
        [System.IO.File]::ReadAllText($out2) | Should -Match '# Version: dev'
    }

    It 'counts top-level functions and lines' {
        $Result.FunctionCount | Should -Be 3
        $Result.LineCount | Should -BeGreaterThan 10
    }

    It 'produces a file that dot-sources and runs end to end' {
        . $Out
        Invoke-FakeMain | Should -Be 'core'
        $script:FakeTranslations.Hello | Should -Be 'hi'
    }

    It 'reports no layer violations for a downward-only call graph' {
        @($Result.Violations).Count | Should -Be 0
    }
}

Describe 'Build-WinToolify gates' {
    It 'throws naming both files when a function is defined twice' {
        $root = Join-Path $TestDrive 'src-dup'
        New-WtFakeTree -Root $root
        New-WtFakePart -Root $root -RelativePath '60-actions/dup.ps1' -Text 'function Get-FakeCore { 2 }'
        $out = Join-Path $TestDrive 'out-dup\WinToolify.ps1'
        { Build-WinToolify -SourceRoot $root -OutputPath $out } |
            Should -Throw -ExpectedMessage '*Get-FakeCore*00-core/00-header.ps1*60-actions/dup.ps1*'
    }

    It 'throws on a parse error and names the source file and line' {
        $root = Join-Path $TestDrive 'src-parse'
        New-WtFakeTree -Root $root
        New-WtFakePart -Root $root -RelativePath '70-info/broken.ps1' -Text "# ok`nfunction Broken( {"
        $out = Join-Path $TestDrive 'out-parse\WinToolify.ps1'
        { Build-WinToolify -SourceRoot $root -OutputPath $out } |
            Should -Throw -ExpectedMessage '*src/70-info/broken.ps1:*'
    }

    It 'reports an upward call as a layer violation with the source location' {
        $root = Join-Path $TestDrive 'src-layer'
        New-WtFakeTree -Root $root
        New-WtFakePart -Root $root -RelativePath '00-core/bad.ps1' -Text @'
# comment line
function Get-FakeBad {
    return (Invoke-FakeMain)
}
'@
        $out = Join-Path $TestDrive 'out-layer\WinToolify.ps1'
        $result = Build-WinToolify -SourceRoot $root -OutputPath $out
        $v = @($result.Violations)
        $v.Count | Should -Be 1
        $v[0].Caller | Should -Be 'Get-FakeBad'
        $v[0].Callee | Should -Be 'Invoke-FakeMain'
        $v[0].CallerLayer | Should -Be 0
        $v[0].CalleeLayer | Should -Be 80
        $v[0].SourceFile | Should -Be 'src/00-core/bad.ps1'
        $v[0].SourceLine | Should -Be 3
    }

    It 'ignores calls to functions that are not defined in the build' {
        $root = Join-Path $TestDrive 'src-extern'
        New-WtFakeTree -Root $root
        New-WtFakePart -Root $root -RelativePath '00-core/ext.ps1' -Text 'function Get-FakeExt { Get-Date }'
        $out = Join-Path $TestDrive 'out-extern\WinToolify.ps1'
        @((Build-WinToolify -SourceRoot $root -OutputPath $out).Violations).Count | Should -Be 0
    }

    It 'fails when the source root has no parts' {
        $root = Join-Path $TestDrive 'src-empty'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $out = Join-Path $TestDrive 'out-empty\WinToolify.ps1'
        { Build-WinToolify -SourceRoot $root -OutputPath $out } | Should -Throw -ExpectedMessage '*no *.ps1 parts*'
    }
}
