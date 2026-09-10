# Tool row constructors and the Actions / Information row TABLES; they
# live with the catalogs since the assistant index derives entries from them.
# Covered by: tests/ToolScreenStructure.Tests.ps1

function New-WtCapturedActionItem {
    <#
    .SYNOPSIS
        An action whose output is captured and shown inside the box
        (Invoke-WtCapturedAction) instead of on a cleared console. The
        action must not call Read-Host - ask for input in the panel
        first, or build the row as a plain inline Action instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LabelKey,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Risk = '',
        [AllowNull()][System.Text.Encoding]$Encoding = $null
    )
    $label = Get-Translation $LabelKey
    return New-WtListItem -Kind 'Action' -Name $Name -Label $label -Risk $Risk -Data @{ Captured = $true; Title = $label; Action = $Action; Encoding = $Encoding }
}

function New-WtToolRow {
    <#
    .SYNOPSIS
        The one declaration form for every Actions/Information row. Kind
        decides the shape: Captured streams output into the panel (its
        scriptblock must never call Read-Host - it deadlocks behind the
        capture); Inline paints its own panel to ask for a value first;
        Power is the reboot/shutdown class, gated by ConsequenceKey;
        Native runs one long console tool via FilePath/Arguments as a
        polled child process, for a row that prints nothing itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$Action,
        [ValidateSet('Captured', 'Inline', 'Power', 'Native')][string]$Kind = 'Captured',
        [ValidateSet('', 'SAFE', 'CAUTION', 'ADVANCED')][string]$Risk = '',
        [string]$ConsequenceKey = '',
        [AllowNull()][System.Text.Encoding]$Encoding = $null,
        [string]$FilePath = '',
        [string]$Arguments = ''
    )
    if ($Kind -eq 'Native') {
        if (-not $FilePath) { throw "New-WtToolRow: a Native row needs -FilePath ($Name)." }
    }
    elseif (-not $Action) { throw "New-WtToolRow: a $Kind row needs -Action ($Name)." }
    switch ($Kind) {
        'Native' {
            $label = Get-Translation $Name
            return New-WtListItem -Kind 'Action' -Name $Name -Label $label -Risk $Risk `
                -Data @{ Native = $true; Title = $label; FilePath = $FilePath; Arguments = $Arguments; Encoding = $Encoding }
        }
        'Captured' {
            return New-WtCapturedActionItem -Name $Name -LabelKey $Name -Action $Action -Risk $Risk -Encoding $Encoding
        }
        'Inline' {
            return New-WtListItem -Kind 'Action' -Name $Name -Label (Get-Translation $Name) -Risk $Risk -Data @{ Action = $Action }
        }
        'Power' {
            return New-WtListItem -Kind 'Action' -Name $Name -Label (Get-Translation $Name) -Risk 'ADVANCED' -Data @{ Power = $true; ConsequenceKey = $ConsequenceKey; Action = $Action }
        }
    }
}

function Get-WtActionToolGroups {
    <#
    .SYNOPSIS
        Basic Tools > Actions as seven ordered groups: a header
        translation key plus a delegate returning that group's rows;
        Get-WtToolScreenItems drops a group with nothing to show. sfc.exe
        runs Native, not Captured, since it emits UTF-16LE (OEM decoding
        corrupts it) and prints nothing for minutes at a time.
        CleanComponentStore never passes /ResetBase - that would
        permanently block uninstalling updates already on the machine.
    #>
    return @(
        @{ HeaderKey = 'ActionGroupQuickFixes'; GetRows = {
                @(
                    (New-WtToolRow -Name 'RestartExplorerAction' -Action {
                            $r = Invoke-WtRestartExplorer
                            if ($r.Restarted) { Write-Host (Get-Translation 'RestartExplorerDone') -ForegroundColor Green } else { Write-Host (Get-Translation 'RestartExplorerFailed') -ForegroundColor Red }
                        })
                    (New-WtToolRow -Name 'RepairStartMenu' -Kind 'Captured' -Risk 'CAUTION' -Action { $null = Invoke-WtStartMenuRepair })
                    (New-WtToolRow -Name 'RebuildExplorerCaches' -Kind 'Captured' -Risk 'CAUTION' -Action { $null = Invoke-WtRebuildExplorerCaches })
                    (New-WtToolRow -Name 'RestartAudioServices' -Kind 'Captured' -Risk 'SAFE' -Action { $null = Invoke-WtRestartAudioServices })
                    (New-WtToolRow -Name 'RestartPrinter' -Action { Restart-Service -Name Spooler; Write-Host (Get-Translation 'ActionCompleted') })
                    (New-WtToolRow -Name 'ClearPrintQueue' -Risk 'CAUTION' -Action {
                            Stop-Service -Name Spooler -Force
                            Remove-Item -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
                            Start-Service -Name Spooler
                            Write-Host (Get-Translation 'PrintQueueCleared') -ForegroundColor Green
                        })
                    (New-WtToolRow -Name 'CloseNotRespondingApps' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtCloseNotRespondingAppsAction })
                    (New-WtToolRow -Name 'FreeMemory' -Kind 'Inline' -Action { Invoke-WtFreeMemoryAction })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupWindowsRepair'; GetRows = {
                @(
                    (New-WtToolRow -Name 'RepairWindowsSystemFiles' -Kind 'Native' -FilePath 'sfc.exe' -Arguments '/scannow' -Encoding ([System.Text.Encoding]::Unicode))
                    (New-WtToolRow -Name 'RepairComponentStore' -Kind 'Native' -FilePath 'Dism.exe' -Arguments '/Online /Cleanup-Image /RestoreHealth')
                    (New-WtToolRow -Name 'ResetWindowsUpdateComponents' -Kind 'Captured' -Risk 'ADVANCED' -Action { Invoke-WtResetWindowsUpdateComponentsAction })
                    (New-WtToolRow -Name 'RebuildSearchIndex' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRebuildSearchIndexAction })
                    (New-WtToolRow -Name 'RepairWmiRepository' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRepairWmiRepositoryAction })
                    (New-WtToolRow -Name 'RestorePowerSchemeDefaults' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRestorePowerSchemeDefaultsAction })
                    (New-WtToolRow -Name 'UpdateGroupPolicies' -Action { gpupdate /force })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupNetworkRepair'; GetRows = {
                @(
                    (New-WtToolRow -Name 'FlushDNSCache' -Action { ipconfig /flushdns })
                    (New-WtToolRow -Name 'RenewIpLease' -Action {
                            ipconfig /release
                            ipconfig /renew
                            Write-Host ''
                            foreach ($line in (Get-WtIpConfigSummaryLines)) { Write-Host $line }
                        })
                    (New-WtToolRow -Name 'PingTest' -Kind 'Inline' -Action { Invoke-WtPingTestAction })
                    (New-WtToolRow -Name 'RestartNetworkAdapters' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtRestartNetworkAdaptersAction })
                    (New-WtToolRow -Name 'ForgetWifiProfile' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtForgetWifiProfileAction })
                    (New-WtToolRow -Name 'ResetWinsock' -Kind 'Captured' -Risk 'CAUTION' -Action { Invoke-WtResetWinsockAction })
                    (New-WtToolRow -Name 'ResetTcpIpStack' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtResetTcpIpStackAction })
                    (New-WtToolRow -Name 'ResetWinHttpProxy' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtResetWinHttpProxyAction })
                    (New-WtToolRow -Name 'ResetHostsFile' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtResetHostsFileAction })
                    (New-WtToolRow -Name 'ResetFirewallRules' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtResetFirewallRulesAction })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupCleanupDisk'; GetRows = {
                @(
                    (New-WtToolRow -Name 'WindowsDiskCleanup' -Risk 'CAUTION' -Action { Invoke-WtDiskCleanupAction })
                    (New-WtToolRow -Name 'CleanUnnecessaryFiles' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtCleanupPreviewAction })
                    (New-WtToolRow -Name 'ClearBrowserCaches' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtClearBrowserCachesAction })
                    (New-WtToolRow -Name 'CleanComponentStore' -Kind 'Captured' -Risk 'CAUTION' -Action {
                        Write-Host (Get-Translation 'ComponentCleanupStarting') -ForegroundColor Cyan
                        Write-Host (Get-Translation 'ComponentCleanupResetBaseNote')
                        DISM /Online /Cleanup-Image /StartComponentCleanup
                    })
                    (New-WtToolRow -Name 'DuplicateFinder' -Kind 'Inline' -Action { Invoke-WtDuplicateFinderAction })
                    (New-WtToolRow -Name 'OptimizeVolumes' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtOptimizeVolumesAction })
                    (New-WtToolRow -Name 'ScheduleDiskRepair' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtScheduleDiskRepairAction })
                    (New-WtToolRow -Name 'DeleteOldRestorePoints' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtDeleteOldRestorePointsAction })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupSoftware'; GetRows = {
                @(
                    (New-WtToolRow -Name 'UpdateWindowsStoreApps' -Action { Invoke-WtStoreUpdatesAction })
                    (New-WtToolRow -Name 'UpdateAllProgramsWithWinGet' -Action { Invoke-WtWingetUpgradeAction } -Encoding ([System.Text.Encoding]::UTF8))
                    (New-WtToolRow -Name 'WingetUpgradeSinglePackage' -Kind 'Inline' -Risk 'SAFE' -Action { Invoke-WtWingetUpgradeSinglePackageAction })
                    (New-WtToolRow -Name 'InstallVCRedist' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtVcRedistAction })
                    (New-WtToolRow -Name 'UninstallProgram' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtUninstallProgramAction })
                    (New-WtToolRow -Name 'ResetStoreCache' -Kind 'Captured' -Risk 'SAFE' -Action { foreach ($line in (Get-WtResetStoreCacheLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ReRegisterStoreApp' -Kind 'Captured' -Risk 'CAUTION' -Action { foreach ($line in (Get-WtStoreRepairLines)) { Write-Host $line } })
                )
            }
        }
        @{ HeaderKey = 'ActionGroupBackupReports'; GetRows = { @(
            (New-WtToolRow -Name 'BackupRegistry' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtBackupRegistryAction })
            (New-WtToolRow -Name 'ExportDrivers' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtExportDriversAction })
            (New-WtToolRow -Name 'BatteryReport' -Kind 'Captured' -Risk 'SAFE' -Action { Invoke-WtBatteryReportAction })
            (New-WtToolRow -Name 'ExportWifiProfiles' -Kind 'Inline' -Risk 'ADVANCED' -Action { Invoke-WtExportWifiProfilesAction })
        ) } }
        @{ HeaderKey = 'ActionGroupPowerSession'; GetRows = { @(
            New-WtToolRow -Name 'ShutdownTimer' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtShutdownTimerAction }
            New-WtToolRow -Name 'RestartComputer' -Kind 'Power' -ConsequenceKey 'ConsequenceRestart' -Action { Restart-Computer -Force }
            New-WtToolRow -Name 'ShutdownComputer' -Kind 'Power' -ConsequenceKey 'ConsequenceShutdown' -Action { Stop-Computer -Force }
            New-WtToolRow -Name 'RestartToAdvancedStartup' -Kind 'Power' -ConsequenceKey 'ConsequenceRestartToAdvancedStartup' -Action { Invoke-WtRestartToAdvancedStartup }
            New-WtToolRow -Name 'RestartToFirmwareSettings' -Kind 'Power' -ConsequenceKey 'ConsequenceRestartToFirmwareSettings' -Action { Invoke-WtRestartToFirmwareSettings }
            New-WtToolRow -Name 'RestartInSafeMode' -Kind 'Power' -ConsequenceKey 'ConsequenceSafeMode' -Action { bcdedit /set '{default}' safeboot minimal; Restart-Computer -Force }
            New-WtToolRow -Name 'ExitSafeMode' -Kind 'Power' -ConsequenceKey 'ConsequenceExitSafeMode' -Action { bcdedit /deletevalue '{default}' safeboot }
        ) } }
    )
}

function Get-WtInfoToolGroups {
    <#
    .SYNOPSIS
        Basic Tools > Information as seven ordered groups. Every row is
        read-only except the two Inline rows that ask the user first
        (Wi-Fi profile name, save-the-report). DISM's component-store
        verdict prints verbatim since it is localized text; only
        InternetConnectivityTest and DnsResolutionTest contact the
        internet, and the former must print its host list before running
        its queries.
    #>
    return @(
        @{ HeaderKey = 'InfoGroupSystemSummary'; GetRows = {
                @(
                    (New-WtToolRow -Name 'ShowComputerAndUserName' -Action {
                            Write-Host ('{0}: {1}' -f (Get-Translation 'ComputerName'), $env:COMPUTERNAME) -ForegroundColor Green
                            Write-Host ('{0}: {1}' -f (Get-Translation 'ActiveUser'), $env:USERNAME) -ForegroundColor Green
                        })
                    (New-WtToolRow -Name 'ShowWindowsVersion' -Action { foreach ($l in (Get-WtWindowsVersionLines)) { Write-Host $l -ForegroundColor Green }; Start-Process -FilePath 'winver.exe' })
                    (New-WtToolRow -Name 'WindowsUpgradeHistory' -Kind 'Captured' -Action { foreach ($l in (Get-WtWindowsUpgradeHistoryLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'GetSystemInformation' -Action { systeminfo })
                    (New-WtToolRow -Name 'ShowWindowsLicenseStatus' -Action {
                            cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /xpr
                            Write-Host ''
                            cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /dlv
                        })
                    (New-WtToolRow -Name 'PendingRebootCheck' -Kind 'Captured' -Action { foreach ($l in (Get-WtPendingRebootLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'ShowTimeSyncStatus' -Kind 'Captured' -Action { foreach ($l in (Get-WtTimeSyncLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'ShutdownHistory' -Kind 'Captured' -Action { foreach ($l in (Get-WtShutdownHistoryLines)) { Write-Host $l } })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupHardware'; GetRows = {
                @(
                    (New-WtToolRow -Name 'HardwareSummary' -Action {
                            foreach ($l in (Get-WtSystemIdentityLines)) { Write-Host $l -ForegroundColor Green }
                            foreach ($l in (Format-WtSensorLines -Snapshot (Get-WtSensorSnapshot))) { Write-Host $l }
                        })
                    (New-WtToolRow -Name 'ShowRAMUsage' -Action {
                            $os = Get-CimInstance -ClassName Win32_OperatingSystem
                            Write-Host ((Get-Translation 'RamUsageLine') -f [math]::Round($os.FreePhysicalMemory / 1024), [math]::Round($os.TotalVisibleMemorySize / 1024)) -ForegroundColor Green
                        })
                    (New-WtToolRow -Name 'MemoryModuleReport' -Kind 'Captured' -Action { foreach ($l in (Get-WtMemoryModuleLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'MotherboardBiosInfo' -Action { foreach ($line in (Get-WtMotherboardBiosLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ShowCPUInfo' -Action { Get-CimInstance -ClassName Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | Format-List | Out-String | Write-Host })
                    (New-WtToolRow -Name 'GpuDriverDetails' -Kind 'Captured' -Action { foreach ($l in (Get-WtGpuDriverLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'BatteryHealthReport' -Kind 'Captured' -Action {
                            Write-Host (Get-Translation 'BatteryReportRunning')
                            foreach ($l in (Get-WtBatteryHealthLines)) { Write-Host $l }
                        })
                    (New-WtToolRow -Name 'ProblemDeviceReport' -Kind 'Captured' -Action { foreach ($l in (Get-WtProblemDeviceLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'ShowPrinterStatus' -Action { Get-Printer | Format-Table Name, PrinterStatus, DriverName, PortName -AutoSize | Out-String | Write-Host })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupStorage'; GetRows = {
                @(
                    (New-WtToolRow -Name 'ShowStorageStatus' -Action { foreach ($l in (Get-WtStorageLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'CheckDiskStatus' -Action { Get-PhysicalDisk | Format-Table FriendlyName, MediaType, HealthStatus, OperationalStatus, @{ Name = 'Size'; Expression = { Format-WtByteSize -Bytes ([long]$_.Size) } } -AutoSize | Out-String | Write-Host })
                    (New-WtToolRow -Name 'LargestFoldersReport' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtLargestFoldersReportAction })
                    (New-WtToolRow -Name 'LargestFilesReport' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtLargestFilesReportAction })
                    (New-WtToolRow -Name 'ComponentStoreAnalysis' -Kind 'Captured' -Risk 'CAUTION' -Action {
                        $available = Test-WtDismAvailable
                        foreach ($l in (Get-WtComponentStoreAnalysisLines -DismAvailable $available)) { Write-Host $l }
                        if (-not $available) { return }
                        DISM /Online /Cleanup-Image /AnalyzeComponentStore
                    })
                    (New-WtToolRow -Name 'RestorePointShadowStorage' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtRestorePointShadowStorageLines)) { Write-Host $l }
                        vssadmin list shadowstorage
                    })
                    (New-WtToolRow -Name 'DiskPartitionLayout' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtDiskPartitionLayoutLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ScanHardDisk' -Action { chkdsk $env:SystemDrive /scan })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupNetwork'; GetRows = {
                @(
                    (New-WtToolRow -Name 'ShowIPConfigSummary' -Action { foreach ($line in (Get-WtIpConfigSummaryLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ShowNetworkAdapters' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtNetworkAdapterLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowWifiLinkDetails' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtWifiLinkLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowWifiPassword' -Kind 'Inline' -Risk 'CAUTION' -Action { Invoke-WtWifiPasswordAction })
                    (New-WtToolRow -Name 'ShowNetworkProfileState' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtNetworkProfileLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowListeningPorts' -Action { foreach ($line in (Get-WtListeningPortLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ShowActiveConnections' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtActiveConnectionLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'ShowHostsFile' -Kind 'Captured' -Risk 'CAUTION' -Action {
                        foreach ($l in (Get-WtHostsFileLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'InternetConnectivityTest' -Kind 'Captured' -Action {
                        foreach ($l in (Get-WtInternetTestPlanLines)) { Write-Host $l }
                        foreach ($l in (Get-WtInternetTestResultLines)) { Write-Host $l }
                    })
                    (New-WtToolRow -Name 'DnsResolutionTest' -Kind 'Inline' -Action { Invoke-WtDnsResolutionTestAction })
                    (New-WtToolRow -Name 'ShowFullIPConfig' -Action { ipconfig /all })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupSoftwareStartup'; GetRows = { @(
                    (New-WtToolRow -Name 'InstalledProgramsList' -Kind 'Captured' -Action { foreach ($line in (Get-WtInstalledProgramsLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'StartupProgramsList' -Kind 'Captured' -Action { foreach ($line in (Get-WtStartupProgramsLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'NonMicrosoftScheduledTasks' -Kind 'Captured' -Action { foreach ($line in (Get-WtNonMicrosoftTaskLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'InstalledUpdatesList' -Kind 'Captured' -Action { foreach ($line in (Get-WtInstalledUpdatesLines)) { Write-Host $line } })
                ) }
        }
        @{ HeaderKey = 'InfoGroupSecurity'; GetRows = {
                @(
                    (New-WtToolRow -Name 'DefenderStatusInfo' -Kind 'Captured' -Action { foreach ($line in (Get-WtDefenderStatusLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'SecureBootTpmStatus' -Kind 'Captured' -Action { foreach ($line in (Get-WtSecureBootTpmLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'LocalAdministrators' -Kind 'Captured' -Action { foreach ($line in (Get-WtLocalAdministratorsLines)) { Write-Host $line } })
                    (New-WtToolRow -Name 'ListUserAccounts' -Action { Get-WtLocalUserTable | Format-Table -AutoSize | Out-String | Write-Host })
                    (New-WtToolRow -Name 'SecurityPostureInfo' -Kind 'Captured' -Action { foreach ($line in (Get-WtSecurityPostureLines)) { Write-Host $line } })
                )
            }
        }
        @{ HeaderKey = 'InfoGroupEventsDiagnostics'; GetRows = {
                @(
                    (New-WtToolRow -Name 'SystemHealthReport' -Kind 'Inline' -Action { Invoke-WtSystemHealthAction })
                    (New-WtToolRow -Name 'RecentSystemErrors' -Kind 'Captured' -Action { foreach ($l in (Get-WtRecentSystemErrorsLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'BlueScreenHistory' -Kind 'Captured' -Action { foreach ($l in (Get-WtBlueScreenHistoryLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'DiskErrorEvents' -Kind 'Captured' -Action { foreach ($l in (Get-WtDiskErrorEventsLines)) { Write-Host $l } })
                    (New-WtToolRow -Name 'TopProcessesByMemory' -Kind 'Captured' -Action { foreach ($l in (Get-WtTopProcessesByMemoryLines)) { Write-Host $l } })
                )
            }
        }
    )
}
