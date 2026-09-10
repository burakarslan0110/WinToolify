#Requires -Modules Pester

<#
.SYNOPSIS
    The native kernel minidump parser. Synthetic dump bytes are built by
    the tests FROM the parser's own layout table, and the table itself is
    pinned by absolute offsets verified against volatility crash_vtypes
    and the dumplib DMPTemplate - so parser and builder cannot drift
    together unnoticed.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-WtFakeDump64 {
        <# a minimal 64-bit triage dump: header + triage block + one driver + stack + exception + context #>
        param(
            [uint32]$BugCheck = 0x133,
            [uint64[]]$Params = @([uint64]0, [uint64]0x501, [uint64]0x500, [uint64]0),
            [uint64]$DriverBase = [Convert]::ToUInt64('FFFFF80000000000', 16),
            [uint64]$DriverSize = 0x100000,
            [string]$DriverName = 'nvlddmkm.sys',
            [uint64[]]$Stack = @(),
            [uint64]$ExceptionAddress = 0,
            [uint64]$Rip = 0,
            [AllowNull()][Nullable[uint32]]$DriverCountOverride = $null,
            [AllowNull()][Nullable[uint32]]$StackSizeOverride = $null
        )
        $layout = Get-WtMinidumpLayout
        $bytes = New-Object byte[] 0x9000
        $put32 = { param([int]$Offset, [uint32]$Value) [Array]::Copy([BitConverter]::GetBytes($Value), 0, $bytes, $Offset, 4) }
        $put64 = { param([int]$Offset, [uint64]$Value) [Array]::Copy([BitConverter]::GetBytes($Value), 0, $bytes, $Offset, 8) }
        [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('PAGE'), 0, $bytes, 0, 4)
        [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('DU64'), 0, $bytes, 4, 4)
        & $put32 $layout.MinorVersion 19044
        & $put32 $layout.MachineType64 0x8664
        & $put32 $layout.ProcessorCount64 8
        & $put32 $layout.BugCheckCode64 $BugCheck
        for ($i = 0; $i -lt 4; $i++) { & $put64 ($layout.BugCheckParams64 + (8 * $i)) $Params[$i] }
        & $put32 $layout.DumpType64 4
        & $put64 $layout.SystemTime64 ([uint64][datetime]::UtcNow.ToFileTimeUtc())
        $t = [int]$layout.Triage64Offset
        & $put32 ($t + $layout.TriageContextOffset) 0x3000
        & $put32 ($t + $layout.TriageExceptionOffset) 0x4000
        & $put32 ($t + $layout.TriageCallStackOffset) 0x5000
        & $put32 ($t + $layout.TriageSizeOfCallStack) $(if ($null -ne $StackSizeOverride) { [uint32]$StackSizeOverride } else { [uint32](8 * @($Stack).Count) })
        & $put32 ($t + $layout.TriageDriverListOffset) 0x6000
        & $put32 ($t + $layout.TriageDriverCount) $(if ($null -ne $DriverCountOverride) { [uint32]$DriverCountOverride } else { [uint32]1 })
        & $put32 ($t + $layout.TriageStringPoolOffset) 0x7000
        & $put32 ($t + $layout.TriageStringPoolSize) 0x200
        & $put64 0x3000 0
        & $put64 (0x3000 + $layout.ContextRip) $Rip
        & $put32 (0x4000 + $layout.ExceptionCode) ([Convert]::ToUInt32('C0000005', 16))
        & $put64 (0x4000 + $layout.ExceptionAddress) $ExceptionAddress
        for ($i = 0; $i -lt @($Stack).Count; $i++) { & $put64 (0x5000 + 8 * $i) $Stack[$i] }
        & $put32 (0x6000 + $layout.DriverNameOffset) 0x7000
        & $put64 (0x6000 + $layout.DriverDllBase) $DriverBase
        & $put64 (0x6000 + $layout.DriverSizeOfImage) $DriverSize
        & $put64 (0x6000 + $layout.DriverTimeDateStamp) 1700000000
        & $put32 0x7000 ([uint32]$DriverName.Length)
        [Array]::Copy([System.Text.Encoding]::Unicode.GetBytes($DriverName), 0, $bytes, 0x7004, 2 * $DriverName.Length)
        $path = Join-Path $TestDrive ('fake-' + [guid]::NewGuid().ToString('N') + '.dmp')
        [System.IO.File]::WriteAllBytes($path, $bytes)
        return $path
    }
}

Describe 'Get-WtMinidumpLayout' {
    It 'pins the header offsets to the values the two external sources agree on' {
        $layout = Get-WtMinidumpLayout
        $layout.BugCheckCode64 | Should -Be 0x38
        $layout.BugCheckParams64 | Should -Be 0x40
        $layout.DumpType64 | Should -Be 0xF98
        $layout.SystemTime64 | Should -Be 0xFA8
        $layout.BugCheckCode32 | Should -Be 0x28
        $layout.BugCheckParams32 | Should -Be 0x2C
        $layout.Triage64Offset | Should -Be 0x2000
        $layout.TriageDriverListOffset | Should -Be 0x30
        $layout.TriageStringPoolOffset | Should -Be 0x38
        $layout.DriverEntrySize | Should -Be 0x90
        $layout.DriverDllBase | Should -Be 0x38
        $layout.DriverSizeOfImage | Should -Be 0x48
        $layout.DriverTimeDateStamp | Should -Be 0x88
        $layout.ContextRip | Should -Be 0xF8
        $layout.ExceptionAddress | Should -Be 0x10
    }
}

Describe 'Read-WtMinidumpHeader' {
    It 'reads the bugcheck, parameters, build and dump type from a 64-bit dump' {
        $path = New-WtFakeDump64 -BugCheck 0x133 -Params @([uint64]1, [uint64]0x501, [uint64]0x500, [uint64]0)
        $header = Read-WtMinidumpHeader -Path $path
        $header.Ok | Should -BeTrue
        $header.Is64 | Should -BeTrue
        $header.BugCheckHex | Should -Be '0x00000133'
        $header.ParametersHex[1] | Should -Be '0x0000000000000501'
        $header.Build | Should -Be 19044
        $header.DumpType | Should -Be 4
    }

    It 'rejects a non-dump file with a reason instead of throwing' {
        $path = Join-Path $TestDrive 'not-a-dump.dmp'
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::ASCII.GetBytes('MZ hello'))
        $header = Read-WtMinidumpHeader -Path $path
        $header.Ok | Should -BeFalse
        $header.Reason | Should -Not -BeNullOrEmpty
    }

    It 'rejects a file too short for a header' {
        $path = Join-Path $TestDrive 'tiny.dmp'
        [System.IO.File]::WriteAllBytes($path, (New-Object byte[] 64))
        (Read-WtMinidumpHeader -Path $path).Ok | Should -BeFalse
    }
}

Describe 'Read-WtMinidumpTriage and attribution' {
    It 'reads the driver list, the stack and the exception, and attributes addresses' {
        $base = [Convert]::ToUInt64('FFFFF80000000000', 16)
        $inDriver = $base + 0x1000
        $path = New-WtFakeDump64 -DriverBase $base -DriverSize 0x100000 -DriverName 'nvlddmkm.sys' `
            -Stack @([uint64]0x11, $inDriver, [uint64]0x22) -ExceptionAddress $inDriver -Rip $inDriver
        $triage = Read-WtMinidumpTriage -Path $path
        $triage.Ok | Should -BeTrue
        @($triage.Drivers).Count | Should -Be 1
        $triage.Drivers[0].Name | Should -Be 'nvlddmkm.sys'
        @($triage.Stack).Count | Should -Be 3
        $triage.ExceptionAddress | Should -Be $inDriver
        (Get-WtMinidumpModuleForAddress -Drivers $triage.Drivers -Address $inDriver).Name | Should -Be 'nvlddmkm.sys'
        Get-WtMinidumpModuleForAddress -Drivers $triage.Drivers -Address ([uint64]0x11) | Should -BeNullOrEmpty
    }

    It 'clamps an untrusted driver count instead of throwing (top bit set)' {
        $path = New-WtFakeDump64 -DriverCountOverride ([Convert]::ToUInt32('FFFFFFFF', 16))
        { Read-WtMinidumpTriage -Path $path } | Should -Not -Throw
        $triage = Read-WtMinidumpTriage -Path $path
        $triage.Ok | Should -BeTrue
        @($triage.Drivers).Count | Should -BeLessOrEqual 512
        $triage.Drivers[0].Name | Should -Be 'nvlddmkm.sys'
    }

    It 'clamps an untrusted stack size instead of throwing (top bit set)' {
        $path = New-WtFakeDump64 -StackSizeOverride ([Convert]::ToUInt32('FFFFFFFF', 16))
        { Read-WtMinidumpTriage -Path $path } | Should -Not -Throw
        $triage = Read-WtMinidumpTriage -Path $path
        $triage.Ok | Should -BeTrue
        @($triage.Stack).Count | Should -BeLessOrEqual 4096
    }
}

Describe 'Get-WtBugcheckName' {
    It 'names the common codes and stays silent on unknown ones' {
        Get-WtBugcheckName -Code ([Convert]::ToUInt32('133', 16)) | Should -Be 'DPC_WATCHDOG_VIOLATION'
        Get-WtBugcheckName -Code ([Convert]::ToUInt32('116', 16)) | Should -Be 'VIDEO_TDR_FAILURE'
        Get-WtBugcheckName -Code ([Convert]::ToUInt32('D1', 16)) | Should -Be 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
        Get-WtBugcheckName -Code ([Convert]::ToUInt32('DEAD', 16)) | Should -Be ''
    }

    It 'never throws for a code with the top bit set (uint32, not int32)' {
        { Get-WtBugcheckName -Code ([Convert]::ToUInt32('DEADDEAD', 16)) } | Should -Not -Throw
        Get-WtBugcheckName -Code ([Convert]::ToUInt32('DEADDEAD', 16)) | Should -Be 'MANUALLY_INITIATED_CRASH1'
        { Get-WtBugcheckName -Code ([Convert]::ToUInt32('80000000', 16)) } | Should -Not -Throw
        Get-WtBugcheckName -Code ([Convert]::ToUInt32('80000000', 16)) | Should -Be ''
        { Get-WtBugcheckName -Code ([Convert]::ToUInt32('FFFFFFFF', 16)) } | Should -Not -Throw
    }
}

Describe 'Get-WtMinidumpAnalysis' {
    It 'combines header, drivers and attribution into the model-ready shape' {
        $base = [Convert]::ToUInt64('FFFFF80000000000', 16)
        $path = New-WtFakeDump64 -BugCheck 0x116 -DriverBase $base -DriverName 'nvlddmkm.sys' `
            -Stack @($base + 0x2000) -ExceptionAddress ($base + 0x1000) -Rip ($base + 0x1500)
        $analysis = Get-WtMinidumpAnalysis -Path $path -GetCdb { '' }
        $analysis.bugcheck.code | Should -Be '0x00000116'
        $analysis.bugcheck.name | Should -Be 'VIDEO_TDR_FAILURE'
        $analysis.probable_cause.driver | Should -Be 'nvlddmkm.sys'
        @($analysis.drivers_on_stack)[0].driver | Should -Be 'nvlddmkm.sys'
        $analysis.driver_count | Should -Be 1
        $analysis.note | Should -Not -BeNullOrEmpty
    }

    It 'excludes the kernel itself from probable cause' {
        $base = [Convert]::ToUInt64('FFFFF80000000000', 16)
        $path = New-WtFakeDump64 -DriverName 'ntoskrnl.exe' -DriverBase $base -Stack @($base + 0x10) -ExceptionAddress ($base + 0x10) -Rip ($base + 0x10)
        (Get-WtMinidumpAnalysis -Path $path -GetCdb { '' }).probable_cause.driver | Should -Be ''
    }
}

Describe 'Resolve-WtMinidumpRequestPath' {
    BeforeAll {
        $script:Files = @(
            [PSCustomObject]@{ Name = 'old.dmp'; FullName = 'X:\md\old.dmp'; LastWriteTime = [datetime]'2026-08-01' }
            [PSCustomObject]@{ Name = 'new.dmp'; FullName = 'X:\md\new.dmp'; LastWriteTime = [datetime]'2026-08-30' }
        )
    }

    It 'defaults to the newest dump and finds a named one' {
        Resolve-WtMinidumpRequestPath -GetFiles { $script:Files } | Should -Be 'X:\md\new.dmp'
        Resolve-WtMinidumpRequestPath -File 'old.dmp' -GetFiles { $script:Files } | Should -Be 'X:\md\old.dmp'
    }

    It 'refuses path traversal and unknown names' {
        Resolve-WtMinidumpRequestPath -File '..\..\secrets.txt' -GetFiles { $script:Files } | Should -Be ''
        Resolve-WtMinidumpRequestPath -File 'C:\anything.dmp' -GetFiles { $script:Files } | Should -Be ''
        Resolve-WtMinidumpRequestPath -File 'yok.dmp' -GetFiles { $script:Files } | Should -Be ''
        Resolve-WtMinidumpRequestPath -GetFiles { @() } | Should -Be ''
    }

    It 'returns empty instead of throwing on a NUL-embedded name' {
        $embedded = 'a' + [char]0 + 'b.dmp'
        { Resolve-WtMinidumpRequestPath -File $embedded -GetFiles { $script:Files } } | Should -Not -Throw
        Resolve-WtMinidumpRequestPath -File $embedded -GetFiles { $script:Files } | Should -Be ''
    }
}

Describe 'cdb enrichment' {
    It 'finds cdb in the known kit path or on PATH, and reports absence as empty' {
        (Find-WtCdbPath -TestPath { param($Path) $true } -GetCommand { param($Name) $null }) | Should -Match 'cdb\.exe$'
        (Find-WtCdbPath -TestPath { param($Path) $false } -GetCommand { param($Name) $null }) | Should -Be ''
        (Find-WtCdbPath -TestPath { param($Path) $false } -GetCommand { param($Name) [PSCustomObject]@{ Source = 'C:\tools\cdb.exe' } }) | Should -Be 'C:\tools\cdb.exe'
    }

    It 'runs the analyze command through the injected runner and keeps the tail' {
        $script:RunnerArgs = $null
        $runner = { param($FilePath, $Arguments, $State)
            $script:RunnerArgs = @{ FilePath = $FilePath; Arguments = $Arguments }
            for ($i = 1; $i -le 300; $i++) { $State.Lines.Add("line $i") }
            0
        }
        $text = Invoke-WtCdbAnalyze -DumpPath 'X:\md\new.dmp' -CdbPath 'C:\tools\cdb.exe' -Runner $runner
        $script:RunnerArgs.FilePath | Should -Be 'C:\tools\cdb.exe'
        $script:RunnerArgs.Arguments | Should -Match 'analyze'
        $script:RunnerArgs.Arguments | Should -Match ([regex]::Escape('X:\md\new.dmp'))
        $text | Should -Match 'line 300'
        $text | Should -Not -Match '"line 1"'
        ($text -csplit "\r?\n").Count | Should -BeLessOrEqual 205
    }

    It 'returns empty when there is no cdb anywhere' {
        Invoke-WtCdbAnalyze -DumpPath 'X:\a.dmp' -CdbPath '' -Runner { param($FilePath, $Arguments, $State) 0 } | Should -Be ''
    }

    It 'leaves the analysis byte-identical when cdb is absent, routed through the real Invoke-WtCdbAnalyze' {
        $base = [Convert]::ToUInt64('FFFFF80000000000', 16)
        $path = New-WtFakeDump64 -BugCheck 0x116 -DriverBase $base -DriverName 'nvlddmkm.sys' `
            -Stack @($base + 0x2000) -ExceptionAddress ($base + 0x1000) -Rip ($base + 0x1500)
        $withNoCdb = { param($DumpPath) Invoke-WtCdbAnalyze -DumpPath $DumpPath -CdbPath '' }
        $baseline = Get-WtMinidumpAnalysis -Path $path -GetCdb { '' }
        $real = Get-WtMinidumpAnalysis -Path $path -GetCdb $withNoCdb
        (ConvertTo-WtAssistantToolText -Value $real) | Should -Be (ConvertTo-WtAssistantToolText -Value $baseline)
        $real.PSObject.Properties.Name | Should -Not -Contain 'cdb_analysis'
    }

    It 'wires the DEFAULT runner chain end to end with no -Runner/-Streamed/-StartChildProcess override' {
        { Invoke-WtCdbAnalyze -DumpPath 'X:\md\anything.dmp' -CdbPath 'X:\missing\cdb.exe' } | Should -Not -Throw
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $text = Invoke-WtCdbAnalyze -DumpPath 'X:\md\anything.dmp' -CdbPath 'X:\missing\cdb.exe'
        $clock.Stop()
        $clock.ElapsedMilliseconds | Should -BeLessThan 10000
        $text | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-WtTimeBoundedStreamedProcess' {
    It 'kills a child that never exits on its own once the bound passes, and returns the partial capture within that bound' {
        $fakeProcess = [PSCustomObject]@{ HasExited = $false }
        Add-Member -InputObject $fakeProcess -MemberType ScriptMethod -Name Kill -Value { $this.HasExited = $true }
        $fakeStart = { param($StartInfo) $fakeProcess }
        $fakeStreamed = { param($RunFilePath, $RunArguments, $RunState, $OnTick, $StartProcess)
            $watch = 'a same-named local on purpose - must not leak into -OnTick'
            $proc = & $StartProcess (New-Object System.Diagnostics.ProcessStartInfo)
            $RunState.Lines.Add('partial-before-timeout')
            $spins = 0
            while (-not $proc.HasExited -and $spins -lt 3000) { & $OnTick; Start-Sleep -Milliseconds 1; $spins++ }
            0
        }
        $state = New-WtNativeOutputState
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $timedOut = Invoke-WtTimeBoundedStreamedProcess -FilePath 'cdb.exe' -Arguments 'x' -State $state -TimeoutMs 20 -StartChildProcess $fakeStart -Streamed $fakeStreamed
        $clock.Stop()
        $timedOut | Should -BeTrue
        $clock.ElapsedMilliseconds | Should -BeLessThan 3000
        @($state.Lines.ToArray()) | Should -Contain 'partial-before-timeout'
        $fakeProcess.HasExited | Should -BeTrue
    }

    It 'does not kill a child that exits on its own well within the bound' {
        $script:WtProbeKilled = $false
        $fakeProcess = [PSCustomObject]@{ HasExited = $false }
        Add-Member -InputObject $fakeProcess -MemberType ScriptMethod -Name Kill -Value { $script:WtProbeKilled = $true }
        $fakeStart = { param($StartInfo) $fakeProcess }
        $fakeStreamed = { param($RunFilePath, $RunArguments, $RunState, $OnTick, $StartProcess)
            $proc = & $StartProcess (New-Object System.Diagnostics.ProcessStartInfo)
            & $OnTick
            $proc.HasExited = $true
            $RunState.Lines.Add('completed-normally')
            0
        }
        $state = New-WtNativeOutputState
        $timedOut = Invoke-WtTimeBoundedStreamedProcess -FilePath 'cdb.exe' -Arguments 'x' -State $state -TimeoutMs 60000 -StartChildProcess $fakeStart -Streamed $fakeStreamed
        $timedOut | Should -BeFalse
        $script:WtProbeKilled | Should -BeFalse
        @($state.Lines.ToArray()) | Should -Contain 'completed-normally'
    }

    It 'redirects the child stdin before starting it, so an unexpected prompt cannot read the console' {
        $script:WtProbeStartInfo = $null
        $fakeProcess = [PSCustomObject]@{ HasExited = $true }
        $fakeStart = { param($StartInfo) $script:WtProbeStartInfo = $StartInfo; $fakeProcess }
        $fakeStreamed = { param($RunFilePath, $RunArguments, $RunState, $OnTick, $StartProcess)
            $null = & $StartProcess (New-Object System.Diagnostics.ProcessStartInfo)
            0
        }
        $state = New-WtNativeOutputState
        $null = Invoke-WtTimeBoundedStreamedProcess -FilePath 'cdb.exe' -Arguments 'x' -State $state -TimeoutMs 60000 -StartChildProcess $fakeStart -Streamed $fakeStreamed
        $script:WtProbeStartInfo.RedirectStandardInput | Should -BeTrue
    }
}

Describe 'cdb enrichment: character budget' {
    It 'caps the cdb section length so it cannot dominate the 12000-char serializer budget on its own' {
        $runner = { param($FilePath, $Arguments, $State)
            $longLine = 'C:\Windows\System32\drivers\nvlddmkm.sys stack frame ' + ('x' * 150)
            for ($i = 1; $i -le 300; $i++) { $State.Lines.Add($longLine) }
            0
        }
        $text = Invoke-WtCdbAnalyze -DumpPath 'X:\md\new.dmp' -CdbPath 'C:\tools\cdb.exe' -Runner $runner
        $text.Length | Should -BeLessOrEqual 4300
    }

    It 'keeps the LAST characters of the (already line-trimmed) tail, where the verdict lives, not the first' {
        $runner = { param($FilePath, $Arguments, $State)
            $State.Lines.Add('FIRST_LINE_MARKER_' + ('p' * 70))
            for ($i = 2; $i -le 149; $i++) { $State.Lines.Add('padding-' + ('y' * 70) + '-' + $i) }
            $State.Lines.Add('VERDICT_MARKER_AT_THE_END')
            0
        }
        $text = Invoke-WtCdbAnalyze -DumpPath 'X:\md\new.dmp' -CdbPath 'C:\tools\cdb.exe' -Runner $runner
        $text | Should -Match ([regex]::Escape('VERDICT_MARKER_AT_THE_END'))
        $text | Should -Not -Match ([regex]::Escape('FIRST_LINE_MARKER_'))
    }

    It 'keeps the structured analysis fields readable even when cdb is verbose - only the giant cdb_analysis line is cut' {
        $base = [Convert]::ToUInt64('FFFFF80000000000', 16)
        $path = New-WtFakeDump64 -BugCheck 0x116 -DriverBase $base -DriverName 'nvlddmkm.sys' `
            -Stack @($base + 0x2000) -ExceptionAddress ($base + 0x1000) -Rip ($base + 0x1500)
        $getCdb = { param($DumpPath)
            $hugeRunner = { param($FilePath, $Arguments, $State)
                $longLine = 'C:\Windows\System32\drivers\nvlddmkm.sys stack frame ' + ('x' * 150)
                for ($i = 1; $i -le 300; $i++) { $State.Lines.Add($longLine) }
                0
            }
            Invoke-WtCdbAnalyze -DumpPath $DumpPath -CdbPath 'C:\tools\cdb.exe' -Runner $hugeRunner
        }
        $analysis = Get-WtMinidumpAnalysis -Path $path -GetCdb $getCdb
        $text = ConvertTo-WtAssistantToolText -Value $analysis
        $text.Length | Should -BeLessOrEqual 2500
        $text | Should -Match 'name: VIDEO_TDR_FAILURE'
        $text | Should -Match 'driver: nvlddmkm.sys'
        $lines = @($text -split "`n")
        $lines[-1] | Should -Match '^omitted: \d+ lines$'
    }
}
