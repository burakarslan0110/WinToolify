#Requires -Modules Pester

<#
.SYNOPSIS
    Window lock: the console opens maximized, the sizing border and the
    minimize/maximize boxes are removed for the session, the system menu
    loses Restore/Move/Size/Minimize/Maximize, and every input wait
    re-maximizes a window something restored. Then the window icon: the
    embedded logo replaces the host's PowerShell icon while the script
    runs and the window's own icon goes back when it exits. Everything is
    best effort - no console window (tests, CI) means no lock, no icon
    and no error.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtLockedWindowStyle' {
    It 'clears the sizing border, the maximize box and the minimize box and keeps every other bit' {
        Get-WtLockedWindowStyle -Style 0x15EF0000 | Should -Be 0x15E80000
    }
    It 'leaves an already locked style unchanged' {
        Get-WtLockedWindowStyle -Style 0x15E80000 | Should -Be 0x15E80000
    }
    It 'keeps the sign bit (WS_POPUP) of a negative style value' {
        Get-WtLockedWindowStyle -Style ([int]-2147418112) | Should -Be ([int]::MinValue)
    }
}

Describe 'Lock-WtWindow' {
    AfterEach { $script:WtWindowLock = $null }
    It 'a failing Apply is swallowed: returns nothing and leaves no lock state' {
        (Lock-WtWindow -Apply { throw 'no console' }) | Should -BeNullOrEmpty
        $script:WtWindowLock | Should -BeNullOrEmpty
    }
    It 'an Apply that finds no console window leaves no lock state' {
        (Lock-WtWindow -Apply { $null }) | Should -BeNullOrEmpty
        $script:WtWindowLock | Should -BeNullOrEmpty
    }
    It 'keeps the state Apply returns so Unlock and the guard can reach the window' {
        $state = Lock-WtWindow -Apply { @{ Handle = 42; Style = 0x15EF0000 } }
        $state.Style | Should -Be 0x15EF0000
        $script:WtWindowLock.Handle | Should -Be 42
    }
}

Describe 'Unlock-WtWindow' {
    AfterEach { $script:WtWindowLock = $null }
    It 'does nothing without lock state' {
        $script:WtWindowLock = $null
        $script:Applied = 0
        Unlock-WtWindow -Apply { param($State) $script:Applied++ }
        $script:Applied | Should -Be 0
    }
    It 'hands the saved state to Apply once and clears it' {
        $script:WtWindowLock = @{ Handle = 42; Style = 7 }
        $script:Seen = @()
        Unlock-WtWindow -Apply { param($State) $script:Seen += @($State.Style) }
        $script:Seen | Should -Be @(7)
        $script:WtWindowLock | Should -BeNullOrEmpty
    }
    It 'a failing Apply is swallowed and the state is still cleared' {
        $script:WtWindowLock = @{ Handle = 42; Style = 7 }
        { Unlock-WtWindow -Apply { throw 'gone' } } | Should -Not -Throw
        $script:WtWindowLock | Should -BeNullOrEmpty
    }
}

Describe 'Assert-WtWindowMaximized' {
    AfterEach { $script:WtWindowLock = $null }
    It 'is a no-op without lock state' {
        $script:WtWindowLock = $null
        $script:Maximized = 0
        Assert-WtWindowMaximized -IsZoomed { param($H) $false } -Maximize { param($H) $script:Maximized++ } | Should -BeFalse
        $script:Maximized | Should -Be 0
    }
    It 'leaves a maximized window alone' {
        $script:WtWindowLock = @{ Handle = 42; Style = 7 }
        $script:Maximized = 0
        Assert-WtWindowMaximized -IsZoomed { param($H) $true } -Maximize { param($H) $script:Maximized++ } | Should -BeFalse
        $script:Maximized | Should -Be 0
    }
    It 'maximizes the locked window again when something restored or minimized it' {
        $script:WtWindowLock = @{ Handle = 42; Style = 7 }
        $script:Handles = @()
        Assert-WtWindowMaximized -IsZoomed { param($H) $false } -Maximize { param($H) $script:Handles += @($H) } | Should -BeTrue
        $script:Handles | Should -Be @(42)
    }
    It 'a failing query is swallowed' {
        $script:WtWindowLock = @{ Handle = 42; Style = 7 }
        Assert-WtWindowMaximized -IsZoomed { throw 'gone' } -Maximize { param($H) } | Should -BeFalse
    }
}

Describe 'native window helper' {
    It 'compiles under this PowerShell (C# 5 only: PS 5.1 has no newer compiler)' {
        if (-not ('WtWindowNative' -as [type])) { Add-Type -TypeDefinition $script:WtWindowNativeSource -ErrorAction Stop }
        ('WtWindowNative' -as [type]) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Sync-WtBufferToWindow' {
    AfterEach { $script:WtReplMode = $false }
    It 'pins the buffer to the window when the framed TUI owns the screen' {
        $script:WtReplMode = $false
        $script:Ran = 0
        Sync-WtBufferToWindow -Apply { $script:Ran++ }
        $script:Ran | Should -Be 1
    }
    It 'is a no-op in REPL mode: the assistant keeps its tall scrollback and no buffer resize hits the crash-prone path' {
        $script:WtReplMode = $true
        $script:Ran = 0
        Sync-WtBufferToWindow -Apply { $script:Ran++ }
        $script:Ran | Should -Be 0
    }
    It 'swallows a failing Apply' {
        $script:WtReplMode = $false
        { Sync-WtBufferToWindow -Apply { throw 'no console' } } | Should -Not -Throw
    }
}

Describe 'Set-WtWindowIcon' {
    AfterEach { $script:WtWindowIcon = $null }
    It 'a failing Apply is swallowed: reports false and leaves no icon state' {
        (Set-WtWindowIcon -Apply { throw 'no console' }) | Should -BeFalse
        $script:WtWindowIcon | Should -BeNullOrEmpty
    }
    It 'an Apply that finds no window to brand leaves no icon state' {
        (Set-WtWindowIcon -Apply { $null }) | Should -BeFalse
        $script:WtWindowIcon | Should -BeNullOrEmpty
    }
    It 'keeps the handles Apply returns so the old icon can be put back' {
        (Set-WtWindowIcon -Apply { @{ Handle = 42; Icons = @(@{ Which = 0; Made = 7; Previous = 3 }) } }) | Should -BeTrue
        $script:WtWindowIcon.Handle | Should -Be 42
        $script:WtWindowIcon.Icons[0].Previous | Should -Be 3
    }
}

Describe 'Restore-WtWindowIcon' {
    AfterEach { $script:WtWindowIcon = $null }
    It 'does nothing without icon state' {
        $script:WtWindowIcon = $null
        $script:Applied = 0
        Restore-WtWindowIcon -Apply { param($State) $script:Applied++ }
        $script:Applied | Should -Be 0
    }
    It 'hands both saved slots to Apply once and clears them' {
        $script:WtWindowIcon = @{ Handle = 42; Icons = @(@{ Which = 0; Made = 7; Previous = 3 }, @{ Which = 1; Made = 8; Previous = 0 }) }
        $script:Seen = @()
        Restore-WtWindowIcon -Apply { param($State) $script:Seen += @(@($State.Icons).Count) }
        $script:Seen | Should -Be @(2)
        $script:WtWindowIcon | Should -BeNullOrEmpty
    }
    It 'a failing Apply is swallowed and the state is still cleared' {
        $script:WtWindowIcon = @{ Handle = 42; Icons = @() }
        { Restore-WtWindowIcon -Apply { throw 'gone' } } | Should -Not -Throw
        $script:WtWindowIcon | Should -BeNullOrEmpty
    }
}

Describe 'the embedded logo' {
    It 'is byte-identical to the shipped site/assets/logo-160.png' {
        $shipped = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $RepoRoot 'site/assets/logo-160.png')))
        (Get-WtWinToolifyLogoBase64) | Should -Be $shipped
    }
    It 'is a PNG Windows turns into an icon at both WM_SETICON sizes' {
        if (-not ('WtWindowNative' -as [type])) { Add-Type -TypeDefinition $script:WtWindowNativeSource -ErrorAction Stop }
        $bytes = [byte[]][Convert]::FromBase64String([string](Get-WtWinToolifyLogoBase64))
        foreach ($size in 16, 32) {
            $icon = [WtWindowNative]::CreateIconFromResourceEx($bytes, [uint32]$bytes.Length, $true, 0x00030000, $size, $size, 0)
            $icon | Should -Not -Be ([IntPtr]::Zero)
            $null = [WtWindowNative]::DestroyIcon($icon)
        }
    }
}

Describe 'window lock wiring (source guards)' {
    BeforeAll { $script:src = Get-Content -LiteralPath $TargetPath -Raw }
    It 'the main block locks the window right after Set-WindowSize' {
        $src | Should -Match 'Set-WindowSize \| Out-Null\r?\n\s*\$null = Lock-WtWindow'
    }
    It 'the main block unlocks the window in finally, after Restore-WtTui' {
        $src | Should -Match 'finally \{[^}]*Restore-WtTui\r?\n\s*Unlock-WtWindow'
    }
    It 'the main block brands the window right after the lock' {
        $src | Should -Match '\$null = Lock-WtWindow\r?\n\s*\$null = Set-WtWindowIcon'
    }
    It 'the main block puts the window icon back in finally, after the unlock' {
        $src | Should -Match 'Unlock-WtWindow\r?\n\s*Restore-WtWindowIcon'
    }
    It 'every elevation relaunch opens the new console maximized' {
        $spawns = @([regex]::Matches($src, '(?m)^.*WINTOOLIFY_SPAWNED=''1''.*$') | ForEach-Object Value)
        $spawns.Count | Should -BeGreaterOrEqual 2
        foreach ($line in $spawns) { $line | Should -Match '-WindowStyle Maximized' }
    }
    It 'every input wait that re-asserts Ctrl+C also re-asserts the maximized window' {
        $ctrlC = ([regex]::Matches($src, '\$null = Assert-WtTuiCtrlCInput')).Count
        $paired = ([regex]::Matches($src, '\$null = Assert-WtTuiCtrlCInput\r?\n\s*\$null = Assert-WtWindowMaximized')).Count
        $ctrlC | Should -BeGreaterThan 0
        $paired | Should -Be $ctrlC
    }
}
