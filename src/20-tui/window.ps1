# Set-WindowSize, the window lock and the console window icon.
# Covered by: tests/Guard.Tests.ps1, tests/WindowLock.Tests.ps1

function Set-WindowSize {
    <#
    .SYNOPSIS
        Sets the console window and buffer to a target size (falling back
        to a fixed 120x65 default). The buffer is grown before the
        window, since Windows never allows a window larger than its
        buffer, then pinned back to match so there is no scrollback and
        (0,0) is always the visible top-left. Returns $false, never
        throws, when the console does not support resizing.
    #>
    param (
        [int]$contentWidth = 120,
        [int]$contentHeight = 65
    )

    try {
        $pswindow = $Host.UI.RawUI
        $Host.UI.RawUI.WindowTitle = Get-WtWindowTitle
        $max = $pswindow.MaxWindowSize
        $targetW = [Math]::Min($contentWidth, [int]$max.Width)
        $targetH = [Math]::Min($contentHeight, [int]$max.Height)
        $current = $pswindow.WindowSize
        if ($current.Width -lt $targetW -or $current.Height -lt $targetH) {
            $buf = $pswindow.BufferSize
            $buf.Width = [Math]::Max([int]$buf.Width, $targetW)
            $buf.Height = [Math]::Max([int]$buf.Height, $targetH)
            $pswindow.BufferSize = $buf
            $win = $pswindow.WindowSize
            $win.Width = [Math]::Max([int]$current.Width, $targetW)
            $win.Height = [Math]::Max([int]$current.Height, $targetH)
            $pswindow.WindowSize = $win
        }
        $pswindow.BufferSize = $pswindow.WindowSize
        return $true
    }
    catch {
        Write-Host (Get-Translation 'WindowSizeFailed') -ForegroundColor Yellow
        return $false
    }
}

$script:WtWindowNativeSource = @'
using System;
using System.Runtime.InteropServices;
public static class WtWindowNative
{
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
    [DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr CreateIconFromResourceEx(byte[] pbIconBits, uint cbIconBits, bool fIcon, uint dwVer, int cxDesired, int cyDesired, uint uFlags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
}
'@

function Get-WtLockedWindowStyle {
    <#
    .SYNOPSIS
        GWL_STYLE value without WS_THICKFRAME (sizing border), WS_MAXIMIZEBOX
        (restore box, caption double-click) and WS_MINIMIZEBOX (minimize
        box, taskbar minimize). Pure; every other bit is kept.
    #>
    param([int]$Style)
    return [int]($Style -band (-bnot ([int]0x00040000 -bor [int]0x00010000 -bor [int]0x00020000)))
}

function Sync-WtBufferToWindow {
    <#
    .SYNOPSIS
        Pins the buffer to the window size so there is no scrollback and
        (0,0) is always the visible top-left. Skipped while the assistant
        REPL is open, which keeps a tall scrollback on purpose and whose
        BufferSize resize is exactly the console path known to FAST_FAIL.
    #>
    param([scriptblock]$Apply = {
        $raw = $Host.UI.RawUI
        for ($i = 0; $i -lt 2; $i++) { $raw.BufferSize = $raw.WindowSize }
    })
    if ($script:WtReplMode) { return }
    try { & $Apply } catch { $null = $_ }
}

function Lock-WtWindow {
    <#
    .SYNOPSIS
        Maximizes the console window and removes the ways to shrink it
        (sizing border, minimize/maximize boxes, the system menu's
        Restore/Move/Size/Minimize/Maximize). Inside Windows Terminal,
        GetConsoleWindow returns a hidden pseudo-console that ShowWindow
        would make visible, so only the terminal's own foreground window
        is maximized there and nothing is locked. Returns the state
        Unlock-WtWindow needs, kept in $script:WtWindowLock; $null when
        there is no console window or any call fails.
    #>
    param([scriptblock]$Apply = {
        if (-not ('WtWindowNative' -as [type])) { Add-Type -TypeDefinition $script:WtWindowNativeSource -ErrorAction Stop }
        if ($env:WT_SESSION) {
            $fg = [WtWindowNative]::GetForegroundWindow()
            $ownerPid = [uint32]0
            $null = [WtWindowNative]::GetWindowThreadProcessId($fg, [ref]$ownerPid)
            if ($ownerPid -gt 0 -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName -eq 'WindowsTerminal') {
                $null = [WtWindowNative]::ShowWindow($fg, 3)
            }
            return $null
        }
        $hwnd = [WtWindowNative]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $null }
        $null = [WtWindowNative]::ShowWindow($hwnd, 3)
        $style = [WtWindowNative]::GetWindowLong($hwnd, -16)
        $null = [WtWindowNative]::SetWindowLong($hwnd, -16, (Get-WtLockedWindowStyle -Style $style))
        $null = [WtWindowNative]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, [uint32]0x27)
        $menu = [WtWindowNative]::GetSystemMenu($hwnd, $false)
        foreach ($sc in 0xF120, 0xF010, 0xF000, 0xF020, 0xF030) {
            $null = [WtWindowNative]::DeleteMenu($menu, [uint32]$sc, 0)
        }
        Sync-WtBufferToWindow
        return @{ Handle = $hwnd; Style = $style }
    })
    $script:WtWindowLock = $null
    try { $state = & $Apply } catch { $state = $null }
    if ($null -eq $state) { return $null }
    $script:WtWindowLock = $state
    return $state
}

function Unlock-WtWindow {
    <#
    .SYNOPSIS
        Puts the original window style and system menu back, so a console
        the user opened themselves behaves normally again. No-op when
        Lock-WtWindow never took; never throws.
    #>
    param([scriptblock]$Apply = { param($State)
        $null = [WtWindowNative]::SetWindowLong($State.Handle, -16, [int]$State.Style)
        $null = [WtWindowNative]::SetWindowPos($State.Handle, [IntPtr]::Zero, 0, 0, 0, 0, [uint32]0x27)
        $null = [WtWindowNative]::GetSystemMenu($State.Handle, $true)
    })
    $state = $script:WtWindowLock
    $script:WtWindowLock = $null
    if ($null -eq $state) { return }
    try { $null = & $Apply $state } catch { $null = $_ }
}

function Assert-WtWindowMaximized {
    <#
    .SYNOPSIS
        Maximizes the locked window again when something restored or
        minimized it: Win+Down, a caption drag, a programmatic SC_RESTORE
        - none of these check the removed style bits. Called before every
        blocking input wait, next to Assert-WtTuiCtrlCInput; one cheap
        IsZoomed query when nothing changed. No-op without a lock; never
        throws. Returns $true when it had to maximize.
    #>
    param(
        [scriptblock]$IsZoomed = { param($Handle) [bool][WtWindowNative]::IsZoomed($Handle) },
        [scriptblock]$Maximize = { param($Handle) $null = [WtWindowNative]::ShowWindow($Handle, 3); Sync-WtBufferToWindow }
    )
    $state = $script:WtWindowLock
    if ($null -eq $state) { return $false }
    try {
        if ([bool](& $IsZoomed $state.Handle)) { return $false }
        $null = & $Maximize $state.Handle
        return $true
    }
    catch { return $false }
}

function Set-WtWindowIcon {
    <#
    .SYNOPSIS
        Puts the WinToolify logo on the console window - title bar,
        Alt+Tab and the taskbar - in place of the host's own PowerShell
        icon. WM_SETICON takes one handle per slot, so the embedded logo
        becomes a 16- and a 32-pixel icon at its own size rather than one
        bitmap Windows shrinks twice. CreateIconFromResourceEx reads a
        PNG directly on Vista and later, which keeps this on user32 next
        to the rest of the window work instead of pulling System.Drawing
        into a script that loads no other assembly. Inside Windows
        Terminal GetConsoleWindow is a hidden pseudo-console and the tab
        icon comes from the profile, so nothing is set there - the same
        case Lock-WtWindow steps around. What the window had is kept in
        $script:WtWindowIcon for Restore-WtWindowIcon. Returns $false and
        changes nothing when there is no window to brand; never throws.
    #>
    param([scriptblock]$Apply = {
        if ($env:WT_SESSION) { return $null }
        if (-not ('WtWindowNative' -as [type])) { Add-Type -TypeDefinition $script:WtWindowNativeSource -ErrorAction Stop }
        $hwnd = [WtWindowNative]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $null }
        $bytes = [byte[]][Convert]::FromBase64String([string](Get-WtWinToolifyLogoBase64))
        $set = New-Object System.Collections.Generic.List[object]
        foreach ($slot in @(@{ Which = 0; Size = 16 }, @{ Which = 1; Size = 32 })) {
            $made = [WtWindowNative]::CreateIconFromResourceEx($bytes, [uint32]$bytes.Length, $true, 0x00030000, [int]$slot.Size, [int]$slot.Size, 0)
            if ($made -eq [IntPtr]::Zero) { continue }
            $previous = [WtWindowNative]::SendMessage($hwnd, 0x0080, [IntPtr][int]$slot.Which, $made)
            $set.Add(@{ Which = [int]$slot.Which; Made = $made; Previous = $previous })
        }
        if ($set.Count -eq 0) { return $null }
        return @{ Handle = $hwnd; Icons = $set.ToArray() }
    })
    $script:WtWindowIcon = $null
    try { $state = & $Apply } catch { $state = $null }
    if ($null -eq $state) { return $false }
    $script:WtWindowIcon = $state
    return $true
}

function Restore-WtWindowIcon {
    <#
    .SYNOPSIS
        Gives the console window its own icon back and frees the ones
        this script made, so a console the user opened themselves is not
        left branded once WinToolify exits. A saved handle of zero goes
        back as zero on purpose: that is the window saying it had no icon
        of its own and drew its class icon, which is what it will draw
        again. No-op when Set-WtWindowIcon never took; never throws.
    #>
    param([scriptblock]$Apply = { param($State)
        foreach ($icon in @($State.Icons)) {
            $null = [WtWindowNative]::SendMessage([IntPtr]$State.Handle, 0x0080, [IntPtr][int]$icon.Which, [IntPtr]$icon.Previous)
            if ([IntPtr]$icon.Made -ne [IntPtr]::Zero) { $null = [WtWindowNative]::DestroyIcon([IntPtr]$icon.Made) }
        }
    })
    $state = $script:WtWindowIcon
    $script:WtWindowIcon = $null
    if ($null -eq $state) { return }
    try { $null = & $Apply $state } catch { $null = $_ }
}
