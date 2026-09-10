# Apply records, commit plan, change-set commit, apply gates.
# Covered by: tests/ApplyEngine.Tests.ps1, tests/ApplyFlow.Tests.ps1

function New-WtApplyRecord {
    <#
    .SYNOPSIS
        One "apply this entry" record in the shape Get-WtCommitPlan
        consumes. Records are built from a screen's marks at apply time
        and live only for that apply - nothing is staged across screens.
        Direction: Apply writes the target, Remove writes the Windows
        default, derived from the row's Applied flag.
    #>
    param(
        [Parameter(Mandatory)][string]$SectionKey,
        [Parameter(Mandatory)][string]$EntryName,
        [string]$DisplayLabel = '',
        [ValidateSet('SAFE', 'CAUTION', 'ADVANCED')][string]$Risk = 'SAFE',
        [bool]$RestartsExplorer = $false,
        [bool]$RequiresReboot = $false,
        [hashtable]$Data,
        [ValidateSet('Apply', 'Remove')][string]$Direction = 'Apply'
    )
    $label = if ($DisplayLabel) { $DisplayLabel } else { $EntryName }
    return [PSCustomObject]@{
        SectionKey       = $SectionKey
        EntryName        = $EntryName
        DisplayLabel     = $label
        Risk             = $Risk
        RestartsExplorer = $RestartsExplorer
        RequiresReboot   = $RequiresReboot
        Data             = $Data
        Direction        = $Direction
    }
}

function ConvertTo-WtApplyRecords {
    <#
    .SYNOPSIS
        Marked names -> apply records, via the screen's Meta map
        (Name -> @{ SectionKey; Entry; Data }). Names without Meta are
        ignored (group headers, info rows never reach the selection).
        Items (the screen's rows) decides the direction: a marked name
        whose row is Applied becomes a Remove record.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Selection,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Meta,
        [AllowEmptyCollection()][array]$Items = @(),
        [hashtable]$Cycle = @{}
    )
    $appliedNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in @($Items)) {
        if (($item.PSObject.Properties.Name -contains 'Applied') -and [bool]$item.Applied) { $appliedNames.Add([string]$item.Name) | Out-Null }
    }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(@($Selection) | Sort-Object)) {
        if (-not $Meta.ContainsKey($name)) { continue }
        $m = $Meta[$name]
        $entry = $m.Entry
        $props = $entry.PSObject.Properties.Name
        $args = @{
            SectionKey       = [string]$m.SectionKey
            EntryName        = [string]$name
            DisplayLabel     = (Get-WtSelectorDisplayLabel -Entry $entry)
            Risk             = $(if ($props -contains 'Risk' -and $entry.Risk) { [string]$entry.Risk } else { 'SAFE' })
            RestartsExplorer = [bool](($props -contains 'RestartsExplorer') -and $entry.RestartsExplorer)
            RequiresReboot   = [bool](($props -contains 'RestartRequired') -and $entry.RestartRequired)
            Direction        = $(if ($appliedNames.Contains([string]$name)) { 'Remove' } else { 'Apply' })
        }
        if ($m.Data) { $args['Data'] = [hashtable]$m.Data }
        if ($Cycle.ContainsKey([string]$name)) {
            $data = $(if ($args.ContainsKey('Data')) { @{} + $args['Data'] } else { @{} })
            $data['Target'] = [string]$Cycle[[string]$name]
            $args['Data'] = $data
        }
        $records.Add((New-WtApplyRecord @args))
    }
    return $records.ToArray()
}

function Get-WtCommitPlan {
    <#
    .SYNOPSIS
        Pure planning half of an apply: orders records by section-catalog
        priority and pre-computes every gate the summary needs (ADVANCED
        CONFIRM, non-restorable-package YES, Explorer/reboot). Each
        section plan splits names into ApplyNames/RemoveNames, and a
        cycling screen (Services) gets a Targets map alongside Data,
        since one Data slot cannot hold a per-row target.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ChangeSet,
        [array]$Sections = (Get-WtApplySectionCatalog),
        [scriptblock]$GetPackageCatalog = { Get-WtPackageCatalog }
    )

    $sectionPlans = New-Object System.Collections.Generic.List[object]
    foreach ($section in $Sections) {
        $entries = @($ChangeSet | Where-Object { $_.SectionKey -eq $section.Key })
        if ($entries.Count -eq 0) { continue }
        if ($section.Key -eq 'Firewall' -and $entries.Count -gt 1) { $entries = @($entries[-1]) }
        $data = $null
        foreach ($e in $entries) { if ($e.Data) { $data = $e.Data; break } }
        $targets = @{}
        foreach ($e in $entries) { if ($e.Data -and $e.Data.ContainsKey('Target')) { $targets[[string]$e.EntryName] = [string]$e.Data['Target'] } }
        if ($targets.Count -gt 0) {
            $data = $(if ($data) { @{} + $data } else { @{} })
            $data['Targets'] = $targets
        }
        $sectionPlans.Add([PSCustomObject]@{
            Key              = $section.Key
            TitleKey         = $section.TitleKey
            RestartsExplorer = [bool]$section.RestartsExplorer
            EntryNames       = [string[]]@($entries | ForEach-Object EntryName)
            ApplyNames       = [string[]]@($entries | Where-Object { $_.Direction -ne 'Remove' } | ForEach-Object EntryName)
            RemoveNames      = [string[]]@($entries | Where-Object { $_.Direction -eq 'Remove' } | ForEach-Object EntryName)
            Entries          = $entries
            Data             = $data
        })
    }

    $knownKeys = @($Sections | ForEach-Object Key)
    $pkgCatalog = @(& $GetPackageCatalog)
    $nonRestorable = @($ChangeSet | Where-Object { $_.SectionKey -eq 'Packages' } | Where-Object {
        $entryName = $_.EntryName
        $catalogEntry = $pkgCatalog | Where-Object Name -eq $entryName | Select-Object -First 1
        ($catalogEntry -and -not $catalogEntry.Restorable)
    } | ForEach-Object EntryName)

    return [PSCustomObject]@{
        Sections                  = $sectionPlans.ToArray()
        UnknownEntries            = @($ChangeSet | Where-Object { $knownKeys -notcontains $_.SectionKey })
        AdvancedEntries           = @($ChangeSet | Where-Object { $_.Risk -eq 'ADVANCED' -and $_.Direction -ne 'Remove' })
        NonRestorablePackageNames = [string[]]$nonRestorable
        HasExplorerRestart        = (@($sectionPlans | Where-Object RestartsExplorer).Count -gt 0)
        RebootEntryNames          = [string[]]@($ChangeSet | Where-Object RequiresReboot | ForEach-Object EntryName)
    }
}

function New-WtSectionFailureRow {
    <#
    .SYNOPSIS
        PURE: the result row Invoke-WtCommitChangeSet reports for one entry
        whose section delegate threw. Same shape every Apply delegate
        returns, so Get-WtApplyResultLines prints it as
        "<name>: Not applied - <message>" with no special case.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][ValidateSet('Apply', 'Remove')][string]$Direction
    )
    return [PSCustomObject]@{
        Item      = [PSCustomObject]@{ Name = $Name }
        Applied   = $false
        Error     = $Message
        Direction = $Direction
    }
}

function Invoke-WtCommitChangeSet {
    <#
    .SYNOPSIS
        The apply half of the commit: every planned section through its
        guarded Apply delegate for the Apply names, then TurnOff for the
        Remove names, one undo entry per section - all interactive gates
        already ran before this is called. A section whose TurnOff half
        aborts still reports the rows its Apply half already wrote, and
        those count toward NeedsExplorerRestart/RebootEntryNames since
        the writes already happened. A delegate that throws is contained
        as a failed row per entry; any other exception still unwinds the
        navigation loop and closes the window.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Plan,
        [array]$Sections = (Get-WtApplySectionCatalog),
        [scriptblock]$OnSectionStart
    )

    $outcomes = New-Object System.Collections.Generic.List[object]
    $aborted = $false
    foreach ($sectionPlan in @($Plan.Sections)) {
        $section = $Sections | Where-Object Key -eq $sectionPlan.Key | Select-Object -First 1
        $outcome = 'NothingToApply'
        $results = @()
        if ($aborted) { $outcome = 'Skipped' }
        elseif ($section -and @($sectionPlan.EntryNames).Count -gt 0) {
            if ($OnSectionStart) { & $OnSectionStart $sectionPlan.Key }
            $applyNames = [string[]]@($sectionPlan.ApplyNames)
            $removeNames = [string[]]@($sectionPlan.RemoveNames)
            $rows = New-Object System.Collections.Generic.List[object]
            $sectionAborted = $false
            if ($applyNames.Count -gt 0) {
                $applyResult = $null
                try { $applyResult = & $section.Apply $applyNames $sectionPlan.Data }
                catch { foreach ($n in $applyNames) { $rows.Add((New-WtSectionFailureRow -Name $n -Message $_.Exception.Message -Direction 'Apply')) } }
                if ($applyResult -and $applyResult.Aborted) { $sectionAborted = $true }
                elseif ($applyResult) {
                    foreach ($row in @($applyResult.Results)) { $rows.Add(($row | Add-Member -NotePropertyName 'Direction' -NotePropertyValue 'Apply' -Force -PassThru)) }
                }
            }
            if (-not $sectionAborted -and $removeNames.Count -gt 0) {
                $turnOff = $section.TurnOff
                if ($turnOff) {
                    $removeResult = $null
                    try { $removeResult = & $turnOff $removeNames $sectionPlan.Data }
                    catch { foreach ($n in $removeNames) { $rows.Add((New-WtSectionFailureRow -Name $n -Message $_.Exception.Message -Direction 'Remove')) } }
                    if ($removeResult -and $removeResult.Aborted) { $sectionAborted = $true }
                    elseif ($removeResult) {
                        foreach ($row in @($removeResult.Results)) { $rows.Add(($row | Add-Member -NotePropertyName 'Direction' -NotePropertyValue 'Remove' -Force -PassThru)) }
                    }
                }
                else {
                    foreach ($n in $removeNames) {
                        $rows.Add([PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $n }; Applied = $false; Error = (Get-Translation 'RemoveUnavailable'); Direction = 'Remove' })
                    }
                }
            }
            $results = $rows.ToArray()
            if ($sectionAborted) { $outcome = 'Aborted'; $aborted = $true }
            else { $outcome = 'Applied' }
        }
        $outcomes.Add([PSCustomObject]@{
            Key              = $sectionPlan.Key
            TitleKey         = $sectionPlan.TitleKey
            RestartsExplorer = [bool]$sectionPlan.RestartsExplorer
            Outcome          = $outcome
            Results          = $results
        })
    }

    $needsExplorer = $false
    $anyApplied = $false
    foreach ($o in $outcomes) {
        if (@($o.Results | Where-Object Applied).Count -gt 0) {
            $anyApplied = $true
            if ($o.RestartsExplorer) { $needsExplorer = $true }
        }
    }
    $rebootNames = if ($anyApplied) { [string[]]@($Plan.RebootEntryNames) } else { [string[]]@() }

    return [PSCustomObject]@{
        Aborted              = $aborted
        Sections             = $outcomes.ToArray()
        NeedsExplorerRestart = $needsExplorer
        RebootEntryNames     = $rebootNames
    }
}

function ConvertTo-WtBlocklistMechanism {
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    switch (([string]$Answer).Trim()) {
        '1' { return 'Hosts' }
        '2' { return 'Firewall' }
        '3' { return 'Both' }
        default { return $null }
    }
}

function Invoke-WtApplyGates {
    <#
    .SYNOPSIS
        Every confirmation an apply needs, collected BEFORE anything is
        applied: ADVANCED -> typed CONFIRM, non-restorable packages ->
        typed YES, DNS preset -> disclosure + typed YES, blocklist tiers
        -> mechanism 1/2/3. Returns the surviving records and their
        commit plan. Named $recordList, not $records: PowerShell's
        case-insensitive scoping would otherwise alias the -Records
        parameter, coercing every reassignment back to a plain array and
        losing the List[object] surface this function needs.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Records,
        [array]$Sections = (Get-WtApplySectionCatalog),
        [scriptblock]$GetPackageCatalog = { Get-WtPackageCatalog },
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt, $Risk) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt $Prompt -Risk $Risk },
        [switch]$PreApprovedAdvanced,
        [scriptblock]$GetDnsDisclosure = {
            param($PresetName)
            $preset = (Get-WtDnsPresetCatalog) | Where-Object Name -eq $PresetName | Select-Object -First 1
            $adapterNames = ''
            if ($preset) {
                try {
                    $adapters = @(Get-WtDnsAdapterCaptureState -Preset $preset -DohSupported (Test-WtDohSupported))
                    $adapterNames = ($adapters | ForEach-Object { "Adapter $($_.InterfaceIndex)" }) -join ', '
                }
                catch { $adapterNames = '?' }
            }
            (Get-Translation 'DnsChangeConsequence') -f $adapterNames, $PresetName
        }
    )
    $recordList = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Records) { $recordList.Add($r) }
    $dropNames = {
        param($Key, [string[]]$Names)
        for ($i = $recordList.Count - 1; $i -ge 0; $i--) {
            if ($recordList[$i].SectionKey -eq $Key -and $Names -contains $recordList[$i].EntryName) { $recordList.RemoveAt($i) }
        }
    }
    $replan = { Get-WtCommitPlan -ChangeSet $recordList.ToArray() -Sections $Sections -GetPackageCatalog $GetPackageCatalog }
    $plan = & $replan
    $typedConfirmation = $false
    $dropped = New-Object System.Collections.Generic.List[object]
    $labelsFor = {
        param($Key, [string[]]$Names)
        [string[]]@($recordList | Where-Object { $_.SectionKey -eq $Key -and $Names -contains $_.EntryName } | ForEach-Object DisplayLabel)
    }

    foreach ($u in @($plan.UnknownEntries)) { & $dropNames $u.SectionKey @($u.EntryName) }
    if (@($plan.UnknownEntries).Count -gt 0) { $plan = & $replan }

    if ($PreApprovedAdvanced -and @($plan.AdvancedEntries).Count -gt 0) { $typedConfirmation = $true }
    elseif (@($plan.AdvancedEntries).Count -gt 0) {
        $advancedTag = Get-WtRiskLabel -Risk 'ADVANCED'
        $lines = @(((Get-Translation 'SelectorAdvancedHeader') -f $advancedTag))
        foreach ($rec in @($plan.AdvancedEntries)) {
            $consequence = Get-WtRecordConsequence -Record $rec -Sections $Sections
            $lines += $(if ($consequence) { "  - $($rec.DisplayLabel): $consequence" } else { "  - $($rec.DisplayLabel)" })
        }
        $lines += ''
        $lines += (Get-WtGateWordHint -Kind 'Confirm')
        $typed = [string](& $ReadAnswer $lines ((Get-Translation 'SelectorAdvancedPrompt') -f $advancedTag, (Get-WtTypedWord -Kind 'Confirm')) 'ADVANCED')
        if (Test-WtTypedConfirmation -Answer $typed -Kind 'Confirm') { $typedConfirmation = $true }
        else {
            $dropped.Add([PSCustomObject]@{ Kind = 'Confirm'; Labels = [string[]]@($plan.AdvancedEntries | ForEach-Object DisplayLabel) })
            foreach ($rec in @($plan.AdvancedEntries)) { & $dropNames $rec.SectionKey @($rec.EntryName) }
            $plan = & $replan
        }
    }

    if ($PreApprovedAdvanced -and @($plan.NonRestorablePackageNames).Count -gt 0) { $typedConfirmation = $true }
    elseif (@($plan.NonRestorablePackageNames).Count -gt 0) {
        $lines = @((Get-Translation 'NonRestorableWarning')) + @($plan.NonRestorablePackageNames | ForEach-Object { "  - $_" })
        $lines += ''
        $lines += (Get-WtGateWordHint -Kind 'Yes')
        $typed = [string](& $ReadAnswer $lines ((Get-Translation 'TypeYesToConfirm') -f (Get-WtTypedWord -Kind 'Yes')) 'ADVANCED')
        if (Test-WtTypedConfirmation -Answer $typed -Kind 'Yes') { $typedConfirmation = $true }
        else {
            $dropped.Add([PSCustomObject]@{ Kind = 'Yes'; Labels = (& $labelsFor 'Packages' ([string[]]@($plan.NonRestorablePackageNames))) })
            & $dropNames 'Packages' ([string[]]@($plan.NonRestorablePackageNames))
            $plan = & $replan
        }
    }

    $dnsPlan = @($plan.Sections) | Where-Object Key -eq 'DnsPreset' | Select-Object -First 1
    if ($dnsPlan -and @($dnsPlan.EntryNames).Count -gt 0) {
        $presetName = [string]$dnsPlan.EntryNames[0]
        $dnsLines = @((& $GetDnsDisclosure $presetName), '', (Get-WtGateWordHint -Kind 'Yes'))
        $typed = [string](& $ReadAnswer $dnsLines ((Get-Translation 'TypeYesToConfirm') -f (Get-WtTypedWord -Kind 'Yes')) 'CAUTION')
        if (Test-WtTypedConfirmation -Answer $typed -Kind 'Yes') { $typedConfirmation = $true }
        else {
            $dropped.Add([PSCustomObject]@{ Kind = 'Yes'; Labels = (& $labelsFor 'DnsPreset' ([string[]]@($dnsPlan.EntryNames))) })
            & $dropNames 'DnsPreset' ([string[]]@($dnsPlan.EntryNames))
            $plan = & $replan
        }
    }

    $blPlan = @($plan.Sections) | Where-Object Key -eq 'Blocklist' | Select-Object -First 1
    if ($blPlan -and @($blPlan.EntryNames).Count -gt 0) {
        $lines = @((Get-Translation 'SelectMechanism'), ('  [1] ' + (Get-Translation 'HostsFile')), ('  [2] ' + (Get-Translation 'FirewallRules')), ('  [3] ' + (Get-Translation 'Both')))
        $mechanism = ConvertTo-WtBlocklistMechanism -Answer ([string](& $ReadAnswer $lines (Get-Translation 'YourChoice') 'CAUTION'))
        if ($mechanism) {
            foreach ($rec in @($recordList | Where-Object SectionKey -eq 'Blocklist')) { $rec.Data = @{ Mechanism = $mechanism } }
        }
        else {
            $dropped.Add([PSCustomObject]@{ Kind = 'Mechanism'; Labels = (& $labelsFor 'Blocklist' ([string[]]@($blPlan.EntryNames))) })
            & $dropNames 'Blocklist' ([string[]]@($blPlan.EntryNames))
        }
        $plan = & $replan
    }

    return @{ Records = $recordList.ToArray(); Plan = $plan; TypedConfirmation = $typedConfirmation; Dropped = $dropped.ToArray() }
}
