# Power plan constants, powercfg wrapper, GUID/index readers, catalog and state.
# Covered by: tests/PowerPlan.Tests.ps1

# ---------------------------------------------------------------------------
# Memory & Performance Tuning bundle - Power Plan
# ---------------------------------------------------------------------------

$script:WtPowerUltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:WtPowerWinToolifyUltimateGuid = '4b56727b-66b4-485a-8d8b-a8bef4f7dfb8'
$script:WtPowerBalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:WtPowerProcessorSubGroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
$script:WtPowerCoreParkingSettings = @(
    [PSCustomObject]@{ Guid = '0cc5b647-c1df-4637-891a-dec35c318583'; Label = 'CPMINCORES' }
    [PSCustomObject]@{ Guid = '0cc5b647-c1df-4637-891a-dec35c318584'; Label = 'CPMINCORES1' }
)
$script:WtPowerCoreParkingUnparkedIndex = 100
$script:WtGuidRegex = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
$script:WtHexIndexRegex = '0x[0-9a-fA-F]{8}'

function Invoke-WtPowercfg {
    <#
    .SYNOPSIS
        The one seam every power function goes through: runs powercfg.exe
        with the given arguments and returns ExitCode + Output lines. Never
        throws itself - callers decide. powercfg.exe does not exist on the
        macOS dev host, so the real call lives behind -PowercfgAction and
        tests inject a scripted fake.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [scriptblock]$PowercfgAction = {
            param($Arguments)
            $out = & powercfg.exe @Arguments 2>&1
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
        }
    )

    return (& $PowercfgAction $Arguments)
}

function Get-WtPowercfgGuids {
    <#
    .SYNOPSIS
        Every GUID in the given powercfg output lines, lower-cased, in
        order. Locale-independent: powercfg localizes every label, so only
        the GUID tokens are parsed.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $guids = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        foreach ($m in [regex]::Matches($line, $script:WtGuidRegex)) {
            $guids.Add($m.Value.ToLowerInvariant())
        }
    }
    return $guids.ToArray()
}

function Get-WtPowerSettingIndexes {
    <#
    .SYNOPSIS
        Parses a single-setting "powercfg /query <scheme> <sub> <setting>"
        block into @{ Ac; Dc } from the LAST two 0x tokens - the
        Min/Max/Increment tokens precede them and the AC then DC index
        lines are always the final two hex lines regardless of locale.
        Returns $null when fewer than two hex tokens exist.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        foreach ($m in [regex]::Matches($line, $script:WtHexIndexRegex)) {
            $tokens.Add($m.Value)
        }
    }
    if ($tokens.Count -lt 2) {
        return $null
    }
    $ac = [Convert]::ToInt32($tokens[$tokens.Count - 2].Substring(2), 16)
    $dc = [Convert]::ToInt32($tokens[$tokens.Count - 1].Substring(2), 16)
    return [PSCustomObject]@{ Ac = $ac; Dc = $dc }
}

function Get-WtActivePowerSchemeGuid {
    <#
    .SYNOPSIS
        GUID of the active power scheme (first GUID in /getactivescheme
        output), or $null on failure.
    #>
    param(
        [scriptblock]$PowercfgAction
    )

    $invokeArgs = @{ Arguments = @('/getactivescheme') }
    if ($PowercfgAction) { $invokeArgs['PowercfgAction'] = $PowercfgAction }
    $result = Invoke-WtPowercfg @invokeArgs
    if ($result.ExitCode -ne 0) { return $null }
    $guids = @(Get-WtPowercfgGuids -Lines @($result.Output))
    if ($guids.Count -eq 0) { return $null }
    return $guids[0]
}

function Test-WtPowerSchemeExists {
    <#
    .SYNOPSIS
        Does this power scheme exist at all - listed or hidden? /query
        answers it: exit 0 when it is there. NOT the same question as
        Get-WtListedPowerSchemeGuids: on a battery-powered machine the
        WinToolify copy exists and /query finds it, but /list does not
        show it, while the native Ultimate GUID is found by /query yet
        /setactive answers "Not Supported" on it. Using /list here once
        duplicated an existing, /list-hidden copy and failed with "a
        power scheme with the specified GUID already exists".
    #>
    param(
        [Parameter(Mandatory)][string]$SchemeGuid,
        [scriptblock]$PowercfgAction
    )
    $invokeArgs = @{ Arguments = @('/query', $SchemeGuid) }
    if ($PowercfgAction) { $invokeArgs['PowercfgAction'] = $PowercfgAction }
    return ((Invoke-WtPowercfg @invokeArgs).ExitCode -eq 0)
}

function Get-WtListedPowerSchemeGuids {
    <#
    .SYNOPSIS
        Every scheme GUID in /list output (empty on failure) - i.e. the
        plans Windows will actually let you switch to. For "does this
        scheme exist at all" use Test-WtPowerSchemeExists instead; a
        duplicated Ultimate plan is missing from /list on a laptop.
    #>
    param(
        [scriptblock]$PowercfgAction
    )

    $invokeArgs = @{ Arguments = @('/list') }
    if ($PowercfgAction) { $invokeArgs['PowercfgAction'] = $PowercfgAction }
    $result = Invoke-WtPowercfg @invokeArgs
    if ($result.ExitCode -ne 0) { return @() }
    return @(Get-WtPowercfgGuids -Lines @($result.Output))
}

function Get-WtPowerSettingCurrentIndexes {
    <#
    .SYNOPSIS
        Current AC/DC index of one power setting on one scheme, read via
        "/query <scheme> <sub> <setting>" and falling back to "/qh" (the
        hidden-settings variant) when /query yields no index pair - core
        parking min cores is hidden from Control Panel by default.
        Returns @{ Ac; Dc } or $null when neither works.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubGroupGuid,

        [Parameter(Mandatory)]
        [string]$SettingGuid,

        [scriptblock]$PowercfgAction
    )

    foreach ($switch in @('/query', '/qh')) {
        $invokeArgs = @{ Arguments = @($switch, $SchemeGuid, $SubGroupGuid, $SettingGuid) }
        if ($PowercfgAction) { $invokeArgs['PowercfgAction'] = $PowercfgAction }
        $result = Invoke-WtPowercfg @invokeArgs
        if ($result.ExitCode -ne 0) { continue }
        $parsed = Get-WtPowerSettingIndexes -Lines @($result.Output)
        if ($null -ne $parsed) { return $parsed }
    }
    return $null
}

function Get-WtPowerPlanCatalog {
    <#
    .SYNOPSIS
        The two Power Plan entries: unlock + activate the hidden Ultimate
        Performance plan, and disable CPU core parking on the active plan.
        Both CAUTION - higher power draw/heat is the honest consequence of
        each, and Modern-Standby laptops cannot add the Ultimate plan at all.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'PowerPlan' -Catalog @(
        [PSCustomObject]@{
            Name         = 'UltimatePerformance'
            DisplayLabel = 'Ultimate Performance plan (unlock + activate)'
            Risk         = 'CAUTION'
            Consequence  = 'Higher power draw and heat; Modern-Standby laptops list only Balanced and will report Not applied'
        }
        [PSCustomObject]@{
            Name         = 'DisableCoreParking'
            DisplayLabel = 'Disable CPU core parking (active plan)'
            Risk         = 'CAUTION'
            Consequence  = 'Keeps every core unparked on AC and DC for the active plan - higher idle power/heat, mainly useful on desktops'
        }
    )
}

function Get-WtPowerPlanState {
    <#
    .SYNOPSIS
        Live state of one Power Plan catalog entry. UltimatePerformance is
        Applied when the active scheme is the native or the WinToolify
        Ultimate GUID; DisableCoreParking when CPMINCORES on the active
        scheme reads 100/100 (unreadable = NotApplied).
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $active = Get-WtActivePowerSchemeGuid @actionArgs

    if ($Entry.Name -eq 'UltimatePerformance') {
        $applied = ($null -ne $active -and @($script:WtPowerUltimateGuid, $script:WtPowerWinToolifyUltimateGuid) -contains $active)
        return [PSCustomObject]@{ Applied = $applied }
    }

    if ($Entry.Name -eq 'DisableCoreParking') {
        if ($null -eq $active) { return [PSCustomObject]@{ Applied = $false } }
        $indexes = Get-WtPowerSettingCurrentIndexes -SchemeGuid $active -SubGroupGuid $script:WtPowerProcessorSubGroupGuid -SettingGuid $script:WtPowerCoreParkingSettings[0].Guid @actionArgs
        $applied = ($null -ne $indexes -and $indexes.Ac -eq $script:WtPowerCoreParkingUnparkedIndex -and $indexes.Dc -eq $script:WtPowerCoreParkingUnparkedIndex)
        return [PSCustomObject]@{ Applied = $applied }
    }

    return [PSCustomObject]@{ Applied = $false }
}
