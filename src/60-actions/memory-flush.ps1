# Native memory flush (C# source), catalog, Invoke-WtMemoryFlush and the Free Memory action.
# Covered by: tests/MemoryFlush.Tests.ps1

# ---------------------------------------------------------------------------
# Memory & Performance Tuning bundle - Free Memory (memory-flush)
# ---------------------------------------------------------------------------

$script:WtNativeMemorySource = @'
using System;
using System.Runtime.InteropServices;

namespace WinToolify
{
    public static class NativeMemory
    {
        public const int SystemMemoryListInformation = 80;
        public const int SystemRegistryReconciliationInformation = 155;
        private const int SePrivilegeEnabled = 0x2;
        private const int TokenAdjustPrivileges = 0x0020;
        private const int TokenQuery = 0x0008;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct TokenPrivileges
        {
            public int Count;
            public long Luid;
            public int Attr;
        }

        [DllImport("ntdll.dll", SetLastError = true)]
        public static extern int NtSetSystemInformation(int infoClass, ref int info, int length);

        [DllImport("ntdll.dll", SetLastError = true, EntryPoint = "NtSetSystemInformation")]
        public static extern int NtSetSystemInformationPtr(int infoClass, IntPtr info, int length);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr process, int desiredAccess, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool LookupPrivilegeValue(string systemName, string name, ref long luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges newState, int bufferLength, IntPtr previousState, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        public static bool EnablePrivilege(string name)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TokenAdjustPrivileges | TokenQuery, out token))
            {
                return false;
            }
            try
            {
                TokenPrivileges tp = new TokenPrivileges();
                tp.Count = 1;
                tp.Attr = SePrivilegeEnabled;
                if (!LookupPrivilegeValue(null, name, ref tp.Luid))
                {
                    return false;
                }
                if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                {
                    return false;
                }
                // AdjustTokenPrivileges returns true even when not all
                // privileges were assigned (ERROR_NOT_ALL_ASSIGNED = 1300).
                return Marshal.GetLastWin32Error() == 0;
            }
            finally
            {
                CloseHandle(token);
            }
        }

        public static int SetMemoryListCommand(int command)
        {
            int cmd = command;
            return NtSetSystemInformation(SystemMemoryListInformation, ref cmd, 4);
        }

        public static int ReconcileRegistry()
        {
            return NtSetSystemInformationPtr(SystemRegistryReconciliationInformation, IntPtr.Zero, 0);
        }
    }
}
'@

function Initialize-WtNativeMemory {
    <#
    .SYNOPSIS
        Compiles the WinToolify.NativeMemory P/Invoke type once per
        session (Add-Type refuses to redefine a loaded type), called
        lazily by the Free Memory flush action so a user who never opens
        it never pays for the compile. The C# source targets C# 5 only,
        since Windows PowerShell 5.1's Add-Type compiles with the old
        CodeDOM compiler: no string interpolation, expression-bodied
        members, nameof, out var, or null-conditional operators. The
        second ntdll import binds the same export under a distinct name
        via EntryPoint, so no ref-int/IntPtr overload resolution is ever
        involved.
    #>
    if (-not ([System.Management.Automation.PSTypeName]'WinToolify.NativeMemory').Type) {
        Add-Type -TypeDefinition $script:WtNativeMemorySource -ErrorAction Stop
    }
}

function Get-WtMemoryFlushCatalog {
    <#
    .SYNOPSIS
        The four individually-selectable Free Memory operations: three
        NtSetSystemInformation memory-list commands plus registry
        reconciliation. Working sets is CAUTION - emptying every process's
        working set makes applications stall briefly while pages fault
        back; the other three are transparent to running apps.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'MemoryFlush' -Catalog @(
        [PSCustomObject]@{
            Name         = 'WorkingSets'
            DisplayLabel = 'Working sets (all processes)'
            Risk         = 'CAUTION'
            Consequence  = 'Applications may stall briefly while their pages reload'
            Operation    = 'MemoryList'
            Command      = 2
            Privilege    = 'SeProfileSingleProcessPrivilege'
        }
        [PSCustomObject]@{
            Name         = 'StandbyList'
            DisplayLabel = 'Standby list'
            Risk         = 'SAFE'
            Consequence  = $null
            Operation    = 'MemoryList'
            Command      = 4
            Privilege    = 'SeProfileSingleProcessPrivilege'
        }
        [PSCustomObject]@{
            Name         = 'ModifiedPageList'
            DisplayLabel = 'Modified page list'
            Risk         = 'SAFE'
            Consequence  = $null
            Operation    = 'MemoryList'
            Command      = 3
            Privilege    = 'SeProfileSingleProcessPrivilege'
        }
        [PSCustomObject]@{
            Name         = 'RegistryCache'
            DisplayLabel = 'Registry cache'
            Risk         = 'SAFE'
            Consequence  = $null
            Operation    = 'RegistryReconcile'
            Command      = $null
            Privilege    = $null
        }
    )
}

function Invoke-WtMemoryFlush {
    <#
    .SYNOPSIS
        Runs the selected Free Memory operations, each in its own try/catch
        (one failure never stops the rest), and reports available memory
        before/after plus a per-operation outcome. Deliberately NOT wired
        through Invoke-WtGuardedChange: a memory flush changes no persistent
        state, so there is nothing to restore-point or undo. -FlushAction
        defaults to the real native call and throws on a non-zero NTSTATUS;
        -GetAvailableMemoryAction defaults to the real Win32_OperatingSystem
        read. Both are injectable, since neither ntdll nor CIM exists on
        the macOS dev host.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedNames,

        [scriptblock]$FlushAction = {
            param($Entry)
            Initialize-WtNativeMemory
            if ($Entry.Privilege) {
                if (-not [WinToolify.NativeMemory]::EnablePrivilege($Entry.Privilege)) {
                    throw "Could not enable $($Entry.Privilege)"
                }
            }
            $status = if ($Entry.Operation -eq 'RegistryReconcile') {
                [WinToolify.NativeMemory]::ReconcileRegistry()
            }
            else {
                [WinToolify.NativeMemory]::SetMemoryListCommand([int]$Entry.Command)
            }
            if ($status -ne 0) {
                throw ('NTSTATUS 0x{0:X8}' -f $status)
            }
        },

        [scriptblock]$GetAvailableMemoryAction = {
            [math]::Round((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1024)
        }
    )

    $catalog = Get-WtMemoryFlushCatalog
    $selected = @($catalog | Where-Object { $SelectedNames -contains $_.Name })

    $beforeMB = [double](& $GetAvailableMemoryAction)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $selected) {
        $flushError = $null
        try {
            & $FlushAction $entry
        }
        catch {
            $flushError = $_.Exception.Message
        }
        $results.Add([PSCustomObject]@{
            Name      = $entry.Name
            Succeeded = ($null -eq $flushError)
            Error     = $flushError
        })
    }

    $afterMB = [double](& $GetAvailableMemoryAction)

    return [PSCustomObject]@{
        BeforeMB = $beforeMB
        AfterMB  = $afterMB
        FreedMB  = [math]::Max(0, $afterMB - $beforeMB)
        Results  = $results.ToArray()
    }
}


function Invoke-WtFreeMemoryAction {
    <#
    .SYNOPSIS
        Transient (never staged): the memory-flush selector with the live
        RAM figure on the same screen, then the flush and its report.
    #>
    $flushCatalog = @(Get-WtMemoryFlushCatalog)
    $flushStateItems = foreach ($entry in $flushCatalog) {
        [PSCustomObject]@{ Name = $entry.Name; Selectable = $true; StateLabel = (Get-Translation 'FlushAvailable') }
    }
    $ramLine = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $ramLine = (Get-Translation 'RamUsageLine') -f [math]::Round($os.FreePhysicalMemory / 1024), [math]::Round($os.TotalVisibleMemorySize / 1024)
    }
    catch { $ramLine = '' }
    $selectorArgs = @{ Catalog = $flushCatalog; StateItems = $flushStateItems; Title = (Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'ActionTools', 'FreeMemory') }
    if ($ramLine) { $selectorArgs['InfoLines'] = @($ramLine) }
    $selectedFlush = @(Show-WtSelector @selectorArgs)
    if ($selectedFlush.Count -eq 0) { return }
    $flushResult = Invoke-WtMemoryFlush -SelectedNames $selectedFlush
    Show-WtOutputScreen -Breadcrumb (Get-Translation 'FreeMemory') -Lines (Format-WtMemoryFlushLines -Result $flushResult -Catalog $flushCatalog) | Out-Null
}

function Format-WtMemoryFlushLines {
    <#
    .SYNOPSIS
        PURE: the memory-flush report - one line per area, then before /
        after / freed. Split out of the action so the wording is testable
        without touching real memory.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'FreeMemory') + ':')
    $lines.Add('')
    foreach ($item in @($Result.Results)) {
        $entry = $Catalog | Where-Object Name -eq $item.Name | Select-Object -First 1
        $label = if ($entry) { [string]$entry.DisplayLabel } else { [string]$item.Name }
        $status = if ($item.Succeeded) { Get-Translation 'FlushSucceeded' } else { '{0} - {1}' -f (Get-Translation 'FlushFailed'), $item.Error }
        $lines.Add(('  {0}: {1}' -f $label, $status))
    }
    $lines.Add('')
    $lines.Add(('{0}: {1} MB' -f (Get-Translation 'MemoryBefore'), $Result.BeforeMB))
    $lines.Add(('{0}: {1} MB' -f (Get-Translation 'MemoryAfter'), $Result.AfterMB))
    $lines.Add(('{0}: {1} MB' -f (Get-Translation 'MemoryFreed'), $Result.FreedMB))
    return [string[]]$lines.ToArray()
}

# --- transient / info leaves (never staged) --------------------------------
