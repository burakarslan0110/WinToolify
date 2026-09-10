# Service start-type templates and Invoke-WtApplyServiceSelection.
# Covered by: tests/ApplyEngine.Tests.ps1

function Get-WtServiceTemplateStart {
    <#
    .SYNOPSIS
        Start value of a per-user service TEMPLATE key (the instance
        "<Template>_<LUID>" is recreated at every logon, so only the
        template's Start value persists - Microsoft's documented way).
    #>
    param(
        [Parameter(Mandatory)][string]$Template,
        [scriptblock]$GetValue = { param($p) (Get-ItemProperty -LiteralPath $p -Name 'Start' -ErrorAction SilentlyContinue).Start }
    )
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Template
    $v = & $GetValue $path
    if ($null -eq $v) { return $null }
    return [int]$v
}

function Set-WtServiceTemplateStart {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][int]$Start,
        [scriptblock]$SetValue = { param($p, $v) New-ItemProperty -LiteralPath $p -Name 'Start' -PropertyType DWord -Value $v -Force -ErrorAction Stop | Out-Null }
    )
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Template
    & $SetValue $path $Start
}

function Get-WtServiceTargetStartType {
    <#
    .SYNOPSIS
        PURE: the start type one selected service should end up on. A
        name $Targets does not mention - a profile import, or a row
        marked with A - keeps the historical meaning of "selected":
        Disabled. An unknown word also falls back to Disabled.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][hashtable]$Targets
    )
    if ($null -eq $Targets -or -not $Targets.ContainsKey($Name)) { return 'Disabled' }
    $target = [string]$Targets[$Name]
    if (@('Disabled', 'Manual', 'Automatic') -notcontains $target) { return 'Disabled' }
    return $target
}

function ConvertTo-WtServiceStartValue {
    <#
    .SYNOPSIS
        PURE: start type -> the Start REG_DWORD a per-user service
        TEMPLATE key needs (2 = Automatic, 3 = Manual, 4 = Disabled).
    #>
    param([Parameter(Mandatory)][ValidateSet('Disabled', 'Manual', 'Automatic')][string]$StartType)
    switch ($StartType) {
        'Automatic' { return 2 }
        'Manual'    { return 3 }
        default     { return 4 }
    }
}

function Invoke-WtApplyServiceSelection {
    <#
    .SYNOPSIS
        Wires the Apps & Services selector to Invoke-WtGuardedChange:
        sets each selected service to the start type -Targets maps it to
        (absent means Disabled), resolving per-user template names to
        their live instance first. Disabled also stops the service,
        Automatic also starts it.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames,
        [hashtable]$Targets = @{}
    )

    $catalog = Get-WtServiceCatalog

    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($name in $SelectedNames) {
            $entry = $catalog | Where-Object Name -eq $name
            if (-not $entry) { continue }
            $state = Get-WtServiceState -Name $entry.Name -IsPerUser $entry.IsPerUser
            if (-not $state.Present) { continue }
            $items.Add([PSCustomObject]@{
                ItemType              = 'Service'
                Name                  = $state.Name
                Template              = $entry.Name
                IsPerUser             = $entry.IsPerUser
                TargetStartType       = (Get-WtServiceTargetStartType -Name $entry.Name -Targets $Targets)
                PreviousStatus        = $state.Status
                PreviousStartType     = $state.StartType
                PreviousTemplateStart = $(if ($entry.IsPerUser) { Get-WtServiceTemplateStart -Template $entry.Name } else { $null })
            })
        }
        return $items.ToArray()
    }

    $apply = {
        param($Item)
        $target = [string]$Item.TargetStartType
        Set-Service -Name $Item.Name -StartupType $target -ErrorAction Stop
        if ($Item.IsPerUser) { Set-WtServiceTemplateStart -Template $Item.Template -Start (ConvertTo-WtServiceStartValue -StartType $target) }
        if ($target -eq 'Disabled') { Stop-Service -Name $Item.Name -Force -ErrorAction Stop }
        elseif ($target -eq 'Automatic') { Start-Service -Name $Item.Name -ErrorAction Stop }
    }

    $reReadState = {
        param($Item)
        $state = Get-WtServiceState -Name $Item.Name
        if (-not $state.Present -or $state.StartType -ne [string]$Item.TargetStartType) { return $false }
        switch ([string]$Item.TargetStartType) {
            'Disabled'  { return ($state.Status -eq 'Stopped') }
            'Automatic' { return ($state.Status -eq 'Running') }
            default     { return $true }
        }
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName 'Set Service Start Type'
}
