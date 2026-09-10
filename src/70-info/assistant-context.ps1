# Anonymizer and structured context gatherers for the assistant's agent
# tools. Sources injected; outputs are compact objects for JSON.
# Covered by: tests/AssistantContext.Tests.ps1

function Get-WtAssistantMaskContext {
    <#
    .SYNOPSIS
        Collects, once per turn, every identity value the anonymizer
        masks: machine name, the user names this machine knows (the
        running account, the console user when elevation switched
        accounts, every C:\Users profile folder), BIOS serial, physical
        MACs. Measured: ~160 ms.
    #>
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$UserName = $env:USERNAME,
        [scriptblock]$GetSerial = { try { [string](Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber } catch { '' } },
        [scriptblock]$GetMacs = { try { @(Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' -ErrorAction Stop | ForEach-Object MACAddress | Where-Object { $_ }) } catch { @() } },
        [scriptblock]$GetConsoleUser = { try { $owner = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName; if ($owner) { $owner.Split([char]92)[-1] } else { '' } } catch { '' } },
        [scriptblock]$GetProfileNames = { try { @(Get-ChildItem -LiteralPath (Join-Path ([string]$env:SystemDrive + [string][char]92) 'Users') -Directory -ErrorAction Stop | ForEach-Object Name) } catch { @() } }
    )
    $consoleUser = ''
    try { $consoleUser = ([string](& $GetConsoleUser)).Trim() } catch { $consoleUser = '' }
    $profileNames = @()
    try { $profileNames = @(& $GetProfileNames) } catch { $profileNames = @() }
    $systemFolders = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0', 'WDAGUtilityAccount')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(@([string]$UserName) + @($consoleUser) + @($profileNames))) {
        $name = ([string]$candidate).Trim()
        if (-not $name) { continue }
        $isSystem = $false
        foreach ($folder in $systemFolders) { if ([string]::Equals($name, $folder, [System.StringComparison]::OrdinalIgnoreCase)) { $isSystem = $true; break } }
        if ($isSystem) { continue }
        if ($seen.Add($name)) { $names.Add($name) }
    }
    return @{
        ComputerName    = [string]$ComputerName
        UserName        = [string]$UserName
        ConsoleUserName = $consoleUser
        UserNames       = [string[]]$names.ToArray()
        Serial          = [string](& $GetSerial)
        Macs            = [string[]]@(& $GetMacs)
    }
}

function Protect-WtAssistantText {
    <#
    .SYNOPSIS
        Masks identity values (computer name, user names, profile paths,
        BIOS serial, MACs, public IPv4s) out of a tool result before it
        reaches the model, into deterministic tokens (<pc>, <kullanici>,
        <seri>, <mac-N>, <mac>, <ip>). A bare name is replaced only when
        both neighbouring characters are non-alphanumeric, so a short name
        does not eat pieces of ordinary text; a profile path is matched
        unanchored by length instead, in all three JSON/raw/forward-slash
        spellings. -SkipIpMask disables only the IPv4 pass - identity
        masking always stays on - for web_search/fetch_page, where a
        fetched page's own public IPv4s (e.g. a documented example
        address) must stay readable but this machine's own identity in
        that page must not leak.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][hashtable]$Mask,
        [switch]$SkipIpMask
    )
    $result = [string]$Text
    if (-not $result) { return $result }
    $replaceAll = { param([string]$Source, [string]$Old, [string]$New, [bool]$BoundaryBefore = $false, [bool]$BoundaryAfter = $false)
        if (-not $Old) { return $Source }
        $output = $Source
        $index = 0
        while (($index = $output.IndexOf($Old, $index, [System.StringComparison]::OrdinalIgnoreCase)) -ge 0) {
            $blocked = $false
            if ($BoundaryBefore -and $index -gt 0 -and [char]::IsLetterOrDigit($output[$index - 1])) { $blocked = $true }
            $tail = $index + $Old.Length
            if ($BoundaryAfter -and $tail -lt $output.Length -and [char]::IsLetterOrDigit($output[$tail])) { $blocked = $true }
            if ($blocked) { $index++; continue }
            $output = $output.Remove($index, $Old.Length).Insert($index, $New)
            $index += $New.Length
        }
        return $output
    }
    $stripToHexDigits = { param([string]$Source)
        $builder = New-Object System.Text.StringBuilder
        foreach ($ch in $Source.ToCharArray()) {
            if ([System.Uri]::IsHexDigit($ch)) { [void]$builder.Append($ch) }
        }
        return $builder.ToString()
    }
    $userName = [string]$Mask.UserName
    $userNames = @()
    if ($Mask.ContainsKey('UserNames') -and $null -ne $Mask.UserNames) { $userNames = @(@($Mask.UserNames) | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    if ($userNames.Count -eq 0 -and $userName) { $userNames = @($userName) }
    $consoleUserName = ''
    if ($Mask.ContainsKey('ConsoleUserName')) { $consoleUserName = [string]$Mask.ConsoleUserName }
    foreach ($name in $userNames) {
        $result = & $replaceAll $result ('\\Users\\' + $name) '\\Users\\<kullanici>' $false $true
        $result = & $replaceAll $result ('\Users\' + $name) '\Users\<kullanici>' $false $true
        $result = & $replaceAll $result ('/Users/' + $name) '/Users/<kullanici>' $false $true
    }
    $computerName = [string]$Mask.ComputerName
    if ($computerName.Length -ge 2) { $result = & $replaceAll $result $computerName '<pc>' $true $true }
    if ($userName.Length -ge 2) { $result = & $replaceAll $result $userName '<kullanici>' $true $true }
    if ($consoleUserName.Length -ge 2 -and -not [string]::Equals($consoleUserName, $userName, [System.StringComparison]::OrdinalIgnoreCase)) { $result = & $replaceAll $result $consoleUserName '<kullanici>' $true $true }
    $serial = [string]$Mask.Serial
    if ($serial.Length -ge 4) { $result = & $replaceAll $result $serial '<seri>' $true $true }
    $macIndex = 0
    foreach ($mac in @($Mask.Macs)) {
        $macIndex++
        $token = '<mac-' + $macIndex + '>'
        $macText = [string]$mac
        $result = & $replaceAll $result $macText $token
        $hex = & $stripToHexDigits $macText
        if ($hex.Length -eq 12) {
            $dashForm = '{0}-{1}-{2}-{3}-{4}-{5}' -f $hex.Substring(0, 2), $hex.Substring(2, 2), $hex.Substring(4, 2), $hex.Substring(6, 2), $hex.Substring(8, 2), $hex.Substring(10, 2)
            $colonForm = $dashForm.Replace('-', ':')
            $result = & $replaceAll $result $dashForm $token
            $result = & $replaceAll $result $colonForm $token
            $result = & $replaceAll $result $hex $token
        }
    }
    $result = [regex]::Replace($result, '(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])', '<mac>', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($SkipIpMask) { return $result }
    $keep = [string[]]@(Get-WtAssistantPublicResolverList)
    $evaluator = {
        param($Match)
        $a = [int]$Match.Groups[1].Value
        $b = [int]$Match.Groups[2].Value
        if ($a -gt 255 -or $b -gt 255 -or [int]$Match.Groups[3].Value -gt 255 -or [int]$Match.Groups[4].Value -gt 255) { return $Match.Value }
        if ($a -eq 10 -or $a -eq 127 -or ($a -eq 192 -and $b -eq 168) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 169 -and $b -eq 254)) { return $Match.Value }
        foreach ($k in $keep) { if ([string]::Equals($k, [string]$Match.Value, [System.StringComparison]::Ordinal)) { return $Match.Value } }
        return '<ip>'
    }
    return [regex]::Replace($result, '\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b', $evaluator)
}

function Get-WtAssistantPublicResolverList {
    <#
    .SYNOPSIS
        PURE: the well-known public resolver and ping-target addresses the
        IPv4 mask leaves readable - every DNS preset's IPv4 pair plus the
        connectivity test's ping targets. They identify a provider, never
        this machine.
    #>
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($preset in @(Get-WtDnsPresetCatalog)) {
        foreach ($ip in @([string]$preset.IPv4Primary, [string]$preset.IPv4Secondary)) { if ($ip -and -not $list.Contains($ip)) { $list.Add($ip) } }
    }
    foreach ($ip in @('1.1.1.1', '8.8.8.8', '9.9.9.9')) { if (-not $list.Contains($ip)) { $list.Add($ip) } }
    return [string[]]$list.ToArray()
}

function Test-WtAssistantTextEmpty {
    <#
    .SYNOPSIS
        PURE: a value the text serializer never writes - null, blank,
        false, an empty collection. Tokens the model would pay for and
        learn nothing from.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [bool]) { return (-not $Value) }
    if ($Value -is [string]) { return (([string]$Value).Trim().Length -eq 0) }
    if ($Value -is [System.Collections.IDictionary]) { return ($Value.Count -eq 0) }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) { return (@($Value).Count -eq 0) }
    return $false
}

function Test-WtAssistantTextScalar {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $true }
    return $false
}

function ConvertTo-WtAssistantTextScalar {
    <#
    .SYNOPSIS
        PURE: one value as the model reads it. Booleans yes/no, numbers
        and dates invariant, strings single-line with '|' replaced - a
        pipe inside a value would split a TSV row.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return 'yes' } else { return 'no' } }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return ([double]$Value).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [ValueType] -and -not ($Value -is [char])) {
        try { return [string]$Value.ToString([System.Globalization.CultureInfo]::InvariantCulture) } catch { return [string]$Value }
    }
    $text = [string]$Value
    $text = $text.Replace("`r", ' ').Replace("`n", ' ').Replace('|', '/')
    return $text.Trim()
}

function Get-WtAssistantTextProperties {
    <#
    .SYNOPSIS
        PURE: the (Name, Value) pairs of a dictionary or object in their
        own order, except that 'error' and 'hint' always lead - the model
        must read a refusal first.
    #>
    param([Parameter(Mandatory)]$Value)
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $pairs.Add(@{ Name = [string]$key; Value = $Value[$key] }) }
    }
    else {
        foreach ($property in $Value.PSObject.Properties) { $pairs.Add(@{ Name = [string]$property.Name; Value = $property.Value }) }
    }
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($first in @('error', 'hint')) {
        foreach ($p in $pairs) { if ([string]::Equals([string]$p.Name, $first, [System.StringComparison]::Ordinal)) { $ordered.Add($p) } }
    }
    foreach ($p in $pairs) {
        $name = [string]$p.Name
        if ([string]::Equals($name, 'error', [System.StringComparison]::Ordinal) -or [string]::Equals($name, 'hint', [System.StringComparison]::Ordinal)) { continue }
        $ordered.Add($p)
    }
    return $ordered.ToArray()
}

function ConvertTo-WtAssistantCompactJson {
    <#
    .SYNOPSIS
        PURE: compact JSON for the serializer's escape hatches, with
        Windows PowerShell 5.1's \u00XX escapes for < > & ' turned back
        into their characters and '|' replaced so a TSV row cannot split.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Value, [int]$Depth = 4)
    $json = [string](ConvertTo-Json -InputObject $Value -Depth $Depth -Compress)
    $bs = [char]0x5C
    $escLt = $bs + 'u003c'
    $escGt = $bs + 'u003e'
    $escAmp = $bs + 'u0026'
    $escApos = $bs + 'u0027'
    $json = $json.Replace($escLt, '<').Replace($escGt, '>').Replace($escAmp, '&').Replace($escApos, "'")
    return $json.Replace('|', '/')
}

function Add-WtAssistantTextLines {
    <#
    .SYNOPSIS
        The recursive writer behind ConvertTo-WtAssistantToolText. A
        scalar is "key: value"; a short scalar array is inline; an array
        of objects is ONE header line plus a TSV row per item; a nested
        object indents two spaces; anything deeper than two levels is
        compact json on one line.
    #>
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [AllowNull()]$Value,
        [string]$Indent = '',
        [int]$Depth = 0
    )
    if (Test-WtAssistantTextEmpty -Value $Value) { return }
    $prefix = $(if ($Name) { $Indent + $Name + ':' } else { '' })
    $childIndent = $(if ($Name) { $Indent + '  ' } else { $Indent })
    if (Test-WtAssistantTextScalar -Value $Value) {
        $Lines.Add((($prefix + ' ' + (ConvertTo-WtAssistantTextScalar -Value $Value)).TrimEnd()))
        return
    }
    $isList = ($Value -is [array] -or ($Value -is [System.Collections.IList] -and -not ($Value -is [System.Collections.IDictionary])))
    if ($isList) {
        $items = @(@($Value) | Where-Object { -not (Test-WtAssistantTextEmpty -Value $_) })
        if ($items.Count -eq 0) { return }
        $allScalar = $true
        foreach ($item in $items) { if (-not (Test-WtAssistantTextScalar -Value $item)) { $allScalar = $false; break } }
        if ($allScalar) {
            $texts = @($items | ForEach-Object { ConvertTo-WtAssistantTextScalar -Value $_ })
            $longest = 0
            foreach ($t in $texts) { if ($t.Length -gt $longest) { $longest = $t.Length } }
            if ($texts.Count -le 8 -and $longest -le 24) {
                $Lines.Add((($prefix + ' ' + ($texts -join ', ')).TrimEnd()))
                return
            }
            if ($prefix) { $Lines.Add($prefix) }
            foreach ($t in $texts) { $Lines.Add($childIndent + $t) }
            return
        }
        $columns = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) {
            if (Test-WtAssistantTextScalar -Value $item) { continue }
            foreach ($p in @(Get-WtAssistantTextProperties -Value $item)) {
                if (-not $columns.Contains([string]$p.Name)) { $columns.Add([string]$p.Name) }
            }
        }
        if ($prefix) { $Lines.Add($prefix) }
        $Lines.Add($childIndent + ($columns.ToArray() -join ' | '))
        foreach ($item in $items) {
            if (Test-WtAssistantTextScalar -Value $item) { $Lines.Add($childIndent + (ConvertTo-WtAssistantTextScalar -Value $item)); continue }
            $bag = @{}
            foreach ($p in @(Get-WtAssistantTextProperties -Value $item)) { $bag[[string]$p.Name] = $p.Value }
            $cells = New-Object System.Collections.Generic.List[string]
            foreach ($column in $columns) {
                $cell = ''
                if ($bag.ContainsKey($column)) {
                    $v = $bag[$column]
                    if (Test-WtAssistantTextScalar -Value $v) { $cell = ConvertTo-WtAssistantTextScalar -Value $v }
                    elseif (-not (Test-WtAssistantTextEmpty -Value $v)) { $cell = ConvertTo-WtAssistantCompactJson -Value $v }
                }
                $cells.Add($cell)
            }
            $Lines.Add($childIndent + ($cells.ToArray() -join ' | '))
        }
        return
    }
    if ($Depth -ge 2) {
        $Lines.Add((($prefix + ' ' + (ConvertTo-WtAssistantCompactJson -Value $Value)).TrimEnd()))
        return
    }
    if ($prefix) { $Lines.Add($prefix) }
    foreach ($p in @(Get-WtAssistantTextProperties -Value $Value)) {
        Add-WtAssistantTextLines -Lines $Lines -Name ([string]$p.Name) -Value $p.Value -Indent $childIndent -Depth ($Depth + 1)
    }
}

function ConvertTo-WtAssistantToolText {
    <#
    .SYNOPSIS
        The one serializer every tool result goes through on its way to
        the model: plain "key: value" lines and TSV rows - no braces, no
        quotes, no \u escapes, no empty fields. Oversize output is cut at
        a line boundary and says how many lines it dropped, plus the
        record's hint on how to narrow the call.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [int]$MaxChars = 2500,
        [AllowNull()][AllowEmptyString()][string]$Hint = ''
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Value) {
        if (Test-WtAssistantTextScalar -Value $Value) { $lines.Add((ConvertTo-WtAssistantTextScalar -Value $Value)) }
        else { Add-WtAssistantTextLines -Lines $lines -Name '' -Value $Value -Indent '' -Depth 0 }
    }
    if ($lines.Count -eq 0) { $lines.Add('ok') }
    $text = ($lines.ToArray() -join "`n")
    if ($MaxChars -le 0 -or $text.Length -le $MaxChars) { return $text }
    $hintText = [string]$Hint
    $reserve = 40 + $(if ($hintText) { $hintText.Length + 8 } else { 0 })
    $budget = [Math]::Max(0, $MaxChars - $reserve)
    $kept = New-Object System.Collections.Generic.List[string]
    $used = 0
    foreach ($line in $lines) {
        if ($used + $line.Length + 1 -gt $budget) { break }
        $kept.Add($line)
        $used += $line.Length + 1
    }
    $kept.Add('omitted: ' + ($lines.Count - $kept.Count) + ' lines')
    if ($hintText) { $kept.Add('hint: ' + $hintText) }
    return ($kept.ToArray() -join "`n")
}

function ConvertTo-WtAssistantBool {
    <#
    .SYNOPSIS
        The one reader for a boolean tool argument. Small local models -
        this feature's primary target - stringify booleans routinely, and
        [bool]'false' is $true in PowerShell. A value that is neither a
        recognized yes nor no falls back to Default, the caller's own
        safe direction.
    #>
    param(
        [AllowNull()]$Value,
        [bool]$Default = $false
    )
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return ([double]$Value -ne 0) }
    $text = ([string]$Value).Trim()
    if (-not $text) { return $Default }
    foreach ($no in @('false', '0', 'no', 'off', 'hayir', 'kapali')) {
        if ([string]::Equals($text, $no, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    foreach ($yes in @('true', '1', 'yes', 'on', 'evet', 'acik')) {
        if ([string]::Equals($text, $yes, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $Default
}

function Get-WtAssistantSystemOverview {
    <#
    .SYNOPSIS
        read_system topic=overview: the machine at a glance. Every source
        is injected and individually guarded - one dead WMI class costs
        its own field, never the whole overview.
    #>
    param(
        [scriptblock]$GetOs = { Get-CimInstance -ClassName Win32_OperatingSystem },
        [scriptblock]$GetCs = { Get-CimInstance -ClassName Win32_ComputerSystem },
        [scriptblock]$GetCpu = { Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1 },
        [scriptblock]$GetGpus = { Get-CimInstance -ClassName Win32_VideoController },
        [scriptblock]$GetVolumes = { Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' },
        [scriptblock]$GetDisplayVersion = { (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion },
        [scriptblock]$GetPowerPlan = { (powercfg /getactivescheme) -join ' ' },
        [scriptblock]$GetPendingReboot = { Get-WtPendingRebootLines },
        [scriptblock]$GetTopProcesses = { Get-WtTopProcessesByMemoryLines }
    )
    $os = $null; try { $os = & $GetOs } catch { $null = $_ }
    $cs = $null; try { $cs = & $GetCs } catch { $null = $_ }
    $cpu = $null; try { $cpu = & $GetCpu } catch { $null = $_ }
    $gpus = @(); try { $gpus = @(& $GetGpus) } catch { $gpus = @() }
    $volumes = @(); try { $volumes = @(& $GetVolumes) } catch { $volumes = @() }
    $display = ''; try { $display = [string](& $GetDisplayVersion) } catch { $display = '' }
    $plan = ''; try { $plan = [string](& $GetPowerPlan) } catch { $plan = '' }
    $pending = @(); try { $pending = @(& $GetPendingReboot) } catch { $pending = @() }
    $top = @(); try { $top = @(& $GetTopProcesses) } catch { $top = @() }
    $uptimeHours = 0
    if ($null -ne $os -and $null -ne $os.LastBootUpTime) {
        try { $uptimeHours = [Math]::Round(((Get-Date) - [datetime]$os.LastBootUpTime).TotalHours, 1) } catch { $uptimeHours = 0 }
    }
    $volumeRows = @(foreach ($volume in $volumes) {
        [PSCustomObject]@{
            drive = [string]$volume.DeviceID
            total_gb = [Math]::Round([double]$volume.Size / 1GB, 1)
            free_gb = [Math]::Round([double]$volume.FreeSpace / 1GB, 1)
        }
    })
    return [PSCustomObject]@{
        windows = [PSCustomObject]@{
            caption = $(if ($null -ne $os) { [string]$os.Caption } else { '' })
            display_version = $display
            build = $(if ($null -ne $os) { [string]$os.BuildNumber } else { '' })
            architecture = $(if ($null -ne $os) { [string]$os.OSArchitecture } else { '' })
        }
        hardware = [PSCustomObject]@{
            model = $(if ($null -ne $cs) { [string]$cs.Model } else { '' })
            cpu = $(if ($null -ne $cpu) { [string]$cpu.Name } else { '' })
            cores = $(if ($null -ne $cpu) { [int]$cpu.NumberOfCores } else { 0 })
            logical_processors = $(if ($null -ne $cpu) { [int]$cpu.NumberOfLogicalProcessors } else { 0 })
            ram_total_gb = $(if ($null -ne $os) { [Math]::Round([double]$os.TotalVisibleMemorySize / 1MB, 1) } else { 0 })
            ram_free_gb = $(if ($null -ne $os) { [Math]::Round([double]$os.FreePhysicalMemory / 1MB, 1) } else { 0 })
            gpus = @(foreach ($gpu in $gpus) { [PSCustomObject]@{ name = [string]$gpu.Name; driver = [string]$gpu.DriverVersion } })
        }
        volumes = $volumeRows
        uptime_hours = $uptimeHours
        power_plan = $plan
        pending_reboot = @($pending | ForEach-Object { [string]$_ })
        top_memory = @($top | ForEach-Object { [string]$_ })
    }
}

function Get-WtAssistantRecentErrors {
    <#
    .SYNOPSIS
        read_system topic=errors: error/critical events from System and
        Application, first message line only, hours clamped to [1, 168].
        Get-WinEvent throws a terminating "no events" error on a healthy
        machine, so each log is guarded on its own. MaxPerLog is enforced
        here, not only in the default seam, so an injected source cannot
        exceed the per-log limit before the digest or router see it.
    #>
    param(
        [int]$Hours = 48,
        [int]$MaxPerLog = 20,
        [scriptblock]$GetEvents = { param($LogName, $Start)
            Get-WinEvent -FilterHashtable @{ LogName = $LogName; Level = 1, 2; StartTime = $Start } -MaxEvents 20 -ErrorAction SilentlyContinue
        }
    )
    $hours = [Math]::Max(1, [Math]::Min(168, $Hours))
    $perLog = [Math]::Max(1, $MaxPerLog)
    $start = (Get-Date).AddHours(-$hours)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($log in @('System', 'Application')) {
        $logEvents = @()
        try { $logEvents = @(& $GetEvents $log $start) } catch { $logEvents = @() }
        $taken = 0
        foreach ($event in @($logEvents | Where-Object { $_ })) {
            if ($taken -ge $perLog) { break }
            $taken++
            $message = ''
            $parts = @(([string]$event.Message) -csplit "\r?\n" | Where-Object { $_.Trim() })
            if ($parts.Count -gt 0) { $message = $parts[0].Trim() }
            if ($message.Length -gt 140) { $message = $message.Substring(0, 139) + '~' }
            $when = ''
            if ($event.TimeCreated) { $when = ([datetime]$event.TimeCreated).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
            $rows.Add([PSCustomObject]@{
                time = $when; log = $log
                level = [string]$event.LevelDisplayName
                id = [int]$event.Id
                source = [string]$event.ProviderName
                message = $message
            })
        }
    }
    return [PSCustomObject]@{ hours = $hours; events = @($rows.ToArray()) }
}

function Get-WtAssistantBlueScreenHistory {
    <#
    .SYNOPSIS
        read_system topic=crashes (the history half, paired with the
        crash_analysis source): the existing localized report, verbatim -
        DRY over a second event-log walk; the model reads Turkish fine.
    #>
    param([scriptblock]$GetLines = { Get-WtBlueScreenHistoryLines -Width 120 })
    $lines = @()
    try { $lines = @(& $GetLines) } catch { $lines = @([string]$_.Exception.Message) }
    return @{ lines = @($lines | ForEach-Object { [string]$_ }) }
}

function Get-WtAssistantWintoolifyChanges {
    <#
    .SYNOPSIS
        read_system topic=wintoolify_changes: the undo log projected for
        the model. Action is the row's identity, with SectionKey/Section/
        Label kept as fallbacks, and every field stays presence-checked -
        entry shapes have grown over versions.
    #>
    param([scriptblock]$GetEntries = { Get-WtUndoEntries })
    $sourceEntries = @()
    try { $sourceEntries = @(& $GetEntries) } catch { $sourceEntries = @() }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($sourceEntries | Where-Object { $_ })) {
        $props = @($entry.PSObject.Properties.Name)
        $action = ''
        if ($props -contains 'Action') { $action = [string]$entry.Action }
        elseif ($props -contains 'Label') { $action = [string]$entry.Label }
        elseif ($props -contains 'SectionKey') { $action = [string]$entry.SectionKey }
        elseif ($props -contains 'Section') { $action = [string]$entry.Section }
        $rows.Add([PSCustomObject]@{
            id = $(if ($props -contains 'Id') { [string]$entry.Id } else { '' })
            when = $(if ($props -contains 'Timestamp') { ConvertTo-WtIsoText -Value $entry.Timestamp } else { '' })
            action = $action
            scope = $(if ($props -contains 'Scope') { [string]$entry.Scope } else { '' })
            items = $(if ($props -contains 'Items') { @($entry.Items).Count } else { 0 })
            restored = (($props -contains 'RestoredAt') -and $null -ne $entry.RestoredAt)
        })
    }
    return [PSCustomObject]@{ changes = @($rows.ToArray()) }
}

function Get-WtAssistantLineBlock {
    <#
    .SYNOPSIS
        Helper: run one line-producing seam guarded; a dead seam is an
        empty block, never a crash.
    #>
    param([Parameter(Mandatory)][scriptblock]$Source)
    $lines = @()
    try { $lines = @(& $Source) } catch { $lines = @() }
    return @($lines | ForEach-Object { [string]$_ })
}

function Get-WtAssistantStorageHealth {
    param(
        [scriptblock]$GetVolumes = { Get-WtStorageLines },
        [scriptblock]$GetDiskHealth = { Get-PhysicalDisk | ForEach-Object { ('{0}  {1}  {2}  {3}' -f [string]$_.FriendlyName, [string]$_.MediaType, [string]$_.HealthStatus, [string]$_.OperationalStatus) } },
        [scriptblock]$GetDiskErrors = { Get-WtDiskErrorEventsLines -Width 120 }
    )
    return @{
        volumes_lines = (Get-WtAssistantLineBlock -Source $GetVolumes)
        disk_health   = (Get-WtAssistantLineBlock -Source $GetDiskHealth)
        disk_errors   = (Get-WtAssistantLineBlock -Source $GetDiskErrors)
    }
}

function Get-WtAssistantNetworkStatus {
    <#
    .SYNOPSIS
        read_system topic=network / network_tests: adapters and the IP
        summary are always read; the tests that contact well-known public
        servers run ONLY for network_tests (the router passes -RunTests
        accordingly - never a boolean the model sets directly) - and the
        existing plan lines name the targets before the result lines.
    #>
    param(
        [bool]$RunTests = $false,
        [scriptblock]$GetAdapters = { Get-WtNetworkAdapterLines },
        [scriptblock]$GetIpSummary = { Get-WtIpConfigSummaryLines },
        [string]$DnsName = 'www.microsoft.com',
        [scriptblock]$GetTests = { @(Get-WtInternetTestPlanLines) + @(Get-WtInternetTestResultLines) + @(Get-WtDnsTestPlanLines -Name $DnsName) + @(Get-WtDnsTestResultLines -Name $DnsName) }
    )
    $tests = @()
    if ($RunTests) { $tests = Get-WtAssistantLineBlock -Source $GetTests }
    return @{
        adapters   = (Get-WtAssistantLineBlock -Source $GetAdapters)
        ip_summary = (Get-WtAssistantLineBlock -Source $GetIpSummary)
        tests      = $tests
    }
}

function Get-WtAssistantSecurityStatus {
    param(
        [scriptblock]$GetDefender = { Get-WtDefenderStatusLines },
        [scriptblock]$GetPosture = { Get-WtSecurityPostureLines },
        [scriptblock]$GetBootTpm = { Get-WtSecureBootTpmLines }
    )
    return @{
        defender = (Get-WtAssistantLineBlock -Source $GetDefender)
        posture  = (Get-WtAssistantLineBlock -Source $GetPosture)
        boot_tpm = (Get-WtAssistantLineBlock -Source $GetBootTpm)
    }
}

function Get-WtAssistantStartupSoftware {
    param(
        [AllowNull()][AllowEmptyString()][string]$Query = '',
        [scriptblock]$GetStartup = { Get-WtStartupProgramsLines },
        [scriptblock]$GetTasks = { Get-WtNonMicrosoftTaskLines },
        [scriptblock]$GetInstalled = { Get-WtInstalledProgramsLines }
    )
    $matched = @()
    $query = ([string]$Query).Trim()
    if ($query) {
        $installed = Get-WtAssistantLineBlock -Source $GetInstalled
        $matched = @($installed | Where-Object { ([string]$_).IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    return @{
        startup           = (Get-WtAssistantLineBlock -Source $GetStartup)
        tasks             = (Get-WtAssistantLineBlock -Source $GetTasks)
        installed_matches = $matched
    }
}

function Get-WtAssistantServiceStatus {
    <#
    .SYNOPSIS
        read_system topic=services: one named service, or the WinToolify
        service catalog's live states. A service Get-Service cannot find
        reports status 'not-found' - the model asked about it, so it must
        hear an answer, not see a dropped row.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Name = '',
        [scriptblock]$GetService = { param($ServiceName) Get-Service -Name $ServiceName -ErrorAction Stop },
        [scriptblock]$GetCatalogNames = { @((Get-WtServiceCatalog) | ForEach-Object Name) }
    )
    $names = @()
    if (([string]$Name).Trim()) { $names = @(([string]$Name).Trim()) }
    else { try { $names = @(& $GetCatalogNames) } catch { $names = @() } }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($serviceName in $names) {
        $service = $null
        try { $service = & $GetService ([string]$serviceName) } catch { $service = $null }
        if ($null -eq $service) {
            $rows.Add([PSCustomObject]@{ name = [string]$serviceName; display = ''; status = 'not-found'; start_type = '' })
            continue
        }
        $rows.Add([PSCustomObject]@{
            name = [string]$service.Name
            display = [string]$service.DisplayName
            status = [string]$service.Status
            start_type = [string]$service.StartType
        })
    }
    return @{ services = @($rows.ToArray()) }
}

function Get-WtAssistantMinidumpAnalysis {
    <#
    .SYNOPSIS
        read_system topic=crashes (the crash_analysis source): resolve
        the requested (or newest) dump and parse it; an empty folder or
        unknown name is an error object, not a throw.
    #>
    param([AllowNull()][AllowEmptyString()][string]$File = '')
    $path = Resolve-WtMinidumpRequestPath -File ([string]$File)
    if (-not $path) { return [PSCustomObject]@{ error = 'no minidump found (folder empty or unknown file name)' } }
    return Get-WtMinidumpAnalysis -Path $path
}

function Test-WtAssistantBlockedRegistryPath {
    <#
    .SYNOPSIS
        PURE allowlist: only the four hive drives, never the SAM/SECURITY
        hives or a path that names a credential store. Folded and ordinal
        (tr-TR: no -match, no -like). A '.' or '..' path segment is
        refused outright - the blocklist below is a substring match on
        the raw text and a traversal segment can otherwise detour around
        it (e.g. HKLM:\SOFTWARE\..\SECURITY never contains 'hklm:\security'
        as text, yet resolves there).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $folded = (ConvertTo-WtAssistantSearchText -Text ([string]$Path)).Replace('/', '\')
    $segments = $folded.Split('\')
    for ($i = 0; $i -lt $segments.Length; $i++) {
        $segment = $segments[$i]
        if ([string]::Equals($segment, '.', [System.StringComparison]::Ordinal) -or [string]::Equals($segment, '..', [System.StringComparison]::Ordinal)) { return $true }
        if ($segment -eq '' -and $i -gt 0 -and $i -lt ($segments.Length - 1)) { return $true }
    }
    $allowed = $false
    foreach ($root in 'hklm:\', 'hkcu:\', 'hkcr:\', 'hku:\') {
        if ($folded.StartsWith($root, [System.StringComparison]::Ordinal)) { $allowed = $true }
    }
    if (-not $allowed) { return $true }
    foreach ($blocked in 'hklm:\sam', 'hklm:\security', '\credentials', '\vault', '\policies\secrets', '\lsa\', '\winlogon', '\identitycrl', '\putty\sessions', '\snmp\parameters') {
        if ($folded.IndexOf($blocked, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

function Get-WtAssistantRegistryRead {
    <#
    .SYNOPSIS
        read_raw kind=registry: one value or a key's values + subkeys,
        read-only. Values are stringified and clipped to 200 chars each;
        the PS* note properties Get-ItemProperty adds are dropped.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Name = '',
        [scriptblock]$GetKey = { param($P) Get-Item -LiteralPath $P -ErrorAction SilentlyContinue },
        [scriptblock]$GetValues = { param($P) Get-ItemProperty -LiteralPath $P -ErrorAction SilentlyContinue }
    )
    if (Test-WtAssistantBlockedRegistryPath -Path $Path) { return [PSCustomObject]@{ error = 'registry path refused: only HKLM:/HKCU:/HKCR:/HKU: paths outside the credential hives are readable' } }
    $key = $null
    try { $key = & $GetKey $Path } catch { $key = $null }
    if ($null -eq $key) { return [PSCustomObject]@{ path = $Path; exists = $false; values = @(); subkeys = @() } }
    $valueRows = New-Object System.Collections.Generic.List[object]
    $valueBag = $null
    try { $valueBag = & $GetValues $Path } catch { $valueBag = $null }
    if ($null -ne $valueBag) {
        foreach ($property in $valueBag.PSObject.Properties) {
            $propertyName = [string]$property.Name
            if ($propertyName.StartsWith('PS', [System.StringComparison]::Ordinal)) { continue }
            if ($Name -and -not [string]::Equals($propertyName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $text = ''
            if ($null -ne $property.Value) { $text = [string]((@($property.Value) | ForEach-Object { [string]$_ }) -join ', ') }
            if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '~' }
            if (Test-WtAssistantSecretValueName -Name $propertyName) { $text = '<redacted>' }
            $type = $(if ($null -ne $property.Value) { $property.Value.GetType().Name } else { 'null' })
            $valueRows.Add([PSCustomObject]@{ name = $propertyName; type = $type; value = $text })
        }
    }
    $subkeys = @()
    $omitted = 0
    if (-not $Name) {
        try {
            $allKeys = @(@($key.SubKeyNames) | ForEach-Object { [string]$_ })
            $subkeys = @($allKeys | Select-Object -First 100)
            $omitted = [Math]::Max(0, $allKeys.Count - 100)
        }
        catch { $subkeys = @() }
    }
    $result = [ordered]@{ path = $Path; exists = $true; values = @($valueRows.ToArray()); subkeys = @($subkeys) }
    if ($omitted -gt 0) { $result['subkeys_omitted'] = $omitted }
    return [PSCustomObject]$result
}

function Get-WtAssistantProcessList {
    <#
    .SYNOPSIS
        read_system topic=processes: name/pid/RAM/CPU seconds by working
        set. CPU can throw Access Denied on a protected process - read
        per row, in a try, and report null rather than lose the row.
    #>
    param(
        [int]$Top = 20,
        [scriptblock]$GetProcesses = { Get-Process -ErrorAction SilentlyContinue }
    )
    $take = [Math]::Max(1, [Math]::Min(100, $Top))
    $allProcs = @()
    try { $allProcs = @(& $GetProcesses) } catch { $allProcs = @() }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($allProcs | Sort-Object -Property @{ Expression = { -[long]$_.WorkingSet64 } } | Select-Object -First $take)) {
        $cpu = $null
        try { if ($null -ne $p.CPU) { $cpu = [Math]::Round([double]$p.CPU, 1) } } catch { $cpu = $null }
        $rows.Add([PSCustomObject]@{ name = [string]$p.ProcessName; pid = [int]$p.Id; ram_mb = [Math]::Round([double]$p.WorkingSet64 / 1MB); cpu_seconds = $cpu })
    }
    return [PSCustomObject]@{ processes = @($rows.ToArray()); count = $allProcs.Count }
}

function Test-WtAssistantBlockedFilePath {
    <#
    .SYNOPSIS
        PURE: rooted paths only, and never a credential, key or secret
        store (Windows credential vault, SAM/SECURITY/SYSTEM hives, ntds,
        pfx/p12/kdbx, ssh keys, WinToolify's own settings.json). The
        blocklist is a substring match on the canonicalized path, so a
        '..' detour or an extended-length \\?\ prefix cannot slip a
        blocked path past it as text. Dotenv variants (.env.local, a name
        merely ending in '.env') are refused by file name, not suffix,
        since that is where API keys and database URLs live in a
        developer's tree.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $text = [string]$Path
    if (-not $text) { return $true }
    try { if (-not [System.IO.Path]::IsPathRooted($text)) { return $true } } catch { return $true }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($text) } catch { return $true }
    if ($full.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or $full.StartsWith('\\.\', [System.StringComparison]::Ordinal)) { return $true }
    if ($full.IndexOf('\..', [System.StringComparison]::Ordinal) -ge 0 -or $full.IndexOf('..\', [System.StringComparison]::Ordinal) -ge 0) { return $true }
    $folded = (ConvertTo-WtAssistantSearchText -Text $full).Replace('/', '\')
    foreach ($blocked in '\microsoft\credentials', '\microsoft\vault', '\config\sam', '\config\security', '\config\system', 'ntds.dit', '\.ssh\', 'id_rsa', 'id_ed25519', '\wintoolify\settings.json') {
        if ($folded.IndexOf($blocked, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    foreach ($suffix in '.pem', '.key', '.ppk', '.rdp', '.pfx', '.p12', '.kdbx', '\.env', '\.git-credentials', '\.npmrc', '\.netrc', '\_netrc', '\unattend.xml', '\sysprep.inf', '\login data', '\cookies', '\local state') {
        if ($folded.EndsWith($suffix, [System.StringComparison]::Ordinal)) { return $true }
    }
    $fileName = [System.IO.Path]::GetFileName($folded)
    if ($fileName.StartsWith('.env', [System.StringComparison]::Ordinal) -or $fileName.EndsWith('.env', [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-WtAssistantFileHead {
    <#
    .SYNOPSIS
        read_raw kind=file: the first N lines of a text file, reading at
        most MaxBytes (64 KB) whatever N says. StreamReader detects a BOM
        and otherwise decodes UTF-8.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$Lines = 100,
        [int]$MaxBytes = 65536
    )
    if (Test-WtAssistantBlockedFilePath -Path $Path) { return [PSCustomObject]@{ error = 'file path refused: absolute paths only, never credential or key stores' } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [PSCustomObject]@{ error = 'file not found' } }
    $want = [Math]::Max(1, [Math]::Min(500, $Lines))
    $size = 0
    try { $size = [long](Get-Item -LiteralPath $Path).Length } catch { $size = 0 }
    $rows = New-Object System.Collections.Generic.List[string]
    $truncated = $false
    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
        $read = 0
        while ($rows.Count -lt $want) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $read += [System.Text.Encoding]::UTF8.GetByteCount($line) + 2
            if ($read -gt $MaxBytes) { $truncated = $true; break }
            $rows.Add($line)
        }
        if (-not $truncated -and $null -ne $reader.ReadLine()) { $truncated = $true }
    }
    catch { return [PSCustomObject]@{ error = 'file could not be read'; detail = [string]$_.Exception.Message } }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    return [PSCustomObject]@{ path = $Path; size_bytes = $size; lines = @($rows.ToArray()); truncated = $truncated }
}

function Test-WtAssistantSecretValueName {
    <#
    .SYNOPSIS
        PURE: a registry value name that smells like a secret. Folded and
        ordinal; the VALUE is what gets redacted, the name still shows so
        the model knows the key holds one.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Name)
    $folded = ConvertTo-WtAssistantSearchText -Text ([string]$Name)
    foreach ($word in @('password', 'passwd', 'pwd', 'secret', 'token', 'apikey', 'api_key', 'credential', 'privatekey', 'private_key')) {
        if ($folded.IndexOf($word, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    }
    if ($folded.EndsWith('key', [System.StringComparison]::Ordinal) -and -not $folded.EndsWith('hotkey', [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-WtAssistantRawRead {
    <#
    .SYNOPSIS
        read_raw: kind=registry -> Get-WtAssistantRegistryRead(path, name);
        kind=file -> Get-WtAssistantFileHead(path, lines). One tool, one
        description.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Name = '',
        [int]$Lines = 100
    )
    if ([string]::Equals($Kind, 'registry', [System.StringComparison]::Ordinal)) { return (Get-WtAssistantRegistryRead -Path $Path -Name $Name) }
    if ([string]::Equals($Kind, 'file', [System.StringComparison]::Ordinal)) { return (Get-WtAssistantFileHead -Path $Path -Lines $Lines) }
    return [PSCustomObject]@{ error = 'kind must be registry or file' }
}

# ---------------------------------------------------------------------------
# read_system: the twelve read topics behind ONE tool. The handlers above
# keep returning what the TUI rows print; the digests below turn that into
# the compact objects the text serializer writes - no rulers, no footnotes,
# no padded columns, no field the model does not use.
# ---------------------------------------------------------------------------

function ConvertTo-WtAssistantModelLines {
    <#
    .SYNOPSIS
        PURE: a TUI line block for the model. Drops blank lines, dash
        rulers, headings that end in ':' and the dictionary footnotes
        named in -DropKeys (both languages); collapses padding runs to one
        space or, with -Columns, to ' | ' cells (each cut at -MaxCell with
        '~'); -Max caps the lines and reports the count dropped.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [switch]$Columns,
        [int]$Max = 0,
        [int]$MaxCell = 0,
        [AllowEmptyCollection()][string[]]$DropKeys = @()
    )
    $drop = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($DropKeys)) {
        foreach ($lang in @('EN', 'TR')) {
            $t = [string]$script:Translations[$lang][$key]
            if ($t) { $drop.Add($t.Trim()) }
        }
    }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Lines)) {
        $trimmed = ([string]$raw).Trim()
        if (-not $trimmed) { continue }
        if ([regex]::IsMatch($trimmed, '^[-=\s]{3,}$')) { continue }
        if ($trimmed.EndsWith(':')) { continue }
        $isDropped = $false
        foreach ($d in $drop) { if ([string]::Equals($trimmed, $d, [System.StringComparison]::Ordinal)) { $isDropped = $true; break } }
        if ($isDropped) { continue }
        if ($Columns) {
            $cells = @([regex]::Split($trimmed, '\s{2,}') | ForEach-Object {
                $cell = [string]$_
                if ($MaxCell -gt 1 -and $cell.Length -gt $MaxCell) { $cell = $cell.Substring(0, $MaxCell - 1) + '~' }
                $cell
            })
            $kept.Add(($cells -join ' | '))
        }
        else { $kept.Add([regex]::Replace($trimmed, '\s{2,}', ' ')) }
    }
    if ($Max -gt 0 -and $kept.Count -gt $Max) {
        $result = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $Max; $i++) { $result.Add($kept[$i]) }
        $result.Add('omitted: ' + ($kept.Count - $Max) + ' lines')
        return [string[]]$result.ToArray()
    }
    return [string[]]$kept.ToArray()
}

function ConvertFrom-WtAssistantFixedTable {
    <#
    .SYNOPSIS
        PURE: the padded tables the software/startup rows print (header,
        dash ruler, rows, blank line). Column starts come from the
        header's word positions, so a cell that fills its width still
        splits where the header says - a whitespace split cannot tell
        that apart.
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $all = @($Lines | ForEach-Object { [string]$_ })
    $ruler = -1
    for ($i = 1; $i -lt $all.Count; $i++) {
        if ([regex]::IsMatch($all[$i].Trim(), '^-{3,}$')) { $ruler = $i; break }
    }
    if ($ruler -lt 1) { return @{ Columns = [string[]]@(); Rows = @() } }
    $header = $all[$ruler - 1]
    $starts = New-Object System.Collections.Generic.List[int]
    $names = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $header.Length; $i++) {
        if ($header[$i] -eq ' ') { continue }
        if ($i -eq 0 -or $header[$i - 1] -eq ' ') { $starts.Add($i) }
    }
    for ($c = 0; $c -lt $starts.Count; $c++) {
        $from = $starts[$c]
        $to = $(if ($c + 1 -lt $starts.Count) { $starts[$c + 1] } else { $header.Length })
        $names.Add($header.Substring($from, $to - $from).Trim())
    }
    $rows = New-Object System.Collections.Generic.List[object]
    for ($r = $ruler + 1; $r -lt $all.Count; $r++) {
        $line = $all[$r]
        if (-not $line.Trim()) { break }
        $cells = New-Object System.Collections.Generic.List[string]
        for ($c = 0; $c -lt $starts.Count; $c++) {
            $from = $starts[$c]
            if ($from -ge $line.Length) { $cells.Add(''); continue }
            $to = $(if ($c + 1 -lt $starts.Count) { [Math]::Min($starts[$c + 1], $line.Length) } else { $line.Length })
            $cells.Add($line.Substring($from, $to - $from).Trim())
        }
        $rows.Add([string[]]$cells.ToArray())
    }
    return @{ Columns = [string[]]$names.ToArray(); Rows = @($rows.ToArray()) }
}

function ConvertTo-WtAssistantTableRows {
    <#
    .SYNOPSIS
        PURE: ConvertFrom-WtAssistantFixedTable's rows as objects keyed by
        the lowercased header words, cells cut at -MaxCell, at most -Take
        rows (the caller adds the omitted count).
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @(), [int]$Take = 25, [int]$MaxCell = 60)
    $table = ConvertFrom-WtAssistantFixedTable -Lines $Lines
    $columns = @($table.Columns | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cells in @($table.Rows)) {
        if ($rows.Count -ge $Take) { break }
        $row = [ordered]@{}
        for ($c = 0; $c -lt $columns.Count; $c++) {
            $cell = $(if ($c -lt @($cells).Count) { [string]$cells[$c] } else { '' })
            if ($MaxCell -gt 1 -and $cell.Length -gt $MaxCell) { $cell = $cell.Substring(0, $MaxCell - 1) + '~' }
            $row[$columns[$c]] = $cell
        }
        $rows.Add([PSCustomObject]$row)
    }
    return @{ Rows = @($rows.ToArray()); Total = @($table.Rows).Count }
}

function ConvertTo-WtAssistantPendingRebootText {
    <#
    .SYNOPSIS
        PURE: Get-WtPendingRebootLines for the model - 'no', or 'yes:'
        plus reason CODES. The rename reason names the old and the NEW
        computer name; the code carries neither (the mask only knows the
        old one).
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())
    $all = @($Lines | ForEach-Object { [string]$_ })
    if ($all.Count -eq 0) { return 'unknown' }
    $first = $all[0]
    $colon = $first.LastIndexOf(':')
    $answer = $(if ($colon -ge 0) { $first.Substring($colon + 1).Trim() } else { $first.Trim() })
    $isYes = $false
    foreach ($lang in @('EN', 'TR')) {
        $yes = [string]$script:Translations[$lang]['AnswerYes']
        if ($yes -and [string]::Equals($answer, $yes, [System.StringComparison]::OrdinalIgnoreCase)) { $isYes = $true }
    }
    if (-not $isYes) { return 'no' }
    $codes = New-Object System.Collections.Generic.List[string]
    foreach ($line in $all) {
        $t = $line.Trim()
        if (-not $t.StartsWith('- ', [System.StringComparison]::Ordinal)) { continue }
        $reason = $t.Substring(2).Trim()
        $code = 'other'
        foreach ($lang in @('EN', 'TR')) {
            $table = $script:Translations[$lang]
            if ([string]::Equals($reason, ([string]$table['PendingRebootReasonCbs']).Trim(), [System.StringComparison]::Ordinal)) { $code = 'cbs' }
            elseif ([string]::Equals($reason, ([string]$table['PendingRebootReasonWindowsUpdate']).Trim(), [System.StringComparison]::Ordinal)) { $code = 'windows_update' }
            else {
                $rename = [string]$table['PendingRebootReasonComputerName']
                $head = $rename.Split('{')[0].Trim()
                if ($head.Length -ge 8 -and $reason.StartsWith($head, [System.StringComparison]::Ordinal)) { $code = 'computer_rename' }
            }
        }
        if (-not $codes.Contains($code)) { $codes.Add($code) }
    }
    if ($codes.Count -eq 0) { return 'yes' }
    return 'yes: ' + ($codes.ToArray() -join ', ')
}

function ConvertTo-WtAssistantTopMemoryPairs {
    <#
    .SYNOPSIS
        PURE: Get-WtTopProcessesByMemoryLines rows ("name  count  size")
        as 'name size (count)' pairs; heading, column header and total
        line fall out because their middle cell is not an integer.
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @(), [int]$Take = 10)
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Lines)) {
        $cells = @([regex]::Split(([string]$raw).Trim(), '\s{2,}'))
        if ($cells.Count -ne 3) { continue }
        $count = 0
        if (-not [int]::TryParse([string]$cells[1], [ref]$count)) { continue }
        $pairs.Add([string]$cells[0] + ' ' + [string]$cells[2] + $(if ($count -gt 1) { ' (' + $count + ')' } else { '' }))
        if ($pairs.Count -ge $Take) { break }
    }
    return [string[]]$pairs.ToArray()
}

function ConvertTo-WtAssistantOverviewDigest {
    <#
    .SYNOPSIS
        The machine-at-a-glance overview reduced to one line per fact:
        OS, CPU, RAM, GPUs, volumes, uptime, the active power plan's
        name only, pending-reboot reason codes and top-memory pairs.
        GPUs and volumes are capped (4 / 8) with a '+N more' tail so an
        atypical machine cannot blow the digest's size budget.
    #>
    param([Parameter(Mandatory)]$Overview)
    $w = $Overview.windows
    $h = $Overview.hardware
    $digest = [ordered]@{}
    $osParts = @([string]$w.caption, [string]$w.display_version, $(if ([string]$w.build) { 'build ' + [string]$w.build } else { '' }), [string]$w.architecture) | Where-Object { $_ }
    $digest['os'] = (@($osParts) -join ' ')
    if ([string]$h.model) { $digest['model'] = ([string]$h.model).Trim() }
    $cpu = ([string]$h.cpu).Trim()
    if ($cpu) {
        $digest['cpu'] = $cpu + $(if ([int]$h.cores -gt 0) { ' (' + [int]$h.cores + 'c/' + [int]$h.logical_processors + 't)' } else { '' })
    }
    $digest['ram_gb'] = (ConvertTo-WtAssistantTextScalar -Value $h.ram_total_gb) + ' total, ' + (ConvertTo-WtAssistantTextScalar -Value $h.ram_free_gb) + ' free'
    $gpus = @(foreach ($g in @($h.gpus)) { ([string]$g.name).Trim() + $(if ([string]$g.driver) { ' (' + [string]$g.driver + ')' } else { '' }) })
    $gpuCap = 4
    if ($gpus.Count -gt $gpuCap) { $digest['gpu'] = ((@($gpus | Select-Object -First $gpuCap) + ('+' + ($gpus.Count - $gpuCap) + ' more')) -join '; ') }
    elseif ($gpus.Count -gt 0) { $digest['gpu'] = ($gpus -join '; ') }
    $volumes = @(foreach ($v in @($Overview.volumes)) { [string]$v.drive + ' ' + (ConvertTo-WtAssistantTextScalar -Value $v.total_gb) + ' total, ' + (ConvertTo-WtAssistantTextScalar -Value $v.free_gb) + ' free GB' })
    $volumeCap = 8
    if ($volumes.Count -gt $volumeCap) { $digest['volumes'] = ((@($volumes | Select-Object -First $volumeCap) + ('+' + ($volumes.Count - $volumeCap) + ' more')) -join '; ') }
    elseif ($volumes.Count -gt 0) { $digest['volumes'] = ($volumes -join '; ') }
    $digest['uptime_h'] = $Overview.uptime_hours
    $plan = [string]$Overview.power_plan
    $open = $plan.IndexOf('(')
    if ($open -ge 0) {
        $plan = $plan.Substring($open + 1).Trim()
        if ($plan.EndsWith(')')) { $plan = $plan.Substring(0, $plan.Length - 1) }
    }
    if ($plan) { $digest['power_plan'] = $plan.Trim() }
    $digest['pending_reboot'] = ConvertTo-WtAssistantPendingRebootText -Lines @($Overview.pending_reboot)
    $top = @(ConvertTo-WtAssistantTopMemoryPairs -Lines @($Overview.top_memory) -Take 10)
    if ($top.Count -gt 0) { $digest['top_memory'] = ($top -join ', ') }
    return $digest
}

function ConvertTo-WtAssistantErrorsDigest {
    <#
    .SYNOPSIS
        Recent event-log errors capped at -PerLog rows per log (message
        cut at 120 chars); the count dropped past that cap is reported
        as 'omitted', and 'events' reads 'none' when there were none.
    #>
    param([Parameter(Mandatory)]$Errors, [int]$PerLog = 15)
    $rows = New-Object System.Collections.Generic.List[object]
    $counts = @{}
    $omitted = 0
    foreach ($e in @($Errors.events)) {
        $log = [string]$e.log
        if (-not $counts.ContainsKey($log)) { $counts[$log] = 0 }
        if ([int]$counts[$log] -ge $PerLog) { $omitted++; continue }
        $counts[$log] = [int]$counts[$log] + 1
        $message = [string]$e.message
        if ($message.Length -gt 120) { $message = $message.Substring(0, 119) + '~' }
        $rows.Add([PSCustomObject]@{ time = [string]$e.time; log = $log; level = [string]$e.level; source = [string]$e.source; id = $e.id; message = $message })
    }
    $digest = [ordered]@{ hours = $Errors.hours }
    if ($rows.Count -eq 0) { $digest['events'] = 'none' } else { $digest['events'] = @($rows.ToArray()) }
    if ($omitted -gt 0) { $digest['omitted'] = $omitted }
    return $digest
}

function ConvertTo-WtAssistantCrashDigest {
    <#
    .SYNOPSIS
        Blue-screen history as column rows, plus, when a minidump was
        analyzed, the bugcheck / probable cause / driver stack reduced to
        one line each and the cdb dump cut at 600 chars. An analysis
        error becomes a single 'error: ...' line; the heuristic note is
        always dropped.
    #>
    param([AllowEmptyCollection()][string[]]$HistoryLines = @(), [AllowNull()]$Analysis = $null)
    $digest = [ordered]@{}
    $digest['history'] = @(ConvertTo-WtAssistantModelLines -Lines $HistoryLines -Columns -Max 18)
    if ($null -ne $Analysis) {
        $props = @($Analysis.PSObject.Properties.Name)
        if ($props -contains 'error') { $digest['analysis'] = 'error: ' + [string]$Analysis.error }
        else {
            $a = [ordered]@{ file = [string]$Analysis.file; time = [string]$Analysis.time }
            if ($null -ne $Analysis.bugcheck) {
                $head = @([string]$Analysis.bugcheck.code, [string]$Analysis.bugcheck.name) | Where-Object { $_ }
                $a['bugcheck'] = (@($head) -join ' ') + ' params ' + (@($Analysis.bugcheck.parameters | ForEach-Object { [string]$_ }) -join ' ')
            }
            if ($null -ne $Analysis.probable_cause -and [string]$Analysis.probable_cause.driver) { $a['probable_cause'] = [string]$Analysis.probable_cause.driver + ' (' + [string]$Analysis.probable_cause.via + ')' }
            $stack = @(@($Analysis.drivers_on_stack) | Sort-Object -Property @{ Expression = { -[int]$_.hits } }, @{ Expression = { [string]$_.driver } } | Select-Object -First 8 | ForEach-Object { [string]$_.driver + ' x' + [int]$_.hits })
            if ($stack.Count -gt 0) { $a['drivers_on_stack'] = ($stack -join ', ') }
            if ($props -contains 'cdb_analysis' -and [string]$Analysis.cdb_analysis) {
                $cdb = [string]$Analysis.cdb_analysis
                if ($cdb.Length -gt 600) { $cdb = $cdb.Substring(0, 599) + '~' }
                $a['cdb'] = $cdb
            }
            $digest['analysis'] = $a
        }
    }
    return $digest
}

function ConvertTo-WtAssistantStorageDigest {
    <#
    .SYNOPSIS
        Volume, disk-health and disk-error line blocks run through
        ConvertTo-WtAssistantModelLines so rulers, footnotes and padding
        never reach the model.
    #>
    param([Parameter(Mandatory)]$Storage)
    return [ordered]@{
        volumes     = @(ConvertTo-WtAssistantModelLines -Lines @($Storage.volumes_lines) -Max 12)
        disks       = @(ConvertTo-WtAssistantModelLines -Lines @($Storage.disk_health) -Columns -Max 8)
        disk_errors = @(ConvertTo-WtAssistantModelLines -Lines @($Storage.disk_errors) -Columns -Max 10)
    }
}

function ConvertTo-WtAssistantNetworkDigest {
    <#
    .SYNOPSIS
        One row per adapter (name, up/down status, IPv4, gateway, DNS)
        built from the ip summary and the adapter table, plus the test
        result lines as-is; MAC addresses and link speed never appear.
    #>
    param([Parameter(Mandatory)]$Network)
    $adapters = [ordered]@{}
    $current = ''
    foreach ($raw in @($Network.ip_summary)) {
        $line = [string]$raw
        if (-not $line.Trim()) { $current = ''; continue }
        if (-not $line.StartsWith(' ', [System.StringComparison]::Ordinal)) {
            $current = $line.Trim()
            if (-not $adapters.Contains($current)) { $adapters[$current] = [ordered]@{ name = $current; status = ''; ipv4 = ''; gateway = ''; dns = '' } }
            continue
        }
        if (-not $current) { continue }
        $colon = $line.IndexOf(':')
        if ($colon -lt 0) { continue }
        $key = $line.Substring(0, $colon).Trim()
        $value = $line.Substring($colon + 1).Trim()
        if ($value -eq '-') { $value = '' }
        if ([string]::Equals($key, 'IPv4', [System.StringComparison]::Ordinal)) { $adapters[$current].ipv4 = $value }
        elseif ([string]::Equals($key, 'Gateway', [System.StringComparison]::Ordinal)) { $adapters[$current].gateway = $value }
        elseif ([string]::Equals($key, 'DNS', [System.StringComparison]::Ordinal)) { $adapters[$current].dns = $value }
    }
    foreach ($name in @($adapters.Keys)) {
        foreach ($raw in @($Network.adapters)) {
            $row = ([string]$raw).Trim()
            if (-not $row.StartsWith($name + ' ', [System.StringComparison]::Ordinal)) { continue }
            $rest = $row.Substring($name.Length).Trim()
            $word = @([regex]::Split($rest, '\s+'))[0]
            if ([string]::Equals($word, 'Up', [System.StringComparison]::Ordinal)) { $adapters[$name].status = 'up' }
            elseif ($word) { $adapters[$name].status = 'down' }
            break
        }
    }
    $rows = @(foreach ($name in @($adapters.Keys)) { [PSCustomObject]$adapters[$name] })
    $digest = [ordered]@{}
    if ($rows.Count -eq 0) { $digest['adapters'] = 'none' } else { $digest['adapters'] = $rows }
    $tests = @(ConvertTo-WtAssistantModelLines -Lines @($Network.tests) -Max 10)
    if ($tests.Count -gt 0) { $digest['tests'] = $tests }
    return $digest
}

function Test-WtAssistantTranslatedLine {
    <#
    .SYNOPSIS
        PURE: whether a line equals the given dictionary key's text in
        EN or TR (trimmed, ordinal).
    #>
    param([AllowEmptyString()][string]$Line, [Parameter(Mandatory)][string]$Key)
    foreach ($lang in @('EN', 'TR')) {
        $t = ([string]$script:Translations[$lang][$Key]).Trim()
        if ($t -and [string]::Equals(([string]$Line).Trim(), $t, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function ConvertTo-WtAssistantSecurityDigest {
    <#
    .SYNOPSIS
        Defender / posture / boot lines for the model. The Remote Desktop
        Users line carries account names and e-mails - it becomes a
        count. The 'net accounts' dump (fixed line order: 0 force
        logoff, 1 min age, 2 max age, 3 min length, 4 history, 5 lockout
        threshold, 6 duration, 7 window, 8 role) becomes three integers
        (min_len, max_age_days, lockout_threshold); anything that is not
        an integer is 'n/a'.
    #>
    param([Parameter(Mandatory)]$Security)
    $digest = [ordered]@{}
    $digest['defender'] = @(ConvertTo-WtAssistantModelLines -Lines @($Security.defender) -Max 10)
    $posture = New-Object System.Collections.Generic.List[string]
    $policy = New-Object System.Collections.Generic.List[string]
    $inPolicy = $false
    foreach ($raw in @($Security.posture)) {
        $line = ([string]$raw).Trim()
        if (-not $line) { continue }
        if (Test-WtAssistantTranslatedLine -Line $line -Key 'PostureSectionPasswordPolicy') { $inPolicy = $true; continue }
        if ($inPolicy) {
            $colon = $line.LastIndexOf(':')
            if ($colon -lt 0) { continue }
            $value = $line.Substring($colon + 1).Trim()
            $n = 0
            $policy.Add($(if ([int]::TryParse($value, [ref]$n)) { [string]$n } else { 'n/a' }))
            continue
        }
        if ((Test-WtAssistantTranslatedLine -Line $line -Key 'PostureSectionUac') -or (Test-WtAssistantTranslatedLine -Line $line -Key 'PostureSectionRemote')) { continue }
        $colon = $line.IndexOf(':')
        if ($colon -gt 0) {
            $label = $line.Substring(0, $colon).Trim()
            if (Test-WtAssistantTranslatedLine -Line $label -Key 'PostureRdpUsersLabel') {
                $value = $line.Substring($colon + 1).Trim()
                $count = '0'
                if (Test-WtAssistantTranslatedLine -Line $value -Key 'SecStateUnknown') { $count = 'unknown' }
                elseif ($value -and -not (Test-WtAssistantTranslatedLine -Line $value -Key 'PostureRdpUsersEmpty')) { $count = [string]@($value.Split(',') | Where-Object { $_.Trim() }).Count }
                $posture.Add($label + ': ' + $count)
                continue
            }
        }
        $posture.Add([regex]::Replace($line, '\s{2,}', ' '))
    }
    $digest['posture'] = @($posture.ToArray())
    if ($policy.Count -ge 6) { $digest['password_policy'] = 'min_len ' + $policy[3] + ', max_age_days ' + $policy[2] + ', lockout_threshold ' + $policy[5] }
    $digest['boot_tpm'] = @(ConvertTo-WtAssistantModelLines -Lines @($Security.boot_tpm) -Max 8)
    return $digest
}

function ConvertTo-WtAssistantStartupDigest {
    <#
    .SYNOPSIS
        Startup entries, scheduled tasks and installed-software matches
        as padded tables turned into header + rows, cells cut at 60
        chars; footnotes and count lines fall out, and
        installed_matches is omitted entirely when there is nothing to
        report.
    #>
    param([Parameter(Mandatory)]$Startup)
    $digest = [ordered]@{}
    $startupTable = ConvertTo-WtAssistantTableRows -Lines @($Startup.startup) -Take 25 -MaxCell 60
    $digest['startup'] = $(if (@($startupTable.Rows).Count -gt 0) { @($startupTable.Rows) } else { 'none' })
    if ($startupTable.Total -gt 25) { $digest['startup_omitted'] = $startupTable.Total - 25 }
    $tasks = ConvertTo-WtAssistantTableRows -Lines @($Startup.tasks) -Take 15 -MaxCell 60
    if (@($tasks.Rows).Count -gt 0) { $digest['tasks'] = @($tasks.Rows) }
    if ($tasks.Total -gt 15) { $digest['tasks_omitted'] = $tasks.Total - 15 }
    $installedTable = ConvertTo-WtAssistantTableRows -Lines @($Startup.installed_matches) -Take 15 -MaxCell 60
    if (@($installedTable.Rows).Count -gt 0) { $digest['installed_matches'] = @($installedTable.Rows) }
    elseif (@($Startup.installed_matches).Count -gt 0) { $digest['installed_matches'] = @(ConvertTo-WtAssistantModelLines -Lines @($Startup.installed_matches) -Columns -Max 15 -MaxCell 60) }
    return $digest
}

function ConvertTo-WtAssistantServicesDigest {
    <#
    .SYNOPSIS
        A single named service (matched by -Filter down to one row)
        becomes one object with its display name; otherwise the whole
        catalog becomes rows without the display name, to keep the list
        compact.
    #>
    param([Parameter(Mandatory)]$Services, [AllowNull()][AllowEmptyString()][string]$Filter = '')
    $rows = @($Services.services)
    if (([string]$Filter).Trim() -and $rows.Count -eq 1) {
        $s = $rows[0]
        return [ordered]@{ name = [string]$s.name; display = [string]$s.display; status = [string]$s.status; start_type = [string]$s.start_type }
    }
    return [ordered]@{ services = @(foreach ($s in $rows) { [PSCustomObject]@{ name = [string]$s.name; status = [string]$s.status; start = [string]$s.start_type } }) }
}

function ConvertTo-WtAssistantProcessesDigest {
    <#
    .SYNOPSIS
        The top-processes list with short column names (name, pid,
        ram_mb, cpu_s) plus the total process count on the machine.
    #>
    param([Parameter(Mandatory)]$Processes)
    return [ordered]@{
        processes = @(foreach ($p in @($Processes.processes)) { [PSCustomObject]@{ name = [string]$p.name; pid = $p.pid; ram_mb = $p.ram_mb; cpu_s = $p.cpu_seconds } })
        count = $Processes.count
    }
}

function ConvertTo-WtAssistantChangesDigest {
    <#
    .SYNOPSIS
        WinToolify's own change log capped at the newest -Take entries
        (default 10) alongside the true total, so the model can ask for
        more without re-reading everything.
    #>
    param([Parameter(Mandatory)]$Changes, [int]$Take = 10)
    $all = @($Changes.changes)
    $takeClamped = [Math]::Max(1, $Take)
    $rows = @($all | Select-Object -First $takeClamped | ForEach-Object { [PSCustomObject]@{ id = [string]$_.id; when = [string]$_.when; action = [string]$_.action; scope = [string]$_.scope; items = $_.items; restored = [bool]$_.restored } })
    $digest = [ordered]@{}
    $digest['changes'] = $(if ($rows.Count -gt 0) { $rows } else { 'none' })
    $digest['total'] = $all.Count
    return $digest
}

function ConvertTo-WtAssistantStatusDigest {
    <#
    .SYNOPSIS
        WinToolify's applied/total counters per section as one
        'applied/total' string each, dropping the section's display
        title and omitting not_present when it is zero.
    #>
    param([Parameter(Mandatory)]$Status)
    $rows = @(foreach ($s in @($Status.sections)) {
        $row = [ordered]@{ section = [string]$s.section; applied = ([string]$s.applied + '/' + [string]$s.total) }
        if ([int]$s.not_present -gt 0) { $row['not_present'] = [int]$s.not_present }
        [PSCustomObject]$row
    })
    return [ordered]@{ sections = $rows; total = ([string]$Status.applied_total + '/' + [string]$Status.total) }
}

function Get-WtAssistantReadTopicMaxChars {
    <#
    .SYNOPSIS
        PURE: the read_system per-topic size ceiling.
        Get-WtAssistantSystemRead stamps this onto every successful
        digest as '_max_chars'; Invoke-WtAssistantToolCall reads it back
        and cuts with it instead of the registry record's generic
        MaxChars, so each topic gets its own designed budget. An unknown
        topic returns 0, so the record's generic MaxChars backstops it
        there instead.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Topic)
    $ceilings = @{
        overview = 900; errors = 1500; crashes = 1500; storage = 900
        network = 900; network_tests = 1200; security = 700; startup = 1200
        services = 1200; processes = 900; wintoolify_changes = 900; wintoolify_status = 900
    }
    if ($ceilings.ContainsKey($Topic)) { return [int]$ceilings[$Topic] }
    return 0
}

function Get-WtAssistantSystemRead {
    <#
    .SYNOPSIS
        read_system: one topic per call, routed to the gatherer above and
        reduced by its digest. -Filter is topic-specific (hours / name /
        count / dump file); -Sources injects gatherers for tests. Every
        successful digest is stamped with '_max_chars' so the dispatch
        cuts by the topic's own ceiling, not the tool's generic one.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Topic,
        [AllowNull()][AllowEmptyString()][string]$Filter = '',
        [AllowNull()][hashtable]$Sources = $null
    )
    $filterText = ([string]$Filter).Trim()
    $count = 0
    $hasCount = [int]::TryParse($filterText, [ref]$count) -and $count -gt 0
    $defaults = @{
        overview           = { Get-WtAssistantSystemOverview }
        errors             = { param($F) $h = 48; $n = 0; if ([int]::TryParse([string]$F, [ref]$n) -and $n -gt 0) { $h = $n }; Get-WtAssistantRecentErrors -Hours $h }
        crash_history      = { Get-WtAssistantBlueScreenHistory }
        crash_analysis     = { param($F) Get-WtAssistantMinidumpAnalysis -File ([string]$F) }
        storage            = { Get-WtAssistantStorageHealth }
        network            = { Get-WtAssistantNetworkStatus -RunTests:$false }
        network_tests      = { Get-WtAssistantNetworkStatus -RunTests:$true -GetTests { @(Get-WtInternetTestResultLines) + @(Get-WtDnsTestResultLines -Name 'www.microsoft.com') } }
        security           = { Get-WtAssistantSecurityStatus }
        startup            = { param($F) Get-WtAssistantStartupSoftware -Query ([string]$F) }
        services           = { param($F) Get-WtAssistantServiceStatus -Name ([string]$F) }
        processes          = { param($F) $t = 20; $n = 0; if ([int]::TryParse([string]$F, [ref]$n) -and $n -gt 0) { $t = $n }; Get-WtAssistantProcessList -Top $t }
        wintoolify_changes = { Get-WtAssistantWintoolifyChanges }
        wintoolify_status  = { Get-WtAssistantWintoolifyStatus }
    }
    $run = { param($Key, $F)
        $block = $defaults[$Key]
        if ($null -ne $Sources -and $Sources.ContainsKey($Key)) { $block = $Sources[$Key] }
        return (& $block $F)
    }
    $digest = $null
    switch -CaseSensitive ($Topic) {
        'overview' { $digest = ConvertTo-WtAssistantOverviewDigest -Overview (& $run 'overview' $filterText) }
        'errors' { $digest = ConvertTo-WtAssistantErrorsDigest -Errors (& $run 'errors' $filterText) }
        'crashes' {
            $history = & $run 'crash_history' $filterText
            $analysis = & $run 'crash_analysis' $filterText
            if ($null -ne $analysis -and -not $filterText -and (@($analysis.PSObject.Properties.Name) -contains 'error')) { $analysis = $null }
            $digest = ConvertTo-WtAssistantCrashDigest -HistoryLines @($history.lines) -Analysis $analysis
        }
        'storage' { $digest = ConvertTo-WtAssistantStorageDigest -Storage (& $run 'storage' $filterText) }
        'network' { $digest = ConvertTo-WtAssistantNetworkDigest -Network (& $run 'network' $filterText) }
        'network_tests' { $digest = ConvertTo-WtAssistantNetworkDigest -Network (& $run 'network_tests' $filterText) }
        'security' { $digest = ConvertTo-WtAssistantSecurityDigest -Security (& $run 'security' $filterText) }
        'startup' { $digest = ConvertTo-WtAssistantStartupDigest -Startup (& $run 'startup' $filterText) }
        'services' { $digest = ConvertTo-WtAssistantServicesDigest -Services (& $run 'services' $filterText) -Filter $filterText }
        'processes' { $digest = ConvertTo-WtAssistantProcessesDigest -Processes (& $run 'processes' $filterText) }
        'wintoolify_changes' { $digest = ConvertTo-WtAssistantChangesDigest -Changes (& $run 'wintoolify_changes' $filterText) -Take $(if ($hasCount) { $count } else { 10 }) }
        'wintoolify_status' { $digest = ConvertTo-WtAssistantStatusDigest -Status (& $run 'wintoolify_status' $filterText) }
        default { $digest = $null }
    }
    if ($null -ne $digest) {
        $digest['_max_chars'] = Get-WtAssistantReadTopicMaxChars -Topic $Topic
        return $digest
    }
    return [ordered]@{ error = ('unknown topic: ' + $Topic); hint = ('topics: ' + ((Get-WtAssistantReadTopics) -join ', ')) }
}
