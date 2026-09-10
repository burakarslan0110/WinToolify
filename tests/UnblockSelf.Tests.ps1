#Requires -Modules Pester

<#
.SYNOPSIS
    Unblock-WtSelf: the startup call that strips the Mark of the Web from
    WinToolify's own file, so a copy downloaded from the releases page
    stops being refused under RemoteSigned on the next launch. The zone
    probe and the unblock call are both injected, so nothing here reads
    or writes a real Zone.Identifier stream.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-ZoneProbe {
        <#
        .SYNOPSIS
            A recording stand-in for the two injected scriptblocks.
            -Blocked is what the zone probe reports; -FailUnblock makes
            the unblock call throw the way a read-only file would.
        #>
        param([bool]$Blocked = $true, [switch]$FailUnblock)
        $log = New-Object System.Collections.Generic.List[string]
        return @{
            Log     = $log
            Probe   = { param($P) $log.Add('probe:' + $P); return $Blocked }.GetNewClosure()
            Unblock = { param($P) $log.Add('unblock:' + $P); if ($FailUnblock) { throw 'access denied' } }.GetNewClosure()
        }
    }
}

Describe 'Unblock-WtSelf' {
    It 'reports false and never probes the zone when there is no script path (the irm | iex launch)' {
        $api = New-ZoneProbe
        Unblock-WtSelf -Path '' -TestBlockedAction $api.Probe -UnblockAction $api.Unblock | Should -BeFalse
        @($api.Log).Count | Should -Be 0
    }

    It 'reports false and leaves the file alone when it carries no zone marker' {
        $api = New-ZoneProbe -Blocked $false
        Unblock-WtSelf -Path 'C:\Tools\WinToolify.ps1' -TestBlockedAction $api.Probe -UnblockAction $api.Unblock | Should -BeFalse
        @($api.Log) | Should -Be @('probe:C:\Tools\WinToolify.ps1')
    }

    It 'unblocks the file and reports true when it carries a zone marker' {
        $api = New-ZoneProbe -Blocked $true
        Unblock-WtSelf -Path 'C:\Tools\WinToolify.ps1' -TestBlockedAction $api.Probe -UnblockAction $api.Unblock | Should -BeTrue
        @($api.Log) | Should -Be @('probe:C:\Tools\WinToolify.ps1', 'unblock:C:\Tools\WinToolify.ps1')
    }

    It 'reports false instead of throwing when the unblock call fails' {
        $api = New-ZoneProbe -Blocked $true -FailUnblock
        { $script:Result = Unblock-WtSelf -Path 'C:\Tools\WinToolify.ps1' -TestBlockedAction $api.Probe -UnblockAction $api.Unblock } | Should -Not -Throw
        $script:Result | Should -BeFalse
        @($api.Log) | Should -Be @('probe:C:\Tools\WinToolify.ps1', 'unblock:C:\Tools\WinToolify.ps1')
    }

    It 'reports false instead of throwing when the zone probe itself fails' {
        { $script:Result = Unblock-WtSelf -Path 'C:\Tools\WinToolify.ps1' -TestBlockedAction { param($P) throw 'no such drive' } -UnblockAction { param($P) throw 'must not run' } } | Should -Not -Throw
        $script:Result | Should -BeFalse
    }
}

Describe 'Unblock-WtSelf - wired into the main flow' {
    It 'runs in the entry point before the settings are read' {
        $main = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/90-main/20-main.ps1') -Raw
        $main | Should -Match 'Unblock-WtSelf'
        $main.IndexOf('Unblock-WtSelf') | Should -BeLessThan $main.IndexOf('Read-WtSettings')
    }
}
