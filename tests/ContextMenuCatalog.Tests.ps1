#Requires -Modules Pester

<#
.SYNOPSIS
    Explorer & Context-Menu bundle: Get-WtContextMenuCatalog (the four
    context-menu entries' exact keys, values and command strings,
    compared against literals, not rebuilt from the implementation's
    own expressions) and Get-WtTerminalCommand (Windows Terminal vs.
    PowerShell fallback).
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    $script:FileCmd = @'
powershell -windowstyle hidden -command "Start-Process cmd -ArgumentList '/c takeown /f \"%1\" && icacls \"%1\" /grant *S-1-3-4:F /t /c /l & pause' -Verb runAs"
'@
    $script:DirCmd = @'
powershell -windowstyle hidden -command "$Y = ($null | choice).Substring(1,1); Start-Process cmd -ArgumentList ('/c takeown /f \"%1\" /r /d ' + $Y + ' && icacls \"%1\" /grant *S-1-3-4:F /t /c /l /q & pause') -Verb runAs"
'@
    $script:DriveCmd = @'
powershell -windowstyle hidden -command "$Y = ($null | choice).Substring(1,1); Start-Process cmd -ArgumentList ('/c takeown /f \"%1\\\" /r /d ' + $Y + ' && icacls \"%1\\\" /grant *S-1-3-4:F /t /c /l /q & pause') -Verb runAs"
'@
    $script:AppliesToDirC = @'
NOT (System.ItemPathDisplay:="C:\Users" OR System.ItemPathDisplay:="C:\ProgramData" OR System.ItemPathDisplay:="C:\Windows" OR System.ItemPathDisplay:="C:\Windows\System32" OR System.ItemPathDisplay:="C:\Program Files" OR System.ItemPathDisplay:="C:\Program Files (x86)")
'@
    $script:AppliesToDriveC = @'
NOT (System.ItemPathDisplay:="C:\")
'@
    $script:WtTerminalCmd = @'
powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process wt.exe -Verb RunAs -ArgumentList '-d','%V'"
'@
    $script:FallbackTerminalCmd = @'
powershell.exe -NoProfile -WindowStyle Hidden -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit','-Command','Set-Location -LiteralPath ''%V'''"
'@
    $script:RestartExplorerCmd = 'cmd.exe /c taskkill /f /im explorer.exe & start explorer.exe'
    $script:RunWithPowerShellCmd = @'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%1"
'@

    $script:Terminal = [PSCustomObject]@{ Command = $WtTerminalCmd; Icon = 'wt.exe' }
    $script:Catalog = Get-WtContextMenuCatalog -TerminalCommand $Terminal -SystemDrive 'C:'

    function Get-KeyChange {
        param($Entry, [string]$SubKey)
        return ($Entry.KeyChanges | Where-Object SubKey -eq $SubKey | Select-Object -First 1)
    }
    function Get-ValueOf {
        param($KeyChange, [string]$Name)
        return ($KeyChange.Values | Where-Object Name -eq $Name | Select-Object -First 1).Value
    }
}

Describe 'Get-WtContextMenuCatalog - shape' {
    It 'returns the five entries in order, all restarting Explorer, with the two consequences the plan names' {
        @($Catalog).Count | Should -Be 5
        @($Catalog | ForEach-Object Name) | Should -Be @('RestoreClassicContextMenu', 'AddTakeOwnership', 'AddOpenTerminalHere', 'AddRestartExplorer', 'AddRunWithPowerShell')
        $Catalog | Where-Object Name -ne 'AddRunWithPowerShell' | ForEach-Object { $_.Risk | Should -Be 'SAFE' }
        $Catalog | ForEach-Object { $_.RestartsExplorer | Should -BeTrue }
        $Catalog | ForEach-Object { $_.DisplayLabel | Should -Not -BeNullOrEmpty }
        ($Catalog | Where-Object Name -eq 'RestoreClassicContextMenu').Consequence | Should -Not -BeNullOrEmpty
        ($Catalog | Where-Object Name -eq 'AddTakeOwnership').Consequence | Should -Not -BeNullOrEmpty
        ($Catalog | Where-Object Name -eq 'AddTakeOwnership').Consequence | Should -BeLike '*apostrophe*'
        ($Catalog | Where-Object Name -eq 'AddOpenTerminalHere').Consequence | Should -BeLike '*apostrophe*'
    }

    It 'never targets a \shell\runas key and keeps every SubKey strictly below its own RootBoundary' {
        foreach ($entry in $Catalog) {
            foreach ($change in $entry.KeyChanges) {
                $change.SubKey | Should -Not -Match '\\shell\\runas$'
                $change.SubKey | Should -Not -Match '\\shell\\runas\\'
                $change.SubKey.StartsWith($change.RootBoundary + '\', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue -Because "$($change.SubKey) must be under $($change.RootBoundary)"
                $change.Hive | Should -BeIn @('CurrentUser', 'LocalMachine')
                foreach ($value in $change.Values) { $value.Kind | Should -Be 'String' }
            }
        }
    }
}

Describe 'Get-WtContextMenuCatalog - AddRunWithPowerShell' {
    BeforeAll { $script:RunEntry = $Catalog | Where-Object Name -eq 'AddRunWithPowerShell' }

    It 'is the one CAUTION row and says what the bypass costs' {
        $RunEntry.Risk | Should -Be 'CAUTION'
        $RunEntry.RestartsExplorer | Should -BeTrue
        $RunEntry.Consequence | Should -Not -BeNullOrEmpty
        $RunEntry.Consequence | Should -BeLike '*execution policy*'
    }

    It 'adds its own Wt-prefixed verb under the .ps1 progid and never touches the stock Shell\0 verb' {
        @($RunEntry.KeyChanges | ForEach-Object SubKey) | Should -Be @(
            'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\WtRunPowerShellBypass',
            'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\WtRunPowerShellBypass\command'
        )
        $RunEntry.KeyChanges | ForEach-Object {
            $_.Hive | Should -Be 'LocalMachine'
            $_.RootBoundary | Should -Be 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell'
            $_.SubKey | Should -Not -Match '\\Shell\\0'
        }
    }

    It 'runs the clicked script with the policy bypassed and no profile' {
        $verb = Get-KeyChange $RunEntry 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\WtRunPowerShellBypass'
        @($verb.Values | ForEach-Object Name) | Should -Be @('', 'Icon')
        Get-ValueOf $verb 'Icon' | Should -Be 'powershell.exe'
        Get-ValueOf $verb '' | Should -Not -BeNullOrEmpty

        $command = Get-KeyChange $RunEntry 'SOFTWARE\Classes\Microsoft.PowerShellScript.1\Shell\WtRunPowerShellBypass\command'
        Get-ValueOf $command '' | Should -Be $RunWithPowerShellCmd
    }
}

Describe 'Get-WtContextMenuCatalog - RestoreClassicContextMenu' {
    It 'writes an empty default value to the per-user InprocServer32 CLSID key, bounded at CLSID' {
        $entry = $Catalog | Where-Object Name -eq 'RestoreClassicContextMenu'
        @($entry.KeyChanges).Count | Should -Be 1
        $change = $entry.KeyChanges[0]
        $change.Hive | Should -Be 'CurrentUser'
        $change.SubKey | Should -Be 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        $change.RootBoundary | Should -Be 'Software\Classes\CLSID'
        @($change.Values).Count | Should -Be 1
        $change.Values[0].Name | Should -Be ''
        $change.Values[0].Value | Should -Be ''
    }
}

Describe 'Get-WtContextMenuCatalog - AddTakeOwnership' {
    BeforeAll { $script:Entry = $Catalog | Where-Object Name -eq 'AddTakeOwnership' }

    It 'declares the six machine-wide TakeOwnership keys with the exact values and command strings' {
        $Entry.KeyChanges | ForEach-Object { $_.Hive | Should -Be 'LocalMachine' }
        @($Entry.KeyChanges | ForEach-Object SubKey) | Should -Be @(
            'SOFTWARE\Classes\*\shell\TakeOwnership',
            'SOFTWARE\Classes\*\shell\TakeOwnership\command',
            'SOFTWARE\Classes\Directory\shell\TakeOwnership',
            'SOFTWARE\Classes\Directory\shell\TakeOwnership\command',
            'SOFTWARE\Classes\Drive\shell\TakeOwnership',
            'SOFTWARE\Classes\Drive\shell\TakeOwnership\command'
        )

        $file = Get-KeyChange $Entry 'SOFTWARE\Classes\*\shell\TakeOwnership'
        $file.RootBoundary | Should -Be 'SOFTWARE\Classes\*\shell'
        @($file.Values | ForEach-Object Name) | Should -Be @('', 'HasLUAShield', 'NoWorkingDirectory', 'NeverDefault')
        Get-ValueOf $file '' | Should -Be 'Take Ownership'
        Get-ValueOf $file 'HasLUAShield' | Should -Be ''
        Get-ValueOf $file 'NoWorkingDirectory' | Should -Be ''
        Get-ValueOf $file 'NeverDefault' | Should -Be ''
        Get-ValueOf (Get-KeyChange $Entry 'SOFTWARE\Classes\*\shell\TakeOwnership\command') '' | Should -Be $FileCmd

        $dir = Get-KeyChange $Entry 'SOFTWARE\Classes\Directory\shell\TakeOwnership'
        $dir.RootBoundary | Should -Be 'SOFTWARE\Classes\Directory\shell'
        @($dir.Values | ForEach-Object Name) | Should -Be @('', 'AppliesTo', 'HasLUAShield', 'NoWorkingDirectory', 'Position')
        Get-ValueOf $dir '' | Should -Be 'Take Ownership'
        Get-ValueOf $dir 'AppliesTo' | Should -Be $AppliesToDirC
        Get-ValueOf $dir 'Position' | Should -Be 'middle'
        Get-ValueOf (Get-KeyChange $Entry 'SOFTWARE\Classes\Directory\shell\TakeOwnership\command') '' | Should -Be $DirCmd

        $drive = Get-KeyChange $Entry 'SOFTWARE\Classes\Drive\shell\TakeOwnership'
        $drive.RootBoundary | Should -Be 'SOFTWARE\Classes\Drive\shell'
        @($drive.Values | ForEach-Object Name) | Should -Be @('', 'AppliesTo', 'HasLUAShield', 'NoWorkingDirectory', 'Position')
        Get-ValueOf $drive 'AppliesTo' | Should -Be $AppliesToDriveC
        Get-ValueOf $drive 'Position' | Should -Be 'middle'
        Get-ValueOf (Get-KeyChange $Entry 'SOFTWARE\Classes\Drive\shell\TakeOwnership\command') '' | Should -Be $DriveCmd
    }

    It 'derives the recursive confirmation character from choice and never hard-codes /d y' {
        foreach ($sub in @('SOFTWARE\Classes\Directory\shell\TakeOwnership\command', 'SOFTWARE\Classes\Drive\shell\TakeOwnership\command')) {
            $cmd = Get-ValueOf (Get-KeyChange $Entry $sub) ''
            $cmd | Should -BeLike '*($null | choice).Substring(1,1)*'
            $cmd | Should -Not -BeLike '*/d y*'
        }
    }

    It 'grants to the Owner Rights SID, never to administrators' {
        foreach ($change in ($Entry.KeyChanges | Where-Object SubKey -like '*\command')) {
            $cmd = Get-ValueOf $change ''
            $cmd | Should -BeLike '*/grant `*S-1-3-4:F*'
            $cmd | Should -Not -BeLike '*administrators*'
        }
    }

    It 'builds both AppliesTo filters from the injected system drive, with no literal C: left over' {
        $catalogD = Get-WtContextMenuCatalog -TerminalCommand $Terminal -SystemDrive 'D:'
        $entryD = $catalogD | Where-Object Name -eq 'AddTakeOwnership'
        $dirApplies = Get-ValueOf (Get-KeyChange $entryD 'SOFTWARE\Classes\Directory\shell\TakeOwnership') 'AppliesTo'
        $driveApplies = Get-ValueOf (Get-KeyChange $entryD 'SOFTWARE\Classes\Drive\shell\TakeOwnership') 'AppliesTo'

        $dirApplies | Should -BeLike '*System.ItemPathDisplay:="D:\Windows\System32"*'
        $dirApplies | Should -BeLike '*System.ItemPathDisplay:="D:\Program Files (x86)"*'
        $driveApplies | Should -Be 'NOT (System.ItemPathDisplay:="D:\")'
        foreach ($e in $catalogD) {
            foreach ($c in $e.KeyChanges) {
                foreach ($v in $c.Values) {
                    if ($v.Name -eq 'AppliesTo') { $v.Value | Should -Not -BeLike '*C:*' }
                }
            }
        }
    }
}

Describe 'Get-WtContextMenuCatalog - AddOpenTerminalHere and AddRestartExplorer' {
    It 'writes the resolved terminal command and icon under Directory and Directory\Background' {
        $entry = $Catalog | Where-Object Name -eq 'AddOpenTerminalHere'
        @($entry.KeyChanges | ForEach-Object SubKey) | Should -Be @(
            'SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin',
            'SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin\command',
            'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin',
            'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin\command'
        )
        $entry.KeyChanges | ForEach-Object { $_.Hive | Should -Be 'LocalMachine' }
        (Get-KeyChange $entry 'SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin').RootBoundary | Should -Be 'SOFTWARE\Classes\Directory\shell'
        (Get-KeyChange $entry 'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin\command').RootBoundary | Should -Be 'SOFTWARE\Classes\Directory\Background\shell'

        foreach ($sub in @('SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin', 'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin')) {
            $verb = Get-KeyChange $entry $sub
            @($verb.Values | ForEach-Object Name) | Should -Be @('', 'Icon', 'HasLUAShield', 'NoWorkingDirectory')
            Get-ValueOf $verb '' | Should -Be 'Open Terminal here (Admin)'
            Get-ValueOf $verb 'Icon' | Should -Be 'wt.exe'
            Get-ValueOf (Get-KeyChange $entry "$sub\command") '' | Should -Be $WtTerminalCmd
        }
    }

    It 'takes the fallback command and icon from the injected terminal resolution' {
        $fallback = [PSCustomObject]@{ Command = $FallbackTerminalCmd; Icon = 'powershell.exe' }
        $entry = (Get-WtContextMenuCatalog -TerminalCommand $fallback -SystemDrive 'C:') | Where-Object Name -eq 'AddOpenTerminalHere'
        Get-ValueOf (Get-KeyChange $entry 'SOFTWARE\Classes\Directory\shell\WtOpenTerminalAdmin') 'Icon' | Should -Be 'powershell.exe'
        Get-ValueOf (Get-KeyChange $entry 'SOFTWARE\Classes\Directory\Background\shell\WtOpenTerminalAdmin\command') '' | Should -Be $FallbackTerminalCmd
    }

    It 'writes the Restart Explorer verb to DesktopBackground\Shell with icon, position and command' {
        $entry = $Catalog | Where-Object Name -eq 'AddRestartExplorer'
        @($entry.KeyChanges | ForEach-Object SubKey) | Should -Be @(
            'SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer',
            'SOFTWARE\Classes\DesktopBackground\Shell\WtRestartExplorer\command'
        )
        $verb = $entry.KeyChanges[0]
        $verb.Hive | Should -Be 'LocalMachine'
        $verb.RootBoundary | Should -Be 'SOFTWARE\Classes\DesktopBackground\Shell'
        @($verb.Values | ForEach-Object Name) | Should -Be @('', 'Icon', 'Position')
        Get-ValueOf $verb '' | Should -Be 'Restart Explorer'
        Get-ValueOf $verb 'Icon' | Should -Be 'explorer.exe'
        Get-ValueOf $verb 'Position' | Should -Be 'Bottom'
        Get-ValueOf $entry.KeyChanges[1] '' | Should -Be $RestartExplorerCmd
    }
}

Describe 'Get-WtTerminalCommand' {
    It 'returns the wt.exe command and icon when the probe reports Windows Terminal present' {
        $result = Get-WtTerminalCommand -TestTerminalAction { $true }
        $result.Command | Should -Be $WtTerminalCmd
        $result.Icon | Should -Be 'wt.exe'
    }

    It 'returns the PowerShell fallback command and icon when the probe reports it absent' {
        $result = Get-WtTerminalCommand -TestTerminalAction { $false }
        $result.Command | Should -Be $FallbackTerminalCmd
        $result.Icon | Should -Be 'powershell.exe'
    }
}
