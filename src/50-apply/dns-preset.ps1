# Adapter DNS configuration and preset apply.
# Covered by: tests/DnsPreset.Tests.ps1

function Set-WtDnsAdapterConfiguration {
    <#
    .SYNOPSIS
        Applies one preset to one adapter in three independent,
        individually-caught steps: IPv4 servers, then IPv6, then (if
        DohSupported) DoH per address. Windows ships Cloudflare/Google/
        Quad9 on the known-DoH list with AutoUpgrade off, and Add- cannot
        re-add a listed address; on failure the address is switched in
        place with Set-DnsClientDohServerAddress and reported as
        Modified, so undo restores the recorded entry instead of
        removing it. Returns @{ AddedDohAddresses; ModifiedDohAddresses }.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,

        [Parameter(Mandatory)]
        [PSCustomObject]$Preset,

        [Parameter(Mandatory)]
        [bool]$DohSupported,

        [scriptblock]$SetIPv4Action = {
            param($InterfaceIndex, $Addresses)
            Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $Addresses
        },

        [scriptblock]$SetIPv6Action = {
            param($InterfaceIndex, $Addresses)
            Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $Addresses
        },

        [scriptblock]$AddDohAction = {
            param($ServerAddress, $DohTemplate)
            Add-DnsClientDohServerAddress -ServerAddress $ServerAddress -DohTemplate $DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true
        },

        [scriptblock]$SetDohAction = {
            param($ServerAddress, $DohTemplate)
            Set-DnsClientDohServerAddress -ServerAddress $ServerAddress -DohTemplate $DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true
        }
    )

    try {
        & $SetIPv4Action $Item.InterfaceIndex @($Preset.IPv4Primary, $Preset.IPv4Secondary)
    }
    catch { }

    try {
        & $SetIPv6Action $Item.InterfaceIndex @($Preset.IPv6Primary, $Preset.IPv6Secondary)
    }
    catch { }

    $addedDoh = New-Object System.Collections.Generic.List[string]
    $modifiedDoh = New-Object System.Collections.Generic.List[string]
    if ($DohSupported) {
        foreach ($address in @($Preset.IPv4Primary, $Preset.IPv4Secondary, $Preset.IPv6Primary, $Preset.IPv6Secondary)) {
            try {
                & $AddDohAction $address $Preset.DohTemplate
                $addedDoh.Add($address)
            }
            catch {
                try {
                    & $SetDohAction $address $Preset.DohTemplate
                    $modifiedDoh.Add($address)
                }
                catch { }
            }
        }
    }

    return [PSCustomObject]@{ AddedDohAddresses = $addedDoh.ToArray(); ModifiedDohAddresses = $modifiedDoh.ToArray() }
}

function Invoke-WtApplyDnsPreset {
    <#
    .SYNOPSIS
        Wires the Network Privacy "DNS Preset" action to
        Invoke-WtGuardedChange: names the adapters that will change and
        requires the typed-YES gate before proceeding (a DNS preset can
        sever internal/VPN name resolution, so it gets its own explicit
        disclosure on top of the restore-point offer), applies via
        Set-WtDnsAdapterConfiguration per adapter, and flushes DNS only
        when the guarded change actually ran.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PresetName,

        [switch]$SkipConfirmation
    )

    $preset = (Get-WtDnsPresetCatalog) | Where-Object Name -eq $PresetName
    if (-not $preset) {
        return [PSCustomObject]@{ Aborted = $true; Results = @() }
    }

    $dohSupported = Test-WtDohSupported
    $adapterItems = Get-WtDnsAdapterCaptureState -Preset $preset -DohSupported $dohSupported
    $adapterNames = ($adapterItems | ForEach-Object { "Adapter $($_.InterfaceIndex)" }) -join ', '

    if (-not $SkipConfirmation) {
        if (-not (Confirm-WtDestructiveAction -Consequence ((Get-Translation 'DnsChangeConsequence') -f $adapterNames, $PresetName))) {
            return [PSCustomObject]@{ Aborted = $true; Results = @() }
        }
    }

    $captureState = { return $adapterItems }

    $apply = {
        param($Item)
        Set-WtDnsAdapterConfiguration -Item $Item -Preset $preset -DohSupported $dohSupported | Out-Null
    }

    $reReadState = {
        param($Item)
        $currentIPv4 = @(Get-DnsClientServerAddress -InterfaceIndex $Item.InterfaceIndex -AddressFamily 'IPv4').ServerAddresses
        return (@($currentIPv4) -join ',') -eq (@($preset.IPv4Primary, $preset.IPv4Secondary) -join ',')
    }

    $result = Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName 'Apply DNS Preset'

    if (-not $result.Aborted) {
        Clear-DnsClientCache
        if (-not $dohSupported) {
            $result | Add-Member -NotePropertyName 'DohDowngradeDisclosed' -NotePropertyValue $true -Force
        }
    }

    return $result
}
