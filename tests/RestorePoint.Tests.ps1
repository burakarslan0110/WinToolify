#Requires -Modules Pester

<#
.SYNOPSIS
    Restore-point coverage: the PS5.1/PS7 API branch predicate, the CIM
    result handling, and the main menu's on-demand row - the only thing in
    WinToolify that makes a restore point.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Test-WtUsesCimRestorePointApi' {
    It 'selects the CIM path for PowerShell 6 and above' {
        Test-WtUsesCimRestorePointApi -PSMajorVersion 6 | Should -BeTrue
        Test-WtUsesCimRestorePointApi -PSMajorVersion 7 | Should -BeTrue
        Test-WtUsesCimRestorePointApi -PSMajorVersion 10 | Should -BeTrue
    }

    It 'selects the cmdlet (Checkpoint-Computer) path below version 6' {
        Test-WtUsesCimRestorePointApi -PSMajorVersion 5 | Should -BeFalse
        Test-WtUsesCimRestorePointApi -PSMajorVersion 4 | Should -BeFalse
    }
}

Describe 'New-WtRestorePoint (CIM branch result handling)' {
    It 'returns $true when the CIM method reports ReturnValue 0' {
        $fake = { param($Arguments) [PSCustomObject]@{ ReturnValue = 0 } }
        New-WtRestorePoint -Description 'unit' -PSMajorVersion 7 -InvokeCimAction $fake -WarningAction SilentlyContinue | Should -BeTrue
    }

    It 'returns $false when the CIM method reports a non-zero ReturnValue instead of throwing' {
        $fake = { param($Arguments) [PSCustomObject]@{ ReturnValue = 2147943458 } }
        New-WtRestorePoint -Description 'unit' -PSMajorVersion 7 -InvokeCimAction $fake -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'returns $false when the CIM call throws' {
        $fake = { param($Arguments) throw 'simulated: Access denied' }
        New-WtRestorePoint -Description 'unit' -PSMajorVersion 7 -InvokeCimAction $fake -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'passes the documented MODIFY_SETTINGS (12) / BEGIN_SYSTEM_CHANGE (100) arguments and the description' {
        $seen = $null
        $fake = { param($Arguments) $script:seen = $Arguments; [PSCustomObject]@{ ReturnValue = 0 } }
        New-WtRestorePoint -Description 'WinToolify: unit' -PSMajorVersion 7 -InvokeCimAction $fake | Out-Null
        $script:seen.RestorePointType | Should -Be 12
        $script:seen.EventType | Should -Be 100
        $script:seen.Description | Should -Be 'WinToolify: unit'
    }

    It 'reports the reason on the warning stream only, so a painted frame stays intact' {
        $captured = $null
        $fake = { param($Arguments) throw 'the service cannot be started because it is disabled' }
        New-WtRestorePoint -Description 'unit' -PSMajorVersion 7 -InvokeCimAction $fake -WarningAction SilentlyContinue -WarningVariable captured | Out-Null
        @($captured).Count | Should -Be 1
        [string]$captured[0] | Should -BeLike "$(Get-Translation 'RpCreateFailed')*"
        [string]$captured[0] | Should -Match 'the service cannot be started because it is disabled'
    }

    It 'the failure never reaches the host: warning stream only, and the panel caller captures it' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        $src | Should -Not -Match 'Write-Host[^\r\n]*RpCreateFailed'
        $src | Should -Match 'New-WtRestorePoint -Description \$Description -WarningAction SilentlyContinue -WarningVariable captured'
    }
    It 'no other painted screen can let a warning through either' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        $src | Should -Match 'Read-WtJson -Path \$file\.FullName -WarningAction SilentlyContinue'
    }
}

Describe 'Invoke-WtCreateRestorePointAction (the only thing that makes a restore point)' {
    BeforeEach {
        $script:shown = New-Object 'System.Collections.Generic.List[string]'
        $script:record = { param($Lines) foreach ($l in @($Lines)) { $script:shown.Add([string]$l) } }
    }

    It 'creates without asking first and reports success' {
        $made = $null
        $r = Invoke-WtCreateRestorePointAction -GetProtectionEnabled { $true } -GetLastPointAgeHours { $null } `
            -CreatePoint { param($Description) $script:made = $Description; [PSCustomObject]@{ Created = $true; Reason = '' } } `
            -ShowMessage { } -Acknowledge $record
        $r | Should -BeTrue
        $script:made | Should -Be ('WinToolify: ' + (Get-Translation 'RpManualDescription'))
        @($script:shown) | Should -Be @((Get-Translation 'RpCreated'))
    }

    It 'shows the failure reason wrapped inside the panel, never on the host' {
        $reason = "$(Get-Translation 'RpCreateFailed') This command cannot be run due to the following error: the service cannot be started because it is disabled or does not have enabled devices associated with it."
        $r = Invoke-WtCreateRestorePointAction -GetProtectionEnabled { $true } -GetLastPointAgeHours { $null } `
            -CreatePoint { param($Description) [PSCustomObject]@{ Created = $false; Reason = $reason } }.GetNewClosure() `
            -ShowMessage { } -Acknowledge $record -WrapWidth 60
        $r | Should -BeFalse
        @($script:shown).Count | Should -BeGreaterThan 1
        foreach ($l in $script:shown) { $l.Length | Should -BeLessOrEqual 60 }
        (@($script:shown) -join ' ') | Should -Be $reason
    }

    It 'falls back to the plain failure line when no reason came back' {
        Invoke-WtCreateRestorePointAction -GetProtectionEnabled { $true } -GetLastPointAgeHours { $null } `
            -CreatePoint { param($Description) [PSCustomObject]@{ Created = $false; Reason = '' } } `
            -ShowMessage { } -Acknowledge $record | Should -BeFalse
        @($script:shown) | Should -Be @((Get-Translation 'RpCreateFailed'))
    }

    It 'states that System Protection is off instead of pretending to create one' {
        Invoke-WtCreateRestorePointAction -GetProtectionEnabled { $false } -CreatePoint { throw 'must not create' } `
            -ShowMessage { } -Acknowledge $record | Should -BeFalse
        @($script:shown) | Should -Be @((Get-Translation 'RpProtectionDisabled'))
    }

    It 'states the 24h throttle instead of asking Windows for a point it will not make' {
        Invoke-WtCreateRestorePointAction -GetProtectionEnabled { $true } -GetLastPointAgeHours { 3 } -CreatePoint { throw 'must not create' } `
            -ShowMessage { } -Acknowledge $record | Should -BeFalse
        @($script:shown) | Should -Be @((Get-Translation 'RpThrottled'))
    }
}

Describe 'No automatic restore point anywhere' {
    It 'the gate, the decision matrix and the startup offer are all gone' {
        foreach ($fn in 'Get-WtRestorePointDecision', 'Invoke-WtRestorePointGate', 'Invoke-WtStartupRestorePoint', 'Invoke-WtStartupRestorePointFlow', 'Invoke-WtDefaultRestorePointFlow', 'Invoke-WtPanelRestorePointFlow') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$fn must not come back"
        }
    }
    It 'nothing in the source tracks a restore-point session state' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        $src | Should -Not -Match 'WtRestorePointSessionState'
    }
    It 'the only caller of New-WtRestorePoint is the main-menu action' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        ([regex]::Matches($src, '(?<![A-Za-z-])New-WtRestorePoint(?![A-Za-z-])')).Count | Should -Be 2
    }
}

