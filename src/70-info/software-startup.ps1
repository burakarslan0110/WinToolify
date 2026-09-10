# Installed programs, startup entries, scheduled tasks, installed updates.
# Covered by: tests/InfoSoftwareStartup.Tests.ps1

function Format-WtSoftwareCell {
    <#
    .SYNOPSIS
        PURE: one fixed-width table cell for the Software and startup
        rows. Truncates with '~' - the same mark the panel itself uses -
        and pads with spaces, so a caller can size its columns against
        Get-WtPanelInnerWidth instead of the hard-coded 100 that
        Out-String assumes. CR/LF/TAB are folded to a space first, since
        a Run value or task Execute path may legally contain them and a
        raw newline would break the table into two mis-aligned rows; the
        fold uses -creplace, never -replace, since a culture-aware
        compare matches differently under tr-TR.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    if ($Width -lt 1) { return '' }
    $value = if ($null -eq $Text) { '' } else { [string]$Text }
    $value = $value -creplace '[\r\n\t]+', ' '
    if ($value.Length -gt $Width) {
        if ($Width -eq 1) { return '~' }
        return ($value.Substring(0, $Width - 1) + '~')
    }
    return $value.PadRight($Width)
}

function Get-WtInstalledProgramsLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: the classic desktop program inventory, over the three
        Uninstall roots Get-WtUninstallRegistryRoots owns - HKLM,
        HKLM\WOW6432Node and Registry::HKEY_USERS\<SID>. The MSI
        product-enumeration API is never used, since enumerating it makes
        Windows Installer reconfigure every installed package, and the
        retired WMI cmdlet is banned (absent in PowerShell 7). Under
        elevation HKCU is the ADMIN's hive, so the interactive user's
        entries come via Get-WtConsoleUserSid; with no SID the row says so
        rather than quietly showing a short list. Injected results are
        captured as @($raw), never @(& $Action), which would double-wrap a
        comma-protected array.
    #>
    param(
        [scriptblock]$GetUninstallEntries = {
            param($Path)
            $out = New-Object System.Collections.Generic.List[object]
            foreach ($k in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if ($props) { $out.Add($props) }
            }
            return , $out.ToArray()
        },
        [scriptblock]$GetUserSid = { Get-WtConsoleUserSid },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $roots = @()
    try { $roots = @(Get-WtUninstallRegistryRoots -GetUserSid $GetUserSid) } catch { $roots = @() }
    $hasUserHive = $false
    foreach ($root in $roots) {
        if ([string]::Equals([string]$root.ScopeKey, 'UninstallScopeUser', [System.StringComparison]::Ordinal)) { $hasUserHive = $true; break }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $skipReleaseTypes = @('Security Update', 'Update', 'Hotfix', 'ServicePack')
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        $entries = @()
        try {
            $raw = & $GetUninstallEntries $root.Path
            $entries = if ($null -eq $raw) { @() } else { @($raw) }
        }
        catch { $entries = @() }
        foreach ($entry in $entries) {
            if (-not $entry) { continue }
            $name = [string]$entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (('' + $entry.SystemComponent) -ceq '1') { continue }
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.ParentKeyName)) { continue }
            $release = [string]$entry.ReleaseType
            $isUpdate = $false
            foreach ($type in $skipReleaseTypes) {
                if ([string]::Equals($type, $release, [System.StringComparison]::OrdinalIgnoreCase)) { $isUpdate = $true; break }
            }
            if ($isUpdate) { continue }
            $version = [string]$entry.DisplayVersion
            if (-not $seen.Add($name + '|' + $version)) { continue }
            $rows.Add([PSCustomObject]@{
                    SortKey   = $name.ToUpperInvariant()
                    Name      = $name
                    Version   = $version
                    Publisher = [string]$entry.Publisher
                })
        }
    }

    if ($rows.Count -eq 0) {
        $lines.Add((Get-Translation 'InstalledProgramsNone'))
        if (-not $hasUserHive) { $lines.Add((Get-Translation 'InstalledProgramsNoUserHive')) }
        return [string[]]$lines.ToArray()
    }

    $verWidth = 14
    $pubWidth = 24
    $nameWidth = [Math]::Max(20, $Width - $verWidth - $pubWidth - 2)
    $total = $nameWidth + $verWidth + $pubWidth + 2

    $lines.Add(((Get-Translation 'InstalledProgramsCount') -f $rows.Count))
    if (-not $hasUserHive) { $lines.Add((Get-Translation 'InstalledProgramsNoUserHive')) }
    $lines.Add('')
    $lines.Add((((Format-WtSoftwareCell -Text 'Name' -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text 'Version' -Width $verWidth) + ' ' + (Format-WtSoftwareCell -Text 'Publisher' -Width $pubWidth)).TrimEnd()))
    $lines.Add('-' * [Math]::Min($total, [Math]::Max(20, $Width)))
    foreach ($row in ($rows | Sort-Object -Property SortKey)) {
        $lines.Add((((Format-WtSoftwareCell -Text $row.Name -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Version -Width $verWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Publisher -Width $pubWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'InstalledProgramsFootnote'))
    return [string[]]$lines.ToArray()
}

function Test-WtStartupEntryEnabled {
    <#
    .SYNOPSIS
        PURE: is a Run / Startup-folder entry enabled, given its
        StartupApproved value (or $null when Explorer has never written
        one)? The rule is inverted: byte 0's low bit SET means DISABLED
        (0x02/0x06 enabled, 0x03/0x05/0x07 disabled); no value at all
        means enabled, since Explorer only writes one once a user has
        toggled the entry.
    #>
    param([AllowNull()]$ApprovalValue)
    if ($null -eq $ApprovalValue) { return $true }
    $bytes = @($ApprovalValue)
    if ($bytes.Count -lt 1) { return $true }
    $first = 0
    try { $first = [int]$bytes[0] }
    catch { return $true }
    return (($first -band 1) -eq 0)
}

function Get-WtStartupProgramsLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: everything that starts at sign-in, from all eight
        locations - Run and RunOnce under HKLM, under HKLM\WOW6432Node and
        under the INTERACTIVE user's hive, plus the common and the
        per-user Startup folder - with its command line and whether it is
        disabled. StartupApproved is merged from both hives with the
        user's copy added last, so a per-user entry the user disabled
        wins. Under elevation HKCU is the ADMIN's hive, so the
        interactive user's keys and Startup folder are reached via the
        console SID, never [Environment]::GetFolderPath('Startup'),
        which would return the admin's folder.
    #>
    param(
        [scriptblock]$GetValueMap = {
            param($Path)
            $map = [ordered]@{}
            $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($key) {
                foreach ($valueName in $key.GetValueNames()) {
                    if ([string]::IsNullOrEmpty($valueName)) { continue }
                    $map[$valueName] = [string]$key.GetValue($valueName)
                }
            }
            return $map
        },
        [scriptblock]$GetApprovalMap = {
            param($Path)
            $map = @{}
            $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($key) {
                foreach ($valueName in $key.GetValueNames()) {
                    if ([string]::IsNullOrEmpty($valueName)) { continue }
                    $map[$valueName] = $key.GetValue($valueName)
                }
            }
            return $map
        },
        [scriptblock]$GetFolderEntries = {
            param($Path)
            $out = New-Object System.Collections.Generic.List[object]
            if ($Path -and (Test-Path -LiteralPath $Path)) {
                foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)) {
                    if ([string]::Equals($file.Name, 'desktop.ini', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $out.Add([PSCustomObject]@{ Name = $file.Name; Command = $file.FullName })
                }
            }
            return , $out.ToArray()
        },
        [scriptblock]$GetUserSid = { Get-WtConsoleUserSid },
        [scriptblock]$GetUserProfilePath = {
            param($Sid)
            if (-not $Sid) { return $null }
            $profileKey = Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $Sid) -ErrorAction SilentlyContinue
            if (-not $profileKey -or -not $profileKey.ProfileImagePath) { return $null }
            return [Environment]::ExpandEnvironmentVariables([string]$profileKey.ProfileImagePath)
        },
        [string]$CommonStartup = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'),
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $sid = $null
    try { $sid = & $GetUserSid } catch { $sid = $null }
    $userRoot = if ($sid) { 'Registry::HKEY_USERS\' + $sid } else { $null }

    $approved = @{ 'Run' = @{}; 'Run32' = @{}; 'StartupFolder' = @{} }
    $approvalRoots = New-Object System.Collections.Generic.List[string]
    $approvalRoots.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved')
    if ($userRoot) { $approvalRoots.Add($userRoot + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved') }
    foreach ($root in $approvalRoots) {
        foreach ($kind in 'Run', 'Run32', 'StartupFolder') {
            $map = $null
            try { $map = & $GetApprovalMap ($root + '\' + $kind) }
            catch { $map = $null }
            if (-not $map) { continue }
            foreach ($valueName in @($map.Keys)) { $approved[$kind][[string]$valueName] = $map[$valueName] }
        }
    }

    $sources = New-Object System.Collections.Generic.List[object]
    $sources.Add([PSCustomObject]@{ Label = 'HKLM Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approval = 'Run' })
    $sources.Add([PSCustomObject]@{ Label = 'HKLM RunOnce'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approval = '' })
    $sources.Add([PSCustomObject]@{ Label = 'HKLM32 Run'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approval = 'Run32' })
    $sources.Add([PSCustomObject]@{ Label = 'HKLM32 RunOnce'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Approval = '' })
    if ($userRoot) {
        $sources.Add([PSCustomObject]@{ Label = 'HKU Run'; Path = $userRoot + '\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approval = 'Run' })
        $sources.Add([PSCustomObject]@{ Label = 'HKU RunOnce'; Path = $userRoot + '\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Approval = '' })
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($source in $sources) {
        $map = $null
        try { $map = & $GetValueMap $source.Path }
        catch { $map = $null }
        if (-not $map) { continue }
        foreach ($valueName in @($map.Keys)) {
            $name = [string]$valueName
            $approval = $null
            if ($source.Approval -and $approved[$source.Approval].ContainsKey($name)) { $approval = $approved[$source.Approval][$name] }
            $rows.Add([PSCustomObject]@{
                    SortKey  = $name.ToUpperInvariant()
                    Name     = $name
                    Location = $source.Label
                    Command  = [string]$map[$valueName]
                    Enabled  = (Test-WtStartupEntryEnabled -ApprovalValue $approval)
                })
        }
    }

    $folders = New-Object System.Collections.Generic.List[object]
    $folders.Add([PSCustomObject]@{ Label = 'Startup (all)'; Path = $CommonStartup })
    $profilePath = $null
    if ($sid) {
        try { $profilePath = & $GetUserProfilePath $sid }
        catch { $profilePath = $null }
    }
    if ($profilePath) {
        $folders.Add([PSCustomObject]@{ Label = 'Startup (user)'; Path = (Join-Path $profilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') })
    }
    foreach ($folder in $folders) {
        $entries = @()
        try {
            $raw = & $GetFolderEntries $folder.Path
            $entries = if ($null -eq $raw) { @() } else { @($raw) }
        }
        catch { $entries = @() }
        foreach ($entry in $entries) {
            if (-not $entry) { continue }
            $name = [string]$entry.Name
            $approval = $null
            if ($approved['StartupFolder'].ContainsKey($name)) { $approval = $approved['StartupFolder'][$name] }
            $rows.Add([PSCustomObject]@{
                    SortKey  = $name.ToUpperInvariant()
                    Name     = $name
                    Location = $folder.Label
                    Command  = [string]$entry.Command
                    Enabled  = (Test-WtStartupEntryEnabled -ApprovalValue $approval)
                })
        }
    }

    if ($rows.Count -eq 0) {
        $lines.Add((Get-Translation 'StartupProgramsNone'))
        if (-not $sid) { $lines.Add((Get-Translation 'StartupProgramsNoUserHive')) }
        return [string[]]$lines.ToArray()
    }

    $enabledCount = @($rows | Where-Object { $_.Enabled }).Count
    $lines.Add(((Get-Translation 'StartupProgramsCount') -f $rows.Count, $enabledCount, ($rows.Count - $enabledCount)))
    if (-not $sid) { $lines.Add((Get-Translation 'StartupProgramsNoUserHive')) }
    $lines.Add('')

    $nameWidth = 24
    $stateWidth = 11
    $locWidth = 14
    $cmdWidth = [Math]::Max(20, $Width - $nameWidth - $stateWidth - $locWidth - 3)
    $total = $nameWidth + $stateWidth + $locWidth + $cmdWidth + 3

    $lines.Add((((Format-WtSoftwareCell -Text 'Name' -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text 'State' -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text 'Location' -Width $locWidth) + ' ' + (Format-WtSoftwareCell -Text 'Command' -Width $cmdWidth)).TrimEnd()))
    $lines.Add('-' * [Math]::Min($total, [Math]::Max(20, $Width)))
    foreach ($row in ($rows | Sort-Object -Property Location, SortKey)) {
        $state = if ($row.Enabled) { Get-Translation 'StartupStateEnabled' } else { Get-Translation 'StartupStateDisabled' }
        $lines.Add((((Format-WtSoftwareCell -Text $row.Name -Width $nameWidth) + ' ' + (Format-WtSoftwareCell -Text $state -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Location -Width $locWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Command -Width $cmdWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'StartupProgramsFootnote'))
    return [string[]]$lines.ToArray()
}

function Get-WtNonMicrosoftTaskLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: the scheduled tasks that did not ship with Windows -
        where updaters and adware live once the Startup list is clean.
        Actions[0].Execute is guarded, not assumed, since it comes back
        $null for ComHandler and SendEmail actions. LastRunTime of
        1899-11-30 means "never ran" - Task Scheduler's sentinel for no
        run - so only a year past 1900 counts as a real timestamp.
    #>
    param(
        [scriptblock]$GetTasks = { Get-ScheduledTask -ErrorAction Stop },
        [scriptblock]$GetTaskInfo = { param($Task) Get-ScheduledTaskInfo -InputObject $Task -ErrorAction SilentlyContinue },
        [int]$Width = (Get-WtPanelInnerWidth -Width (Get-WtConsoleSize).Width)
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $all = @()
    try {
        $raw = & $GetTasks
        $all = if ($null -eq $raw) { @() } else { @($raw) }
    }
    catch {
        $lines.Add((Get-Translation 'ScheduledTasksNotAvailable'))
        return [string[]]$lines.ToArray()
    }

    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($task in $all) {
        if (-not $task) { continue }
        $taskPath = [string]$task.TaskPath
        if ($taskPath.StartsWith('\Microsoft\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $tasks.Add($task)
    }

    if ($tasks.Count -eq 0) {
        $lines.Add((Get-Translation 'ScheduledTasksNone'))
        $lines.Add((Get-Translation 'ScheduledTasksFootnote'))
        return [string[]]$lines.ToArray()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($task in $tasks) {
        $full = ([string]$task.TaskPath) + ([string]$task.TaskName)

        $program = ''
        $actions = @($task.Actions)
        if ($actions.Count -gt 0 -and $actions[0] -and ($actions[0].PSObject.Properties.Name -contains 'Execute')) {
            $program = [string]$actions[0].Execute
        }
        if ([string]::IsNullOrWhiteSpace($program)) { $program = '-' }

        $lastRun = '-'
        $info = $null
        try { $info = & $GetTaskInfo $task }
        catch { $info = $null }
        if ($info -and ($info.LastRunTime -is [datetime])) {
            if ($info.LastRunTime.Year -gt 1900) {
                $lastRun = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }

        $rows.Add([PSCustomObject]@{
                SortKey = $full.ToUpperInvariant()
                Path    = $full
                State   = [string]$task.State
                LastRun = $lastRun
                Program = $program
            })
    }

    $disabledCount = 0
    foreach ($row in $rows) {
        if ([string]::Equals($row.State, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)) { $disabledCount++ }
    }
    $lines.Add(((Get-Translation 'ScheduledTasksCount') -f $rows.Count, ($rows.Count - $disabledCount), $disabledCount))
    $lines.Add('')

    $pathWidth = 34
    $stateWidth = 9
    $runWidth = 16
    $progWidth = [Math]::Max(16, $Width - $pathWidth - $stateWidth - $runWidth - 3)
    $total = $pathWidth + $stateWidth + $runWidth + $progWidth + 3

    $lines.Add((((Format-WtSoftwareCell -Text 'Task' -Width $pathWidth) + ' ' + (Format-WtSoftwareCell -Text 'State' -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text 'Last run' -Width $runWidth) + ' ' + (Format-WtSoftwareCell -Text 'Program' -Width $progWidth)).TrimEnd()))
    $lines.Add('-' * [Math]::Min($total, [Math]::Max(20, $Width)))
    foreach ($row in ($rows | Sort-Object -Property SortKey)) {
        $lines.Add((((Format-WtSoftwareCell -Text $row.Path -Width $pathWidth) + ' ' + (Format-WtSoftwareCell -Text $row.State -Width $stateWidth) + ' ' + (Format-WtSoftwareCell -Text $row.LastRun -Width $runWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Program -Width $progWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'ScheduledTasksFootnote'))
    return [string[]]$lines.ToArray()
}

function Get-WtInstalledUpdatesLines {
    <#
    .SYNOPSIS
        PURE-FRONTED: which KB updates are installed and when - the first
        thing to look at when a problem "started after an update". An
        empty or unparsable InstalledOn sorts last rather than throwing.
        Store apps and driver updates are not in this source at all; the
        footnote says so. The table is a fixed ~69 columns, so unlike the
        program and startup tables it needs no width measurement.
    #>
    param(
        [scriptblock]$GetHotFixes = { Get-HotFix -ErrorAction Stop }
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $items = @()
    try {
        $raw = & $GetHotFixes
        $items = if ($null -eq $raw) { @() } else { @($raw) }
    }
    catch {
        $lines.Add((Get-Translation 'InstalledUpdatesNotAvailable'))
        return [string[]]$lines.ToArray()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if (-not $item) { continue }
        $installed = $null
        if ($item.InstalledOn -is [datetime]) { $installed = [datetime]$item.InstalledOn }
        $rows.Add([PSCustomObject]@{
                SortStamp   = $(if ($installed) { $installed } else { [datetime]::MinValue })
                HotFixID    = [string]$item.HotFixID
                Description = [string]$item.Description
                Installed   = $(if ($installed) { $installed.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { '-' })
                InstalledBy = [string]$item.InstalledBy
            })
    }

    if ($rows.Count -eq 0) {
        $lines.Add((Get-Translation 'InstalledUpdatesNone'))
        $lines.Add((Get-Translation 'InstalledUpdatesFootnote'))
        return [string[]]$lines.ToArray()
    }

    $idWidth = 12
    $descWidth = 20
    $dateWidth = 12
    $byWidth = 22

    $lines.Add(((Get-Translation 'InstalledUpdatesCount') -f $rows.Count))
    $lines.Add('')
    $lines.Add((((Format-WtSoftwareCell -Text 'HotFixID' -Width $idWidth) + ' ' + (Format-WtSoftwareCell -Text 'Type' -Width $descWidth) + ' ' + (Format-WtSoftwareCell -Text 'Installed' -Width $dateWidth) + ' ' + (Format-WtSoftwareCell -Text 'Installed by' -Width $byWidth)).TrimEnd()))
    $lines.Add('-' * ($idWidth + $descWidth + $dateWidth + $byWidth + 3))
    foreach ($row in ($rows | Sort-Object -Property SortStamp -Descending)) {
        $lines.Add((((Format-WtSoftwareCell -Text $row.HotFixID -Width $idWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Description -Width $descWidth) + ' ' + (Format-WtSoftwareCell -Text $row.Installed -Width $dateWidth) + ' ' + (Format-WtSoftwareCell -Text $row.InstalledBy -Width $byWidth)).TrimEnd()))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'InstalledUpdatesFootnote'))
    return [string[]]$lines.ToArray()
}

# --- Information rows: Hardware -------------------------------------------------
