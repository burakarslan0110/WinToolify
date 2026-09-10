#Requires -Modules Pester

<#
.SYNOPSIS
    Get-WtDataPath scope resolution and the Write-WtJson / Read-WtJson
    serialization helpers.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtDataPath' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'requires -Scope (no default)' {
        $scopeParam = (Get-Command Get-WtDataPath).Parameters['Scope']
        $mandatoryAttrs = $scopeParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -ExpandProperty Mandatory
        $mandatoryAttrs | Should -Contain $true
    }

    It 'resolves Machine and User scopes to independent roots' {
        $machinePath = Get-WtDataPath -Scope Machine -TestRootOverride $FakeRoot
        $userPath = Get-WtDataPath -Scope User -TestRootOverride $FakeRoot
        $machinePath | Should -Not -Be $userPath
    }

    It 'creates a missing subdirectory' {
        $subPath = Get-WtDataPath -Scope User -SubPath 'undo' -TestRootOverride $FakeRoot
        Test-Path -LiteralPath $subPath -PathType Container | Should -BeTrue
    }

    It 'is safe to call repeatedly (idempotent)' {
        Get-WtDataPath -Scope Machine -SubPath 'undo' -TestRootOverride $FakeRoot | Out-Null
        { Get-WtDataPath -Scope Machine -SubPath 'undo' -TestRootOverride $FakeRoot } | Should -Not -Throw
        $second = Get-WtDataPath -Scope Machine -SubPath 'undo' -TestRootOverride $FakeRoot
        Test-Path -LiteralPath $second -PathType Container | Should -BeTrue
    }
}

Describe 'Write-WtJson / Read-WtJson round trip' {
    BeforeEach {
        $script:JsonPath = Join-Path $TestDrive "$([guid]::NewGuid().ToString()).json"
    }

    It 'survives a four-level-nested object round trip unchanged' {
        $original = [PSCustomObject]@{
            Id    = 'change-1'
            Level = [PSCustomObject]@{
                Two = [PSCustomObject]@{
                    Three = [PSCustomObject]@{
                        Four = 'deep-value'
                        Items = @('a', 'b', 'c')
                    }
                }
            }
        }

        Write-WtJson -Path $JsonPath -InputObject $original
        $roundTripped = Read-WtJson -Path $JsonPath

        $roundTripped.Id | Should -Be 'change-1'
        $roundTripped.Level.Two.Three.Four | Should -Be 'deep-value'
        @($roundTripped.Level.Two.Three.Items) | Should -Be @('a', 'b', 'c')
    }

    It 'returns $null for a missing file, without throwing' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.json'
        { Read-WtJson -Path $missingPath } | Should -Not -Throw
        Read-WtJson -Path $missingPath | Should -BeNullOrEmpty
    }

    It 'returns $null and warns for a corrupt file, without throwing' {
        Set-Content -LiteralPath $JsonPath -Encoding UTF8 -Value '{ this is not valid json'
        $warnings = $null
        $result = Read-WtJson -Path $JsonPath -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        @($warnings).Count | Should -BeGreaterThan 0
    }

    It 'a timestamp survives the round trip as invariant ISO text on either host' {
        Write-WtJson -Path $JsonPath -InputObject ([PSCustomObject]@{
                RoundTrip = (Get-Date '2026-09-01T11:00:00').ToString('o')
                Seconds   = (Get-Date '2026-09-01T08:00:00').ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            })
        $back = Read-WtJson -Path $JsonPath

        (ConvertTo-WtIsoText -Value $back.RoundTrip) | Should -Match '^2026-09-01T11:00:00'
        (ConvertTo-WtIsoText -Value $back.Seconds) | Should -Match '^2026-09-01T08:00:00'
    }
}

Describe 'ConvertTo-WtIsoText' {
    It 'passes a string through untouched' {
        (ConvertTo-WtIsoText -Value '2026-09-01T11:00:00.0000000') | Should -Be '2026-09-01T11:00:00.0000000'
        (ConvertTo-WtIsoText -Value 'not a date at all') | Should -Be 'not a date at all'
    }

    It 'formats a DateTime as invariant ISO, whatever the current culture is' {
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            (ConvertTo-WtIsoText -Value (Get-Date '2026-09-01T11:00:00')) | Should -Match '^2026-09-01T11:00:00'
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
            (ConvertTo-WtIsoText -Value (Get-Date '2026-09-01T11:00:00')) | Should -Match '^2026-09-01T11:00:00'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous }
    }

    It 'gives an empty string for $null and for an empty value' {
        (ConvertTo-WtIsoText -Value $null) | Should -Be ''
        (ConvertTo-WtIsoText -Value '') | Should -Be ''
    }
}

Describe 'Write-WtErrorLog' {
    BeforeEach { $script:LogFile = Join-Path $TestDrive ('errors-' + [guid]::NewGuid().ToString('N') + '.log') }
    It 'appends a block with the context, the type, the message, the position and the script stack, and returns the path' {
        try { throw 'disk on fire' } catch { $record = $_ }
        $path = Write-WtErrorLog -ErrorRecord $record -Context 'Screen: SystemSettings' -Path $script:LogFile
        $path | Should -Be $script:LogFile
        $text = Get-Content -LiteralPath $script:LogFile -Raw
        $text | Should -Match '==== \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} Screen: SystemSettings'
        $text | Should -Match 'Type: System.Management.Automation.RuntimeException'
        $text | Should -Match 'Message: disk on fire'
        $text | Should -Match 'At: '
        $text | Should -Match 'Stack: '
        $null = Write-WtErrorLog -ErrorRecord $record -Context 'second' -Path $script:LogFile
        ([regex]::Matches((Get-Content -LiteralPath $script:LogFile -Raw), '====')).Count | Should -Be 2
    }
    It 'takes a bare exception too' {
        $path = Write-WtErrorLog -ErrorRecord ([System.InvalidOperationException]::new('bare')) -Context 'c' -Path $script:LogFile
        $path | Should -Be $script:LogFile
        (Get-Content -LiteralPath $script:LogFile -Raw) | Should -Match 'Message: bare'
    }
    It 'never throws - an unwritable path yields an empty string' {
        try { throw 'x' } catch { $record = $_ }
        $result = $null
        { $result = Write-WtErrorLog -ErrorRecord $record -Context 'c' -Path 'Q:\no\such\drive\errors.log' } | Should -Not -Throw
        [string]$result | Should -Be ''
    }
    It 'starts over once the log passes a megabyte' {
        Set-Content -LiteralPath $script:LogFile -Value ('x' * (1MB + 10)) -NoNewline
        try { throw 'after trim' } catch { $record = $_ }
        $null = Write-WtErrorLog -ErrorRecord $record -Context 'c' -Path $script:LogFile
        (Get-Item -LiteralPath $script:LogFile).Length | Should -BeLessThan 4KB
    }
    It 'Get-WtErrorLogPath lives under the user data root and honours the script override' {
        $root = Join-Path $TestDrive 'root'
        (Get-WtErrorLogPath -TestRootOverride $root) | Should -Be (Join-Path (Join-Path $root 'User') 'errors.log')
        $script:WtErrorLogPath = 'C:\elsewhere\e.log'
        try { (Get-WtErrorLogPath -TestRootOverride $root) | Should -Be 'C:\elsewhere\e.log' }
        finally { $script:WtErrorLogPath = $null }
    }
    It 'Get-WtErrorSummaryLines gives the message and the first position line' {
        try { throw 'summary me' } catch { $record = $_ }
        $lines = @(Get-WtErrorSummaryLines -ErrorRecord $record)
        $lines[0] | Should -Be 'summary me'
        $lines.Count | Should -Be 2
        $lines[1] | Should -Match '^At '
        @(Get-WtErrorSummaryLines -ErrorRecord ([System.Exception]::new('plain'))) | Should -Be @('plain')
    }
}
