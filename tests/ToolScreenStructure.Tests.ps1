#Requires -Modules Pester

<#
.SYNOPSIS
    The Actions / Information screens' group scaffolding: the single row
    factory every tool row is declared with, and the flattener that turns
    a group descriptor list into Header + rows + spacers.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'New-WtToolRow' {
    It 'builds a captured row that carries its own action and title' {
        $row = New-WtToolRow -Name 'FlushDNSCache' -Action { 'x' }
        $row.Kind | Should -Be 'Action'
        $row.Name | Should -Be 'FlushDNSCache'
        $row.Data.Captured | Should -BeTrue
        $row.Data.Action | Should -Not -BeNullOrEmpty
        $row.Data.Title | Should -Be (Get-Translation 'FlushDNSCache')
    }

    It 'builds an inline row with no capture flag, so the delegate paints its own panel' {
        $row = New-WtToolRow -Name 'PingTest' -Kind 'Inline' -Action { 'x' }
        $row.Kind | Should -Be 'Action'
        $row.Data.Captured | Should -BeNullOrEmpty
        $row.Data.Power | Should -BeNullOrEmpty
        $row.Data.Action | Should -Not -BeNullOrEmpty
    }

    It 'builds a power row that always carries ADVANCED and a consequence key' {
        $row = New-WtToolRow -Name 'RestartComputer' -Kind 'Power' -ConsequenceKey 'ConsequenceRestart' -Action { 'x' }
        $row.Data.Power | Should -BeTrue
        $row.Data.ConsequenceKey | Should -Be 'ConsequenceRestart'
        $row.Risk | Should -Be 'ADVANCED'
    }

    It 'carries the risk badge through on a captured row' {
        (New-WtToolRow -Name 'FlushDNSCache' -Risk 'CAUTION' -Action { 'x' }).Risk | Should -Be 'CAUTION'
    }

    It 'rejects a kind it does not know' {
        { New-WtToolRow -Name 'FlushDNSCache' -Kind 'Nonsense' -Action { 'x' } } | Should -Throw
    }

    It 'builds a native row from a command line instead of a scriptblock' {
        $row = New-WtToolRow -Name 'RepairWindowsSystemFiles' -Kind 'Native' -FilePath 'sfc.exe' -Arguments '/scannow' -Encoding ([System.Text.Encoding]::Unicode)
        $row.Kind | Should -Be 'Action'
        $row.Data.Native | Should -BeTrue
        $row.Data.FilePath | Should -Be 'sfc.exe'
        $row.Data.Arguments | Should -Be '/scannow'
        $row.Data.Action | Should -BeNullOrEmpty
        $row.Data.Title | Should -Be (Get-Translation 'RepairWindowsSystemFiles')
    }

    It 'refuses a native row with no command and a scriptblock row with no action' {
        { New-WtToolRow -Name 'RepairWindowsSystemFiles' -Kind 'Native' } | Should -Throw
        { New-WtToolRow -Name 'FlushDNSCache' } | Should -Throw
        { New-WtToolRow -Name 'PingTest' -Kind 'Inline' } | Should -Throw
    }
}

Describe 'Get-WtToolScreenItems' {
    BeforeAll {
        $script:fakeGroups = @(
            @{ HeaderKey = 'ActionGroupQuickFixes'; GetRows = { @((New-WtToolRow -Name 'FlushDNSCache' -Action { 'a' })) } }
            @{ HeaderKey = 'ActionGroupSoftware'; GetRows = { @(
                (New-WtToolRow -Name 'PingTest' -Action { 'b' })
                (New-WtToolRow -Name 'RestartPrinter' -Action { 'c' })
            ) } }
        )
    }

    It 'emits one header per group, followed by that group s rows' {
        $items = @(Get-WtToolScreenItems -Groups $fakeGroups)
        @($items | Where-Object Kind -eq 'Header' | ForEach-Object Name) | Should -Be @('Header:ActionGroupQuickFixes', 'Header:ActionGroupSoftware')
        @($items | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name) | Should -Be @('FlushDNSCache', 'PingTest', 'RestartPrinter')
    }

    It 'puts a spacer before every header except the first' {
        $kinds = @((Get-WtToolScreenItems -Groups $fakeGroups) | ForEach-Object Kind)
        $kinds[0] | Should -Be 'Header'
        $kinds | Should -Contain 'Spacer'
        @($kinds | Where-Object { $_ -eq 'Spacer' }).Count | Should -Be 1
    }

    It 'labels the header from the translation table' {
        $items = @(Get-WtToolScreenItems -Groups $fakeGroups)
        ($items | Where-Object Name -eq 'Header:ActionGroupQuickFixes').Label | Should -Be (Get-Translation 'ActionGroupQuickFixes')
    }

    It 'skips a group with nothing to show instead of leaving a dangling header' {
        $groups = @(
            @{ HeaderKey = 'ActionGroupQuickFixes'; GetRows = { @((New-WtToolRow -Name 'FlushDNSCache' -Action { 'a' })) } }
            @{ HeaderKey = 'ActionGroupBackupReports'; GetRows = { @() } }
        )
        $items = @(Get-WtToolScreenItems -Groups $groups)
        @($items | Where-Object Kind -eq 'Header' | ForEach-Object Name) | Should -Be @('Header:ActionGroupQuickFixes')
    }

    It 'returns nothing for an empty group list' {
        @(Get-WtToolScreenItems -Groups @()).Count | Should -Be 0
    }

    It 'never makes a header focusable, so the cursor cannot land on one' {
        foreach ($item in @(Get-WtToolScreenItems -Groups $fakeGroups | Where-Object Kind -eq 'Header')) {
            Test-WtItemFocusable -Item $item | Should -BeFalse
        }
    }
}

Describe 'Action screen groups' {
    <#
    .SYNOPSIS
        RepairWindowsSystemFiles (sfc) and RepairComponentStore (DISM) are
        Native rows, not scriptblocks: driven through the capture
        pipeline, the panel only repaints when a line arrives, and both
        commands go silent for minutes, so a scriptblock wrapper let the
        elapsed counter freeze mid-scan. sfc's own console output is
        UTF-16; decoded as the OEM default every character came back with
        a NUL after it and the panel showed an empty box for the whole
        scan.
    #>
    BeforeAll { $script:groups = @(Get-WtActionToolGroups) }

    It 'declares the seven groups in the designed order' {
        @($groups | ForEach-Object HeaderKey) | Should -Be @(
            'ActionGroupQuickFixes', 'ActionGroupWindowsRepair', 'ActionGroupNetworkRepair',
            'ActionGroupCleanupDisk', 'ActionGroupSoftware', 'ActionGroupBackupReports',
            'ActionGroupPowerSession')
    }

    It 'resolves every group header in both languages' {
        foreach ($g in $groups) {
            $script:Translations['EN'].ContainsKey($g.HeaderKey) | Should -BeTrue -Because "EN needs '$($g.HeaderKey)'"
            $script:Translations['TR'].ContainsKey($g.HeaderKey) | Should -BeTrue -Because "TR needs '$($g.HeaderKey)'"
        }
    }

    It 'shows the fifty rows the design calls for, plus the VCRedist installer that moved in from Basic Tools' {
        $rows = @(Get-WtActionToolsItems | Where-Object { Test-WtItemFocusable -Item $_ })
        $rows.Count | Should -Be 51
    }

    It 'keeps every row name unique across the screen' {
        $names = @(Get-WtActionToolsItems | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name)
        @($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'runs sfc and DISM /RestoreHealth as Native rows - the two that go silent for minutes' {
        foreach ($name in @('RepairWindowsSystemFiles', 'RepairComponentStore')) {
            $row = @(Get-WtActionToolsItems | Where-Object Name -eq $name)[0]
            $row.Data.Native | Should -BeTrue -Because "$name has to be a Native row"
            $row.Data.FilePath | Should -Not -BeNullOrEmpty
            $row.Data.Action | Should -BeNullOrEmpty
        }
    }

    It 'decodes sfc as UTF-16 and leaves DISM on the OEM default' {
        $sfc = @(Get-WtActionToolsItems | Where-Object Name -eq 'RepairWindowsSystemFiles')[0]
        $sfc.Data.FilePath | Should -Be 'sfc.exe'
        $sfc.Data.Arguments | Should -Be '/scannow'
        $sfc.Data.Encoding.CodePage | Should -Be ([System.Text.Encoding]::Unicode.CodePage)
        $dism = @(Get-WtActionToolsItems | Where-Object Name -eq 'RepairComponentStore')[0]
        $dism.Data.Encoding | Should -BeNullOrEmpty
    }

    It 'leaves every other row on the OEM default (a null encoding), UTF-8 winget aside' {
        $utf16 = @(Get-WtActionToolsItems |
            Where-Object { $_.Data -and $_.Data.Encoding -and $_.Data.Encoding.CodePage -eq [System.Text.Encoding]::Unicode.CodePage } |
            ForEach-Object Name)
        @($utf16) | Should -Be @('RepairWindowsSystemFiles')
    }
}

Describe 'Information screen groups' {
    BeforeAll { $script:groups = @(Get-WtInfoToolGroups) }

    It 'declares the seven groups in the designed order' {
        @($groups | ForEach-Object HeaderKey) | Should -Be @(
            'InfoGroupSystemSummary', 'InfoGroupHardware', 'InfoGroupStorage', 'InfoGroupNetwork',
            'InfoGroupSoftwareStartup', 'InfoGroupSecurity', 'InfoGroupEventsDiagnostics')
    }

    It 'resolves every group header in both languages' {
        foreach ($g in $groups) {
            $script:Translations['EN'].ContainsKey($g.HeaderKey) | Should -BeTrue -Because "EN needs '$($g.HeaderKey)'"
            $script:Translations['TR'].ContainsKey($g.HeaderKey) | Should -BeTrue -Because "TR needs '$($g.HeaderKey)'"
        }
    }

    It 'shows the full fifty rows the design calls for' {
        $rows = @(Get-WtInfoToolsItems | Where-Object { Test-WtItemFocusable -Item $_ })
        $rows.Count | Should -Be 50
    }

    It 'keeps every row name unique across the screen' {
        $names = @(Get-WtInfoToolsItems | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name)
        @($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }
}

Describe 'CAUTION badge budget' {
    <#
    .SYNOPSIS
        Locks the CAUTION count the design catalogue lists: 19 rows on the
        Actions screen, 5 on the Information screen. A silently dropped
        badge fails here instead of only being noticed by someone
        re-counting the catalogue by hand.
    #>
    BeforeAll {
        $script:CautionActionRows = @(Get-WtActionToolsItems | Where-Object { Test-WtItemFocusable -Item $_ } | Where-Object { $_.Risk -eq 'CAUTION' })
        $script:CautionInfoRows = @(Get-WtInfoToolsItems | Where-Object { Test-WtItemFocusable -Item $_ } | Where-Object { $_.Risk -eq 'CAUTION' })
    }

    It 'carries exactly 19 CAUTION rows on the Actions screen' {
        $script:CautionActionRows.Count | Should -Be 19
    }

    It 'carries exactly 5 CAUTION rows on the Information screen' {
        $script:CautionInfoRows.Count | Should -Be 5
    }

    It 'tags ClearPrintQueue, WindowsDiskCleanup and CleanUnnecessaryFiles as CAUTION' {
        foreach ($name in 'ClearPrintQueue', 'WindowsDiskCleanup', 'CleanUnnecessaryFiles') {
            (@($script:CautionActionRows | ForEach-Object Name)) | Should -Contain $name
        }
    }

    It 'tags ShowWifiPassword as CAUTION' {
        (@($script:CautionInfoRows | ForEach-Object Name)) | Should -Contain 'ShowWifiPassword'
    }
}

Describe 'Tool screen contracts' {
    <#
    .SYNOPSIS
        Every info row must stay read-only: no reachable call uses a write
        verb outside a short, explicitly sanctioned exception list.
        StructurallyHarmlessCommands are exempted everywhere because they
        never touch OS state regardless of where they are reached from -
        generic in-memory/.NET construction, WinToolify's own panel
        widgets, and Clear-WtPendingInput (clears console input state,
        persisted nowhere, reached from every captured row).
    #>
    BeforeAll {
        $script:actionRows = @(Get-WtActionToolsItems | Where-Object { Test-WtItemFocusable -Item $_ })
        $script:infoRows = @(Get-WtInfoToolsItems | Where-Object { Test-WtItemFocusable -Item $_ })
        $script:allRows = @($actionRows) + @($infoRows)

        function Get-WtReachableCommands {
            <#
            .SYNOPSIS
                Every command call reachable from a row's Action scriptblock,
                tagged with the Origin it was found in: '<row>' for the row's
                own wrapper, or the function the call graph descends into.
                Walks the AST (CommandAst nodes), never a stringified,
                comment-included [string]$Action, so a doc comment merely
                naming a command can never register as a call. Follows
                named-function calls transitively, with a Visited set for
                cycle safety. -StopAt names a function to record but not
                expand further, for a shared boundary whose internals are
                out of scope for a particular scan.
            #>
            param(
                [Parameter(Mandatory)][scriptblock]$Action,
                [string]$OriginName = '<row>',
                [string[]]$StopAt = @(),
                [System.Collections.Generic.HashSet[string]]$Visited = (New-Object 'System.Collections.Generic.HashSet[string]')
            )
            $commandAsts = @($Action.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            $result = New-Object System.Collections.Generic.List[object]
            foreach ($cmd in $commandAsts) { $result.Add([PSCustomObject]@{ Command = $cmd; Origin = $OriginName }) }
            foreach ($cmd in $commandAsts) {
                $name = $cmd.GetCommandName()
                if (-not $name) { continue }
                if ($StopAt -contains $name) { continue }
                if (-not $Visited.Add($name)) { continue }
                $resolved = Get-Command -Name $name -ErrorAction SilentlyContinue
                if (-not $resolved -or $resolved.CommandType -ne 'Function') { continue }
                $result.AddRange(@(Get-WtReachableCommands -Action $resolved.ScriptBlock -OriginName $name -StopAt $StopAt -Visited $Visited))
            }
            return $result
        }

        function Test-WtActionRowIsGated {
            <#
            .SYNOPSIS
                True when a row's Action scriptblock calls
                Confirm-WtDestructiveAction itself, or delegates through any
                depth of named-function calls to code that does. Matches a
                CommandAst whose command name is Confirm-WtDestructiveAction,
                not a stringified regex, which a doc comment naming the
                function would satisfy without a real call anywhere.
            #>
            param([Parameter(Mandatory)][scriptblock]$Action)
            return [bool]@(Get-WtReachableCommands -Action $Action | Where-Object { $_.Command.GetCommandName() -eq 'Confirm-WtDestructiveAction' }).Count
        }

        $script:StructurallyHarmlessCommands = @(
            'New-Object', 'New-CimSession', 'New-WtListItem', 'New-WtSeg',
            'Set-WtSelectionToggle', 'Set-WtRadioSelection', 'Clear-Host', 'Clear-WtPendingInput'
        )
    }

    It 'resolves every row label in both languages' {
        foreach ($row in $allRows) {
            $script:Translations['EN'].ContainsKey($row.Name) | Should -BeTrue -Because "EN needs '$($row.Name)'"
            $script:Translations['TR'].ContainsKey($row.Name) | Should -BeTrue -Because "TR needs '$($row.Name)'"
        }
    }

    It 'keeps every row name unique across both screens' {
        $names = @($allRows | ForEach-Object Name)
        @($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'proves Test-WtActionRowIsGated actually detects a removed gate, not just a comment that names one' {
        $commentOnly = {
            # this comment mentions Confirm-WtDestructiveAction but never calls it
            Write-Host 'no real gate here'
        }
        Test-WtActionRowIsGated -Action $commentOnly | Should -BeFalse -Because 'a comment is not a call'

        Test-WtActionRowIsGated -Action { Write-Host 'still nothing' } | Should -BeFalse

        function Test-WtFakeGatedHelper { Confirm-WtDestructiveAction -Consequence 'x' -Lines @() }
        Test-WtActionRowIsGated -Action { Test-WtFakeGatedHelper } | Should -BeTrue
    }

    It 'never lets a captured action reach Read-Host through its call graph - it would deadlock behind the capture' {
        <#
            Read-WtPanelAnswer is the shared panel-input primitive every
            confirmation and prompt goes through. Its own Read-Host
            fallback (for redirected/no-TTY input) runs BEFORE any capture
            starts, never inside one, so it is a sanctioned stop boundary
            for this scan, not a hole in it - a Read-Host anywhere else in
            a captured row's reachable code is still found by the
            negative-control test right below.
        #>
        foreach ($row in @($allRows | Where-Object { $_.Data.Captured })) {
            $hit = @(Get-WtReachableCommands -Action $row.Data.Action -StopAt @('Read-WtPanelAnswer') | Where-Object { $_.Command.GetCommandName() -eq 'Read-Host' })
            $hit.Count | Should -Be 0 -Because $row.Name
        }
    }

    It 'still catches a Read-Host that is not behind the Read-WtPanelAnswer boundary' {
        $fakeRow = { Write-Host 'about to ask'; $x = Read-Host 'gimme'; Write-Host $x }
        $hit = @(Get-WtReachableCommands -Action $fakeRow -StopAt @('Read-WtPanelAnswer') | Where-Object { $_.Command.GetCommandName() -eq 'Read-Host' })
        $hit.Count | Should -BeGreaterThan 0 -Because 'a Read-Host outside the sanctioned boundary must still be caught'
    }

    It 'never changes state from an information row, following the row into every function it reaches' {
        <#
            Reads GetCommandName() off the call graph, not
            [string]$row.Data.Action, since several info rows are one-line
            wrappers whose own text never shows a write verb buried in the
            function they delegate to. Two narrow, provably-safe
            exceptions are pinned by name in $sanctionedOrigins: Set-Content
            through Save-WtReport (the documented "press S to save" flow,
            under WinToolify's own reports folder), and New-Item /
            Remove-Item through Get-WtWifiProfileKey (a temp folder always
            deleted in a finally block) or Get-WtDataPath / Write-WtErrorLog
            (WinToolify's own private data folder, never a system path).
            Start-Process is handled by a separate, narrower test below.
        #>
        $writeVerbs = 'Set-', 'Remove-', 'Stop-', 'Start-', 'Restart-', 'New-', 'Clear-', 'Disable-', 'Enable-', 'Rename-', 'Move-'
        $sanctionedOrigins = @{
            'Set-Content' = @('Save-WtReport')
            'New-Item'    = @('Get-WtWifiProfileKey', 'Get-WtDataPath')
            'Remove-Item' = @('Get-WtWifiProfileKey', 'Get-WtDataPath', 'Write-WtErrorLog')
        }
        foreach ($row in $infoRows) {
            $reachable = @(Get-WtReachableCommands -Action $row.Data.Action)
            foreach ($entry in $reachable) {
                $cmdName = $entry.Command.GetCommandName()
                if (-not $cmdName) { continue }
                foreach ($verb in $writeVerbs) {
                    if (-not $cmdName.StartsWith($verb, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($verb -eq 'Start-' -and $cmdName -eq 'Start-Process' -and $row.Name -eq 'ShowWindowsVersion') { continue }
                    if ($script:StructurallyHarmlessCommands -contains $cmdName) { continue }
                    if ($sanctionedOrigins.ContainsKey($cmdName) -and $sanctionedOrigins[$cmdName] -contains $entry.Origin) { continue }
                    $false | Should -BeTrue -Because "$($row.Name) must stay read-only ($verb) - found $cmdName (from $($entry.Origin)): $($entry.Command.Extent.Text)"
                }
            }
            foreach ($entry in @($reachable | Where-Object { $_.Command.GetCommandName() -eq 'netsh' })) {
                $entry.Command.Extent.Text | Should -Not -Match 'netsh\s+\w+\s+reset' -Because "$($row.Name) must stay read-only"
            }
            foreach ($entry in @($reachable | Where-Object { $_.Command.GetCommandName() -eq 'vssadmin' })) {
                $entry.Command.Extent.Text | Should -Not -Match 'vssadmin\s+delete' -Because "$($row.Name) must stay read-only"
            }
        }
    }

    It 'still catches a write verb that is not behind one of the sanctioned exceptions' {
        $fakeRow = { Write-Host 'reading things'; Remove-Item -Path 'C:\not-actually-safe' -Force }
        $hit = @(Get-WtReachableCommands -Action $fakeRow | Where-Object { $_.Command.GetCommandName() -eq 'Remove-Item' })
        $hit.Count | Should -BeGreaterThan 0 -Because 'an unsanctioned write verb must still be caught'
    }

    It 'allows exactly one Start-Process call across the whole Information screen, and only the documented winver.exe one' {
        $starts = New-Object System.Collections.Generic.List[object]
        foreach ($row in $infoRows) {
            foreach ($entry in @(Get-WtReachableCommands -Action $row.Data.Action | Where-Object { $_.Command.GetCommandName() -eq 'Start-Process' })) {
                $starts.Add([PSCustomObject]@{ Row = $row.Name; Text = $entry.Command.Extent.Text })
            }
        }
        $starts.Count | Should -Be 1 -Because 'Start-Process can launch anything - only ShowWindowsVersion is allowed to use it'
        $starts[0].Row | Should -Be 'ShowWindowsVersion'
        $starts[0].Text | Should -Match 'winver\.exe' -Because 'the one sanctioned call must stay exactly what it is documented to be'
    }

    It 'gives every ADVANCED action row a gate - a power consequence or a typed confirmation' {
        foreach ($row in @($actionRows | Where-Object { $_.Risk -eq 'ADVANCED' })) {
            $gated = [bool]$row.Data.Power -or (Test-WtActionRowIsGated -Action $row.Data.Action)
            $gated | Should -BeTrue -Because "$($row.Name) is ADVANCED and must ask before it runs"
        }
    }

    It 'never reaches for Get-WmiObject, which PowerShell 7 does not have' {
        foreach ($fn in 'Get-WtActionToolGroups', 'Get-WtInfoToolGroups') {
            (Get-Command $fn).Definition | Should -Not -Match 'Get-WmiObject'
        }
    }

    It 'never reaches for Win32_Product, which reconfigures every MSI it touches' {
        foreach ($fn in 'Get-WtActionToolGroups', 'Get-WtInfoToolGroups') {
            (Get-Command $fn).Definition | Should -Not -Match 'Win32_Product'
        }
    }

    It 'puts the seven groups of each screen in the designed order with the designed sizes' {
        $actionSizes = [ordered]@{
            ActionGroupQuickFixes = 8; ActionGroupWindowsRepair = 7; ActionGroupNetworkRepair = 10
            ActionGroupCleanupDisk = 8; ActionGroupSoftware = 7; ActionGroupBackupReports = 4
            ActionGroupPowerSession = 7
        }
        $groups = @(Get-WtActionToolGroups)
        @($groups | ForEach-Object HeaderKey) | Should -Be @($actionSizes.Keys)
        foreach ($g in $groups) { @(& $g.GetRows).Count | Should -Be $actionSizes[$g.HeaderKey] -Because $g.HeaderKey }

        $infoSizes = [ordered]@{
            InfoGroupSystemSummary = 8; InfoGroupHardware = 9; InfoGroupStorage = 8
            InfoGroupNetwork = 11; InfoGroupSoftwareStartup = 4; InfoGroupSecurity = 5
            InfoGroupEventsDiagnostics = 5
        }
        $groups = @(Get-WtInfoToolGroups)
        @($groups | ForEach-Object HeaderKey) | Should -Be @($infoSizes.Keys)
        foreach ($g in $groups) { @(& $g.GetRows).Count | Should -Be $infoSizes[$g.HeaderKey] -Because $g.HeaderKey }
    }
}

Describe 'Network disclosure equals contact' {
    <#
    .SYNOPSIS
        Only two rows in the whole application reach outside the machine:
        InternetConnectivityTest and DnsResolutionTest. Each prints the
        hosts it is about to contact before contacting them, and that
        disclosure is the condition the row ships under. Both host lists
        are read off the real functions' parameter defaults via the AST
        rather than being restated here, so a hardcoded third copy can
        never drift from what is actually contacted.
    #>
    BeforeAll {
        function Get-WtParamDefaultValue {
            param([Parameter(Mandatory)][string]$FunctionName, [Parameter(Mandatory)][string]$ParamName)
            $paramAst = (Get-Command $FunctionName).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $ParamName }
            if (-not $paramAst) { throw "Get-WtParamDefaultValue: '$FunctionName' has no parameter '$ParamName'" }
            return $paramAst.DefaultValue.SafeGetValue()
        }

        function Get-WtCommandParameterLiteral {
            <#
            .SYNOPSIS
                Digs a named parameter's literal argument out of every
                command call inside a scriptblock - used to reach the
                'resolver1.opendns.com' passed as -Server on the
                Resolve-DnsName call buried inside $GetPublicIp's default.
            #>
            param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [Parameter(Mandatory)][string]$ParameterName)
            $paramAsts = $ScriptBlock.Ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq $ParameterName
                }, $true)
            foreach ($pa in $paramAsts) {
                if ($pa.Argument) { return $pa.Argument.SafeGetValue() }
                $cmdAst = $pa.Parent
                $idx = $cmdAst.CommandElements.IndexOf($pa)
                if ($idx -ge 0 -and ($idx + 1) -lt $cmdAst.CommandElements.Count) {
                    return $cmdAst.CommandElements[$idx + 1].SafeGetValue()
                }
            }
            return $null
        }
    }

    It 'the internet connectivity test discloses exactly the hosts it contacts' {
        $disclosedResolver = Get-WtParamDefaultValue -FunctionName 'Get-WtInternetTestPlanLines' -ParamName 'ResolverHost'
        $disclosedPingTargets = @(Get-WtParamDefaultValue -FunctionName 'Get-WtInternetTestPlanLines' -ParamName 'PingTargets')

        $contactedPingTargets = @(Get-WtParamDefaultValue -FunctionName 'Get-WtInternetTestResultLines' -ParamName 'PingTargets')
        $getPublicIp = Get-WtParamDefaultValue -FunctionName 'Get-WtInternetTestResultLines' -ParamName 'GetPublicIp'
        $contactedResolver = Get-WtCommandParameterLiteral -ScriptBlock $getPublicIp -ParameterName 'Server'

        $contactedResolver | Should -Be $disclosedResolver -Because 'the DNS server named in the plan must be the one actually queried for the public IP'
        @($contactedPingTargets | Sort-Object) | Should -Be @($disclosedPingTargets | Sort-Object) -Because 'every host pinged for latency must have been named in the plan, and vice versa'
    }

    It 'the DNS resolution test discloses exactly the public servers it queries' {
        $disclosedServers = @(Get-WtParamDefaultValue -FunctionName 'Get-WtDnsTestPlanLines' -ParamName 'PublicServers')
        $queriedServers = @(Get-WtParamDefaultValue -FunctionName 'Get-WtDnsTestResultLines' -ParamName 'PublicServers')
        @($queriedServers | Sort-Object) | Should -Be @($disclosedServers | Sort-Object) -Because 'every public server queried must have been named in the plan, and vice versa'
    }
}
