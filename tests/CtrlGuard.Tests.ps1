#Requires -Modules Pester

<#
.SYNOPSIS
    Ctrl+C / Ctrl+Break guard: a native console control handler
    registered for the whole run swallows CTRL_C_EVENT and
    CTRL_BREAK_EVENT before PowerShell's own handler can stop the
    pipeline. TreatControlCAsInput already makes Ctrl+C a key while
    WinToolify reads keys itself; the guard covers the moments it is
    not: a child process that turned processed input back on (Ctrl+C
    during sfc / DISM / winget) and Ctrl+Break, which is a signal no
    matter what that bit says. Best effort: no console or a failing
    call means no guard and no error.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Enable-WtCtrlGuard' {
    AfterEach { $script:WtCtrlGuard = $false }
    It 'records the guard when Apply installed the handler' {
        (Enable-WtCtrlGuard -Apply { $true }) | Should -BeTrue
        $script:WtCtrlGuard | Should -BeTrue
    }
    It 'records no guard when Apply could not install it' {
        (Enable-WtCtrlGuard -Apply { $false }) | Should -BeFalse
        $script:WtCtrlGuard | Should -BeFalse
    }
    It 'a failing Apply (no console, no compiler) is swallowed and leaves no guard' {
        { $script:Result = Enable-WtCtrlGuard -Apply { throw 'no console' } } | Should -Not -Throw
        $script:Result | Should -BeFalse
        $script:WtCtrlGuard | Should -BeFalse
    }
}

Describe 'Disable-WtCtrlGuard' {
    AfterEach { $script:WtCtrlGuard = $false }
    It 'does nothing when the guard was never installed' {
        $script:WtCtrlGuard = $false
        $script:Applied = 0
        Disable-WtCtrlGuard -Apply { $script:Applied++ }
        $script:Applied | Should -Be 0
    }
    It 'removes the handler once and clears the flag' {
        $script:WtCtrlGuard = $true
        $script:Applied = 0
        Disable-WtCtrlGuard -Apply { $script:Applied++ }
        $script:Applied | Should -Be 1
        $script:WtCtrlGuard | Should -BeFalse
        Disable-WtCtrlGuard -Apply { $script:Applied++ }
        $script:Applied | Should -Be 1
    }
    It 'a failing Apply is swallowed and the flag is still cleared' {
        $script:WtCtrlGuard = $true
        { Disable-WtCtrlGuard -Apply { throw 'gone' } } | Should -Not -Throw
        $script:WtCtrlGuard | Should -BeFalse
    }
}

Describe 'WtCtrlGuard native type' {
    BeforeAll {
        $script:TypeError = $null
        try { if (-not ('WtCtrlGuard' -as [type])) { Add-Type -TypeDefinition $script:WtCtrlGuardSource -ErrorAction Stop } }
        catch { $script:TypeError = $_ }
    }
    AfterAll { try { $null = [WtCtrlGuard]::Remove() } catch { $null = $_ } }
    It 'compiles with the PS 5.1 compiler (C# 5)' {
        $script:TypeError | Should -BeNullOrEmpty
        ('WtCtrlGuard' -as [type]) | Should -Not -BeNullOrEmpty
    }
    It 'Install and Remove are idempotent and report their state' {
        [WtCtrlGuard]::Install() | Should -BeTrue
        [WtCtrlGuard]::IsInstalled | Should -BeTrue
        [WtCtrlGuard]::Install() | Should -BeTrue
        [WtCtrlGuard]::Remove() | Should -BeTrue
        [WtCtrlGuard]::IsInstalled | Should -BeFalse
        [WtCtrlGuard]::Remove() | Should -BeTrue
    }
}

Describe 'The main flow keeps the guard up for the whole run' {
    It 'installs it as the first statement of the try and removes it in the finally' {
        $main = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'src/90-main/20-main.ps1')
        $main.IndexOf('Enable-WtCtrlGuard') | Should -BeGreaterThan $main.IndexOf('try {')
        $main.IndexOf('Enable-WtCtrlGuard') | Should -BeLessThan $main.IndexOf('Read-WtSettings')
        $main.IndexOf('Disable-WtCtrlGuard') | Should -BeGreaterThan $main.IndexOf('finally {')
    }
}

Describe 'The guard end to end (a hidden console child raises the events on itself)' {
    BeforeAll {
        $script:ChildSource = @'
param([string]$Dist, [string]$Log)
$ErrorActionPreference = 'Stop'
. $Dist
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WtCtrlGuardProbe
{
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetConsoleCtrlHandler")] public static extern bool SetConsoleCtrlHandlerPtr(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
}
"@
# a harness may have started this process group with Ctrl+C ignored (the flag is inherited): undo that so Ctrl+C is deliverable
$null = [WtCtrlGuardProbe]::SetConsoleCtrlHandlerPtr([IntPtr]::Zero, $false)
$raise = { param($Type, $Expect)
    $ok = [WtCtrlGuardProbe]::GenerateConsoleCtrlEvent([uint32]$Type, 0)
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ([WtCtrlGuard]::Swallowed -lt $Expect -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    return $ok
}
"guard=$(Enable-WtCtrlGuard)" | Out-File -LiteralPath $Log -Encoding ascii
"raise=$(& $raise 0 1)" | Out-File -LiteralPath $Log -Append -Encoding ascii
"after ctrl+c: swallowed=$([WtCtrlGuard]::Swallowed)" | Out-File -LiteralPath $Log -Append -Encoding ascii
$null = & $raise 1 2
"after ctrl+break: swallowed=$([WtCtrlGuard]::Swallowed)" | Out-File -LiteralPath $Log -Append -Encoding ascii
Disable-WtCtrlGuard
"disabled installed=$([WtCtrlGuard]::IsInstalled)" | Out-File -LiteralPath $Log -Append -Encoding ascii
# control: without the guard the same Ctrl+C must end this script before the next line (not Ctrl+Break:
# unguarded PS 5.1 answers Ctrl+Break by breaking into the debugger, which waits forever in a hidden window)
$null = [WtCtrlGuardProbe]::GenerateConsoleCtrlEvent(0, 0)
Start-Sleep -Milliseconds 2000
"CONTROL FAILED" | Out-File -LiteralPath $Log -Append -Encoding ascii
'@
    }
    It 'Ctrl+C and Ctrl+Break are swallowed while the guard is up, and end the process once it is down' {
        $child = Join-Path $TestDrive 'ctrl-guard-child.ps1'
        $log = Join-Path $TestDrive 'ctrl-guard-child.txt'
        Set-Content -LiteralPath $child -Value $script:ChildSource -Encoding ascii
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$child`" -Dist `"$TargetPath`" -Log `"$log`""
        try { $proc = Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden -PassThru -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because "no console child here: $($_.Exception.Message)"; return }
        if (-not $proc.WaitForExit(90000)) { try { $proc.Kill() } catch { $null = $_ }; throw 'the child did not finish in 90 s' }
        if (-not (Test-Path -LiteralPath $log)) { Set-ItResult -Skipped -Because 'the child left no log (no console?)'; return }
        $lines = @(Get-Content -LiteralPath $log)
        if ($lines -contains 'raise=False') { Set-ItResult -Skipped -Because 'GenerateConsoleCtrlEvent refused: the child has no console'; return }
        if ($lines -contains 'after ctrl+c: swallowed=0') { Set-ItResult -Skipped -Because 'Ctrl+C is not deliverable to the child here (ignored process group)'; return }
        $lines | Should -Contain 'guard=True'
        $lines | Should -Contain 'after ctrl+c: swallowed=1'
        $lines | Should -Contain 'after ctrl+break: swallowed=2'
        $lines | Should -Contain 'disabled installed=False'
        $lines | Should -Not -Contain 'CONTROL FAILED'
    }
}
