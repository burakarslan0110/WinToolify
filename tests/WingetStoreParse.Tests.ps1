#Requires -Modules Pester

<#
.SYNOPSIS
    The winget table parser. winget localises its column headers, so the
    parser must never key off header TEXT - these fixtures are an English
    'winget search' and a Turkish 'winget list', both captured verbatim.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    function Get-Fixture($Name) {
        [string[]](Get-Content -LiteralPath (Join-Path $script:FixtureDir $Name) -Encoding UTF8)
    }
}

Describe 'ConvertFrom-WtWingetTable' {
    It 'parses an English search result and drops the spinner rows above it' {
        $rows = @(ConvertFrom-WtWingetTable -Lines (Get-Fixture 'winget-search-en.txt'))
        $rows.Count | Should -Be 3
        $rows[0].Name    | Should -Be 'VLC media player'
        $rows[0].Id      | Should -Be 'VideoLAN.VLC'
        $rows[0].Version | Should -Be '3.0.21'
        $rows[2].Id      | Should -Be 'OBSProject.OBSStudio'
    }

    It 'parses a Turkish list - the header words are different in every language' {
        $rows = @(ConvertFrom-WtWingetTable -Lines (Get-Fixture 'winget-list-tr.txt') -WithAvailable)
        $rows[0].Name | Should -Be '7-Zip 23.01 (x64)'
        $rows[0].Id   | Should -Be '7zip.7zip'
    }

    It 'reads the available-version column without knowing its localised name' {
        $rows = @(ConvertFrom-WtWingetTable -Lines (Get-Fixture 'winget-list-tr.txt') -WithAvailable)
        ($rows | Where-Object { $_.Id -eq '7zip.7zip' }).Available | Should -Be '24.09'
        ($rows | Where-Object { $_.Id -eq 'Git.Git' }).Available   | Should -Be ''
    }

    It 'does not mistake a Match column for an available version' {
        $rows = @(ConvertFrom-WtWingetTable -Lines (Get-Fixture 'winget-search-en.txt'))
        foreach ($r in $rows) { $r.Available | Should -Be '' }
    }

    It 'keeps an ARP entry that has no source' {
        $rows = @(ConvertFrom-WtWingetTable -Lines (Get-Fixture 'winget-list-tr.txt') -WithAvailable)
        @($rows | Where-Object { $_.Id -eq 'ARPKayit12345' }).Count | Should -Be 1
    }

    It 'drops the summary line printed after the table' {
        $rows = @(ConvertFrom-WtWingetTable -Lines (Get-Fixture 'winget-list-tr.txt') -WithAvailable)
        $rows.Count | Should -Be 4
        foreach ($r in $rows) { $r.Id | Should -Not -BeNullOrEmpty }
    }

    It 'returns nothing rather than throwing when winget printed no table' {
        @(ConvertFrom-WtWingetTable -Lines @('No installed package found matching input criteria.')).Count | Should -Be 0
        @(ConvertFrom-WtWingetTable -Lines @()).Count | Should -Be 0
    }

    It 'does not throw when the input contains blank lines - before the header, between the spinner and the header, and after the table' {
        $lines = @(
            '',
            '   -',
            '',
            'Name              Id                    Version  Match           Source',
            '-----------------------------------------------------------------------',
            'VLC media player  VideoLAN.VLC          3.0.21                   winget',
            '',
            '1 packages have upgrades available.'
        )
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines)
        $rows.Count  | Should -Be 1
        $rows[0].Id  | Should -Be 'VideoLAN.VLC'
    }

    It 'never drops a row because of a blank line immediately after the separator' {
        $fixture = Get-Fixture 'winget-list-tr.txt'
        $lines = @($fixture[0], $fixture[1], '') + $fixture[2..5]
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
        $rows.Count | Should -Be 4
        @($rows | Where-Object { $_.Id -eq '7zip.7zip' }).Count      | Should -Be 1
        @($rows | Where-Object { $_.Id -eq 'ARPKayit12345' }).Count  | Should -Be 1
    }

    It 'never drops a row because of a blank line between two data rows' {
        $fixture = Get-Fixture 'winget-list-tr.txt'
        $lines = @($fixture[0], $fixture[1], $fixture[2], '') + $fixture[3..5]
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
        $rows.Count | Should -Be 4
        @($rows | Where-Object { $_.Id -eq '7zip.7zip' }).Count      | Should -Be 1
        @($rows | Where-Object { $_.Id -eq 'Git.Git' }).Count        | Should -Be 1
        @($rows | Where-Object { $_.Id -eq 'ARPKayit12345' }).Count  | Should -Be 1
    }

    It 'parses a row whose Available value leaves exactly ONE space before the Source column' {
        $header = 'Name                        Id                              Version    Available      Source'
        $starts = Get-WtWingetColumnStarts -Header $header
        $nameWidth      = $starts[1] - $starts[0]
        $idWidth        = $starts[2] - $starts[1]
        $versionWidth   = $starts[3] - $starts[2]
        $availableWidth = $starts[4] - $starts[3]

        $available = '152.0.4191.53'.PadRight($availableWidth - 1, '9')
        $available.Length | Should -Be ($availableWidth - 1)

        $row = 'Edge WebView2 Runtime'.PadRight($nameWidth) +
               'Microsoft.EdgeWebView2Runtime'.PadRight($idWidth) +
               '124.0.6'.PadRight($versionWidth) +
               $available.PadRight($availableWidth) +
               'winget'

        $sourceBoundary = $starts[4]
        $row[$sourceBoundary - 1] | Should -Be ' '
        $row[$sourceBoundary - 2] | Should -Not -Be ' '

        $lines = @($header, ('-' * $header.Length), $row)
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
        $rows.Count       | Should -Be 1
        $rows[0].Id        | Should -Be 'Microsoft.EdgeWebView2Runtime'
        $rows[0].Available | Should -Be $available
        $rows[0].Source    | Should -Be 'winget'
    }

    It 'returns every row when a one-space Available row sits in the MIDDLE of the table' {
        $header = 'Name                        Id                              Version    Available      Source'
        $starts = Get-WtWingetColumnStarts -Header $header
        $nameWidth      = $starts[1] - $starts[0]
        $idWidth        = $starts[2] - $starts[1]
        $versionWidth   = $starts[3] - $starts[2]
        $availableWidth = $starts[4] - $starts[3]

        function Build-WtTestRow($Name, $Id, $Version, $Available, $Source) {
            return $Name.PadRight($nameWidth) + $Id.PadRight($idWidth) +
                   $Version.PadRight($versionWidth) + $Available.PadRight($availableWidth) + $Source
        }

        $rowBefore = Build-WtTestRow '7-Zip 23.01 (x64)' '7zip.7zip' '23.01' '24.09' 'winget'
        $rowEdge   = Build-WtTestRow 'Edge WebView2 Runtime' 'Microsoft.EdgeWebView2Runtime' '124.0.6' `
                        ('152.0.4191.53'.PadRight($availableWidth - 1, '9')) 'winget'
        $rowAfter  = Build-WtTestRow 'Git' 'Git.Git' '2.46.0' '' 'winget'

        $lines = @($header, ('-' * $header.Length), $rowBefore, $rowEdge, $rowAfter)
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
        $rows.Count | Should -Be 3
        @($rows | Where-Object { $_.Id -eq '7zip.7zip' }).Count                      | Should -Be 1
        @($rows | Where-Object { $_.Id -eq 'Microsoft.EdgeWebView2Runtime' }).Count  | Should -Be 1
        @($rows | Where-Object { $_.Id -eq 'Git.Git' }).Count                        | Should -Be 1
    }

    It 'rejects a crafted tail sentence that satisfies only the Id column boundary' {
        $lines = @(
            'Name              Id                    Version  Match           Source',
            '-----------------------------------------------------------------------',
            'VLC media player  VideoLAN.VLC          3.0.21                   winget',
            'Total results     found and displayed above successfully.'
        )
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines)
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'VideoLAN.VLC'
    }

    It 'documents the accepted residual: a short crafted tail still defeats the alignment gate alone' {
        $tableLines = (Get-Fixture 'winget-list-tr.txt') | Select-Object -First 3
        $lines = $tableLines + @('', 'Sonuc bulundu             tamam')
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
        $rows.Count   | Should -Be 2
        $rows[0].Id   | Should -Be '7zip.7zip'
        $rows[1].Name | Should -Be 'Sonuc bulundu'
        $rows[1].Id   | Should -Be 'tamam'
    }

    It 'skips a blank line before several trailing prose lines and still stops at the real summary sentence' {
        $tableLines = (Get-Fixture 'winget-list-tr.txt') | Select-Object -First 3
        $trailer = (Get-Fixture 'winget-list-tr.txt') | Select-Object -Skip 6
        $lines = $tableLines + $trailer + @('Run winget upgrade for details.', 'Done.')
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines -WithAvailable)
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be '7zip.7zip'
    }
}

Describe 'Get-WtWingetSearchResults' {
    It 'passes an exact-source query and returns parsed rows' {
        $seen = $null
        $fake = { param($Arguments) $script:SeenArgs = $Arguments; Get-Fixture 'winget-search-en.txt' }
        $rows = @(Get-WtWingetSearchResults -Query 'obs' -RunWinget $fake)
        $rows.Count | Should -Be 3
        $script:SeenArgs | Should -Contain 'search'
        $script:SeenArgs | Should -Contain 'obs'
        ($script:SeenArgs -join ' ') | Should -BeLike '*--source winget*'
        ($script:SeenArgs -join ' ') | Should -BeLike '*--disable-interactivity*'
    }

    It 'returns nothing for an empty query instead of listing the world' {
        $fake = { param($Arguments) throw 'winget must not be called' }
        @(Get-WtWingetSearchResults -Query '   ' -RunWinget $fake).Count | Should -Be 0
    }

    It 'passes the query as its own argument so nothing is re-parsed as script' {
        $fake = { param($Arguments) $script:SeenArgs = $Arguments; @() }
        $null = Get-WtWingetSearchResults -Query 'a b; rm -rf' -RunWinget $fake
        $script:SeenArgs | Should -Contain 'a b; rm -rf'
    }
}

Describe 'Get-WtWingetInstalledPackages' {
    It 'reads the available-version column from winget list' {
        Clear-WtWingetCache
        $fake = { param($Arguments) $script:SeenArgs = $Arguments; Get-Fixture 'winget-list-tr.txt' }
        $rows = @(Get-WtWingetInstalledPackages -RunWinget $fake)
        $rows.Count | Should -Be 4
        ($rows | Where-Object { $_.Id -eq '7zip.7zip' }).Available | Should -Be '24.09'
        $script:SeenArgs | Should -Contain 'list'
    }

    It 'caches the list so moving the cursor does not re-run winget' {
        Clear-WtWingetCache
        $script:Calls = 0
        $fake = { param($Arguments) $script:Calls++; Get-Fixture 'winget-list-tr.txt' }
        $null = Get-WtWingetInstalledPackages -RunWinget $fake
        $null = Get-WtWingetInstalledPackages -RunWinget $fake
        $script:Calls | Should -Be 1
    }

    It 'runs winget again after the cache is cleared' {
        Clear-WtWingetCache
        $script:Calls = 0
        $fake = { param($Arguments) $script:Calls++; Get-Fixture 'winget-list-tr.txt' }
        $null = Get-WtWingetInstalledPackages -RunWinget $fake
        Clear-WtWingetCache
        $null = Get-WtWingetInstalledPackages -RunWinget $fake
        $script:Calls | Should -Be 2
    }
}

Describe 'ConvertTo-WtNativeArgumentLine' {
    BeforeAll {
        $script:ArgvDumpScript = Join-Path $TestDrive 'dump-argv.ps1'
        Set-Content -LiteralPath $script:ArgvDumpScript -Encoding UTF8 `
            -Value '[Console]::Out.Write([string]::Join([char]1, $args))'

        function Get-NativeRoundTrip {
            <#
            .SYNOPSIS
                Feeds an argument array through ConvertTo-WtNativeArgumentLine and
                a REAL child process - its argv is parsed by the OS/CLR the same
                way any Windows console app's is, winget.exe included - then
                returns what that child actually received. This checks the claim
                that matters: "the child receives exactly this many arguments,
                with exactly this content", not just that the emitted
                command-line string looks plausible.
            #>
            param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
            $line = ConvertTo-WtNativeArgumentLine -Arguments $Arguments
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Get-Process -Id $PID).Path
            $psi.Arguments = '-NoProfile -NoLogo -File "' + $script:ArgvDumpScript + '" ' + $line
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::Start($psi)
            $out = $process.StandardOutput.ReadToEnd()
            $process.WaitForExit()
            $process.Dispose()
            return , [string[]]@($out -split [char]1)
        }
    }

    # --- whitespace other than a plain space ---

    It 'passes a tab-only value through as one argument, not two' {
        $got = Get-NativeRoundTrip -Arguments @('a' + [char]9 + 'b')
        $got.Count | Should -Be 1
        $got[0] | Should -Be ('a' + [char]9 + 'b')
    }

    It 'passes a value containing a newline through as one argument' {
        $got = Get-NativeRoundTrip -Arguments @('a' + [char]10 + 'b')
        $got.Count | Should -Be 1
        $got[0] | Should -Be ('a' + [char]10 + 'b')
    }

    It 'passes a value with both a tab and a quote through as one argument' {
        $got = Get-NativeRoundTrip -Arguments @('a' + [char]9 + '"' + 'b')
        $got.Count | Should -Be 1
        $got[0] | Should -Be ('a' + [char]9 + '"' + 'b')
    }

    # --- Prior round-trip coverage ---

    It 'round-trips a value with a space and a semicolon as its own argument' {
        $got = Get-NativeRoundTrip -Arguments @('search', 'a b; rm -rf')
        $got.Count | Should -Be 2
        $got[0] | Should -Be 'search'
        $got[1] | Should -Be 'a b; rm -rf'
    }

    It 'round-trips a flag and a value that need no quoting at all' {
        $got = Get-NativeRoundTrip -Arguments @('--source', 'winget')
        $got.Count | Should -Be 2
        $got[0] | Should -Be '--source'
        $got[1] | Should -Be 'winget'
    }

    It 'round-trips embedded literal quotes' {
        $got = Get-NativeRoundTrip -Arguments @('name with "quotes" inside')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'name with "quotes" inside'
    }

    It 'round-trips a lone trailing backslash that never needed quoting' {
        $got = Get-NativeRoundTrip -Arguments @('trailing\')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'trailing\'
    }

    It 'round-trips an empty-string argument alongside a real one' {
        $got = Get-NativeRoundTrip -Arguments @('', 'after-empty')
        $got.Count | Should -Be 2
        $got[0] | Should -Be ''
        $got[1] | Should -Be 'after-empty'
    }

    It 'round-trips a plain value needing no quoting' {
        $got = Get-NativeRoundTrip -Arguments @('simple')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'simple'
    }

    It 'round-trips backslashes mid-word that never needed quoting' {
        $got = Get-NativeRoundTrip -Arguments @('back\slash\end\')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'back\slash\end\'
    }

    It 'round-trips a literal quote mixed with backslashes that do need quoting' {
        $got = Get-NativeRoundTrip -Arguments @('quote"and\backslash\')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'quote"and\backslash\'
    }

    It 'round-trips one backslash immediately before a literal quote' {
        $got = Get-NativeRoundTrip -Arguments @('a\"b c')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'a\"b c'
    }

    It 'round-trips two backslashes immediately before a literal quote' {
        $got = Get-NativeRoundTrip -Arguments @('a\\"b c')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'a\\"b c'
    }

    It 'round-trips three backslashes immediately before a literal quote' {
        $got = Get-NativeRoundTrip -Arguments @('a\\\"b c')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'a\\\"b c'
    }

    It 'round-trips a trailing backslash run forced into quoting by a space' {
        $got = Get-NativeRoundTrip -Arguments @('trailing\ ')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'trailing\ '
    }

    It 'round-trips a lone quote character' {
        $got = Get-NativeRoundTrip -Arguments @('"')
        $got.Count | Should -Be 1
        $got[0] | Should -Be '"'
    }

    It 'round-trips three plain arguments with no quoting needed' {
        $got = Get-NativeRoundTrip -Arguments @('list', '--id', '7zip.7zip')
        $got.Count | Should -Be 3
        $got[0] | Should -Be 'list'
        $got[1] | Should -Be '--id'
        $got[2] | Should -Be '7zip.7zip'
    }
}
