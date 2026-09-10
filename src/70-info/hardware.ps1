# Memory modules, GPU, battery, problem devices, motherboard/BIOS.
# Covered by: tests/InfoHardware.Tests.ps1

function Get-WtMemoryTypeName {
    <#
    .SYNOPSIS
        The DDR generation of one Win32_PhysicalMemory instance.
        SMBIOSMemoryType is authoritative; MemoryType is the fallback when
        firmware leaves SMBIOS at 0. An unrecognised number is printed raw
        rather than guessed.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$Module)
    $code = 0
    if ($Module.SMBIOSMemoryType) { $code = [int]$Module.SMBIOSMemoryType }
    elseif ($Module.MemoryType) { $code = [int]$Module.MemoryType }
    switch ($code) {
        20 { return 'DDR' }
        21 { return 'DDR2' }
        22 { return 'DDR2 FB-DIMM' }
        24 { return 'DDR3' }
        26 { return 'DDR4' }
        27 { return 'LPDDR' }
        28 { return 'LPDDR2' }
        29 { return 'LPDDR3' }
        30 { return 'LPDDR4' }
        34 { return 'DDR5' }
        35 { return 'LPDDR5' }
        default { return ((Get-Translation 'MemoryModuleTypeUnknown') -f $code) }
    }
}

function Get-WtMemoryModuleLines {
    <#
    .SYNOPSIS
        One line per physical memory stick (bank, capacity, DDR
        generation, speed, part number) plus free slots and the board's
        max capacity. The installed total sums Capacity, not
        Win32_ComputerSystem.TotalPhysicalMemory, which is the usable
        figure and would hide the firmware reservation. Sticks are told
        apart by BankLabel, since DeviceLocator can read 'DIMM 0' for both
        sticks on the same board.
    #>
    param(
        [scriptblock]$GetModules = { Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop },
        [scriptblock]$GetArrays = { Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction Stop }
    )
    $modules = @()
    try { $modules = @(& $GetModules) } catch { $modules = @() }
    if ($modules.Count -eq 0) { return [string[]]@((Get-Translation 'MemoryModuleNotAvailable')) }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'MemoryModuleHeader'))
    $installed = [long]0
    foreach ($m in $modules) {
        $capacity = [long]0
        if ($m.Capacity) { $capacity = [long]$m.Capacity }
        $installed += $capacity
        $slot = [string]$m.BankLabel
        if (-not $slot) { $slot = [string]$m.DeviceLocator }
        if (-not $slot) { $slot = '-' }
        $speedText = if ($m.Speed) { '{0} MHz' -f [int]$m.Speed } else { Get-Translation 'MemoryModuleSpeedUnknown' }
        $part = ([string]$m.PartNumber).Trim()
        if (-not $part) { $part = '-' }
        $lines.Add(('  {0}: {1} {2} {3} ({4})' -f $slot, (Format-WtByteSize -Bytes $capacity), (Get-WtMemoryTypeName -Module $m), $speedText, $part))
    }
    $lines.Add(((Get-Translation 'MemoryModuleTotalLine') -f (Format-WtByteSize -Bytes $installed), $modules.Count))

    $arrays = @()
    try { $arrays = @(& $GetArrays) } catch { $arrays = @() }
    $slots = 0
    $maxCapacityKb = [long]0
    foreach ($a in $arrays) {
        if ($a.MemoryDevices) { $slots += [int]$a.MemoryDevices }
        if ($a.MaxCapacityEx) { $maxCapacityKb += [long]$a.MaxCapacityEx }
    }
    if ($slots -gt 0) {
        $free = $slots - $modules.Count
        if ($free -lt 0) { $free = 0 }
        $lines.Add(((Get-Translation 'MemoryModuleSlotsLine') -f $slots, $free))
    }
    else { $lines.Add((Get-Translation 'MemoryModuleSlotsUnknown')) }
    if ($maxCapacityKb -gt 0) { $lines.Add(((Get-Translation 'MemoryModuleMaxLine') -f (Format-WtByteSize -Bytes ($maxCapacityKb * 1024)))) }
    return [string[]]$lines.ToArray()
}

function ConvertTo-WtVramByteCount {
    <#
    .SYNOPSIS
        HardwareInformation.qwMemorySize as a byte count. The value is a
        REG_QWORD (Int64) on most drivers and REG_BINARY (byte[]) on Intel
        and older WDDM stacks; both are decoded here since a plain
        [int64] cast throws on the byte-array form.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return [long]0 }
    if ($Value -is [byte[]]) {
        if ($Value.Length -eq 0) { return [long]0 }
        $buffer = [byte[]]::new(8)
        [System.Array]::Copy($Value, 0, $buffer, 0, [math]::Min(8, $Value.Length))
        return [long][System.BitConverter]::ToInt64($buffer, 0)
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) { return [long]$Value }
    $parsed = [long]0
    if ([long]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return [long]0
}

function Get-WtGpuVramEntries {
    <#
    .SYNOPSIS
        The display-adapter class key's VRAM values, one object per
        adapter subkey: DriverDesc + the decoded byte count. Kept apart
        from Get-WtGpuDriverLines so the formatter is testable with
        fixtures. Only the four-digit subkeys are adapters - the class key
        also carries 'Configuration' and 'Properties' siblings.
    #>
    $root = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $entries = New-Object System.Collections.Generic.List[psobject]
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        if ([string]$key.PSChildName -cnotmatch '^\d{4}$') { continue }
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }
        if (-not $props) { continue }
        $entries.Add([PSCustomObject]@{
                DriverDesc = [string]$props.DriverDesc
                Bytes      = (ConvertTo-WtVramByteCount -Value $props.'HardwareInformation.qwMemorySize')
            })
    }
    return $entries.ToArray()
}

function Get-WtGpuDriverLines {
    <#
    .SYNOPSIS
        One block per display adapter: real VRAM, driver version, driver
        date and the active display mode. AdapterRAM is not used since it
        saturates at 4 GB; a null CurrentHorizontalResolution means the
        adapter is present but drives no display, not an error, so the
        row says "not active" rather than "0x0".
    #>
    param(
        [scriptblock]$GetControllers = { Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop },
        [scriptblock]$GetVramEntries = { Get-WtGpuVramEntries }
    )
    $controllers = @()
    try { $controllers = @(& $GetControllers) } catch { $controllers = @() }
    if ($controllers.Count -eq 0) { return [string[]]@((Get-Translation 'GpuDriverNotAvailable')) }
    $vram = @()
    try { $vram = @(& $GetVramEntries) } catch { $vram = @() }

    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $controllers.Count; $i++) {
        $c = $controllers[$i]
        $name = [string]$c.Name
        if (-not $name) { $name = [string]$c.Description }
        if (-not $name) { $name = '-' }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add(((Get-Translation 'GpuDriverNameLine') -f $name))

        $bytes = [long]0
        foreach ($e in $vram) {
            if ([string]::Equals([string]$e.DriverDesc, $name, [System.StringComparison]::Ordinal)) { $bytes = [long]$e.Bytes; break }
        }
        if ($bytes -le 0 -and $i -lt $vram.Count -and $vram[$i]) { $bytes = [long]$vram[$i].Bytes }
        $vramText = if ($bytes -gt 0) { Format-WtByteSize -Bytes $bytes } else { Get-Translation 'GpuDriverVramUnknown' }
        $lines.Add(((Get-Translation 'GpuDriverVramLine') -f $vramText))

        $dateText = Get-Translation 'GpuDriverDateUnknown'
        if ($c.DriverDate) { $dateText = ([datetime]$c.DriverDate).ToString('yyyy-MM-dd') }
        $version = [string]$c.DriverVersion
        if (-not $version) { $version = '-' }
        $lines.Add(((Get-Translation 'GpuDriverVersionLine') -f $version, $dateText))

        if ($c.CurrentHorizontalResolution) {
            $lines.Add(((Get-Translation 'GpuDriverModeLine') -f [int]$c.CurrentHorizontalResolution, [int]$c.CurrentVerticalResolution, [int]$c.CurrentRefreshRate))
        }
        else { $lines.Add((Get-Translation 'GpuDriverModeInactive')) }
    }
    return [string[]]$lines.ToArray()
}

function Get-WtBatteryXmlValue {
    <#
    .SYNOPSIS
        The text of one direct child element of a battery-report node,
        found by local name, since the report carries a default namespace
        that a plain name lookup would miss.
    #>
    param(
        [Parameter(Mandatory)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string]$LocalName
    )
    foreach ($child in $Node.ChildNodes) {
        if ([string]::Equals([string]$child.LocalName, $LocalName, [System.StringComparison]::Ordinal)) { return [string]$child.InnerText }
    }
    return ''
}

function Get-WtBatteryReportXml {
    <#
    .SYNOPSIS
        Runs powercfg's battery report into %TEMP% as XML, loads it and
        deletes the file again. Returns $null when powercfg produced
        nothing readable. Uses [System.IO.File] rather than Remove-Item /
        New-Item, since the Information screen's files are scanned for
        write verbs.
    #>
    $path = [System.IO.Path]::Combine($env:TEMP, ('wt-batteryreport-{0}.xml' -f [guid]::NewGuid().ToString('N')))
    try {
        $null = & powercfg.exe /batteryreport /XML /OUTPUT $path 2>&1
        if (-not [System.IO.File]::Exists($path)) { return $null }
        $doc = [System.Xml.XmlDocument]::new()
        $doc.Load($path)
        return $doc
    }
    catch { return $null }
    finally {
        try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { $null = $_ }
    }
}

function Get-WtBatteryHealthLines {
    <#
    .SYNOPSIS
        Design capacity, full-charge capacity, wear percentage, cycle
        count and current charge - Windows ships no UI for any of it.
        Every source is wrapped, so a machine with no battery info says so
        rather than dying behind the capture pipeline. Design and full
        charge capacity come from the powercfg battery report alone,
        since Win32_Battery.DesignCapacity can come back null.
    #>
    param(
        [scriptblock]$GetBatteries = { Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop },
        [scriptblock]$GetBatteryReport = { Get-WtBatteryReportXml }
    )
    $batteries = @()
    try { $batteries = @(& $GetBatteries) } catch { $batteries = @() }
    if ($batteries.Count -eq 0) { return [string[]]@((Get-Translation 'BatteryNotFound')) }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($b in $batteries) {
        if ($null -ne $b.EstimatedChargeRemaining) { $lines.Add(((Get-Translation 'BatteryChargeLine') -f [int]$b.EstimatedChargeRemaining)) }
    }

    $xml = $null
    try { $xml = & $GetBatteryReport } catch { $xml = $null }
    $nodes = @()
    if ($xml) {
        try { $nodes = @($xml.SelectNodes("//*[local-name()='Battery']")) } catch { $nodes = @() }
    }
    if ($nodes.Count -eq 0) {
        $lines.Add((Get-Translation 'BatteryReportUnavailable'))
        return [string[]]$lines.ToArray()
    }

    foreach ($n in $nodes) {
        $id = Get-WtBatteryXmlValue -Node $n -LocalName 'Id'
        if (-not $id) { $id = '-' }
        $lines.Add(((Get-Translation 'BatteryNameLine') -f $id))

        $design = [long]0
        $null = [long]::TryParse((Get-WtBatteryXmlValue -Node $n -LocalName 'DesignCapacity'), [ref]$design)
        $full = [long]0
        $null = [long]::TryParse((Get-WtBatteryXmlValue -Node $n -LocalName 'FullChargeCapacity'), [ref]$full)
        $cycles = [long]0
        $null = [long]::TryParse((Get-WtBatteryXmlValue -Node $n -LocalName 'CycleCount'), [ref]$cycles)

        if ($design -gt 0) { $lines.Add(((Get-Translation 'BatteryDesignLine') -f $design)) }
        if ($full -gt 0) { $lines.Add(((Get-Translation 'BatteryFullChargeLine') -f $full)) }
        if ($design -gt 0 -and $full -gt 0) {
            $wear = [math]::Round((1 - ([double]$full / [double]$design)) * 100, 1)
            if ($wear -lt 0) { $wear = 0 }
            $lines.Add(((Get-Translation 'BatteryWearLine') -f ([double]$wear).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)))
        }
        else { $lines.Add((Get-Translation 'BatteryWearUnknown')) }
        if ($cycles -gt 0) { $lines.Add(((Get-Translation 'BatteryCycleLine') -f $cycles)) }
        else { $lines.Add((Get-Translation 'BatteryCycleUnknown')) }
    }
    return [string[]]$lines.ToArray()
}

function Get-WtProblemDeviceCodeText {
    <#
    .SYNOPSIS
        One CM_PROB_* error code in plain language. A code the dictionary
        has no wording for falls back to the number itself - a device
        Windows flagged is never dropped from the report just because its
        code is unusual.
    #>
    param([Parameter(Mandatory)][int]$Code)
    $text = [string](Get-Translation ('ProblemDeviceCode' + $Code))
    if ($text) { return $text }
    return ((Get-Translation 'ProblemDeviceCodeUnknown') -f $Code)
}

function Get-WtProblemDeviceLines {
    <#
    .SYNOPSIS
        Every device Device Manager would flag, with its CM_PROB error
        code translated into plain language, the device name and the
        instance path. The filter is WQL syntax ('<>', not PowerShell's
        '-ne'), filtered inside the query rather than over every PnP
        entity so the row stays instant.
    #>
    param([scriptblock]$GetDevices = { Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop })
    $devices = @()
    try { $devices = @(& $GetDevices) } catch { return [string[]]@((Get-Translation 'ProblemDeviceNotAvailable')) }
    if ($devices.Count -eq 0) { return [string[]]@((Get-Translation 'ProblemDeviceNone')) }

    $room = 95 - 4
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(((Get-Translation 'ProblemDeviceCountLine') -f $devices.Count))
    $ordered = @($devices | Sort-Object -Property @{ Expression = { [int]$_.ConfigManagerErrorCode } }, @{ Expression = { [string]$_.Name } })
    foreach ($d in $ordered) {
        $code = [int]$d.ConfigManagerErrorCode
        $lines.Add(('  {0} - {1}' -f $code, (Get-WtProblemDeviceCodeText -Code $code)))
        $name = [string]$d.Name
        if (-not $name) { $name = [string]$d.Caption }
        if (-not $name) { $name = '-' }
        if ($name.Length -gt $room) { $name = $name.Substring(0, $room - 1) + '~' }
        $lines.Add('    ' + $name)
        $id = [string]$d.DeviceID
        if ($id) {
            if ($id.Length -gt $room) { $id = $id.Substring(0, $room - 1) + '~' }
            $lines.Add('    ' + $id)
        }
    }
    return [string[]]$lines.ToArray()
}


function Get-WtMotherboardBiosLines {
    <#
    .SYNOPSIS
        Board maker, model, revision and serial, BIOS vendor / version /
        date, and the chassis type - what you need in front of you before
        a BIOS update. Win32_BIOS.SerialNumber is printed as the system
        serial.
    #>
    param(
        [scriptblock]$GetBoard = { Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1 },
        [scriptblock]$GetBios = { Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1 },
        [scriptblock]$GetEnclosure = { Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1 }
    )
    $board = $null
    try { $board = & $GetBoard } catch { $board = $null }
    $bios = $null
    try { $bios = & $GetBios } catch { $bios = $null }
    if (-not $board -and -not $bios) { return [string[]]@((Get-Translation 'BiosInfoUnavailable')) }

    $clean = { param($Value) ([string]$Value).Trim() }

    $lines = New-Object System.Collections.Generic.List[string]
    if ($board) {
        $lines.Add(('Board        : {0} {1}' -f (& $clean $board.Manufacturer), (& $clean $board.Product)))
        if (& $clean $board.Version) { $lines.Add(('Board Rev    : {0}' -f (& $clean $board.Version))) }
        if (& $clean $board.SerialNumber) { $lines.Add(('Board Serial : {0}' -f (& $clean $board.SerialNumber))) }
    }
    if ($bios) {
        $lines.Add(('BIOS         : {0} {1}' -f (& $clean $bios.Manufacturer), (& $clean $bios.SMBIOSBIOSVersion)))
        if ($bios.ReleaseDate) { $lines.Add(('BIOS Date    : {0}' -f ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd'))) }
        if (& $clean $bios.SerialNumber) { $lines.Add(('System Serial: {0}' -f (& $clean $bios.SerialNumber))) }
    }

    $enclosure = $null
    try { $enclosure = & $GetEnclosure } catch { $enclosure = $null }
    if ($enclosure -and @($enclosure.ChassisTypes).Count -gt 0) {
        $code = [int](@($enclosure.ChassisTypes)[0])
        $chassisNames = @{
            3 = 'Desktop'; 4 = 'Low Profile Desktop'; 5 = 'Pizza Box'; 6 = 'Mini Tower'; 7 = 'Tower'
            8 = 'Portable'; 9 = 'Laptop'; 10 = 'Notebook'; 11 = 'Hand Held'; 13 = 'All in One'
            14 = 'Sub Notebook'; 15 = 'Space-saving'; 16 = 'Lunch Box'; 17 = 'Main System Chassis'
            23 = 'Rack Mount Chassis'; 30 = 'Tablet'; 31 = 'Convertible'; 32 = 'Detachable'
        }
        $chassis = if ($chassisNames.ContainsKey($code)) { $chassisNames[$code] } else { "Chassis type $code" }
        $lines.Add(('Chassis      : {0}' -f $chassis))
    }
    return [string[]]$lines.ToArray()
}

# --- Information Tools > Network -------------------------------------------------
