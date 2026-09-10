#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the dot-source guard, Set-WindowSize's parameter names,
    and scripted AST scans that catch known bug patterns - relative-path
    writes, unquoted native-command braces, exits inside the main loop,
    undocumented store URIs, hard-coded Windows paths, and more.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'

    function Test-WtNoRelativeLiteralWrite {
        <#
        .SYNOPSIS
            Scans a PowerShell file's AST for -Path/-FilePath arguments on
            write cmdlets that are bare relative string literals (not
            $env:-rooted, not drive-rooted, not UNC-rooted, not a variable
            reference). Returns the offending literal values.
        #>
        param([Parameter(Mandatory)][string]$Path)

        $writeCmdlets = @('Out-File', 'Set-Content', 'Add-Content', 'Export-Csv', 'Export-Clixml')
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

        $offenders = New-Object System.Collections.Generic.List[string]

        $commandAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        foreach ($cmd in $commandAsts) {
            $cmdName = $cmd.GetCommandName()
            if (-not $cmdName -or ($writeCmdlets -notcontains $cmdName)) { continue }

            for ($i = 0; $i -lt $cmd.CommandElements.Count; $i++) {
                $el = $cmd.CommandElements[$i]
                $isPathParam = $el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    ($el.ParameterName -eq 'FilePath' -or $el.ParameterName -eq 'Path')
                if (-not $isPathParam) { continue }
                if (($i + 1) -ge $cmd.CommandElements.Count) { continue }

                $valueEl = $cmd.CommandElements[$i + 1]
                if ($valueEl -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $val = $valueEl.Value
                    $isRooted = $val -match '^\$env:' -or $val -match '^[A-Za-z]:' -or $val -match '^\\\\'
                    if ($val -and -not $isRooted) {
                        $offenders.Add($val)
                    }
                }
            }
        }

        return @($offenders)
    }
}

Describe 'Test-WtIsMainInvocation (dot-source guard predicate)' {
    It 'returns $false for dot-sourcing (InvocationName ".")' {
        . $TargetPath
        Test-WtIsMainInvocation -InvocationName '.' | Should -BeFalse
    }

    It 'returns $true for a value simulating iex (empty InvocationName)' {
        . $TargetPath
        Test-WtIsMainInvocation -InvocationName '' | Should -BeTrue
    }

    It 'returns $true for a value simulating the call operator (&)' {
        . $TargetPath
        Test-WtIsMainInvocation -InvocationName '&' | Should -BeTrue
    }

    It 'returns $true for a value simulating -File (a real path)' {
        . $TargetPath
        Test-WtIsMainInvocation -InvocationName $TargetPath | Should -BeTrue
    }
}

Describe 'Dot-sourcing WinToolify.ps1' {
    It 'defines its functions without elevating, prompting, or entering the menu loop' {
        . $TargetPath

        Get-Command Set-WindowSize -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Show-Menu -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-WingetInstalled -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-WtIsMainInvocation -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Set-WindowSize parameter names' {
    It 'declares -contentWidth and -contentHeight, matching every caller' {
        . $TargetPath
        $paramNames = (Get-Command Set-WindowSize).Parameters.Keys
        $paramNames | Should -Contain 'contentWidth'
        $paramNames | Should -Contain 'contentHeight'
        $paramNames | Should -Not -Contain 'fixedWidth'
        $paramNames | Should -Not -Contain 'fixedHeight'
    }

    It 'has no caller passing -fixedWidth or -fixedHeight' {
        $content = Get-Content -LiteralPath $TargetPath -Raw
        $content | Should -Not -Match '-fixedWidth'
        $content | Should -Not -Match '-fixedHeight'
    }
}

Describe 'Test-WtNoRelativeLiteralWrite (scripted relative-path scan)' {
    BeforeAll {
        $script:FixtureDir = Join-Path $TestDrive 'fixtures'
        New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null

        $script:BadFixture = Join-Path $FixtureDir 'relative-write.ps1'
        Set-Content -LiteralPath $BadFixture -Encoding UTF8 -Value @'
"hello" | Out-File -FilePath ".\log.txt" -Append
'@

        $script:CleanFixture = Join-Path $FixtureDir 'rooted-write.ps1'
        Set-Content -LiteralPath $CleanFixture -Encoding UTF8 -Value @'
$logPath = Join-Path $env:ProgramData "WinToolify\log.txt"
"hello" | Out-File -FilePath $logPath -Append
"world" | Out-File -FilePath "$env:ProgramData\WinToolify\log2.txt" -Append
'@
    }

    It 'flags a bare relative literal write target' {
        $offenders = Test-WtNoRelativeLiteralWrite -Path $BadFixture
        $offenders.Count | Should -BeGreaterThan 0
    }

    It 'does not flag a rooted write target' {
        $offenders = Test-WtNoRelativeLiteralWrite -Path $CleanFixture
        $offenders.Count | Should -Be 0
    }

    It 'finds no relative-path literal write target in the current WinToolify.ps1' {
        $offenders = Test-WtNoRelativeLiteralWrite -Path $TargetPath
        $offenders.Count | Should -Be 0
    }
}

Describe 'Legacy Action/Information Tools scans' {
    BeforeAll {
        $script:ScanFixtureDir = Join-Path $TestDrive 'scan-fixtures'
        New-Item -ItemType Directory -Path $ScanFixtureDir -Force | Out-Null

        function Get-WtScriptAst {
            param([Parameter(Mandatory)][string]$Path)
            $tokens = $null
            $parseErrors = $null
            return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        }

        function Test-WtNoScriptBlockArgumentToNativeCommand {
            <#
            .SYNOPSIS
                Returns every native-style command (no hyphen, e.g.
                bcdedit, powercfg, netsh) that receives a bare { ... }
                argument - PowerShell turns it into -encodedCommand
                before the native program ever sees it, so an unquoted
                {default} never reaches bcdedit. The identifier must be
                quoted: '{default}'.
            #>
            param([Parameter(Mandatory)][string]$Path)
            $ast = Get-WtScriptAst -Path $Path
            $offenders = New-Object System.Collections.Generic.List[string]
            $commandAsts = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($cmd in $commandAsts) {
                $name = $cmd.GetCommandName()
                if (-not $name -or $name.Contains('-')) { continue }
                for ($i = 1; $i -lt $cmd.CommandElements.Count; $i++) {
                    if ($cmd.CommandElements[$i] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                        $offenders.Add("$name (line $($cmd.Extent.StartLineNumber))")
                    }
                }
            }
            return @($offenders)
        }

        function Test-WtNoExitInsideMainLoop {
            <#
            .SYNOPSIS
                Returns the line numbers of every "exit" command inside a
                top-level (not function-scoped) loop - the interactive
                main menu loop. An exit there terminates the whole tool,
                and its console window too, instead of returning to the
                menu.
            #>
            param([Parameter(Mandatory)][string]$Path)
            $ast = Get-WtScriptAst -Path $Path
            $offenders = New-Object System.Collections.Generic.List[int]
            $mainLoops = $ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.LoopStatementAst]) { return $false }
                $parent = $node.Parent
                while ($parent) {
                    if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
                    $parent = $parent.Parent
                }
                return $true
            }, $true)
            foreach ($loop in $mainLoops) {
                $exits = $loop.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ExitStatementAst]
                }, $true)
                foreach ($exitCmd in $exits) { $offenders.Add($exitCmd.Extent.StartLineNumber) }
            }
            return @($offenders)
        }

        function Test-WtStoreUrisAreDocumented {
            <#
            .SYNOPSIS
                Returns every ms-windows-store: URI literal whose page is
                not one Microsoft documents (learn.microsoft.com
                windows/uwp/launch-resume/launch-store-app).
            #>
            param([Parameter(Mandatory)][string]$Path)
            $documentedPages = @('home', 'navigatetopage/', 'downloadsandupdates', 'mylibrary', 'settings', 'pdp/', 'review/', 'assoc/', 'search/', 'browse/', 'publisher/')
            $ast = Get-WtScriptAst -Path $Path
            $offenders = New-Object System.Collections.Generic.List[string]
            $strings = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
            foreach ($s in $strings) {
                if ($s.Value -notmatch '^ms-windows-store://(.*)$') { continue }
                $page = $Matches[1]
                $known = $false
                foreach ($p in $documentedPages) { if ($page.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { $known = $true; break } }
                if (-not $known) { $offenders.Add($s.Value) }
            }
            return @($offenders)
        }

        function Test-WtNoHardcodedWindowsDirectory {
            <#
            .SYNOPSIS
                Returns every string literal (quoted or bare argument) that
                hard-codes a "<drive>:\Windows" path instead of
                $env:SystemRoot / $env:WinDir - wrong on any install whose
                system drive is not C:.
            #>
            param([Parameter(Mandatory)][string]$Path)
            $ast = Get-WtScriptAst -Path $Path
            $offenders = New-Object System.Collections.Generic.List[string]
            $strings = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true)
            foreach ($s in $strings) {
                if ($s.Value -match '^[A-Za-z]:\\Windows(\\|$)') { $offenders.Add("$($s.Value) (line $($s.Extent.StartLineNumber))") }
            }
            return @($offenders)
        }

        $script:BadScanFixture = Join-Path $ScanFixtureDir 'legacy-bad.ps1'
        Set-Content -LiteralPath $BadScanFixture -Encoding UTF8 -Value @'
do {
    switch (Read-Host) {
        "1" { bcdedit /set {default} safeboot minimal }
        "2" { Start-Process "ms-windows-store://updates" }
        "3" { Remove-Item C:\Windows\System32\spool\PRINTERS\* -Force }
        "4" { exit }
    }
} while ($true)
'@

        $script:CleanScanFixture = Join-Path $ScanFixtureDir 'legacy-clean.ps1'
        Set-Content -LiteralPath $CleanScanFixture -Encoding UTF8 -Value @'
function Invoke-Elevated { if (-not $elevated) { Start-Process powershell -Verb RunAs; exit } }
do {
    switch (Read-Host) {
        "1" { bcdedit /set '{default}' safeboot minimal }
        "2" { Start-Process "ms-windows-store://downloadsandupdates" }
        "3" { Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force }
        "4" { $items | Where-Object { $_.Name } | ForEach-Object { $_ } }
    }
} while ($true)
'@
    }

    Context 'scan self-checks against fixtures' {
        It 'flags a bare {default} script-block argument to a native command' {
            (Test-WtNoScriptBlockArgumentToNativeCommand -Path $BadScanFixture).Count | Should -Be 1
            (Test-WtNoScriptBlockArgumentToNativeCommand -Path $CleanScanFixture).Count | Should -Be 0
        }

        It 'flags an exit inside the top-level loop but not inside a function' {
            (Test-WtNoExitInsideMainLoop -Path $BadScanFixture).Count | Should -Be 1
            (Test-WtNoExitInsideMainLoop -Path $CleanScanFixture).Count | Should -Be 0
        }

        It 'flags an undocumented ms-windows-store page' {
            (Test-WtStoreUrisAreDocumented -Path $BadScanFixture) | Should -Be @('ms-windows-store://updates')
            (Test-WtStoreUrisAreDocumented -Path $CleanScanFixture).Count | Should -Be 0
        }

        It 'flags a hard-coded C:\Windows path' {
            (Test-WtNoHardcodedWindowsDirectory -Path $BadScanFixture).Count | Should -Be 1
            (Test-WtNoHardcodedWindowsDirectory -Path $CleanScanFixture).Count | Should -Be 0
        }
    }

    Context 'the current WinToolify.ps1' {
        It 'passes no bare { ... } argument to a native command (bcdedit safe boot)' {
            Test-WtNoScriptBlockArgumentToNativeCommand -Path $TargetPath | Should -BeNullOrEmpty
        }

        It 'never exits the tool from inside the interactive main loop (Wi-Fi profile lookup)' {
            Test-WtNoExitInsideMainLoop -Path $TargetPath | Should -BeNullOrEmpty
        }

        It 'opens the Microsoft Store only through documented ms-windows-store pages' {
            Test-WtStoreUrisAreDocumented -Path $TargetPath | Should -BeNullOrEmpty
        }

        It 'does not hard-code the Windows directory on drive C: (print spooler queue)' {
            Test-WtNoHardcodedWindowsDirectory -Path $TargetPath | Should -BeNullOrEmpty
        }

        It 'never calls .GetNewClosure() - a closure cannot see the script own functions when the file is RUN' {
            $src = Get-Content -LiteralPath $TargetPath -Raw
            $code = @($src -split '\r?\n' | Where-Object { $_.Trim() -notmatch '^#' -and $_ -notmatch 'do NOT use|needed\.' })
            @($code | Where-Object { $_ -match '\.GetNewClosure\(\)' }) | Should -BeNullOrEmpty
        }

        It 'the only Add-Type calls live in memory-flush, the QuickEdit helper, the window lock, the window icon and the Ctrl+C guard, all inside try/catch' {
            $src = Get-Content -LiteralPath $TargetPath
            $hits = @($src | Select-String -Pattern 'Add-Type -TypeDefinition' -SimpleMatch | ForEach-Object { $_.LineNumber })
            $hits.Count | Should -Be 5
        }

        It 'every delegate still resolves its captured variables when the file is RUN, not dot-sourced' {
            $probe = Join-Path $TestDrive 'delegate-probe.ps1'
            @'
function Get-Thing { 'resolved' }
function Invoke-Runner { param([scriptblock]$Delegate) & $Delegate }
function Outer {
    $captured = 'captured'
    $delegate = { "$(Get-Thing)/$captured" }
    Invoke-Runner -Delegate $delegate
}
Outer
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
            (& $probe) | Should -Be 'resolved/captured'
        }

        It 'defines no function that nothing calls (except the Guard-pinned entry points)' {
            $ast = Get-WtScriptAst -Path $TargetPath
            $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
            $src = Get-Content -LiteralPath $TargetPath -Raw
            $pinned = 'Show-Menu', 'Set-WindowSize', 'Test-WingetInstalled', 'Test-WtIsMainInvocation', 'Invoke-WtMainLoop', 'Initialize-WtTui', 'Restore-WtTui', 'Invoke-WtFirstRunLanguage', 'Read-WtSettings',
                'Get-WtSelectorPage', 'Get-WtVisibleLength'
            $orphans = foreach ($fn in $defined) {
                if ($pinned -contains $fn) { continue }
                $count = ([regex]::Matches($src, '(?<![A-Za-z0-9-])' + [regex]::Escape($fn) + '(?![A-Za-z0-9-])')).Count
                if ($count -le 1) { $fn }
            }
            @($orphans) | Should -BeNullOrEmpty
        }

        It 'every translation key is referenced at least once in the source or is a catalog text key' {
            $src = Get-Content -LiteralPath $TargetPath -Raw
            . $TargetPath
            $unused = foreach ($key in $script:Translations['EN'].Keys) {
                if ($key -match '^(Cat|HdCat)[A-Z]') { continue }
                if ($key -match '^(Risk(SAFE|CAUTION|ADVANCED)|UndoAction\.|SvcStatus\.|SvcStart\.|LocalAdminObject\.|LocalAdminSource\.)') { continue }
                if ($key -match '^((Yes|No)Letter|Typed(Yes|Confirm)Word)$') { continue }
                if ($key -match '^ProblemDeviceCode\d+$') { continue }
                if ($key -match '^AsErr[A-Za-z]+$') { continue }
                if (([regex]::Matches($src, '[''"]' + [regex]::Escape($key) + '[''"]')).Count -le 2) { $key }
            }
            @($unused) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-WtNoFormatExpressionAsMethodArgument (format-arg bug scan)' {
    BeforeAll {
        function Test-WtNoFormatExpressionAsMethodArgument {
            <#
            .SYNOPSIS
                Returns every .Method(...) call whose first argument is a
                "-f" format expression followed by more arguments -
                PowerShell's method-call argument list claims the comma
                that should feed -f its second operand, so -f gets only
                its first operand and throws at runtime. Wrap the -f
                expression in parens: $list.Add(('{0}: {1}' -f $a, $b)).
            #>
            param([Parameter(Mandatory)][string]$Path)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
            $offenders = New-Object System.Collections.Generic.List[string]
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
            foreach ($call in $calls) {
                if ($null -eq $call.Arguments -or $call.Arguments.Count -lt 2) { continue }
                $first = $call.Arguments[0]
                if ($first -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                    $first.Operator -eq [System.Management.Automation.Language.TokenKind]::Format) {
                    $offenders.Add("line $($call.Extent.StartLineNumber): .$($call.Member.Extent.Text)(...)")
                }
            }
            return @($offenders)
        }

        $script:FormatArgFixtureDir = Join-Path $TestDrive 'format-arg-fixtures'
        New-Item -ItemType Directory -Path $FormatArgFixtureDir -Force | Out-Null

        $script:BadFormatArgFixture = Join-Path $FormatArgFixtureDir 'format-arg-bad.ps1'
        Set-Content -LiteralPath $BadFormatArgFixture -Encoding UTF8 -Value @'
$list = New-Object System.Collections.Generic.List[string]
$a = "x"; $b = "y"
$list.Add('{0}: {1}' -f $a, $b)
'@

        $script:CleanFormatArgFixture = Join-Path $FormatArgFixtureDir 'format-arg-clean.ps1'
        Set-Content -LiteralPath $CleanFormatArgFixture -Encoding UTF8 -Value @'
$list = New-Object System.Collections.Generic.List[string]
$a = "x"; $b = "y"
$list.Add(('{0}: {1}' -f $a, $b))
'@
    }

    Context 'scan self-checks against fixtures' {
        It 'flags a format expression that lost its second operand to the argument list' {
            (Test-WtNoFormatExpressionAsMethodArgument -Path $BadFormatArgFixture).Count | Should -Be 1
        }

        It 'does not flag a format expression wrapped in its own parentheses' {
            (Test-WtNoFormatExpressionAsMethodArgument -Path $CleanFormatArgFixture).Count | Should -Be 0
        }
    }

    Context 'the current WinToolify.ps1' {
        It 'never passes a bare -f format expression as a method argument alongside further arguments' {
            $offenders = Test-WtNoFormatExpressionAsMethodArgument -Path $TargetPath
            $offenders | Should -BeNullOrEmpty -Because ('offending sites: ' + ($offenders -join '; '))
        }
    }
}

Describe 'Elevation relaunch fetches the release asset' {
    It 'never points the irm relaunch at the raw main branch (there is no WinToolify.ps1 on main any more)' {
        $content = Get-Content -LiteralPath $TargetPath -Raw
        $content | Should -Not -Match 'raw\.githubusercontent\.com/burakarslan0110/WinToolify/main/WinToolify\.ps1'
        $content | Should -Match 'https://github\.com/burakarslan0110/WinToolify/releases/latest/download/WinToolify\.ps1'
    }

    It 'declares the -Assistant switch at the top of the built file and forwards it across the elevation relaunch' {
        $src = Get-Content -LiteralPath $TargetPath -Raw
        $src | Should -Match '(?m)^param\(\[switch\]\$Assistant\)'
        $elevation = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/90-main/10-elevation.ps1') -Raw
        $elevation | Should -Match "' -Assistant'"
        ([regex]::Matches($elevation, '\$assistantArg')).Count | Should -BeGreaterOrEqual 3
        $main = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/90-main/20-main.ps1') -Raw
        $main | Should -Match 'InitialScreens'
    }

    It 'hands the elevated child the script text, never a bare file load the execution policy can refuse' {
        $elevation = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/90-main/10-elevation.ps1') -Raw
        $elevation | Should -Not -Match "& '\`$spawnPath'"
        $spawnLines = @(($elevation -split "`r?`n") | Where-Object { $_ -match 'Start-Process powershell' })
        @($spawnLines).Count | Should -Be 2
        foreach ($line in $spawnLines) {
            $line | Should -Match ([regex]::Escape('[scriptblock]::Create'))
            $line | Should -Match '-ExecutionPolicy Bypass'
        }
        $elevation | Should -Match 'Get-Content -Raw -LiteralPath'
    }

    It 'drops the Mark of the Web before spawning, while the path is still in hand' {
        $elevation = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/90-main/10-elevation.ps1') -Raw
        $elevation | Should -Match 'Unblock-WtSelf'
        $elevation.IndexOf('Unblock-WtSelf') | Should -BeLessThan $elevation.IndexOf('Start-Process')
    }

    It 'hands the launch folder down, since the child has no $PSScriptRoot to find the bundled runtimes with' {
        $elevation = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/90-main/10-elevation.ps1') -Raw
        $elevation | Should -Match 'WINTOOLIFY_HOME'
        $vc = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/60-actions/vcredist.ps1') -Raw
        $vc | Should -Match 'WINTOOLIFY_HOME'
    }
}

Describe 'Rich text layer purity (src/20-tui/richtext.ps1)' {
    It 'keeps the rich text layer free of the console and of translations' {
        $path = Join-Path $RepoRoot 'src/20-tui/richtext.ps1'
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($needle in @('Write-Host', 'Get-Translation', 'Get-WtConsoleSize', '$Host')) {
            $text.IndexOf($needle, [System.StringComparison]::Ordinal) | Should -Be -1
        }
    }
}
