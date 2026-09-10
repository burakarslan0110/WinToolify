# Terminal command lookup and the context-menu catalog.
# Covered by: tests/ContextMenuCatalog.Tests.ps1

function Get-WtTerminalCommand {
    <#
    .SYNOPSIS
        Resolves the "Open Terminal here (Admin)" command - Windows Terminal
        when wt.exe is on the path, else an elevated Windows PowerShell window
        - built from single-quoted literals so %V reaches the registry
        unexpanded; a folder path with an apostrophe breaks the fallback.
    #>
    param(
        [scriptblock]$TestTerminalAction = {
            return ($null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue))
        }
    )

    if ([bool](& $TestTerminalAction)) {
        return [PSCustomObject]@{
            Command = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process wt.exe -Verb RunAs -ArgumentList ''-d'',''%V''"'
            Icon    = 'wt.exe'
        }
    }

    return [PSCustomObject]@{
        Command = 'powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList ''-NoExit'',''-Command'',''Set-Location -LiteralPath ''''%V''''''"'
        Icon    = 'powershell.exe'
    }
}

function Get-WtContextMenuCatalog {
    <#
    .SYNOPSIS
        The five-entry Context Menu catalog: classic right-click menu, Take
        Ownership, "Open Terminal here (Admin)", "Restart Explorer" and the
        .ps1 "Run with PowerShell (Bypass)" verb - never *\shell\runas. The
        last one adds its own Wt-prefixed verb beside Microsoft's Shell\0
        rather than overwriting it, so undo never has to guess at a stock
        key it did not write. The drive command's \"%1\\\" is deliberate:
        powershell.exe's parser turns \\\" into \" (backslash + quote), so
        takeown gets "D:\" - a drive root needs the trailing separator.
    #>
    param(
        [PSCustomObject]$TerminalCommand = (Get-WtTerminalCommand),

        [string]$SystemDrive = $env:SystemDrive
    )

    $sd = $SystemDrive.TrimEnd('\')

    $fileCmd = @'
powershell -windowstyle hidden -command "Start-Process cmd -ArgumentList '/c takeown /f \"%1\" && icacls \"%1\" /grant *S-1-3-4:F /t /c /l & pause' -Verb runAs"
'@
    $dirCmd = @'
powershell -windowstyle hidden -command "$Y = ($null | choice).Substring(1,1); Start-Process cmd -ArgumentList ('/c takeown /f \"%1\" /r /d ' + $Y + ' && icacls \"%1\" /grant *S-1-3-4:F /t /c /l /q & pause') -Verb runAs"
'@
    $driveCmd = @'
powershell -windowstyle hidden -command "$Y = ($null | choice).Substring(1,1); Start-Process cmd -ArgumentList ('/c takeown /f \"%1\\\" /r /d ' + $Y + ' && icacls \"%1\\\" /grant *S-1-3-4:F /t /c /l /q & pause') -Verb runAs"
'@
    $appliesToDir = ('NOT (System.ItemPathDisplay:="{0}\Users" OR System.ItemPathDisplay:="{0}\ProgramData" OR System.ItemPathDisplay:="{0}\Windows" OR System.ItemPathDisplay:="{0}\Windows\System32" OR System.ItemPathDisplay:="{0}\Program Files" OR System.ItemPathDisplay:="{0}\Program Files (x86)")' -f $sd)
    $appliesToDrive = ('NOT (System.ItemPathDisplay:="{0}\")' -f $sd)

    $str = { param($n, $v) [PSCustomObject]@{ Name = $n; Kind = 'String'; Value = $v } }
    $key = { param($h, $s, $b, $v) [PSCustomObject]@{ Hive = $h; SubKey = $s; RootBoundary = $b; Values = @($v) } }

    $takeOwnershipVerb = @((& $str '' 'Take Ownership'), (& $str 'HasLUAShield' ''), (& $str 'NoWorkingDirectory' ''), (& $str 'NeverDefault' ''))
    $takeOwnershipDir = @((& $str '' 'Take Ownership'), (& $str 'AppliesTo' $appliesToDir), (& $str 'HasLUAShield' ''), (& $str 'NoWorkingDirectory' ''), (& $str 'Position' 'middle'))
    $takeOwnershipDrive = @((& $str '' 'Take Ownership'), (& $str 'AppliesTo' $appliesToDrive), (& $str 'HasLUAShield' ''), (& $str 'NoWorkingDirectory' ''), (& $str 'Position' 'middle'))
    $terminalVerb = @((& $str '' 'Open Terminal here (Admin)'), (& $str 'Icon' $TerminalCommand.Icon), (& $str 'HasLUAShield' ''), (& $str 'NoWorkingDirectory' ''))
    $terminalCmd = @((& $str '' $TerminalCommand.Command))
    $runPsVerb = @((& $str '' 'Run with PowerShell (Bypass)'), (& $str 'Icon' 'powershell.exe'))
    $runPsCmd = @'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%1"
'@

    return Resolve-WtCatalogText -KeyPrefix 'ContextMenu' -Catalog @(
        [PSCustomObject]@{
            Name             = 'RestoreClassicContextMenu'
            DisplayLabel     = 'Restore classic right-click menu'
            Risk             = 'SAFE'
            Consequence      = 'Windows 11 only; visible after Explorer restarts. Undo Last Change deletes the key again'
            RestartsExplorer = $true
            KeyChanges       = @(
                (& $key 'CurrentUser' 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' 'Software\Classes\CLSID' @((& $str '' '')))
            )
        }
        [PSCustomObject]@{
            Name             = 'AddTakeOwnership'
            DisplayLabel     = 'Add "Take Ownership" to the right-click menu'
            Risk             = 'SAFE'
            Consequence      = 'Each use prompts for UAC and grants Full Control to the current owner; skips the system folders. Paths containing an apostrophe are not supported'
            RestartsExplorer = $true
            KeyChanges       = @(
                (& $key 'LocalMachine' 'SOFTWARE\Classes\*\shell\TakeOwnership' 'SOFTWARE\Classes\*\shell' $takeOwnershipVerb)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\*\shell\TakeOwnership\command' 'SOFTWARE\Classes\*\shell' @((& $str '' $fileCmd)))
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Directory\shell\TakeOwnership' 'SOFTWARE\Classes\Directory\shell' $takeOwnershipDir)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Directory\shell\TakeOwnership\command' 'SOFTWARE\Classes\Directory\shell' @((& $str '' $dirCmd)))
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Drive\shell\TakeOwnership' 'SOFTWARE\Classes\Drive\shell' $takeOwnershipDrive)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Drive\shell\TakeOwnership\command' 'SOFTWARE\Classes\Drive\shell' @((& $str '' $driveCmd)))
            )
        }
        [PSCustomObject]@{
            Name             = 'AddOpenTerminalHere'
            DisplayLabel     = 'Add "Open Terminal here (Admin)" to folder menus'
            Risk             = 'SAFE'
            Consequence      = 'Folder paths containing an apostrophe are not supported'
            RestartsExplorer = $true
            KeyChanges       = @(
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin' 'SOFTWARE\Classes\Directory\shell' $terminalVerb)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin\command' 'SOFTWARE\Classes\Directory\shell' $terminalCmd)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin' 'SOFTWARE\Classes\Directory\Background\shell' $terminalVerb)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin\command' 'SOFTWARE\Classes\Directory\Background\shell' $terminalCmd)
            )
        }
        [PSCustomObject]@{
            Name             = 'AddRestartExplorer'
            DisplayLabel     = 'Add "Restart Explorer" to the desktop menu'
            Risk             = 'SAFE'
            Consequence      = $null
            RestartsExplorer = $true
            KeyChanges       = @(
                (& $key 'LocalMachine' 'SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer' 'SOFTWARE\Classes\DesktopBackground\Shell' @((& $str '' 'Restart Explorer'), (& $str 'Icon' 'explorer.exe'), (& $str 'Position' 'Bottom')))
                (& $key 'LocalMachine' 'SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer\command' 'SOFTWARE\Classes\DesktopBackground\Shell' @((& $str '' 'cmd.exe /c taskkill /f /im explorer.exe & start explorer.exe')))
            )
        }
        [PSCustomObject]@{
            Name             = 'AddRunWithPowerShell'
            DisplayLabel     = 'Add "Run with PowerShell (Bypass)" to .ps1 files'
            Risk             = 'CAUTION'
            Consequence      = 'Every .ps1 gains a right-click entry that runs it with the execution policy bypassed, so a downloaded script runs without the block Windows normally applies; the stock "Run with PowerShell" entry is left untouched'
            RestartsExplorer = $true
            KeyChanges       = @(
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\WtRunPowerShellBypass' 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell' $runPsVerb)
                (& $key 'LocalMachine' 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\WtRunPowerShellBypass\command' 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell' @((& $str '' $runPsCmd)))
            )
        }
    )
}
