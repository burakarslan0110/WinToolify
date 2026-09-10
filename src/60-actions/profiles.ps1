# Profile snapshot, save/read/list, import plan, apply, export/import screens.
# Covered by: tests/ConfigProfile.Tests.ps1

function New-WtProfileSnapshot {
    <#
    .SYNOPSIS
        Builds a profile object from the machine's live state: for every
        section, the Name of each catalog entry whose GetState is Applied.
        A profile is a snapshot of the machine, not of the session - it
        records what Windows currently has in the target state, whoever
        put it there.
    #>
    param(
        [array]$Sections = (Get-WtProfileSectionCatalog),

        [string]$Name,

        [scriptblock]$Progress
    )

    $sectionValues = [ordered]@{}
    foreach ($section in $Sections) {
        if ($Progress) { & $Progress $section.Key }
        $applied = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @(& $section.GetCatalog)) {
            if ((& $section.GetState $entry) -eq 'Applied') {
                $applied.Add([string]$entry.Name)
            }
        }
        $sectionValues[$section.Key] = [string[]]$applied.ToArray()
    }

    return [PSCustomObject]@{
        SchemaVersion     = 1
        Name              = $Name
        CreatedAt         = (Get-Date).ToString('s')
        ComputerName      = [string]$env:COMPUTERNAME
        OsVersion         = [System.Environment]::OSVersion.Version.ToString()
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Sections          = [PSCustomObject]$sectionValues
    }
}

function ConvertTo-WtProfileFileName {
    <#
    .SYNOPSIS
        Sanitizes a user-typed profile name into a file stem: every
        Windows-invalid or ASCII control character becomes '-', blank
        falls back to a timestamp. The invalid set is a literal, not
        GetInvalidFileNameChars() - on macOS that returns only '/' and
        NUL, which would make the tests host-dependent.
    #>
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Name
    )

    $stem = if ($null -eq $Name) { '' } else { $Name }
    $stem = [regex]::Replace($stem, '[\\/:*?"<>|\x00-\x1F]', '-').Trim()
    if ([string]::IsNullOrWhiteSpace($stem)) {
        $stem = 'profile-{0}' -f (Get-Date).ToString('yyyyMMdd-HHmmss')
    }
    return $stem
}

function Save-WtProfile {
    <#
    .SYNOPSIS
        Writes a profile to <profiles dir>\<sanitized name>.json under the
        User scope, sets the profile's Name to the
        sanitized stem so file and header agree, and returns the absolute
        path. Overwriting a same-named profile is allowed and silent - the
        name was the user's choice.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [string]$TestRootOverride
    )

    $dataPathArgs = @{ Scope = 'User'; SubPath = 'profiles' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    $profileDir = Get-WtDataPath @dataPathArgs

    $stem = ConvertTo-WtProfileFileName -Name $Profile.Name
    $Profile.Name = $stem
    $path = Join-Path $profileDir "$stem.json"
    Write-WtJson -Path $path -InputObject $Profile
    return $path
}

function Read-WtProfile {
    <#
    .SYNOPSIS
        Loads and validates one profile file. Never throws: returns
        @{ Profile; Error } where Error is $null on success or one of
        'NotReadable' (missing / not JSON), 'UnsupportedVersion'
        (SchemaVersion missing or not 1), 'NoSections' (Sections missing
        or not an object) - the caller maps these to translated lines.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $raw = Read-WtJson -Path $Path
    if ($null -eq $raw -or -not ($raw -is [PSCustomObject])) {
        return [PSCustomObject]@{ Profile = $null; Error = 'NotReadable' }
    }

    $hasVersion = $raw.PSObject.Properties.Name -contains 'SchemaVersion'
    if (-not $hasVersion -or [string]$raw.SchemaVersion -ne '1') {
        return [PSCustomObject]@{ Profile = $null; Error = 'UnsupportedVersion' }
    }

    $hasSections = $raw.PSObject.Properties.Name -contains 'Sections'
    if (-not $hasSections -or $null -eq $raw.Sections -or -not ($raw.Sections -is [PSCustomObject])) {
        return [PSCustomObject]@{ Profile = $null; Error = 'NoSections' }
    }

    return [PSCustomObject]@{ Profile = $raw; Error = $null }
}

function Get-WtProfiles {
    <#
    .SYNOPSIS
        Lists every valid profile in the User-scope profiles directory,
        newest first; each gains a Path note-property. Sorted by CreatedAt
        parsed as [datetime]: PS 7's ConvertFrom-Json already returns a
        DateTime (5.1 leaves it a string), and a string sort would
        misorder months before years. Invalid files are skipped, not fatal.
    #>
    param(
        [string]$TestRootOverride
    )

    $dataPathArgs = @{ Scope = 'User'; SubPath = 'profiles' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    $profileDir = Get-WtDataPath @dataPathArgs

    $profiles = New-Object System.Collections.Generic.List[object]
    $files = Get-ChildItem -LiteralPath $profileDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $loaded = Read-WtProfile -Path $file.FullName
        if ($loaded.Error) { continue }
        $loaded.Profile | Add-Member -NotePropertyName 'Path' -NotePropertyValue $file.FullName -Force
        $profiles.Add($loaded.Profile)
    }

    return @($profiles | Sort-Object -Property { [datetime]$_.CreatedAt } -Descending)
}

function Get-WtProfileImportPlan {
    <#
    .SYNOPSIS
        Diffs a loaded profile against the machine: each name lands in one
        bucket - ToApply, AlreadyApplied, NotPresent, or Unknown; unknown
        section keys go to UnknownSections. Reads state only for the
        profile's own names, so a diff costs less than a full export. Pure.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [array]$Sections = (Get-WtProfileSectionCatalog),

        [scriptblock]$Progress
    )

    $knownKeys = @($Sections | ForEach-Object { $_.Key })
    $sectionPlans = New-Object System.Collections.Generic.List[object]

    foreach ($section in $Sections) {
        if ($Progress) { & $Progress $section.Key }

        $names = @()
        if ($Profile.Sections.PSObject.Properties.Name -contains $section.Key) {
            $names = @($Profile.Sections.($section.Key) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        }

        $catalog = @(& $section.GetCatalog)
        $toApply = New-Object System.Collections.Generic.List[string]
        $alreadyApplied = New-Object System.Collections.Generic.List[string]
        $notPresent = New-Object System.Collections.Generic.List[string]
        $unknown = New-Object System.Collections.Generic.List[string]

        foreach ($name in $names) {
            $entry = $catalog | Where-Object Name -eq $name | Select-Object -First 1
            if (-not $entry) { $unknown.Add($name); continue }
            switch ([string](& $section.GetState $entry)) {
                'Applied'    { $alreadyApplied.Add($name) }
                'NotPresent' { $notPresent.Add($name) }
                default      { $toApply.Add($name) }
            }
        }

        $sectionPlans.Add([PSCustomObject]@{
            Key              = $section.Key
            TitleKey         = $section.TitleKey
            RestartsExplorer = [bool]$section.RestartsExplorer
            Catalog          = $catalog
            ToApply          = [string[]]$toApply.ToArray()
            AlreadyApplied   = [string[]]$alreadyApplied.ToArray()
            NotPresent       = [string[]]$notPresent.ToArray()
            Unknown          = [string[]]$unknown.ToArray()
        })
    }

    $unknownSections = @($Profile.Sections.PSObject.Properties.Name | Where-Object { $knownKeys -notcontains $_ })

    return [PSCustomObject]@{
        Sections        = $sectionPlans.ToArray()
        UnknownSections = [string[]]$unknownSections
    }
}

function Invoke-WtApplyProfile {
    <#
    .SYNOPSIS
        Applies an import plan section by section through each section's
        guarded Apply delegate with that section's ToApply names. The first
        Aborted result (the user declined the restore-point prompt) ends the
        import: later sections are recorded Skipped, never re-prompted.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Plan,

        [array]$Sections = (Get-WtProfileSectionCatalog)
    )

    $outcomes = New-Object System.Collections.Generic.List[object]
    $aborted = $false

    foreach ($sectionPlan in @($Plan.Sections)) {
        $section = $Sections | Where-Object Key -eq $sectionPlan.Key | Select-Object -First 1
        $names = @($sectionPlan.ToApply)

        $outcome = 'NothingToApply'
        $results = @()

        if ($aborted) {
            $outcome = 'Skipped'
        }
        elseif ($names.Count -gt 0 -and $section) {
            $applyResult = & $section.Apply ([string[]]$names)
            if ($applyResult -and $applyResult.Aborted) {
                $outcome = 'Aborted'
                $aborted = $true
            }
            else {
                $outcome = 'Applied'
                if ($applyResult) { $results = @($applyResult.Results) }
            }
        }

        $outcomes.Add([PSCustomObject]@{
            Key              = $sectionPlan.Key
            TitleKey         = $sectionPlan.TitleKey
            RestartsExplorer = [bool]$sectionPlan.RestartsExplorer
            Catalog          = $sectionPlan.Catalog
            Outcome          = $outcome
            Results          = $results
        })
    }

    return [PSCustomObject]@{ Sections = $outcomes.ToArray(); Aborted = $aborted }
}

function Format-WtProfileResultLabel {
    <#
    .SYNOPSIS
        Display label for one apply-result row of any section: the catalog
        entry name when the undo item carries one (Registry / PowerSetting
        / RegistryKey items), plus the item's own Name in parentheses when
        it differs; plain Name otherwise (Service / Package items).
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item
    )

    $props = $Item.PSObject.Properties.Name
    $catalogEntry = if ($props -contains 'CatalogEntry') { [string]$Item.CatalogEntry } else { '' }
    $name = if ($props -contains 'Name') { [string]$Item.Name } else { '' }

    if ($catalogEntry -and $name -and $catalogEntry -ne $name) { return "$catalogEntry ($name)" }
    if ($catalogEntry) { return $catalogEntry }
    return $name
}

function Show-WtProfileExport {
    <#
    .SYNOPSIS
        Export branch of the Config Profiles menu: asks for a name, takes a
        live-state snapshot, saves it, and prints the absolute path, since
        an elevated standard-account user has the file under the
        administrator's LOCALAPPDATA. All rendered inside the panel.
    #>
    param(
        [string]$TestRootOverride,
        [scriptblock]$AskName = { Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines @() -Prompt (Get-Translation 'ProfileNamePrompt') -Layout 'Compact' },
        [scriptblock]$ShowProgress = { param($Lines) Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null }
    )

    $sections = @(Get-WtProfileSectionCatalog)
    $titleByKey = @{}
    foreach ($section in $sections) { $titleByKey[$section.Key] = $section.TitleKey }
    if (-not $script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb = Get-Translation 'ExportProfile' }

    $name = ([string](& $AskName)).Trim()
    if (-not $name) { return }

    $progressLines = New-Object System.Collections.Generic.List[string]
    $profile = New-WtProfileSnapshot -Sections $sections -Name $name -Progress {
        param($Key)
        $progressLines.Add(('  {0}: {1}...' -f (Get-Translation 'ProfileReadingState'), (Get-Translation $titleByKey[$Key])))
        & $ShowProgress $progressLines.ToArray()
    }

    $saveArgs = @{ Profile = $profile }
    if ($TestRootOverride) { $saveArgs['TestRootOverride'] = $TestRootOverride }
    $path = Save-WtProfile @saveArgs

    & $ShowResult (Format-WtProfileExportLines -Profile $profile -Sections $sections -Path $path)
}

function Format-WtProfileExportLines {
    <#
    .SYNOPSIS
        PURE: where the profile was written, then one row per section
        with how many entries it captured.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Profile,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Sections,
        [Parameter(Mandatory)][string]$Path
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Translation 'ProfileSaved') + ':')
    $lines.Add('  ' + $Path)
    $lines.Add('')
    $lines.Add((Get-Translation 'ProfileSectionCount') + ':')
    foreach ($section in $Sections) {
        $lines.Add(('  {0}: {1}' -f (Get-Translation $section.TitleKey), @($Profile.Sections.($section.Key)).Count))
    }
    return [string[]]$lines.ToArray()
}

function Show-WtProfileImport {
    <#
    .SYNOPSIS
        Import branch of the Config Profiles menu: pick or type a path,
        validate, show the diff, re-raise the two gates Show-WtSelector
        would apply (typed CONFIRM for ADVANCED, typed YES for
        non-restorable, since import bypasses the selector), confirm once,
        apply, and offer one Explorer restart.
    #>
    param(
        [string]$TestRootOverride,
        [scriptblock]$Ask = { param($Lines, $Prompt, $Risk) Read-WtPanelAnswer -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines -Prompt $Prompt -Risk $Risk },
        [scriptblock]$ShowProgress = { param($Lines) Show-WtPanelMessage -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null },
        [scriptblock]$ShowResult = { param($Lines) Show-WtOutputScreen -Breadcrumb $script:WtPanelBreadcrumb -Lines $Lines | Out-Null }
    )

    $listArgs = @{}
    if ($TestRootOverride) { $listArgs['TestRootOverride'] = $TestRootOverride }
    $profiles = @(Get-WtProfiles @listArgs)
    if (-not $script:WtPanelBreadcrumb) { $script:WtPanelBreadcrumb = Get-Translation 'ImportProfile' }

    $choice = ([string](& $Ask (Format-WtProfilePickerLines -Profiles $profiles) (Get-Translation 'YourChoice') '')).Trim()
    $path = $null
    if ($choice -match '^[Qq]$' -or -not $choice) { return }
    if ($choice -match '^[Ff]$') {
        $typedPath = ([string](& $Ask @() (Get-Translation 'ProfilePathPrompt') '')).Trim().Trim('"')
        if (-not $typedPath) { return }
        $path = $typedPath
    }
    elseif ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $profiles.Count) {
        $path = $profiles[[int]$choice].Path
    }
    else {
        Wait-WtEnter -Lines @((Get-Translation 'InvalidSelection'))
        return
    }

    $loaded = Read-WtProfile -Path $path
    if ($loaded.Error) {
        $messageKey = switch ($loaded.Error) {
            'UnsupportedVersion' { 'ProfileUnsupportedVersion' }
            'NoSections' { 'ProfileNoSections' }
            default { 'ProfileNotReadable' }
        }
        Wait-WtEnter -Lines @((Get-Translation $messageKey))
        return
    }

    $sections = @(Get-WtProfileSectionCatalog)
    $titleByKey = @{}
    foreach ($section in $sections) { $titleByKey[$section.Key] = $section.TitleKey }

    $progressLines = New-Object System.Collections.Generic.List[string]
    $plan = Get-WtProfileImportPlan -Profile $loaded.Profile -Sections $sections -Progress {
        param($Key)
        $progressLines.Add(('  {0}: {1}...' -f (Get-Translation 'ProfileReadingState'), (Get-Translation $titleByKey[$Key])))
        & $ShowProgress $progressLines.ToArray()
    }

    $diff = Format-WtProfileDiffLines -Plan $plan -ProfileName $loaded.Profile.Name

    $totalToApply = 0
    foreach ($sectionPlan in @($plan.Sections)) { $totalToApply += @($sectionPlan.ToApply).Count }
    if ($totalToApply -eq 0) {
        & $ShowResult (@($diff) + @('', (Get-Translation 'ProfileNothingToApply')))
        return
    }

    $advancedRows = New-Object System.Collections.Generic.List[object]
    foreach ($sectionPlan in @($plan.Sections)) {
        if (Test-WtSelectionNeedsAdvancedConfirm -Catalog $sectionPlan.Catalog -SelectionSet @($sectionPlan.ToApply)) {
            foreach ($entry in @($sectionPlan.Catalog | Where-Object { $sectionPlan.ToApply -contains $_.Name -and $_.Risk -eq 'ADVANCED' })) {
                $advancedRows.Add([PSCustomObject]@{ SectionPlan = $sectionPlan; Entry = $entry })
            }
        }
    }
    $typedConfirmation = $false
    if ($advancedRows.Count -gt 0) {
        $advancedTag = Get-WtRiskLabel -Risk 'ADVANCED'
        $lines = @((Get-Translation 'ProfileAdvancedWarning') -f $advancedTag)
        foreach ($row in $advancedRows) { $lines += ('  - {0}: {1}' -f $row.Entry.Name, $row.Entry.Consequence) }
        $typed = [string](& $Ask $lines ((Get-Translation 'ProfileTypeConfirm') -f $advancedTag, (Get-WtTypedWord -Kind 'Confirm')) 'ADVANCED')
        if (Test-WtTypedConfirmation -Answer $typed -Kind 'Confirm') { $typedConfirmation = $true }
        else {
            foreach ($row in $advancedRows) {
                $row.SectionPlan.ToApply = [string[]]@($row.SectionPlan.ToApply | Where-Object { $_ -ne $row.Entry.Name })
            }
        }
    }

    $packagesPlan = @($plan.Sections) | Where-Object Key -eq 'Packages' | Select-Object -First 1
    if ($packagesPlan) {
        $nonRestorable = @($packagesPlan.Catalog | Where-Object { $packagesPlan.ToApply -contains $_.Name -and -not $_.Restorable })
        if ($nonRestorable.Count -gt 0) {
            $lines = @((Get-Translation 'NonRestorableWarning'))
            foreach ($nrEntry in $nonRestorable) { $lines += ('  - ' + $nrEntry.Name) }
            $nrTyped = [string](& $Ask $lines ((Get-Translation 'TypeYesToConfirm') -f (Get-WtTypedWord -Kind 'Yes')) 'ADVANCED')
            if (Test-WtTypedConfirmation -Answer $nrTyped -Kind 'Yes') { $typedConfirmation = $true }
            else {
                $dropped = @($nonRestorable | ForEach-Object { $_.Name })
                $packagesPlan.ToApply = [string[]]@($packagesPlan.ToApply | Where-Object { $dropped -notcontains $_ })
            }
        }
    }

    $totalToApply = 0
    foreach ($sectionPlan in @($plan.Sections)) { $totalToApply += @($sectionPlan.ToApply).Count }
    if ($totalToApply -eq 0) {
        & $ShowResult (@($diff) + @('', (Get-Translation 'ProfileNothingToApply')))
        return
    }

    if (-not $typedConfirmation) {
        $answer = [string](& $Ask $diff (Get-WtYesNoPrompt -Text ((Get-Translation 'ProfileConfirmApply') + " [$totalToApply]")) '')
        if (-not (Test-WtAffirmativeAnswer -Answer $answer)) {
            Wait-WtEnter -Lines @((Get-Translation 'ActionCancelled'))
            return
        }
    }

    $result = Invoke-WtApplyProfile -Plan $plan -Sections $sections
    $lines = Format-WtProfileImportResultLines -Result $result -ProfileName $loaded.Profile.Name

    $restartCatalog = New-Object System.Collections.Generic.List[object]
    $restartResults = New-Object System.Collections.Generic.List[object]
    foreach ($sectionResult in @($result.Sections)) {
        if (-not $sectionResult.RestartsExplorer -or $sectionResult.Outcome -ne 'Applied') { continue }
        foreach ($entry in @($sectionResult.Catalog)) { $restartCatalog.Add($entry) }
        foreach ($row in @($sectionResult.Results)) { $restartResults.Add($row) }
    }
    if ($restartResults.Count -gt 0) {
        Show-WtExplorerRestartPrompt -Catalog $restartCatalog.ToArray() -Results $restartResults.ToArray()
    }

    & $ShowResult (@($lines) + @('', (Get-Translation 'ProfileImportDone')))
}

function Format-WtProfilePickerLines {
    <#
    .SYNOPSIS
        PURE: the numbered profile list plus the [F] path and [Q] cancel
        rows, exactly as the panel prompt shows them.
    #>
    param([AllowEmptyCollection()][array]$Profiles = @())
    $lines = New-Object System.Collections.Generic.List[string]
    if (@($Profiles).Count -eq 0) { $lines.Add('  ' + (Get-Translation 'NoProfilesFound')) }
    else {
        for ($i = 0; $i -lt @($Profiles).Count; $i++) {
            $p = @($Profiles)[$i]
            $lines.Add(('  [{0}] {1} - {2} - {3}' -f $i, $p.Name, ([datetime]$p.CreatedAt).ToString('yyyy-MM-dd HH:mm:ss'), $p.ComputerName))
        }
    }
    $lines.Add('  [F] ' + (Get-Translation 'EnterProfilePath'))
    $lines.Add('  [Q] ' + (Get-Translation 'Cancel'))
    return [string[]]$lines.ToArray()
}

function Format-WtProfileDiffLines {
    <#
    .SYNOPSIS
        PURE: the per-section import diff - what will apply, how much is
        already applied, what is missing and what this build does not know.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Plan,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProfileName
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'ImportProfile'), $ProfileName))
    $lines.Add('')
    foreach ($sectionPlan in @($Plan.Sections)) {
        $lines.Add([string](Get-Translation $sectionPlan.TitleKey))
        $toApply = if (@($sectionPlan.ToApply).Count -gt 0) { @($sectionPlan.ToApply) -join ', ' } else { '-' }
        $lines.Add(('  {0}: {1}' -f (Get-Translation 'ProfileToApply'), $toApply))
        $lines.Add(('  {0}: {1}' -f (Get-Translation 'ProfileAlreadyApplied'), @($sectionPlan.AlreadyApplied).Count))
        if (@($sectionPlan.NotPresent).Count -gt 0) { $lines.Add(('  {0}: {1}' -f (Get-Translation 'ProfileNotPresent'), (@($sectionPlan.NotPresent) -join ', '))) }
        if (@($sectionPlan.Unknown).Count -gt 0) { $lines.Add(('  {0}: {1}' -f (Get-Translation 'ProfileUnknownEntries'), (@($sectionPlan.Unknown) -join ', '))) }
    }
    if (@($Plan.UnknownSections).Count -gt 0) {
        $lines.Add('')
        $lines.Add(('{0}: {1}' -f (Get-Translation 'ProfileUnknownSections'), (@($Plan.UnknownSections) -join ', ')))
    }
    return [string[]]$lines.ToArray()
}

function Format-WtProfileImportResultLines {
    <#
    .SYNOPSIS
        PURE: what the import actually did, per section and per row, plus
        the reboot note when an applied entry needs one.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProfileName
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('{0}: {1}' -f (Get-Translation 'ImportProfile'), $ProfileName))
    $lines.Add('')
    foreach ($sectionResult in @($Result.Sections)) {
        if ($sectionResult.Outcome -eq 'NothingToApply') { continue }
        $lines.Add([string](Get-Translation $sectionResult.TitleKey))
        switch ($sectionResult.Outcome) {
            'Aborted' { $lines.Add('  ' + (Get-Translation 'ActionCancelled')) }
            'Skipped' { $lines.Add('  ' + (Get-Translation 'ProfileImportStopped')) }
            default {
                foreach ($row in @($sectionResult.Results)) {
                    $status = if ($row.Applied) { Get-Translation 'Applied' } else { Get-Translation 'NotApplied' }
                    if (-not $row.Applied -and $row.Error) { $status = '{0} - {1}' -f $status, $row.Error }
                    $lines.Add(('  {0}: {1}' -f (Format-WtProfileResultLabel -Item $row.Item), $status))
                }
            }
        }
    }
    if (Test-WtProfileRebootNeeded -Sections @($Result.Sections)) {
        $lines.Add('')
        $lines.Add([string](Get-Translation 'RestartRequired'))
    }
    return [string[]]$lines.ToArray()
}
