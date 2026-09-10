#Requires -Modules Pester

<#
.SYNOPSIS
    winget argument arrays and exit-code classification. $LASTEXITCODE is a
    signed Int32 and winget's documented codes are unsigned, so every
    comparison goes through ConvertTo-WtWingetExitCode.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtWingetInstallArguments' {
    It 'is an array, so a package id is never re-parsed as script' {
        $a = Get-WtWingetInstallArguments -Id 'VideoLAN.VLC'
        $a -is [string[]] | Should -BeTrue
        $a | Should -Contain 'VideoLAN.VLC'
    }

    It 'can never block on a prompt - the output panel has no cancel key' {
        $a = Get-WtWingetInstallArguments -Id 'VideoLAN.VLC'
        $a | Should -Contain '--silent'
        $a | Should -Contain '--disable-interactivity'
        $a | Should -Contain '--accept-source-agreements'
        $a | Should -Contain '--accept-package-agreements'
    }

    It 'pins the id and the source so a name collision cannot install the wrong app' {
        $a = Get-WtWingetInstallArguments -Id 'VideoLAN.VLC'
        $a | Should -Contain '--exact'
        ($a -join ' ') | Should -BeLike '*--source winget*'
    }
}

Describe 'Get-WtWingetUninstallArguments' {
    It 'uninstalls by exact id and never prompts' {
        $a = Get-WtWingetUninstallArguments -Id '7zip.7zip'
        $a[0] | Should -Be 'uninstall'
        $a | Should -Contain '--exact'
        $a | Should -Contain '--silent'
        $a | Should -Contain '--disable-interactivity'
    }
}

Describe 'Get-WtWingetResultKind' {
    It 'reads success' {
        Get-WtWingetResultKind -ExitCode 0 | Should -Be 'Ok'
    }

    It 'reads the documented codes through the signed/unsigned conversion' {
        $noApp = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32('8A150014', 16)), 0)
        Get-WtWingetResultKind -ExitCode $noApp | Should -Be 'NotFound'

        $noUpgrade = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32('8A15002B', 16)), 0)
        Get-WtWingetResultKind -ExitCode $noUpgrade | Should -Be 'NoUpgrade'
    }

    It 'falls back to Failed for a code it does not know' {
        Get-WtWingetResultKind -ExitCode 1 | Should -Be 'Failed'
        Get-WtWingetResultKind -ExitCode $null | Should -Be 'Failed'
    }

    It '0x8A150049 is APPINSTALLER_CLI_ERROR_MSI_INSTALL_FAILED, not reboot required - must stay Failed, never re-added as a success kind' {
        $msiInstallFailed = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32('8A150049', 16)), 0)
        Get-WtWingetResultKind -ExitCode $msiInstallFailed | Should -Be 'Failed'
    }
}

Describe 'Get-WtWingetResultLine' {
    It 'prints an unknown code as unsigned hex - a negative decimal cannot be looked up' {
        $line = Get-WtWingetResultLine -Id 'A.B' -Kind 'Failed' -ExitCode -1978335189
        $line | Should -BeLike '*0x8A15002B*'
    }

    It 'names the package in every verdict' {
        foreach ($k in 'Ok', 'AlreadyInstalled', 'NoUpgrade', 'NotFound', 'Failed') {
            (Get-WtWingetResultLine -Id 'A.B' -Kind $k -ExitCode 0) | Should -BeLike '*A.B*'
        }
    }
}
