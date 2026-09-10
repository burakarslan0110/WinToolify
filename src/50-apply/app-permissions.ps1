# Invoke-WtApplyAppPermissionSelection.
# Covered by: tests/AiAndPermissionCatalogs.Tests.ps1

function Invoke-WtApplyAppPermissionSelection {
    <#
    .SYNOPSIS
        Wires the App Permissions Capability Defaults selector to
        Invoke-WtGuardedChange: writes -Value ('Deny' by default) to each
        selected capability's ConsentStore Value, one Registry undo item
        per capability. -Value 'Allow' with a Revert action name is the
        TurnOff path, so Restore-WtUndoEntry writes Deny back.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames,

        [ValidateSet('Deny', 'Allow')]
        [string]$Value = 'Deny',

        [string]$ActionName = 'Apply App Permission Defaults'
    )

    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($capability in $SelectedNames) {
            $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capability"
            $current = Get-WtRegistryValue -Path $path -Name 'Value'
            $items.Add([PSCustomObject]@{
                ItemType        = 'Registry'
                Path            = $path
                Name            = 'Value'
                RegType         = 'String'
                PreviousPresent = $current.Present
                PreviousValue   = $current.Value
            })
        }
        return $items.ToArray()
    }

    $apply = {
        param($Item)
        Set-WtRegistryValue -Path $Item.Path -Name $Item.Name -RegType 'String' -Value $Value
    }

    $reReadState = {
        param($Item)
        $current = Get-WtRegistryValue -Path $Item.Path -Name $Item.Name
        return ($current.Present -and $current.Value -eq $Value)
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName $ActionName
}
