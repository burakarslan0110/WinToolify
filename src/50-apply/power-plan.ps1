# Power plan apply/restore/remove.
# Covered by: tests/PowerPlan.Tests.ps1

function Assert-WtPowercfgSucceeded {
    <#
    .SYNOPSIS
        Throws with powercfg's own output when a result carries a non-zero
        exit code - Invoke-WtGuardedChange records the message as the
        item's Error, so the row shows Not applied with the real reason.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Result.ExitCode -ne 0) {
        $detail = (@($Result.Output) -join [Environment]::NewLine).Trim()
        if (-not $detail) { $detail = "exit code $($Result.ExitCode)" }
        throw "$Context failed: $detail"
    }
}

function Get-WtPowerPlanCaptureState {
    <#
    .SYNOPSIS
        Pre-change capture for the Power Plan selection: everything undo
        needs is decided here, since Invoke-WtGuardedChange serializes the
        undo entry before Apply runs. Returns @{ Items; Skipped }, with
        unreadable settings listed in Skipped rather than written blind.
        UltimatePerformance is checked via /list ("can we switch to the
        native Ultimate plan?") and /query ("does our own copy already
        exist?"), because on some machines each command sees a plan the
        other misses.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedNames,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $items = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[string]

    $active = Get-WtActivePowerSchemeGuid @actionArgs
    $coreParkingScheme = $active

    if ($SelectedNames -contains 'UltimatePerformance') {
        $listed = @(Get-WtListedPowerSchemeGuids @actionArgs)
        $target = $script:WtPowerWinToolifyUltimateGuid
        $created = $script:WtPowerWinToolifyUltimateGuid
        if ($listed -contains $script:WtPowerUltimateGuid) {
            $target = $script:WtPowerUltimateGuid
            $created = $null
        }
        elseif (Test-WtPowerSchemeExists -SchemeGuid $script:WtPowerWinToolifyUltimateGuid @actionArgs) {
            $created = $null
        }
        $items.Add([PSCustomObject]@{
            ItemType             = 'PowerPlan'
            CatalogEntry         = 'UltimatePerformance'
            PreviousActiveScheme = $active
            TargetScheme         = $target
            CreatedScheme        = $created
        })
        $coreParkingScheme = $target
    }

    if ($SelectedNames -contains 'DisableCoreParking' -and -not $coreParkingScheme) {
        foreach ($setting in $script:WtPowerCoreParkingSettings) { $skipped.Add($setting.Label) }
    }

    if ($SelectedNames -contains 'DisableCoreParking' -and $coreParkingScheme) {
        foreach ($setting in $script:WtPowerCoreParkingSettings) {
            $indexes = Get-WtPowerSettingCurrentIndexes -SchemeGuid $coreParkingScheme -SubGroupGuid $script:WtPowerProcessorSubGroupGuid -SettingGuid $setting.Guid @actionArgs
            if ($null -eq $indexes) {
                $skipped.Add($setting.Label)
                continue
            }
            $items.Add([PSCustomObject]@{
                ItemType     = 'PowerSetting'
                CatalogEntry = 'DisableCoreParking'
                SchemeGuid   = $coreParkingScheme
                SubGroupGuid = $script:WtPowerProcessorSubGroupGuid
                SettingGuid  = $setting.Guid
                SettingLabel = $setting.Label
                PreviousAc   = $indexes.Ac
                PreviousDc   = $indexes.Dc
            })
        }
    }

    return [PSCustomObject]@{ Items = $items.ToArray(); Skipped = $skipped.ToArray() }
}

function Set-WtPowerSettingIndexes {
    <#
    .SYNOPSIS
        Writes one setting's AC and DC index on one scheme, then
        re-activates that scheme ONLY when it is the active one (index
        changes on the active plan need the re-activation to take effect;
        on an inactive plan an unconditional /setactive would silently
        switch the user's plan). Shared by apply and undo.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubGroupGuid,

        [Parameter(Mandatory)]
        [string]$SettingGuid,

        [Parameter(Mandatory)]
        [int]$AcIndex,

        [Parameter(Mandatory)]
        [int]$DcIndex,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $ac = Invoke-WtPowercfg -Arguments @('/setacvalueindex', $SchemeGuid, $SubGroupGuid, $SettingGuid, "$AcIndex") @actionArgs
    Assert-WtPowercfgSucceeded -Result $ac -Context "powercfg /setacvalueindex $SettingGuid"
    $dc = Invoke-WtPowercfg -Arguments @('/setdcvalueindex', $SchemeGuid, $SubGroupGuid, $SettingGuid, "$DcIndex") @actionArgs
    Assert-WtPowercfgSucceeded -Result $dc -Context "powercfg /setdcvalueindex $SettingGuid"

    if ((Get-WtActivePowerSchemeGuid @actionArgs) -eq $SchemeGuid) {
        $refresh = Invoke-WtPowercfg -Arguments @('/setactive', $SchemeGuid) @actionArgs
        Assert-WtPowercfgSucceeded -Result $refresh -Context 'powercfg /setactive'
    }
}

function Invoke-WtApplyPowerPlanItem {
    <#
    .SYNOPSIS
        The -Apply delegate for one captured Power Plan item. PowerPlan
        duplicates the hidden Ultimate policy (if CreatedScheme is set) and
        activates the target, throwing on any non-zero exit. PowerSetting
        checks the scheme via /query rather than /list (the just-activated
        plan can be a hidden copy /list would miss), then writes 100/100
        via Set-WtPowerSettingIndexes.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    if ($Item.ItemType -eq 'PowerPlan') {
        if ($Item.CreatedScheme) {
            $dup = Invoke-WtPowercfg -Arguments @('/duplicatescheme', $script:WtPowerUltimateGuid, $Item.CreatedScheme) @actionArgs
            Assert-WtPowercfgSucceeded -Result $dup -Context 'powercfg /duplicatescheme'
            $rename = Invoke-WtPowercfg -Arguments @('/changename', $Item.CreatedScheme, 'Ultimate Performance (WinToolify)', "Windows' hidden Ultimate Performance plan, unlocked by WinToolify") @actionArgs
            Assert-WtPowercfgSucceeded -Result $rename -Context 'powercfg /changename'
        }
        $activate = Invoke-WtPowercfg -Arguments @('/setactive', $Item.TargetScheme) @actionArgs
        Assert-WtPowercfgSucceeded -Result $activate -Context 'powercfg /setactive'
        return
    }

    if ($Item.ItemType -eq 'PowerSetting') {
        if (-not (Test-WtPowerSchemeExists -SchemeGuid $Item.SchemeGuid @actionArgs)) {
            throw "Power plan $($Item.SchemeGuid) is not available - core parking skipped"
        }
        Set-WtPowerSettingIndexes -SchemeGuid $Item.SchemeGuid -SubGroupGuid $Item.SubGroupGuid -SettingGuid $Item.SettingGuid -AcIndex $script:WtPowerCoreParkingUnparkedIndex -DcIndex $script:WtPowerCoreParkingUnparkedIndex @actionArgs
        return
    }

    throw "Unknown power item type '$($Item.ItemType)'"
}

function Test-WtPowerPlanItemApplied {
    <#
    .SYNOPSIS
        The -ReReadState delegate body: PowerPlan is applied when the
        active scheme equals TargetScheme; PowerSetting when the setting
        reads 100/100 - a post-apply re-read, never the command's own
        success.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    if ($Item.ItemType -eq 'PowerPlan') {
        return ((Get-WtActivePowerSchemeGuid @actionArgs) -eq $Item.TargetScheme)
    }
    if ($Item.ItemType -eq 'PowerSetting') {
        $indexes = Get-WtPowerSettingCurrentIndexes -SchemeGuid $Item.SchemeGuid -SubGroupGuid $Item.SubGroupGuid -SettingGuid $Item.SettingGuid @actionArgs
        return ($null -ne $indexes -and $indexes.Ac -eq $script:WtPowerCoreParkingUnparkedIndex -and $indexes.Dc -eq $script:WtPowerCoreParkingUnparkedIndex)
    }
    return $false
}

function Restore-WtPowerPlanItem {
    <#
    .SYNOPSIS
        Undo for a PowerPlan item: re-activate the previously active scheme
        (throw on failure), then delete the copy this run created (best
        effort - a failed delete leaves a harmless extra plan behind).
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $activate = Invoke-WtPowercfg -Arguments @('/setactive', $Item.PreviousActiveScheme) @actionArgs
    Assert-WtPowercfgSucceeded -Result $activate -Context 'powercfg /setactive'
    if ($Item.CreatedScheme) {
        Invoke-WtPowercfg -Arguments @('/delete', $Item.CreatedScheme) @actionArgs | Out-Null
    }
}

function Restore-WtPowerSettingItem {
    <#
    .SYNOPSIS
        Undo for a PowerSetting item: write back the recorded AC/DC indexes
        (re-activating the scheme only if it is the active one).
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    Set-WtPowerSettingIndexes -SchemeGuid $Item.SchemeGuid -SubGroupGuid $Item.SubGroupGuid -SettingGuid $Item.SettingGuid -AcIndex ([int]$Item.PreviousAc) -DcIndex ([int]$Item.PreviousDc) @actionArgs
}

function Invoke-WtApplyPowerPlanSelection {
    <#
    .SYNOPSIS
        Wires the Power Plan selector to Invoke-WtGuardedChange with the
        capture / apply / re-read pieces above. Adds the capture's Skipped
        labels to the returned result so the menu can say "Skipped -
        current value unreadable".
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames,

        [scriptblock]$PowercfgAction
    )

    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }

    $capture = Get-WtPowerPlanCaptureState -SelectedNames $SelectedNames @actionArgs

    $captureState = { return $capture.Items }
    $apply = { param($Item) Invoke-WtApplyPowerPlanItem -Item $Item @actionArgs }
    $reReadState = { param($Item) return (Test-WtPowerPlanItemApplied -Item $Item @actionArgs) }

    $result = Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName 'Apply Power Plan Settings'
    $result | Add-Member -NotePropertyName 'Skipped' -NotePropertyValue @($capture.Skipped) -Force
    return $result
}

function Invoke-WtRemovePowerPlanSelection {
    <#
    .SYNOPSIS
        TurnOff for the Power Plan section: UltimatePerformance activates
        Windows' Balanced plan (the WinToolify copy is left in place so
        undo can re-activate it), reusing the apply path's delegates.
        DisableCoreParking has no known default and is ignored here
        (IsRemovable keeps it unmarkable).
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames,
        [scriptblock]$PowercfgAction
    )
    $actionArgs = @{}
    if ($PowercfgAction) { $actionArgs['PowercfgAction'] = $PowercfgAction }
    $captureState = {
        if ($SelectedNames -notcontains 'UltimatePerformance') { return @() }
        $active = Get-WtActivePowerSchemeGuid @actionArgs
        return @(
            [PSCustomObject]@{
                ItemType             = 'PowerPlan'
                CatalogEntry         = 'UltimatePerformance'
                PreviousActiveScheme = $active
                TargetScheme         = $script:WtPowerBalancedGuid
                CreatedScheme        = $null
            }
        )
    }
    $apply = { param($Item) Invoke-WtApplyPowerPlanItem -Item $Item @actionArgs }
    $reReadState = { param($Item) return (Test-WtPowerPlanItemApplied -Item $Item @actionArgs) }
    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName 'Revert Power Plan Settings'
}
