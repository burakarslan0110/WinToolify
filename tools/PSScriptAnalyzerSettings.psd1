@{
    # PowerShell 5.1 is the floor; PowerShell 7 must also work (Global Constraints).
    # Profile names verified against the installed PSScriptAnalyzer module's
    # compatibility_profiles directory - do not rename without re-verifying they exist.
    Rules = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'
            )
            # Clear-Host and pause are console-host functions absent from these
            # static profiles but present at runtime on both 5.1 and 7 - verified
            # directly. Without this they produce 53 false-positive findings.
            IgnoreCommands = @('Clear-Host', 'pause')
        }
    }
}
