# Native kernel minidump (triage dump) parser: layout table, header and
# triage readers, driver/stack attribution, bugcheck names, cdb wrapper.
# Covered by: tests/Minidump.Tests.ps1

function Get-WtMinidumpLayout {
    <#
    .SYNOPSIS
        Every offset the parser reads, in one table - the tests build their
        synthetic dumps FROM this same table and separately pin the absolute
        values, so parser and builder cannot drift together. Verified
        against two independent sources (volatility's crash_vtypes.py,
        nforest/dumplib's DMPTemplate.bt); C:\Windows\Minidump files are
        PAGEDU64 triage dumps, not the user-mode MDMP format.
    #>
    return @{
        MajorVersion         = 0x08
        MinorVersion         = 0x0C
        MachineType64        = 0x30
        ProcessorCount64     = 0x34
        BugCheckCode64       = 0x38
        BugCheckParams64     = 0x40
        DumpType64           = 0xF98
        SystemTime64         = 0xFA8
        MachineType32        = 0x20
        ProcessorCount32     = 0x24
        BugCheckCode32       = 0x28
        BugCheckParams32     = 0x2C
        Triage64Offset       = 0x2000
        TriageContextOffset  = 0x0C
        TriageExceptionOffset = 0x10
        TriageCallStackOffset = 0x28
        TriageSizeOfCallStack = 0x2C
        TriageDriverListOffset = 0x30
        TriageDriverCount    = 0x34
        TriageStringPoolOffset = 0x38
        TriageStringPoolSize = 0x3C
        DriverEntrySize      = 0x90
        DriverNameOffset     = 0x00
        DriverDllBase        = 0x38
        DriverSizeOfImage    = 0x48
        DriverTimeDateStamp  = 0x88
        ExceptionCode        = 0x00
        ExceptionAddress     = 0x10
        ContextRip           = 0xF8
    }
}

function Read-WtMinidumpBytes {
    <#
    .SYNOPSIS
        Count bytes at Offset via BinaryReader - the file is never loaded
        whole. Returns $null when the file is shorter than Offset+Count.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Count,
        [scriptblock]$OpenStream = { param($FilePath) [System.IO.File]::OpenRead($FilePath) }
    )
    $stream = $null
    try {
        $stream = & $OpenStream $Path
        if (($Offset + $Count) -gt $stream.Length) { return $null }
        $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.BinaryReader($stream)
        return $reader.ReadBytes($Count)
    }
    catch { return $null }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Read-WtMinidumpHeader {
    <#
    .SYNOPSIS
        The dump header: signature check, bugcheck code + 4 parameters,
        build, machine type, dump type and time. 32-bit dumps get the
        header only (TRIAGE parsing is 64-bit; the limitation is stated
        in the analysis output).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OpenStream = { param($FilePath) [System.IO.File]::OpenRead($FilePath) }
    )
    $no = { param($Reason) return @{ Ok = $false; Reason = [string]$Reason } }
    $layout = Get-WtMinidumpLayout
    $head = Read-WtMinidumpBytes -Path $Path -Offset 0 -Count 0x1000 -OpenStream $OpenStream
    if ($null -eq $head) { return (& $no 'file too short for a dump header') }
    $signature = [System.Text.Encoding]::ASCII.GetString($head, 0, 4)
    $valid = [System.Text.Encoding]::ASCII.GetString($head, 4, 4)
    if ($signature -ne 'PAGE') { return (& $no 'not a kernel dump (missing PAGE signature)') }
    $is64 = ($valid -eq 'DU64')
    if (-not $is64 -and $valid -ne 'DUMP') { return (& $no ('unknown dump variant: ' + $valid)) }
    $build = [BitConverter]::ToUInt32($head, [int]$layout.MinorVersion)
    $parameters = New-Object System.Collections.Generic.List[uint64]
    if ($is64) {
        $code = [BitConverter]::ToUInt32($head, [int]$layout.BugCheckCode64)
        for ($i = 0; $i -lt 4; $i++) { $parameters.Add([BitConverter]::ToUInt64($head, [int]$layout.BugCheckParams64 + (8 * $i))) }
        $machine = [BitConverter]::ToUInt32($head, [int]$layout.MachineType64)
        $processors = [BitConverter]::ToUInt32($head, [int]$layout.ProcessorCount64)
        $dumpType = [BitConverter]::ToUInt32($head, [int]$layout.DumpType64)
        $time = $null
        try { $time = [datetime]::FromFileTimeUtc([BitConverter]::ToInt64($head, [int]$layout.SystemTime64)) } catch { $time = $null }
    }
    else {
        $code = [BitConverter]::ToUInt32($head, [int]$layout.BugCheckCode32)
        for ($i = 0; $i -lt 4; $i++) { $parameters.Add([uint64][BitConverter]::ToUInt32($head, [int]$layout.BugCheckParams32 + (4 * $i))) }
        $machine = [BitConverter]::ToUInt32($head, [int]$layout.MachineType32)
        $processors = [BitConverter]::ToUInt32($head, [int]$layout.ProcessorCount32)
        $dumpType = 0
        $time = $null
    }
    $parametersHex = @($parameters | ForEach-Object { '0x' + $_.ToString('X16', [System.Globalization.CultureInfo]::InvariantCulture) })
    return @{
        Ok = $true; Reason = ''
        Is64 = $is64
        BugCheckCode = $code
        BugCheckHex = ('0x' + $code.ToString('X8', [System.Globalization.CultureInfo]::InvariantCulture))
        Parameters = [uint64[]]$parameters.ToArray()
        ParametersHex = [string[]]$parametersHex
        Build = [int]$build
        MachineType = [uint32]$machine
        Processors = [int]$processors
        DumpType = [int]$dumpType
        Time = $time
    }
}

function Read-WtMinidumpTriage {
    <#
    .SYNOPSIS
        The 64-bit TRIAGE block: driver list (names via the string pool -
        NameOffset is a FILE offset, u32 char count + UTF-16), the raw
        call stack qwords, the exception address and the context Rip.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OpenStream = { param($FilePath) [System.IO.File]::OpenRead($FilePath) }
    )
    $no = @{ Ok = $false; Drivers = @(); Stack = [uint64[]]@(); ExceptionAddress = [uint64]0; Rip = [uint64]0 }
    $layout = Get-WtMinidumpLayout
    $triage = Read-WtMinidumpBytes -Path $Path -Offset ([long]$layout.Triage64Offset) -Count 0x60 -OpenStream $OpenStream
    if ($null -eq $triage) { return $no }
    $contextOffset = [BitConverter]::ToUInt32($triage, [int]$layout.TriageContextOffset)
    $exceptionOffset = [BitConverter]::ToUInt32($triage, [int]$layout.TriageExceptionOffset)
    $stackOffset = [BitConverter]::ToUInt32($triage, [int]$layout.TriageCallStackOffset)
    $stackSize = [BitConverter]::ToUInt32($triage, [int]$layout.TriageSizeOfCallStack)
    $driverListOffset = [BitConverter]::ToUInt32($triage, [int]$layout.TriageDriverListOffset)
    $driverCount = [BitConverter]::ToUInt32($triage, [int]$layout.TriageDriverCount)
    $drivers = New-Object System.Collections.Generic.List[object]
    $maxDrivers = [Math]::Min($driverCount, [uint32]512)
    for ($i = 0; $i -lt $maxDrivers; $i++) {
        $entry = Read-WtMinidumpBytes -Path $Path -Offset ([long]$driverListOffset + [long]$i * [long]$layout.DriverEntrySize) -Count ([int]$layout.DriverEntrySize) -OpenStream $OpenStream
        if ($null -eq $entry) { break }
        $nameOffset = [BitConverter]::ToUInt32($entry, [int]$layout.DriverNameOffset)
        $name = ''
        $lengthBytes = Read-WtMinidumpBytes -Path $Path -Offset ([long]$nameOffset) -Count 4 -OpenStream $OpenStream
        if ($null -ne $lengthBytes) {
            $charCount = [Math]::Min([BitConverter]::ToUInt32($lengthBytes, 0), 260)
            $nameBytes = Read-WtMinidumpBytes -Path $Path -Offset ([long]$nameOffset + 4) -Count ([int](2 * $charCount)) -OpenStream $OpenStream
            if ($null -ne $nameBytes) { $name = [System.Text.Encoding]::Unicode.GetString($nameBytes) }
        }
        $drivers.Add([PSCustomObject]@{
            Name = $name
            Base = [BitConverter]::ToUInt64($entry, [int]$layout.DriverDllBase)
            Size = [BitConverter]::ToUInt64($entry, [int]$layout.DriverSizeOfImage)
            TimeDateStamp = [BitConverter]::ToUInt64($entry, [int]$layout.DriverTimeDateStamp)
        })
    }
    $stack = New-Object System.Collections.Generic.List[uint64]
    $stackBytes = Read-WtMinidumpBytes -Path $Path -Offset ([long]$stackOffset) -Count ([int][Math]::Min($stackSize, [uint32]32KB)) -OpenStream $OpenStream
    if ($null -ne $stackBytes) {
        for ($i = 0; ($i + 8) -le $stackBytes.Length; $i += 8) { $stack.Add([BitConverter]::ToUInt64($stackBytes, $i)) }
    }
    $exceptionAddress = [uint64]0
    $exceptionBytes = Read-WtMinidumpBytes -Path $Path -Offset ([long]$exceptionOffset) -Count 0x20 -OpenStream $OpenStream
    if ($null -ne $exceptionBytes) { $exceptionAddress = [BitConverter]::ToUInt64($exceptionBytes, [int]$layout.ExceptionAddress) }
    $rip = [uint64]0
    $ripBytes = Read-WtMinidumpBytes -Path $Path -Offset ([long]$contextOffset + [long]$layout.ContextRip) -Count 8 -OpenStream $OpenStream
    if ($null -ne $ripBytes) { $rip = [BitConverter]::ToUInt64($ripBytes, 0) }
    return @{ Ok = $true; Drivers = @($drivers.ToArray()); Stack = [uint64[]]$stack.ToArray(); ExceptionAddress = $exceptionAddress; Rip = $rip }
}

function Get-WtMinidumpModuleForAddress {
    param(
        [AllowEmptyCollection()][array]$Drivers = @(),
        [Parameter(Mandatory)][uint64]$Address
    )
    foreach ($driver in @($Drivers)) {
        if ($Address -ge [uint64]$driver.Base -and $Address -lt ([uint64]$driver.Base + [uint64]$driver.Size)) { return $driver }
    }
    return $null
}

function Get-WtBugcheckName {
    <#
    .SYNOPSIS
        The common bugcheck codes by name; unknown codes return '' and the
        model looks them up on Learn via web_search. Code stays uint32 on
        both sides of the comparison and is never narrowed to [int]: a code
        with the top bit set is real (0xDEADDEAD, MANUALLY_INITIATED_CRASH1,
        forced via the kernel debugger), and [int]$Code throws an
        OverflowException on PS 5.1 for anything >= 0x80000000.
    #>
    param([Parameter(Mandatory)][uint32]$Code)
    $names = @{
        0x0A = 'IRQL_NOT_LESS_OR_EQUAL'; 0x1A = 'MEMORY_MANAGEMENT'; 0x1E = 'KMODE_EXCEPTION_NOT_HANDLED'
        0x24 = 'NTFS_FILE_SYSTEM'; 0x3B = 'SYSTEM_SERVICE_EXCEPTION'; 0x4E = 'PFN_LIST_CORRUPT'
        0x50 = 'PAGE_FAULT_IN_NONPAGED_AREA'; 0x7A = 'KERNEL_DATA_INPAGE_ERROR'; 0x7E = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
        0x9F = 'DRIVER_POWER_STATE_FAILURE'; 0xC2 = 'BAD_POOL_CALLER'; 0xD1 = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
        0xEF = 'CRITICAL_PROCESS_DIED'; 0xF4 = 'CRITICAL_OBJECT_TERMINATION'; 0x101 = 'CLOCK_WATCHDOG_TIMEOUT'
        0x116 = 'VIDEO_TDR_FAILURE'; 0x124 = 'WHEA_UNCORRECTABLE_ERROR'; 0x133 = 'DPC_WATCHDOG_VIOLATION'
        0x139 = 'KERNEL_SECURITY_CHECK_FAILURE'; 0x154 = 'UNEXPECTED_STORE_EXCEPTION'
    }
    foreach ($key in $names.Keys) {
        if ([uint32]$key -eq $Code) { return [string]$names[$key] }
    }
    if ($Code -eq [Convert]::ToUInt32('DEADDEAD', 16)) { return 'MANUALLY_INITIATED_CRASH1' }
    return ''
}

function Get-WtMinidumpAnalysis {
    <#
    .SYNOPSIS
        The crash_analysis payload behind read_system topic=crashes: header
        facts, driver stats, which drivers appear on the stack, and the
        probable cause - the FIRST candidate address (exception, then Rip,
        then the stack in order) that lands in a non-core module. Heuristic
        and said so: without symbols this is BlueScreenView-grade
        attribution, not proof.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OpenStream = { param($FilePath) [System.IO.File]::OpenRead($FilePath) },
        [scriptblock]$GetCdb = { param($DumpPath) Invoke-WtCdbAnalyze -DumpPath $DumpPath }
    )
    $header = Read-WtMinidumpHeader -Path $Path -OpenStream $OpenStream
    if (-not $header.Ok) { return [PSCustomObject]@{ error = [string]$header.Reason; file = [System.IO.Path]::GetFileName($Path) } }
    $result = [ordered]@{
        file = [System.IO.Path]::GetFileName($Path)
        time = $(if ($null -ne $header.Time) { ([datetime]$header.Time).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' })
        build = $header.Build
        bugcheck = [PSCustomObject]@{
            code = [string]$header.BugCheckHex
            name = (Get-WtBugcheckName -Code $header.BugCheckCode)
            parameters = @($header.ParametersHex)
        }
        probable_cause = [PSCustomObject]@{ driver = ''; via = '' }
        drivers_on_stack = @()
        driver_count = 0
        note = 'heuristic, symbol-free attribution (BlueScreenView-grade); confirm with the sources before acting'
    }
    if ($header.Is64) {
        $triage = Read-WtMinidumpTriage -Path $Path -OpenStream $OpenStream
        if ($triage.Ok) {
            $result.driver_count = @($triage.Drivers).Count
            $core = @('ntoskrnl.exe', 'ntkrnlmp.exe', 'ntkrnlpa.exe', 'ntkrpamp.exe', 'hal.dll')
            $isCore = { param($Name)
                foreach ($coreName in $core) { if ([string]::Equals([string]$Name, $coreName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
                return $false
            }
            $candidates = @(
                @{ Address = [uint64]$triage.ExceptionAddress; Via = 'exception address' }
                @{ Address = [uint64]$triage.Rip; Via = 'instruction pointer' }
            )
            foreach ($value in @($triage.Stack)) { $candidates += @{ Address = [uint64]$value; Via = 'stack' } }
            foreach ($candidate in $candidates) {
                if ([uint64]$candidate.Address -eq 0) { continue }
                $module = Get-WtMinidumpModuleForAddress -Drivers $triage.Drivers -Address ([uint64]$candidate.Address)
                if ($null -ne $module -and -not (& $isCore ([string]$module.Name))) {
                    $result.probable_cause = [PSCustomObject]@{ driver = [string]$module.Name; via = [string]$candidate.Via }
                    break
                }
            }
            $hits = @{}
            foreach ($value in @($triage.Stack)) {
                $module = Get-WtMinidumpModuleForAddress -Drivers $triage.Drivers -Address ([uint64]$value)
                if ($null -eq $module) { continue }
                $name = [string]$module.Name
                if ($hits.ContainsKey($name)) { $hits[$name] = [int]$hits[$name] + 1 } else { $hits[$name] = 1 }
            }
            $result.drivers_on_stack = @(foreach ($name in $hits.Keys) { [PSCustomObject]@{ driver = [string]$name; hits = [int]$hits[$name] } })
        }
    }
    else {
        $result.note = '32-bit dump: header facts only, TRIAGE attribution is 64-bit'
    }
    $cdb = ''
    try { $cdb = [string](& $GetCdb $Path) } catch { $cdb = '' }
    if ($cdb) { $result['cdb_analysis'] = $cdb }
    return [PSCustomObject]$result
}

function Get-WtMinidumpNewestPath {
    param(
        [scriptblock]$GetFiles = { Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter '*.dmp' -File -ErrorAction SilentlyContinue }
    )
    $files = @()
    try { $files = @(& $GetFiles | Where-Object { $_ }) } catch { $files = @() }
    if ($files.Count -eq 0) { return '' }
    return [string](@($files | Sort-Object -Property LastWriteTime -Descending)[0].FullName)
}

function Resolve-WtMinidumpRequestPath {
    <#
    .SYNOPSIS
        The model's file argument, guarded: a bare file NAME that exists in
        the Minidump folder, or empty for the newest dump. Anything with
        path characters is refused - the model never opens an arbitrary
        path. [System.IO.Path]::GetFileName THROWS for an embedded NUL
        instead of returning false, and File is untrusted JSON input where a
        Unicode NUL escape decodes to a real NUL character, so this is
        wrapped in try/catch to keep the '' contract even then.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$File = '',
        [scriptblock]$GetFiles = { Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter '*.dmp' -File -ErrorAction SilentlyContinue }
    )
    $name = ([string]$File).Trim()
    if (-not $name) { return (Get-WtMinidumpNewestPath -GetFiles $GetFiles) }
    $fileName = ''
    try { $fileName = [System.IO.Path]::GetFileName($name) } catch { return '' }
    if ($fileName -ne $name) { return '' }
    $files = @()
    try { $files = @(& $GetFiles | Where-Object { $_ }) } catch { $files = @() }
    foreach ($fileInfo in $files) {
        if ([string]::Equals([string]$fileInfo.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$fileInfo.FullName }
    }
    return ''
}

function Find-WtCdbPath {
    <#
    .SYNOPSIS
        cdb.exe if this machine has the Debugging Tools: the Windows Kits
        default paths, then PATH. '' means "no enrichment" - never an
        install offer.
    #>
    param(
        [scriptblock]$TestPath = { param($Path) Test-Path -LiteralPath $Path },
        [scriptblock]$GetCommand = { param($Name) Get-Command $Name -ErrorAction SilentlyContinue }
    )
    $kitRoots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    foreach ($root in $kitRoots) {
        $candidate = Join-Path $root 'Windows Kits\10\Debuggers\x64\cdb.exe'
        if (& $TestPath $candidate) { return [string]$candidate }
    }
    $command = & $GetCommand 'cdb.exe'
    if ($null -ne $command -and $command.PSObject.Properties.Name -contains 'Source' -and $command.Source) { return [string]$command.Source }
    return ''
}

function Invoke-WtTimeBoundedStreamedProcess {
    <#
    .SYNOPSIS
        Invoke-WtStreamedProcess, bounded: past -TimeoutMs the child is
        killed so the caller gets whatever -State captured so far, and the
        child's stdin is redirected then CLOSED right after start, so an
        unexpected prompt reads EOF and fails fast instead of idling out the
        whole budget (RedirectStandardInput alone does not deliver EOF - a
        child that reads stdin blocks exactly as a real console would).
        State lives in $script: variables, not locals a nested scriptblock
        would capture by name: a bare-name reference resolves through the
        live call stack, and Invoke-WtStreamedProcess has its own local
        named $watch - exactly the name this would collide with. Returns
        [bool] whether the child was killed for the timeout.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [scriptblock]$StartChildProcess = { param($StartInfo) [System.Diagnostics.Process]::Start($StartInfo) },
        [scriptblock]$Streamed = { param($RunFilePath, $RunArguments, $RunState, $OnTick, $StartProcess)
            Invoke-WtStreamedProcess -FilePath $RunFilePath -Arguments $RunArguments -State $RunState `
                -OnTick $OnTick -Encoding ([System.Text.Encoding]::UTF8) -StartProcess $StartProcess
        }
    )
    $script:WtCdbBoundWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:WtCdbBoundLimitMs = $TimeoutMs
    $script:WtCdbBoundProcess = $null
    $script:WtCdbBoundTimedOut = $false
    $script:WtCdbBoundStartChild = $StartChildProcess
    $startProcess = { param($StartInfo)
        $StartInfo.RedirectStandardInput = $true
        $script:WtCdbBoundProcess = & $script:WtCdbBoundStartChild $StartInfo
        try { $script:WtCdbBoundProcess.StandardInput.Close() } catch { }
        return $script:WtCdbBoundProcess
    }
    $onTick = {
        if ($script:WtCdbBoundWatch.ElapsedMilliseconds -lt $script:WtCdbBoundLimitMs) { return }
        $p = $script:WtCdbBoundProcess
        if ($null -eq $p) { return }
        try { if (-not $p.HasExited) { $p.Kill(); $script:WtCdbBoundTimedOut = $true } } catch { }
    }
    $null = & $Streamed $FilePath $Arguments $State $onTick $startProcess
    return [bool]$script:WtCdbBoundTimedOut
}

function Invoke-WtCdbAnalyze {
    <#
    .SYNOPSIS
        cdb -z <dump> -c "!analyze -v; q" against the public symbol server.
        The tail (last ~200 lines, where the verdict lives) is kept, then
        capped to -MaxChars (default 4000) keeping the END. Bounded by
        -TimeoutMs (default 60000ms, via Invoke-WtTimeBoundedStreamedProcess)
        so a stalled symbol-server fetch cannot wedge the screen behind a
        painted frame with no way to cancel from the keyboard; the child is
        killed and whatever was captured is returned, never nothing.
        -Runner's return value, when truthy, marks the run as stopped early
        by the timeout. Injectable for the tests.
    #>
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$CdbPath = (Find-WtCdbPath),
        [int]$TimeoutMs = 60000,
        [int]$MaxChars = 4000,
        [scriptblock]$Runner = { param($FilePath, $Arguments, $State)
            Invoke-WtTimeBoundedStreamedProcess -FilePath $FilePath -Arguments $Arguments -State $State -TimeoutMs $TimeoutMs
        }
    )
    if (-not $CdbPath) { return '' }
    $state = New-WtNativeOutputState
    $arguments = ConvertTo-WtNativeArgumentLine -Arguments @('-z', $DumpPath, '-y', 'srv*', '-c', '!analyze -v; q')
    $timedOut = [bool](& $Runner $CdbPath $arguments $state)
    if ([string]$state.Current -ne '') { $state.Lines.Add([string]$state.Current) }
    $lines = @($state.Lines.ToArray())
    if ($lines.Count -eq 0) { return '' }
    $tail = @(Get-WtOutputTail -Lines $lines -Count 200)
    $joined = ($tail -join "`n")
    $cap = [Math]::Max(0, $MaxChars)
    if ($joined.Length -gt $cap) { $joined = '...(truncated)' + "`n" + $joined.Substring($joined.Length - $cap) }
    $note = $(if ($timedOut) { (' (stopped after {0}ms, partial output)' -f $TimeoutMs) } else { '' })
    return ('cdb !analyze -v (symbols fetched from the public Microsoft symbol server over the internet)' + $note + ':' + "`n" + $joined)
}
