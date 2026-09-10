# Registry backup, driver export, battery report, Wi-Fi profile export.
# Covered by: tests/ActionBackupReports.Tests.ps1

function Get-WtRegistryBackupTargets {
    <#
    .SYNOPSIS
        PURE: the hives BackupRegistry exports, in export order. SYSTEM
        is marked Reimportable=$false (merging it back into a running
        Windows can leave the machine unbootable). The user hive is
        addressed as HKU\<SID>, never HKCU, since under elevation HKCU is
        the ADMIN's hive; a $null SID exports only the machine hives.
    #>
    param([AllowNull()][string]$UserSid)

    $targets = New-Object System.Collections.Generic.List[object]
    $targets.Add([PSCustomObject]@{ Key = 'HKLM\SOFTWARE'; FileName = 'HKLM-SOFTWARE.reg'; Reimportable = $true })
    $targets.Add([PSCustomObject]@{ Key = 'HKLM\SYSTEM'; FileName = 'HKLM-SYSTEM.reg'; Reimportable = $false })
    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        $targets.Add([PSCustomObject]@{ Key = ('HKU\' + $UserSid); FileName = 'HKU-CurrentUser.reg'; Reimportable = $true })
    }
    return $targets.ToArray()
}

function Invoke-WtBackupRegistryAction {
    <#
    .SYNOPSIS
        Writes importable .reg exports of the main hives into a
        machine-scope folder - the safety net to take before any tweak
        screen. Machine scope on purpose: a User-scope path would land in
        the ADMIN's profile under RunAs. Each export line prints before it
        runs, since HKLM\SOFTWARE alone can take about a minute and the
        panel only repaints on output. reg.exe's own output is swallowed
        and only its exit code trusted, since the success sentence is
        localized and would not parse on Turkish Windows. The folder ends
        up holding cleartext secrets (the admin's HKCU, a manual-autologon
        password), so its ACL inheritance is broken first and narrowed to
        Administrators/SYSTEM by well-known SID.
    #>
    param(
        [scriptblock]$GetUserSid = { Get-WtConsoleUserSid },
        [scriptblock]$GetFolder = { Get-WtDataPath -Scope Machine -SubPath ('RegistryBackup\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) },
        [scriptblock]$HardenFolderAcl = {
            param($Folder)
            $acl = Get-Acl -LiteralPath $Folder
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($wellKnown in @('S-1-5-32-544', 'S-1-5-18')) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier $wellKnown
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            }
            Set-Acl -LiteralPath $Folder -AclObject $acl
        },
        [scriptblock]$ExportAction = {
            param($Key, $File)
            reg.exe export $Key $File /y | Out-Null
            return ($LASTEXITCODE -eq 0)
        },
        [scriptblock]$GetFileSize = { param($File) (Get-Item -LiteralPath $File -ErrorAction SilentlyContinue).Length }
    )

    $sid = $null
    try { $sid = [string](& $GetUserSid) } catch { $sid = $null }

    $folder = [string](& $GetFolder)
    Write-Host ((Get-Translation 'BackupRegistryFolder') -f $folder) -ForegroundColor Cyan

    $aclHardened = $false
    try {
        & $HardenFolderAcl $folder
        $aclHardened = $true
    }
    catch {
        $aclHardened = $false
    }
    if ($aclHardened) {
        Write-Host (Get-Translation 'BackupRegistryAclHardened') -ForegroundColor Yellow
    }
    else {
        Write-Host (Get-Translation 'BackupRegistryAclFailed') -ForegroundColor Red
    }

    if ([string]::IsNullOrWhiteSpace($sid)) {
        Write-Host (Get-Translation 'BackupRegistryNoUserHive') -ForegroundColor Yellow
    }

    $targets = @(Get-WtRegistryBackupTargets -UserSid $sid)
    $ok = 0
    foreach ($t in $targets) {
        $file = Join-Path $folder $t.FileName
        Write-Host ((Get-Translation 'BackupRegistryExporting') -f $t.Key) -ForegroundColor Cyan
        $done = $false
        try { $done = [bool](& $ExportAction $t.Key $file) } catch { $done = $false }
        if ($done) {
            $ok++
            $size = 0
            try { $size = [long](& $GetFileSize $file) } catch { $size = 0 }
            Write-Host ('  ' + $t.FileName + '  ' + (Format-WtByteSize -Bytes ([long]$size))) -ForegroundColor Green
            if (-not $t.Reimportable) {
                Write-Host ('  ' + (Get-Translation 'BackupRegistrySystemWarning')) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host ('  ' + ((Get-Translation 'BackupRegistryFailed') -f $t.Key)) -ForegroundColor Red
        }
    }

    Write-Host ((Get-Translation 'BackupRegistryDone') -f $ok, $targets.Count) -ForegroundColor Green
    Write-Host ((Get-Translation 'BackupRegistryRestoreHint') -f $folder)
}

function Test-WtDriverExportSpace {
    <#
    .SYNOPSIS
        How much room the driver export folder's drive has, and whether it
        clears the 5 GB a full third-party driver export can need. The
        trailing separator is trimmed since GetPathRoot returns "C:\" but
        Win32_LogicalDisk's DeviceID is "C:"; a source that throws counts
        as zero free space, so the row refuses rather than risk filling a
        disk it never measured.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$RequiredBytes = 5368709120,
        [scriptblock]$GetFreeBytes = {
            param($Root)
            (Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Root + "'")).FreeSpace
        }
    )

    $root = ([System.IO.Path]::GetPathRoot($Path)).TrimEnd('\')
    $free = 0
    try { $free = [long](& $GetFreeBytes $root) } catch { $free = 0 }

    return [PSCustomObject]@{
        Root          = $root
        FreeBytes     = $free
        RequiredBytes = $RequiredBytes
        Sufficient    = ($free -ge $RequiredBytes)
    }
}

function Invoke-WtExportDriversAction {
    <#
    .SYNOPSIS
        Copies every third-party driver package into a machine-scope
        folder, so a clean install needs no hunt through OEM sites.
        Machine scope for the same RunAs reason as the registry backup.
        Packages are consumed via ForEach-Object, one line per package:
        collecting the pipeline into @() first would print nothing until
        the whole 1-5 GB export finished.
    #>
    param(
        [scriptblock]$GetFolder = { Get-WtDataPath -Scope Machine -SubPath ('DriverBackup\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) },
        [scriptblock]$CheckSpace = { param($Folder) Test-WtDriverExportSpace -Path $Folder },
        [scriptblock]$ExportAction = { param($Folder) Export-WindowsDriver -Online -Destination $Folder },
        [scriptblock]$GetFolderSize = {
            param($Folder)
            (Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
    )

    $folder = [string](& $GetFolder)
    Write-Host ((Get-Translation 'ExportDriversFolder') -f $folder) -ForegroundColor Cyan

    $space = & $CheckSpace $folder
    Write-Host ((Get-Translation 'ExportDriversFreeSpace') -f $space.Root, (Format-WtByteSize -Bytes ([long]$space.FreeBytes)), (Format-WtByteSize -Bytes ([long]$space.RequiredBytes)))
    if (-not $space.Sufficient) {
        Write-Host (Get-Translation 'ExportDriversNoSpace') -ForegroundColor Red
        return
    }

    Write-Host (Get-Translation 'ExportDriversRunning') -ForegroundColor Cyan
    $exported = New-Object System.Collections.Generic.List[string]
    try {
        & $ExportAction $folder | ForEach-Object {
            $name = [string]$_.OriginalFileName
            $exported.Add($name)
            Write-Host ('  ' + $name)
        }
    }
    catch {
        Write-Host ((Get-Translation 'ExportDriversFailed') -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    if ($exported.Count -eq 0) {
        Write-Host (Get-Translation 'ExportDriversNone') -ForegroundColor Yellow
        return
    }

    $size = 0
    try { $size = [long](& $GetFolderSize $folder) } catch { $size = 0 }
    Write-Host ((Get-Translation 'ExportDriversDone') -f $exported.Count, (Format-WtByteSize -Bytes ([long]$size))) -ForegroundColor Green
    Write-Host ((Get-Translation 'ExportDriversRestoreHint') -f $folder)
}

function Invoke-WtBatteryReportAction {
    <#
    .SYNOPSIS
        Produces Windows' full battery history report - every charge cycle
        and the capacity trend - and hands it to File Explorer. The file
        goes to explorer.exe, never Start-Process on the .html itself:
        that opens the default browser ELEVATED (Chrome refuses to run as
        administrator, Edge opens the admin's profile instead of the
        user's); explorer.exe hands off to the already-running,
        non-elevated shell. The report file name uses digits-only date
        formatting so tr-TR cannot reshape it.
    #>
    param(
        [scriptblock]$GetBattery = { Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue },
        [scriptblock]$GetFolder = { Get-WtDataPath -Scope Machine -SubPath 'Reports' },
        [scriptblock]$RunPowercfg = { param($File) powercfg /batteryreport /output $File },
        [scriptblock]$TestReport = { param($File) Test-Path -LiteralPath $File },
        [scriptblock]$OpenReport = { param($File) Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $File + '"') }
    )

    $batteries = @()
    try { $batteries = @(& $GetBattery) } catch { $batteries = @() }
    if ($batteries.Count -eq 0) {
        Write-Host (Get-Translation 'BatteryReportNoBattery') -ForegroundColor Yellow
        return
    }
    foreach ($b in $batteries) {
        Write-Host ((Get-Translation 'BatteryReportBattery') -f [string]$b.Name)
    }

    $folder = [string](& $GetFolder)
    $file = Join-Path $folder ('battery-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.html')
    Write-Host ((Get-Translation 'BatteryReportFile') -f $file) -ForegroundColor Cyan

    & $RunPowercfg $file

    if (-not (& $TestReport $file)) {
        Write-Host (Get-Translation 'BatteryReportFailed') -ForegroundColor Red
        return
    }
    Write-Host (Get-Translation 'BatteryReportDone') -ForegroundColor Green
    & $OpenReport $file
    Write-Host (Get-Translation 'BatteryReportOpened')
}

function Invoke-WtWifiProfileExport {
    <#
    .SYNOPSIS
        Writes every saved wireless network, passwords included, as
        re-importable XML - the pre-reinstall backup behind the typed
        gate of Invoke-WtExportWifiProfilesAction. The deliberate
        exception to this file's usual delete-after-export rule: these
        files are meant to survive. folder= is built as ONE argument
        ('folder=' + path) so a path with a space in the user name
        survives PowerShell's native-command argument passing.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [scriptblock]$EnsureFolder = {
            param($Path)
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        },
        [scriptblock]$ExportAction = {
            param($Path)
            $folderArg = 'folder=' + $Path
            netsh wlan export profile key=clear $folderArg
        },
        [scriptblock]$GetFiles = { param($Path) Get-ChildItem -LiteralPath $Path -Filter '*.xml' -File -ErrorAction SilentlyContinue }
    )

    Write-Host ((Get-Translation 'ExportWifiProfilesTargetLine') -f $Folder) -ForegroundColor Cyan
    try { & $EnsureFolder $Folder }
    catch {
        Write-Host ((Get-Translation 'ExportWifiProfilesFolderFailed') -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    Write-Host (Get-Translation 'ExportWifiProfilesRunning') -ForegroundColor Cyan
    & $ExportAction $Folder

    $files = @(& $GetFiles $Folder)
    if ($files.Count -eq 0) {
        Write-Host (Get-Translation 'ExportWifiProfilesNone') -ForegroundColor Yellow
        return
    }

    Write-Host ((Get-Translation 'ExportWifiProfilesDone') -f $files.Count, $Folder) -ForegroundColor Green
    Write-Host (Get-Translation 'ExportWifiProfilesClearTextWarning') -ForegroundColor Yellow
    Write-Host (Get-Translation 'ExportWifiProfilesRestoreHeader')
    foreach ($f in $files) {
        Write-Host ('  netsh wlan add profile filename="' + [string]$f.FullName + '"')
    }
}

function Invoke-WtExportWifiProfilesAction {
    <#
    .SYNOPSIS
        Inline flow for the Wi-Fi profile export: asks for the target
        folder in the panel, puts up the typed-confirmation gate, and only
        then runs the export inside the captured panel. The folder prompt
        happens BEFORE Invoke-WtCapturedAction because a Read-Host inside
        a captured action deadlocks behind the capture.
    #>
    param(
        [scriptblock]$GetDefaultFolder = { Join-Path $env:USERPROFILE 'Desktop\WinToolify-WiFi' },
        [scriptblock]$AskFolder = {
            param($Default)
            Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @(((Get-Translation 'ExportWifiProfilesFolderHint') -f $Default)) -Prompt (Get-Translation 'ExportWifiProfilesFolderPrompt') -Risk 'ADVANCED'
        },
        [scriptblock]$Confirm = {
            param($Consequence, $Lines)
            Confirm-WtDestructiveAction -Consequence $Consequence -Lines $Lines -Breadcrumb $script:WtPanelBreadcrumb
        },
        [scriptblock]$Notify = {
            param($Lines)
            $null = Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
        },
        [scriptblock]$Run = {
            param($Folder, $Crumb)
            $target = $Folder
            Invoke-WtCapturedAction -Title (Get-Translation 'ExportWifiProfiles') -Breadcrumb $Crumb -Action { Invoke-WtWifiProfileExport -Folder $target }
        }
    )

    $default = [string](& $GetDefaultFolder)
    $answer = & $AskFolder $default
    if ($null -eq $answer) { return }

    $folder = ([string]$answer).Trim().Trim('"').Trim()
    if (-not $folder) { $folder = $default }

    $lines = @(
        ((Get-Translation 'ExportWifiProfilesTargetLine') -f $folder)
        (Get-Translation 'ExportWifiProfilesClearTextLine')
        (Get-Translation 'ExportWifiProfilesStaysOnDiskLine')
    )
    if (-not (& $Confirm (Get-Translation 'ExportWifiProfilesConsequence') $lines)) {
        & $Notify @((Get-Translation 'ExportWifiProfilesCancelled'))
        return
    }

    & $Run $folder $script:WtPanelBreadcrumb
}


# --- Cleanup and disk ---------------------------------------------------
