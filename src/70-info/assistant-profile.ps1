# The assistant's machine profile: the short one rides every turn as
# system[1]; sources are injected and guarded, masked JSON stays under cap.
# Covered by: tests/AssistantProfile.Tests.ps1

function Get-WtAssistantStartupNames {
    <#
    .SYNOPSIS
        Value names of the three Run keys plus the file names of the two
        Startup folders - names only, never command lines.
    #>
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($keyPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
        $key = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
        if ($null -eq $key) { continue }
        foreach ($valueName in $key.GetValueNames()) { if ($valueName) { $names.Add([string]$valueName) } }
    }
    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            if (-not [string]::Equals($item.Name, 'desktop.ini', [System.StringComparison]::OrdinalIgnoreCase)) { $names.Add([string]$item.BaseName) }
        }
    }
    return [string[]]@($names.ToArray() | Select-Object -Unique)
}

function Get-WtAssistantInstalledProgramCount {
    <#
    .SYNOPSIS
        Distinct name|version pairs across the three Uninstall hives,
        without system components, child entries and updates. Registry
        only - the MSI CIM class reconfigures packages when enumerated.
    #>
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $name = [string]$props.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (('' + $props.SystemComponent) -ceq '1') { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$props.ParentKeyName)) { continue }
            $release = [string]$props.ReleaseType
            $isUpdate = $false
            foreach ($tag in @('Security Update', 'Update', 'Hotfix', 'ServicePack')) {
                if ([string]::Equals($tag, $release, [System.StringComparison]::OrdinalIgnoreCase)) { $isUpdate = $true; break }
            }
            if ($isUpdate) { continue }
            [void]$seen.Add($name + '|' + [string]$props.DisplayVersion)
        }
    }
    return [int]$seen.Count
}

function Get-WtAssistantNonMicrosoftTaskCount {
    $all = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    return @($all | Where-Object { -not ([string]$_.TaskPath).StartsWith('\Microsoft\', [System.StringComparison]::OrdinalIgnoreCase) }).Count
}

function Get-WtAssistantProfileData {
    <#
    .SYNOPSIS
        Gathers the raw (unmasked) profile once. -Os lets the cache
        orchestrator hand in the Win32_OperatingSystem it already read for
        the staleness check, so the warm path never queries twice. The local
        is named $osData, not $os: a bare scriptblock resolves a free
        variable through the live call stack, so a local named $os would
        shadow a test's -GetOs seam closing over its own $os.
    #>
    param(
        [AllowNull()]$Os = $null,
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop },
        [scriptblock]$GetCs = { Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop },
        [scriptblock]$GetCpuName = { [string](Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).ProcessorNameString },
        [scriptblock]$GetCoreCount = { [Environment]::ProcessorCount },
        [scriptblock]$GetGpus = { Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop },
        [scriptblock]$GetVolumes = { Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop },
        [scriptblock]$GetDisplayVersion = { [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion },
        [scriptblock]$IsAdmin = { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) },
        [scriptblock]$GetStartupNames = { Get-WtAssistantStartupNames },
        [scriptblock]$GetInstalledCount = { Get-WtAssistantInstalledProgramCount },
        [scriptblock]$GetTaskCount = { Get-WtAssistantNonMicrosoftTaskCount },
        [scriptblock]$GetPendingReboot = { (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') },
        [scriptblock]$GetDefender = { Get-MpComputerStatus -ErrorAction Stop },
        [scriptblock]$GetChanges = { @((Get-WtAssistantWintoolifyChanges).changes) },
        [datetime]$Now = (Get-Date)
    )
    $osData = $Os
    if ($null -eq $osData) { try { $osData = & $GetOs } catch { $osData = $null } }
    $cs = $null; try { $cs = & $GetCs } catch { $cs = $null }
    $cpuName = ''; try { $cpuName = ([string](& $GetCpuName)).Trim() } catch { $cpuName = '' }
    $cores = 0; try { $cores = [int](& $GetCoreCount) } catch { $cores = 0 }
    $gpus = @(); try { $gpus = @(& $GetGpus | Where-Object { $null -ne $_ }) } catch { $gpus = @() }
    $volumes = @(); try { $volumes = @(& $GetVolumes | Where-Object { $null -ne $_ }) } catch { $volumes = @() }
    $display = ''; try { $display = [string](& $GetDisplayVersion) } catch { $display = '' }
    $admin = $false; try { $admin = [bool](& $IsAdmin) } catch { $admin = $false }
    $startupNames = @(); try { $startupNames = @(& $GetStartupNames | ForEach-Object { [string]$_ }) } catch { $startupNames = @() }
    $installed = 0; try { $installed = [int](& $GetInstalledCount) } catch { $installed = 0 }
    $tasks = 0; try { $tasks = [int](& $GetTaskCount) } catch { $tasks = 0 }
    $pending = $false; try { $pending = [bool](& $GetPendingReboot) } catch { $pending = $false }
    $defender = 'unavailable'
    try {
        $status = & $GetDefender
        if ($null -ne $status) { $defender = [PSCustomObject]@{ realtime = [bool]$status.RealTimeProtectionEnabled; antivirus = [bool]$status.AntivirusEnabled } }
    }
    catch { $defender = 'unavailable' }
    $changes = @(); try { $changes = @(& $GetChanges | Where-Object { $null -ne $_ } | Select-Object -First 5) } catch { $changes = @() }
    $bootTime = ''
    $uptime = 0
    if ($null -ne $osData -and $null -ne $osData.LastBootUpTime) {
        try {
            $boot = [datetime]$osData.LastBootUpTime
            $bootTime = $boot.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $uptime = [Math]::Round(($Now - $boot).TotalHours, 1)
        }
        catch { $bootTime = ''; $uptime = 0 }
    }
    $windows = [PSCustomObject]@{
        caption = $(if ($null -ne $osData) { [string]$osData.Caption } else { '' })
        display = $display
        build   = $(if ($null -ne $osData) { [string]$osData.BuildNumber } else { '' })
        arch    = $(if ($null -ne $osData) { [string]$osData.OSArchitecture } else { '' })
    }
    $volumeRows = @(foreach ($volume in $volumes) {
        [PSCustomObject]@{ drive = [string]$volume.DeviceID; total_gb = [Math]::Round([double]$volume.Size / 1GB, 1); free_gb = [Math]::Round([double]$volume.FreeSpace / 1GB, 1) }
    })
    $gpuRows = @(foreach ($gpu in $gpus) { [PSCustomObject]@{ name = [string]$gpu.Name; driver = [string]$gpu.DriverVersion } })
    $changeRows = @(foreach ($change in $changes) {
        $when = [string]$change.when
        if ($when.Length -gt 10) { $when = $when.Substring(0, 10) }
        [PSCustomObject]@{ when = $when; action = [string]$change.action; scope = [string]$change.scope; items = [int]$change.items; restored = [bool]$change.restored }
    })
    $counts = [PSCustomObject]@{ installed_programs = $installed; startup_entries = @($startupNames).Count; nonms_tasks = $tasks }
    $ramTotal = $(if ($null -ne $osData) { [Math]::Round([double]$osData.TotalVisibleMemorySize / 1MB, 1) } else { 0 })
    $ramFree = $(if ($null -ne $osData) { [Math]::Round([double]$osData.FreePhysicalMemory / 1MB, 1) } else { 0 })
    $full = [PSCustomObject]@{
        windows = $windows
        admin = $admin
        hardware = [PSCustomObject]@{ model = $(if ($null -ne $cs) { [string]$cs.Model } else { '' }); cpu = $cpuName; cores = $cores; ram_total_gb = $ramTotal; ram_free_gb = $ramFree; gpus = $gpuRows }
        volumes = $volumeRows
        uptime_hours = $uptime
        pending_reboot = $pending
        defender = $defender
        counts = $counts
        startup_names = @($startupNames)
        wintoolify_changes = $changeRows
    }
    $short = [PSCustomObject]@{
        windows = $windows
        admin = $admin
        hardware = [PSCustomObject]@{ cpu = $cpuName; ram_total_gb = $ramTotal; gpus = @(foreach ($g in $gpuRows) { [string]$g.name }) }
        volumes = $volumeRows
        pending_reboot = $pending
        defender = $defender
        counts = $counts
        last_change = $(if ($changeRows.Count -gt 0) { $changeRows[0] } else { $null })
    }
    return @{ Full = $full; Short = $short; BootTime = $bootTime }
}

function ConvertTo-WtAssistantProfileJson {
    <#
    .SYNOPSIS
        Masked compact JSON under MaxChars. Works on a deep copy; each
        shrink step is tried only while the text is still too long; the
        last resort keeps windows + admin and says truncated.
    #>
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][hashtable]$Mask,
        [int]$MaxChars = 800
    )
    $work = ConvertTo-Json -InputObject $Profile -Depth 6 -Compress | ConvertFrom-Json
    $render = { param($Object) Protect-WtAssistantText -Text (ConvertTo-Json -InputObject $Object -Depth 6 -Compress) -Mask $Mask }
    $steps = @(
        { param($p) if ($p.PSObject.Properties.Name -contains 'startup_names') { $p.startup_names = @($p.startup_names | Select-Object -First 10) } }
        { param($p) if ($p.PSObject.Properties.Name -contains 'wintoolify_changes') { $p.wintoolify_changes = @($p.wintoolify_changes | Select-Object -First 2) } }
        { param($p) $p.hardware.gpus = @($p.hardware.gpus | Select-Object -First 2) }
        { param($p) $p.volumes = @($p.volumes | Select-Object -First 3) }
        { param($p) if ($p.PSObject.Properties.Name -contains 'startup_names') { $p.startup_names = @() } }
        { param($p) if ($p.PSObject.Properties.Name -contains 'last_change') { $p.last_change = $null } }
        { param($p) $p.volumes = @(); $p.hardware.gpus = @() }
    )
    $json = & $render $work
    foreach ($step in $steps) {
        if ($json.Length -le $MaxChars) { break }
        & $step $work
        $json = & $render $work
    }
    if ($json.Length -gt $MaxChars) {
        $json = & $render ([PSCustomObject]@{ windows = $work.windows; admin = $work.admin; truncated = $true })
    }
    return $json
}

function Test-WtAssistantProfileCacheFresh {
    <#
    .SYNOPSIS
        PURE: stale when the boot epoch changed, when the newest undo entry
        changed (the assistant or the framed TUI applied something), or when
        the build is six hours old. A cache missing either json is never
        fresh.
    #>
    param(
        [AllowNull()]$Cache,
        [AllowNull()][AllowEmptyString()][string]$BootTime = '',
        [AllowNull()][AllowEmptyString()][string]$NewestChangeId = '',
        [datetime]$Now = (Get-Date),
        [double]$MaxAgeHours = 6
    )
    if ($null -eq $Cache) { return $false }
    if (-not [string]$Cache.ShortJson -or -not [string]$Cache.FullJson) { return $false }
    $built = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Cache.BuiltAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$built)) { return $false }
    if (($Now - $built).TotalHours -ge $MaxAgeHours) { return $false }
    if (-not [string]::Equals((ConvertTo-WtIsoText -Value $Cache.BootTime), (ConvertTo-WtIsoText -Value $BootTime), [System.StringComparison]::Ordinal)) { return $false }
    if (-not [string]::Equals([string]$Cache.NewestChangeId, [string]$NewestChangeId, [System.StringComparison]::Ordinal)) { return $false }
    return $true
}

function Get-WtAssistantMachineProfile {
    <#
    .SYNOPSIS
        The cached profile: read the cache, check it against the live boot
        time and the newest undo id, rebuild cold when stale or forced
        (OnCold fires first so the REPL can print its one status line),
        otherwise serve the cached json unchanged. Never throws: a failed
        build returns an empty Json and writes no cache. Returns @{ Json;
        Cold; BuiltAt }. The local is named $osInfo, not $os: a plain
        scriptblock resolves a free variable through the live call stack at
        invocation time, so a local $os here would shadow a test's -GetOs
        seam closing over its own $os of that name.
    #>
    param(
        [ValidateSet('Short', 'Full')][string]$Kind = 'Short',
        [switch]$Force,
        [string]$TestRootOverride,
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop },
        [scriptblock]$GetNewestChangeId = { $entries = @(Get-WtUndoEntries); if ($entries.Count -gt 0) { [string]$entries[0].Id } else { '' } },
        [scriptblock]$Gather = { param($Os) Get-WtAssistantProfileData -Os $Os },
        [scriptblock]$GetMask = { Get-WtAssistantMaskContext },
        [scriptblock]$OnCold = $null,
        [datetime]$Now = (Get-Date)
    )
    $osInfo = $null; try { $osInfo = & $GetOs } catch { $osInfo = $null }
    $bootTime = ''
    if ($null -ne $osInfo -and $null -ne $osInfo.LastBootUpTime) {
        try { $bootTime = ([datetime]$osInfo.LastBootUpTime).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $bootTime = '' }
    }
    $newest = ''; try { $newest = [string](& $GetNewestChangeId) } catch { $newest = '' }
    $cache = Read-WtAssistantProfileCache -TestRootOverride $TestRootOverride
    $fresh = (-not $Force) -and (Test-WtAssistantProfileCacheFresh -Cache $cache -BootTime $bootTime -NewestChangeId $newest -Now $Now)
    if (-not $fresh) {
        if ($null -ne $OnCold) { try { & $OnCold } catch { $null = $_ } }
        try {
            $data = & $Gather $osInfo
            $mask = & $GetMask
            $cache = @{
                v = 1; BuiltAt = $Now.ToString('o'); BootTime = $bootTime; NewestChangeId = $newest
                ShortJson = (ConvertTo-WtAssistantProfileJson -Profile $data.Short -Mask $mask -MaxChars 800)
                FullJson  = (ConvertTo-WtAssistantProfileJson -Profile $data.Full -Mask $mask -MaxChars 2500)
            }
            Save-WtAssistantProfileCache -Cache $cache -TestRootOverride $TestRootOverride
        }
        catch { return @{ Json = ''; Cold = $true; BuiltAt = '' } }
    }
    $json = $(if ($Kind -eq 'Full') { [string]$cache.FullJson } else { [string]$cache.ShortJson })
    return @{ Json = $json; Cold = (-not $fresh); BuiltAt = [string]$cache.BuiltAt }
}
