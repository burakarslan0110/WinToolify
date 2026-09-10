# Disk health, sensors, Wi-Fi profile XML, licence lines, the System Health action.
# Covered by: tests/SystemHealth.Tests.ps1

# ---------------------------------------------------------------------------
# Disk & System Health bundle - System Health Report: disks
# ---------------------------------------------------------------------------

function Get-WtDiskAlarmTemperature {
    <#
    .SYNOPSIS
        Temperature at or above which a drive is flagged: 50 C for HDD,
        60 C for everything else - CrystalDiskInfo's defaults.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$MediaType
    )

    if ($MediaType -eq 'HDD') { return 50 }
    return 60
}

function Get-WtDiskHealthFlags {
    <#
    .SYNOPSIS
        Pure flag evaluator for one disk report entry: Unhealthy ->
        CRITICAL; Warning status, wear >= 90 %, uncorrected errors, or
        temperature at/above the media alarm -> WARNING. Unreported
        ($null) temperature/wear never flag.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Disk
    )

    $flags = New-Object System.Collections.Generic.List[object]

    if ($Disk.HealthStatus -eq 'Unhealthy') {
        $flags.Add([PSCustomObject]@{ Severity = 'CRITICAL'; Message = 'Windows reports this drive unhealthy' })
    }
    elseif ($Disk.HealthStatus -eq 'Warning') {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = 'Windows reports a health warning for this drive' })
    }

    if ($null -ne $Disk.WearPercent -and [int]$Disk.WearPercent -ge 90) {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = ">= 90 % of rated life used ($($Disk.WearPercent) %)" })
    }

    $readErrors = if ($null -ne $Disk.ReadErrorsUncorrected) { [long]$Disk.ReadErrorsUncorrected } else { 0 }
    $writeErrors = if ($null -ne $Disk.WriteErrorsUncorrected) { [long]$Disk.WriteErrorsUncorrected } else { 0 }
    if ($readErrors -gt 0 -or $writeErrors -gt 0) {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = "Uncorrected read/write errors (R $readErrors / W $writeErrors)" })
    }

    if ($null -ne $Disk.TemperatureC) {
        $alarm = Get-WtDiskAlarmTemperature -MediaType $Disk.MediaType
        if ([int]$Disk.TemperatureC -ge $alarm) {
            $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = "Temperature at or above $alarm C ($($Disk.TemperatureC) C)" })
        }
    }

    $severity = 'OK'
    if (@($flags | Where-Object Severity -eq 'CRITICAL').Count -gt 0) { $severity = 'CRITICAL' }
    elseif ($flags.Count -gt 0) { $severity = 'WARNING' }

    return [PSCustomObject]@{ Flags = $flags.ToArray(); Severity = $severity }
}

function Get-WtDiskHealthReport {
    <#
    .SYNOPSIS
        One entry per physical disk: Get-PhysicalDisk joined with its
        Get-StorageReliabilityCounter row by DeviceId, plus flags. A
        counter row that is missing (USB sticks, some controllers) or a
        counters call that throws leaves the reliability fields $null -
        the report never fails because one source is absent. Both calls
        are injectable since neither cmdlet exists on the macOS dev host.
    #>
    param(
        [scriptblock]$GetPhysicalDisksAction = { Get-PhysicalDisk },

        [scriptblock]$GetReliabilityCountersAction = {
            param($Disks)
            $Disks | Get-StorageReliabilityCounter
        }
    )

    $disks = @(& $GetPhysicalDisksAction)

    $counterById = @{}
    try {
        foreach ($counter in @(& $GetReliabilityCountersAction $disks)) {
            if ($null -ne $counter -and $null -ne $counter.DeviceId) {
                $counterById["$($counter.DeviceId)"] = $counter
            }
        }
    }
    catch {
        Write-Warning "Get-WtDiskHealthReport: reliability counters unavailable - $($_.Exception.Message)"
    }

    $report = New-Object System.Collections.Generic.List[object]
    foreach ($disk in $disks) {
        $counter = $counterById["$($disk.DeviceId)"]

        $temperature = $null
        $temperatureMax = $null
        $wear = $null
        $powerOnHours = $null
        $readErrors = $null
        $writeErrors = $null

        if ($counter) {
            if ($null -ne $counter.Temperature -and [int]$counter.Temperature -gt 0) { $temperature = [int]$counter.Temperature }
            if ($null -ne $counter.TemperatureMax -and [int]$counter.TemperatureMax -gt 0) { $temperatureMax = [int]$counter.TemperatureMax }
            if ($null -ne $counter.Wear -and -not ([int]$counter.Wear -eq 0 -and $disk.MediaType -eq 'HDD')) { $wear = [int]$counter.Wear }
            if ($null -ne $counter.PowerOnHours) { $powerOnHours = [long]$counter.PowerOnHours }
            if ($null -ne $counter.ReadErrorsUncorrected) { $readErrors = [long]$counter.ReadErrorsUncorrected }
            if ($null -ne $counter.WriteErrorsUncorrected) { $writeErrors = [long]$counter.WriteErrorsUncorrected }
        }

        $entry = [PSCustomObject]@{
            DeviceId               = "$($disk.DeviceId)"
            FriendlyName           = $disk.FriendlyName
            SerialNumber           = $disk.SerialNumber
            MediaType              = "$($disk.MediaType)"
            BusType                = "$($disk.BusType)"
            SizeBytes              = [long]$disk.Size
            HealthStatus           = "$($disk.HealthStatus)"
            OperationalStatus      = "$($disk.OperationalStatus)"
            TemperatureC           = $temperature
            TemperatureMaxC        = $temperatureMax
            WearPercent            = $wear
            PowerOnHours           = $powerOnHours
            ReadErrorsUncorrected  = $readErrors
            WriteErrorsUncorrected = $writeErrors
            Flags                  = @()
            Severity               = 'OK'
        }

        $flagResult = Get-WtDiskHealthFlags -Disk $entry
        $entry.Flags = $flagResult.Flags
        $entry.Severity = $flagResult.Severity
        $report.Add($entry)
    }

    return $report.ToArray()
}

function Format-WtDiskHealthLines {
    <#
    .SYNOPSIS
        Renders the disk half of the System Health Report as plain string
        lines: a heading, then per disk "[Severity] Name (media, bus,
        size)" followed by indented detail lines and one line per flag.
        Plain strings so the menu can color by the [WARNING]/[CRITICAL]
        prefix and Save-WtReport can write them unchanged.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Report
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== Disks ===')

    if ($Report.Count -eq 0) {
        $lines.Add('No physical disks reported.')
        return $lines.ToArray()
    }

    foreach ($disk in $Report) {
        $lines.Add("[$($disk.Severity)] $($disk.FriendlyName) ($($disk.MediaType), $($disk.BusType), $(Format-WtByteSize -Bytes $disk.SizeBytes))")
        $lines.Add("    Health: $($disk.HealthStatus) / $($disk.OperationalStatus)")

        $temperatureText = if ($null -ne $disk.TemperatureC) {
            if ($null -ne $disk.TemperatureMaxC) { "$($disk.TemperatureC) C (max $($disk.TemperatureMaxC) C)" } else { "$($disk.TemperatureC) C" }
        }
        else { 'n/a' }
        $lines.Add("    Temperature: $temperatureText")

        $wearText = if ($null -ne $disk.WearPercent) { "$($disk.WearPercent) %" } else { 'n/a' }
        $lines.Add("    Wear: $wearText")

        $hoursText = if ($null -ne $disk.PowerOnHours) { "$($disk.PowerOnHours)" } else { 'n/a' }
        $lines.Add("    Power-on hours: $hoursText")

        $errorText = if ($null -ne $disk.ReadErrorsUncorrected -or $null -ne $disk.WriteErrorsUncorrected) {
            "R $(if ($null -ne $disk.ReadErrorsUncorrected) { $disk.ReadErrorsUncorrected } else { 'n/a' }) / W $(if ($null -ne $disk.WriteErrorsUncorrected) { $disk.WriteErrorsUncorrected } else { 'n/a' })"
        }
        else { 'n/a' }
        $lines.Add("    Uncorrected errors: $errorText")

        foreach ($flag in @($disk.Flags)) {
            $lines.Add("    [$($flag.Severity)] $($flag.Message)")
        }
    }

    return $lines.ToArray()
}

# ---------------------------------------------------------------------------
# Disk & System Health bundle - System Health Report: sensors
# ---------------------------------------------------------------------------

function Get-WtGpuUtilizationFromEngines {
    <#
    .SYNOPSIS
        Task Manager's "GPU %" convention over the GPUEngine formatted
        perf class: sum UtilizationPercentage per engine type (the
        engtype_<Type> suffix of Name), report the busiest type. $null
        when no instance carries an engine type.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Engines
    )

    $byType = @{}
    foreach ($engine in $Engines) {
        if ("$($engine.Name)" -match 'engtype_(\w+)$') {
            $type = $Matches[1]
            if (-not $byType.ContainsKey($type)) { $byType[$type] = 0.0 }
            $byType[$type] += [double]$engine.UtilizationPercentage
        }
    }

    if ($byType.Count -eq 0) { return $null }

    $max = 0.0
    foreach ($value in $byType.Values) { if ($value -gt $max) { $max = $value } }
    return [int][math]::Round($max)
}

function Get-WtNvidiaSmiTemperature {
    <#
    .SYNOPSIS
        GPU temperature via nvidia-smi when the NVIDIA driver already ships
        it (never downloaded). $null when the tool is absent, the query
        fails, or the first line is not an integer - the report shows n/a.
    #>
    param(
        [scriptblock]$ResolveAction = {
            $command = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if ($command) { return $command.Source }
            $legacy = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
            if ($env:ProgramFiles -and (Test-Path -LiteralPath $legacy)) { return $legacy }
            return $null
        },

        [scriptblock]$QueryAction = {
            param($Path)
            $output = & $Path --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -ne 0) { throw "nvidia-smi exit code $LASTEXITCODE" }
            return @($output)
        }
    )

    try {
        $path = & $ResolveAction
        if (-not $path) { return $null }

        $lines = @(& $QueryAction $path)
        if ($lines.Count -eq 0) { return $null }

        $first = "$($lines[0])".Trim()
        if ($first -match '^\d+$') { return [int]$first }
        return $null
    }
    catch {
        return $null
    }
}

function Get-WtSensorFlags {
    <#
    .SYNOPSIS
        Pure flag evaluator for the sensor snapshot: memory used >= 90 %
        -> WARNING "High memory pressure".
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot
    )

    $flags = New-Object System.Collections.Generic.List[object]

    if ($null -ne $Snapshot.Memory.UsedPercent -and [int]$Snapshot.Memory.UsedPercent -ge 90) {
        $flags.Add([PSCustomObject]@{ Severity = 'WARNING'; Message = "High memory pressure ($($Snapshot.Memory.UsedPercent) % used)" })
    }

    $severity = if ($flags.Count -gt 0) { 'WARNING' } else { 'OK' }
    return [PSCustomObject]@{ Flags = $flags.ToArray(); Severity = $severity }
}

function Get-WtSensorSnapshot {
    <#
    .SYNOPSIS
        One-shot CPU / memory / GPU snapshot from CIM (Get-CimInstance is
        injectable since there is no CIM on the macOS dev host). Each
        query runs in its own try/catch so a missing class (VM, old
        driver) or an unsupported thermal zone leaves that section $null
        and the rest of the report intact. Never touches Get-Counter -
        counter paths are localized.
    #>
    param(
        [scriptblock]$CimQueryAction = {
            param($Namespace, $ClassName)
            Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
        },

        [scriptblock]$GpuTemperatureAction = { Get-WtNvidiaSmiTemperature }
    )

    $cpu = [PSCustomObject]@{ Name = $null; LoadPercent = $null; ClockMHz = $null; Cores = $null; LogicalProcessors = $null; TemperatureC = $null }
    $memory = [PSCustomObject]@{ TotalMB = $null; UsedMB = $null; AvailableMB = $null; UsedPercent = $null }
    $gpu = [PSCustomObject]@{ Name = $null; DriverVersion = $null; UtilizationPercent = $null; DedicatedVramUsedMB = $null; TemperatureC = $null }

    try {
        $processors = @(& $CimQueryAction 'root/cimv2' 'Win32_Processor')
        if ($processors.Count -gt 0) {
            $cpu.Name = "$($processors[0].Name)".Trim()
            $loads = @($processors | ForEach-Object { [double]$_.LoadPercentage })
            $cpu.LoadPercent = [int][math]::Round(($loads | Measure-Object -Average).Average)
            $cpu.ClockMHz = [int]$processors[0].CurrentClockSpeed
            $cpu.Cores = [int](($processors | Measure-Object -Property NumberOfCores -Sum).Sum)
            $cpu.LogicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        }
    }
    catch { }

    try {
        $zones = @(& $CimQueryAction 'root/wmi' 'MSAcpi_ThermalZoneTemperature')
        $hottest = $null
        foreach ($zone in $zones) {
            $celsius = ([double]$zone.CurrentTemperature / 10) - 273.15
            if ($null -eq $hottest -or $celsius -gt $hottest) { $hottest = $celsius }
        }
        if ($null -ne $hottest) { $cpu.TemperatureC = [int][math]::Round($hottest) }
    }
    catch { }

    try {
        $os = @(& $CimQueryAction 'root/cimv2' 'Win32_OperatingSystem')
        if ($os.Count -gt 0 -and [double]$os[0].TotalVisibleMemorySize -gt 0) {
            $totalKB = [double]$os[0].TotalVisibleMemorySize
            $freeKB = [double]$os[0].FreePhysicalMemory
            $memory.TotalMB = [int][math]::Round($totalKB / 1024)
            $memory.AvailableMB = [int][math]::Round($freeKB / 1024)
            $memory.UsedMB = [int][math]::Round(($totalKB - $freeKB) / 1024)
            $memory.UsedPercent = [int][math]::Round((($totalKB - $freeKB) / $totalKB) * 100)
        }
    }
    catch { }

    try {
        $controllers = @(& $CimQueryAction 'root/cimv2' 'Win32_VideoController')
        if ($controllers.Count -gt 0) {
            $gpu.Name = "$($controllers[0].Name)".Trim()
            $gpu.DriverVersion = "$($controllers[0].DriverVersion)"
        }
    }
    catch { }

    try {
        $engines = @(& $CimQueryAction 'root/cimv2' 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine')
        $gpu.UtilizationPercent = Get-WtGpuUtilizationFromEngines -Engines $engines
    }
    catch { }

    try {
        $adapterMemory = @(& $CimQueryAction 'root/cimv2' 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory')
        if ($adapterMemory.Count -gt 0) {
            $dedicated = ($adapterMemory | ForEach-Object { [double]$_.DedicatedUsage } | Measure-Object -Sum).Sum
            $gpu.DedicatedVramUsedMB = [int][math]::Round($dedicated / 1MB)
        }
    }
    catch { }

    try {
        $gpu.TemperatureC = & $GpuTemperatureAction
    }
    catch { }

    $snapshot = [PSCustomObject]@{
        Cpu      = $cpu
        Memory   = $memory
        Gpu      = $gpu
        Flags    = @()
        Severity = 'OK'
    }

    $flagResult = Get-WtSensorFlags -Snapshot $snapshot
    $snapshot.Flags = $flagResult.Flags
    $snapshot.Severity = $flagResult.Severity
    return $snapshot
}

function ConvertFrom-WtWifiProfileXml {
    <#
    .SYNOPSIS
        Parses an exported WLAN profile XML (netsh wlan export profile
        ... key=clear) - locale-independent, unlike scraping the
        localized "Key Content" line from netsh text output. Open
        networks have no sharedKey element and yield Key = $null.
    #>
    param([Parameter(Mandatory)][xml]$ProfileXml)

    $ns = New-Object System.Xml.XmlNamespaceManager($ProfileXml.NameTable)
    $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
    $name = $ProfileXml.SelectSingleNode('//w:WLANProfile/w:name', $ns)
    $key = $ProfileXml.SelectSingleNode('//w:sharedKey/w:keyMaterial', $ns)
    $auth = $ProfileXml.SelectSingleNode('//w:authEncryption/w:authentication', $ns)

    return [PSCustomObject]@{
        Name           = if ($name) { $name.InnerText } else { $null }
        Key            = if ($key) { $key.InnerText } else { $null }
        Authentication = if ($auth) { $auth.InnerText } else { $null }
    }
}

function Get-WtWifiProfileKey {
    <#
    .SYNOPSIS
        Exports one WLAN profile with its key in clear text into a
        private temp folder, parses it, and ALWAYS deletes the export
        again - the XML holds the passphrase in plain text.
    #>
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [scriptblock]$ExportAction = { param($Name, $Folder) netsh wlan export profile name="$Name" key=clear folder="$Folder" }
    )
    $folder = Join-Path $env:TEMP ("wt-wlan-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    try {
        & $ExportAction $ProfileName $folder | Out-Null
        $file = Get-ChildItem -Path $folder -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $file) { return [PSCustomObject]@{ Found = $false; Name = $ProfileName; Key = $null; Authentication = $null } }
        $parsed = ConvertFrom-WtWifiProfileXml -ProfileXml ([xml](Get-Content -Raw -Path $file.FullName))
        return [PSCustomObject]@{ Found = $true; Name = $parsed.Name; Key = $parsed.Key; Authentication = $parsed.Authentication }
    }
    finally {
        Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-WtLicenseInfoLines {
    <#
    .SYNOPSIS
        Windows activation summary (/xpr) and detailed license info (/dlv)
        as console lines via cscript //nologo - slmgr under wscript pops a
        GUI dialog per call, which a terminal tool must never do.
    #>
    param(
        [scriptblock]$RunSlmgrAction = { param($Switch) cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" $Switch }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($switch in '/xpr', '/dlv') {
        foreach ($line in @(& $RunSlmgrAction $switch)) {
            if ($null -ne $line -and ([string]$line).Trim()) { $lines.Add([string]$line) }
        }
        $lines.Add('')
    }
    return [string[]]$lines.ToArray()
}

function Format-WtSensorLines {
    <#
    .SYNOPSIS
        Renders the sensor snapshot as plain string lines; every $null
        field prints n/a so a partial snapshot never produces an empty
        line or an error.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot
    )

    $na = 'n/a'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== Sensors ===')
    $lines.Add("[$($Snapshot.Severity)] Sensors")

    $cpu = $Snapshot.Cpu
    $lines.Add("CPU: $(if ($cpu.Name) { $cpu.Name } else { $na })")
    $lines.Add("    Load: $(if ($null -ne $cpu.LoadPercent) { "$($cpu.LoadPercent) %" } else { $na })")
    $lines.Add("    Clock: $(if ($null -ne $cpu.ClockMHz) { "$($cpu.ClockMHz) MHz" } else { $na })")
    $lines.Add("    Cores: $(if ($null -ne $cpu.Cores) { "$($cpu.Cores) / $($cpu.LogicalProcessors) threads" } else { $na })")
    $lines.Add("    Temperature: $(if ($null -ne $cpu.TemperatureC) { "$($cpu.TemperatureC) C" } else { $na })")

    $memory = $Snapshot.Memory
    if ($null -ne $memory.TotalMB) {
        $lines.Add("Memory: $($memory.TotalMB) MB total, $($memory.UsedMB) MB used ($($memory.UsedPercent) %), $($memory.AvailableMB) MB available")
    }
    else {
        $lines.Add("Memory: $na")
    }

    $gpu = $Snapshot.Gpu
    $gpuHeading = if ($gpu.Name) { "$($gpu.Name) (driver $(if ($gpu.DriverVersion) { $gpu.DriverVersion } else { $na }))" } else { $na }
    $lines.Add("GPU: $gpuHeading")
    $lines.Add("    Utilization: $(if ($null -ne $gpu.UtilizationPercent) { "$($gpu.UtilizationPercent) %" } else { $na })")
    $lines.Add("    VRAM in use: $(if ($null -ne $gpu.DedicatedVramUsedMB) { "$($gpu.DedicatedVramUsedMB) MB" } else { $na })")
    $lines.Add("    Temperature: $(if ($null -ne $gpu.TemperatureC) { "$($gpu.TemperatureC) C" } else { $na })")

    foreach ($flag in @($Snapshot.Flags)) {
        $lines.Add("    [$($flag.Severity)] $($flag.Message)")
    }

    return $lines.ToArray()
}


function Invoke-WtSystemHealthAction {
    <#
    .SYNOPSIS
        System Health Report - read-only: disks then sensors, every
        Windows-only source degrades to n/a. Rendered in the box, with
        "S" to save it.
    #>
    param(
        [scriptblock]$GetLines = { @(Format-WtDiskHealthLines -Report (Get-WtDiskHealthReport)) + @(Format-WtSensorLines -Snapshot (Get-WtSensorSnapshot)) },
        [scriptblock]$Show = { param($Crumb, $Rows) Show-WtSavableReport -Breadcrumb $Crumb -Lines $Rows -ReportName 'health' }
    )
    $crumb = if ($script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb } else { Get-Translation 'SystemHealthReport' }
    & $Show $crumb @(& $GetLines)
}
