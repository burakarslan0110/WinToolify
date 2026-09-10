#Requires -Modules Pester

<#
.SYNOPSIS
    Running one command back in the INTERACTIVE user's non-elevated
    context. The Task Scheduler itself is injected, so nothing here
    registers a real task or calls winget. Assertions count Lines rather
    than check substring containment, since Get-WtSharedTextLines returns
    its array behind a unary comma and a caller that wraps it in
    [string[]]@(...) can silently join rows that still contain the
    substring.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-FakeTaskApi {
        <#
        .SYNOPSIS
            A recording stand-in for the five Task Scheduler calls. -Codes
            is the sequence Result hands back, one per poll, so a test can
            make the task look busy for a tick before it finishes.
        #>
        param(
            [object[]]$Codes = @(0),
            [string[]]$States = @('Ready'),
            [scriptblock]$OnStart,
            [switch]$FailRegister
        )
        $log = New-Object System.Collections.Generic.List[object]
        $tick = [ref]0
        return @{
            Log      = $log
            Register = {
                param($Context)
                $log.Add(@{ Call = 'Register'; Context = $Context })
                if ($FailRegister) { throw 'register refused' }
            }.GetNewClosure()
            Start    = {
                param($Context)
                $log.Add(@{ Call = 'Start'; Context = $Context })
                if ($OnStart) { & $OnStart $Context }
            }.GetNewClosure()
            State    = {
                param($Context)
                $i = [Math]::Min($tick.Value, $States.Count - 1)
                return [string]$States[$i]
            }.GetNewClosure()
            Result   = {
                param($Context)
                $i = [Math]::Min($tick.Value, $Codes.Count - 1)
                $tick.Value = $tick.Value + 1
                return $Codes[$i]
            }.GetNewClosure()
            Remove   = {
                param($Context)
                $log.Add(@{ Call = 'Remove'; Context = $Context })
            }.GetNewClosure()
        }
    }
}

Describe 'Get-WtInteractiveUserName' {
    It 'reports the console session owner as DOMAIN\User' {
        Get-WtInteractiveUserName -GetConsoleUser { 'DESKTOP-1\Burak' } | Should -Be 'DESKTOP-1\Burak'
    }

    It 'reports an empty string when the console owner cannot be read' {
        Get-WtInteractiveUserName -GetConsoleUser { throw 'no CIM here' } | Should -Be ''
        Get-WtInteractiveUserName -GetConsoleUser { '   ' } | Should -Be ''
        Get-WtInteractiveUserName -GetConsoleUser { $null } | Should -Be ''
    }
}

Describe 'New-WtInteractiveUserShim' {
    It 'embeds the executable and every argument as single-quoted literals' {
        $text = New-WtInteractiveUserShim -FilePath 'winget.exe' `
            -Arguments @('uninstall', '--id', 'Google.Antigravity') -OutputPath 'C:\tmp\out.log'
        $text | Should -BeLike "*'winget.exe'*"
        $text | Should -BeLike "*'uninstall', '--id', 'Google.Antigravity'*"
        $text | Should -BeLike "*'C:\tmp\out.log'*"
    }

    It 'doubles an embedded single quote so an argument can never close its own literal' {
        $payload = "a'; Remove-Item C:\ -Recurse; '"
        $text = New-WtInteractiveUserShim -FilePath 'winget.exe' -Arguments @($payload) -OutputPath 'C:\tmp\out.log'
        $text | Should -BeLike "*a''; Remove-Item C:\ -Recurse; ''*"
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$parseErrors) | Out-Null
        @($parseErrors).Count | Should -Be 0
    }

    It 'never assigns to $args, which is an automatic variable' {
        $text = New-WtInteractiveUserShim -FilePath 'winget.exe' -Arguments @('list') -OutputPath 'C:\tmp\o.log'
        $text | Should -Not -Match '\$args\s*='
    }

    It 'exits on the child exit code and never reports 0 when there was none' {
        $text = New-WtInteractiveUserShim -FilePath 'winget.exe' -Arguments @('list') -OutputPath 'C:\tmp\o.log'
        $text | Should -BeLike '*$LASTEXITCODE*'
        $text | Should -BeLike '*exit *'
    }

    It 'survives an empty argument list' {
        { New-WtInteractiveUserShim -FilePath 'winget.exe' -Arguments @() -OutputPath 'C:\tmp\o.log' } | Should -Not -Throw
    }
}

Describe 'ConvertTo-WtTaskExitCode' {
    It 'treats the scheduler status codes as "not finished yet"' {
        foreach ($pending in @(267009, 267011, 267045)) {
            ConvertTo-WtTaskExitCode -LastTaskResult $pending | Should -Be $null
        }
    }

    It 'passes a real exit code straight through, sign and all' {
        ConvertTo-WtTaskExitCode -LastTaskResult 0 | Should -Be 0
        ConvertTo-WtTaskExitCode -LastTaskResult 42 | Should -Be 42
        ConvertTo-WtTaskExitCode -LastTaskResult -1978335107 | Should -Be -1978335107
    }

    It 'returns null for a missing result' {
        ConvertTo-WtTaskExitCode -LastTaskResult $null | Should -Be $null
    }
}

Describe 'Invoke-WtProcessAsInteractiveUser' {
    It 'refuses without registering anything when there is no interactive user' {
        $api = New-FakeTaskApi
        $r = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('list') `
            -GetUserName { '' } -TaskApi $api -WorkRoot $TestDrive
        $r.Ran | Should -BeFalse
        $r.Reason | Should -Be 'NoInteractiveUser'
        $r.ExitCode | Should -Be $null
        $api.Log.Count | Should -Be 0
    }

    It 'registers, starts, collects the output and hands back the exit code' {
        $api = New-FakeTaskApi -Codes @(0) -States @('Ready') -OnStart {
            param($Context)
            Set-Content -LiteralPath $Context.LogPath -Value "Found Antigravity`r`nSuccessfully uninstalled" -Encoding UTF8
        }
        $r = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('uninstall', '--id', 'X') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1
        $r.Ran | Should -BeTrue
        $r.ExitCode | Should -Be 0
        $r.Reason | Should -Be ''
        $r.Lines.Count | Should -BeGreaterOrEqual 2
        $r.Lines[0] | Should -Be 'Found Antigravity'
        $r.Lines[1] | Should -Be 'Successfully uninstalled'
        @($api.Log | Where-Object { $_.Call -eq 'Register' }).Count | Should -Be 1
        @($api.Log | Where-Object { $_.Call -eq 'Start' }).Count | Should -Be 1
        @($api.Log | Where-Object { $_.Call -eq 'Remove' }).Count | Should -Be 1
    }

    It 'runs the task as the interactive user and points it at a shim holding the real arguments' {
        $api = New-FakeTaskApi -Codes @(0)
        $null = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' `
            -Arguments @('uninstall', '--id', 'Google.Antigravity') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1 -KeepWorkFiles
        $register = @($api.Log | Where-Object { $_.Call -eq 'Register' })[0]
        $register.Context.UserName | Should -Be 'DESKTOP-1\Burak'
        Test-Path -LiteralPath $register.Context.ShimPath | Should -BeTrue
        (Get-Content -LiteralPath $register.Context.ShimPath -Raw) | Should -BeLike "*'Google.Antigravity'*"
    }

    It 'keeps polling while the task is still running' {
        $api = New-FakeTaskApi -Codes @(267011, 267009, 0) -States @('Ready', 'Running', 'Ready')
        $r = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('list') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1
        $r.Ran | Should -BeTrue
        $r.ExitCode | Should -Be 0
    }

    It 'reports a scheduling failure instead of throwing, and still cleans up' {
        $api = New-FakeTaskApi -FailRegister
        $r = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('list') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1
        $r.Ran | Should -BeFalse
        $r.Reason | Should -Be 'ScheduleFailed'
        @($api.Log | Where-Object { $_.Call -eq 'Remove' }).Count | Should -Be 1
    }

    It 'gives up on a task that never finishes and says so' {
        $api = New-FakeTaskApi -Codes @(267009) -States @('Running')
        $r = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('list') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1 -TimeoutSeconds 0
        $r.Ran | Should -BeFalse
        $r.Reason | Should -Be 'Timeout'
        @($api.Log | Where-Object { $_.Call -eq 'Remove' }).Count | Should -Be 1
    }

    It 'deletes the shim and the log it wrote' {
        $api = New-FakeTaskApi -Codes @(0)
        $null = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('list') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1
        $register = @($api.Log | Where-Object { $_.Call -eq 'Register' })[0]
        Test-Path -LiteralPath $register.Context.ShimPath | Should -BeFalse
        Test-Path -LiteralPath $register.Context.LogPath | Should -BeFalse
    }

    It 'feeds the growing output to -OnOutput while it waits' {
        $seen = New-Object System.Collections.Generic.List[object]
        $api = New-FakeTaskApi -Codes @(267009, 0) -States @('Running', 'Ready') -OnStart {
            param($Context)
            Set-Content -LiteralPath $Context.LogPath -Value 'first line' -Encoding UTF8
        }
        $null = Invoke-WtProcessAsInteractiveUser -FilePath 'winget.exe' -Arguments @('list') `
            -GetUserName { 'DESKTOP-1\Burak' } -TaskApi $api -WorkRoot $TestDrive -PollMs 1 `
            -OnOutput { param($TailLines) $seen.Add(@($TailLines)) }
        $seen.Count | Should -BeGreaterThan 0
        (@($seen[$seen.Count - 1]) -join "`n") | Should -BeLike '*first line*'
    }
}

Describe 'Get-WtSharedTextLines' {
    It 'splits a CRLF file into one entry per row' {
        $path = Join-Path $TestDrive 'lines.log'
        Set-Content -LiteralPath $path -Value "one`r`ntwo`r`nthree" -Encoding UTF8
        $lines = Get-WtSharedTextLines -Path $path
        $lines[0] | Should -Be 'one'
        $lines[1] | Should -Be 'two'
        $lines[2] | Should -Be 'three'
    }

    It 'reads a file another process still holds open for writing' {
        $path = Join-Path $TestDrive 'busy.log'
        $writer = New-Object System.IO.StreamWriter($path)
        try {
            $writer.WriteLine('half written')
            $writer.Flush()
            (Get-WtSharedTextLines -Path $path)[0] | Should -Be 'half written'
        }
        finally { $writer.Dispose() }
    }

    It 'is an empty array, never $null, for a file that is not there' {
        $lines = Get-WtSharedTextLines -Path (Join-Path $TestDrive 'missing.log')
        $null -eq $lines | Should -BeFalse
        $lines.Count | Should -Be 0
    }
}

Describe 'Get-WtRetryReasonKey' {
    It 'names a translation key for every reason the runner can report' {
        Get-WtRetryReasonKey -Reason 'NoInteractiveUser' | Should -Be 'WsRetryNoUser'
        Get-WtRetryReasonKey -Reason 'ScheduleFailed' | Should -Be 'WsRetryFailed'
        Get-WtRetryReasonKey -Reason 'Timeout' | Should -Be 'WsRetryTimeout'
        Get-WtRetryReasonKey -Reason 'anything else' | Should -Be 'WsRetryFailed'
    }

    It 'resolves each of those keys in both languages' {
        foreach ($key in @('WsRetryNoUser', 'WsRetryFailed', 'WsRetryTimeout', 'WsRetryAsUser', 'WsResultAdminContext')) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
}
