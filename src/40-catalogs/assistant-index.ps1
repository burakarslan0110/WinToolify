# The state-aware WinToolify tool index the assistant searches, suggests
# from and acts on, built stateless once per process and cached.
# Covered by: tests/AssistantIndex.Tests.ps1

function Get-WtAssistantNeverRunRows {
    <#
    .SYNOPSIS
        Action rows the model may only SUGGEST, never run, on top of the
        structural rules (Power rows, Inline rows, Delete* names): the
        cleanups that discard data with no undo entry.
    #>
    return [string[]]@('ClearPrintQueue', 'CleanComponentStore', 'WindowsDiskCleanup', 'DeleteOldRestorePoints')
}

function Get-WtAssistantCatalogText {
    <#
    .SYNOPSIS
        One catalog prose field in ONE requested language: the key's
        translated text (formatted with its Args property when present),
        else the entry's shipped literal, else empty. Needed because
        catalogs resolve DisplayLabel only in the active language.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$KeyProperty,
        [Parameter(Mandatory)][string]$TextProperty,
        [Parameter(Mandatory)][ValidateSet('EN', 'TR')][string]$Language
    )
    $props = @($Entry.PSObject.Properties.Name)
    if ($props -contains $KeyProperty -and $Entry.$KeyProperty) {
        $text = [string]$script:Translations[$Language][[string]$Entry.$KeyProperty]
        if ($text) {
            $argsProperty = $KeyProperty.Replace('Key', 'Args')
            if ($props -contains $argsProperty -and $null -ne $Entry.$argsProperty) {
                try { $text = $text -f @($Entry.$argsProperty) } catch { $null = $_ }
            }
            return $text
        }
    }
    if ($props -contains $TextProperty -and $Entry.$TextProperty) { return [string]$Entry.$TextProperty }
    return ''
}

function ConvertTo-WtAssistantSearchTokens {
    <#
    .SYNOPSIS
        Folded (Turkish letters -> ASCII, invariant lower) and split on
        anything that is not a-z/0-9. The class is ordinal in .NET regex,
        so tr-TR casing cannot reach it.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $folded = ConvertTo-WtAssistantSearchText -Text ([string]$Text)
    return [string[]]@([regex]::Split($folded, '[^a-z0-9]+') | Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
}

function Remove-WtAssistantLabelPrefix {
    <#
    .SYNOPSIS
        PURE: strips a '<Name> - ' prefix from a catalog label whose id
        already carries the name (Packages); a label that IS the prefix,
        or does not start with it, comes back unchanged.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Label, [AllowNull()][AllowEmptyString()][string]$Prefix)
    $text = [string]$Label
    $head = [string]$Prefix
    if ($head -and $text.Length -gt $head.Length -and $text.StartsWith($head, [System.StringComparison]::OrdinalIgnoreCase)) { return $text.Substring($head.Length) }
    return $text
}

function New-WtAssistantIndexEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Toggle', 'Action', 'Info', 'Screen', 'Winget')][string]$Kind,
        [string]$SectionKey = '',
        [string]$Section = '',
        [AllowEmptyString()][string]$LabelEn = '',
        [AllowEmptyString()][string]$LabelTr = '',
        [AllowEmptyString()][string]$PathEn = '',
        [AllowEmptyString()][string]$PathTr = '',
        [AllowEmptyString()][string]$Risk = '',
        [AllowEmptyString()][string]$ConsequenceEn = '',
        [AllowEmptyString()][string]$ConsequenceTr = '',
        [bool]$Removable = $false,
        [bool]$Runnable = $false,
        [string]$Screen = '',
        [AllowNull()]$Item = $null,
        [AllowNull()]$Entry = $null,
        [AllowEmptyString()][string]$ExtraSearchText = '',
        [AllowEmptyString()][string]$DescriptionEn = '',
        [AllowEmptyString()][string]$DescriptionTr = '',
        [AllowEmptyString()][string]$Tags = '',
        [AllowEmptyString()][string]$Twin = ''
    )
    $haystack = ConvertTo-WtAssistantSearchText -Text (@($LabelEn, $LabelTr, $PathEn, $PathTr, $ConsequenceEn, $ConsequenceTr, $DescriptionEn, $DescriptionTr, $Id, $ExtraSearchText, $Tags) -join ' ')
    $labelText = ConvertTo-WtAssistantSearchText -Text (@($LabelEn, $LabelTr, $Id, $Tags, $ExtraSearchText) -join ' ')
    $descText = ConvertTo-WtAssistantSearchText -Text (@($ConsequenceEn, $ConsequenceTr, $DescriptionEn, $DescriptionTr) -join ' ')
    $pathText = ConvertTo-WtAssistantSearchText -Text (@($PathEn, $PathTr) -join ' ')
    return [PSCustomObject]@{
        Id = $Id; Kind = $Kind; SectionKey = $SectionKey; Section = $Section
        LabelEn = $LabelEn; LabelTr = $LabelTr; PathEn = $PathEn; PathTr = $PathTr
        Risk = $Risk; ConsequenceEn = $ConsequenceEn; ConsequenceTr = $ConsequenceTr
        DescriptionEn = $DescriptionEn; DescriptionTr = $DescriptionTr; Tags = $Tags; Twin = $Twin
        Removable = $Removable; Runnable = $Runnable; Screen = $Screen; Item = $Item; Entry = $Entry
        Haystack = $haystack
        Tokens = (ConvertTo-WtAssistantSearchTokens -Text $haystack)
        LabelTokens = (ConvertTo-WtAssistantSearchTokens -Text $labelText)
        DescTokens = (ConvertTo-WtAssistantSearchTokens -Text $descText)
        PathTokens = (ConvertTo-WtAssistantSearchTokens -Text $pathText)
    }
}

function Test-WtAssistantRowRunnable {
    <#
    .SYNOPSIS
        The assistant may run a Captured or Native row; never a Power
        row, an Inline row (it paints its own panel and reads the
        keyboard), a Delete* row, or one on the never-run list.
    #>
    param([Parameter(Mandatory)]$Row)
    $data = $Row.Data
    $name = [string]$Row.Name
    if ($name.StartsWith('Delete', [System.StringComparison]::Ordinal)) { return $false }
    foreach ($never in (Get-WtAssistantNeverRunRows)) {
        if ([string]::Equals($never, $name, [System.StringComparison]::Ordinal)) { return $false }
    }
    if ($null -eq $data) { return $false }
    if ($data.Power) { return $false }
    if ($data.Native -or $data.Captured) { return $true }
    return $false
}

function Get-WtAssistantTagArgs {
    <#
    .SYNOPSIS
        PURE: the splat for New-WtAssistantIndexEntry from the tag table's
        record for one id - empty strings when the id has none.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Id, [AllowNull()][hashtable]$Table = $null)
    $args = @{ DescriptionEn = ''; DescriptionTr = ''; Tags = '' }
    if ($null -eq $Table -or -not $Table.ContainsKey($Id)) { return $args }
    $record = $Table[$Id]
    if ($record.ContainsKey('En')) { $args.DescriptionEn = [string]$record.En }
    if ($record.ContainsKey('Tr')) { $args.DescriptionTr = [string]$record.Tr }
    if ($record.ContainsKey('Tags')) { $args.Tags = [string]$record.Tags }
    return $args
}

function Get-WtAssistantNavRows {
    <#
    .SYNOPSIS
        Action rows that live on navigation screens rather than the
        Actions/Information tables - the main menu's restore point,
        Profiles' export/import - as @{ Item; Section; PathKeys }. A
        missing screen builder (a partial dot-source) yields no rows
        rather than an error.
    #>
    $sources = @(
        @{ Builder = 'Get-WtMainMenuItems'; Section = 'MainMenu'; PathKeys = @('MainMenu') }
        @{ Builder = 'Get-WtBasicToolsItems'; Section = 'BasicTools'; PathKeys = @('MainMenu', 'BasicTools') }
        @{ Builder = 'Get-WtProfilesMenuItems'; Section = 'ConfigProfiles'; PathKeys = @('MainMenu', 'ConfigProfiles') }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($source in $sources) {
        if (-not (Get-Command -Name ([string]$source.Builder) -ErrorAction SilentlyContinue)) { continue }
        $items = @()
        try { $items = @(& ([string]$source.Builder)) } catch { $items = @() }
        foreach ($item in $items) {
            if ([string]$item.Kind -ne 'Action' -or $null -eq $item.Data) { continue }
            if ($item.Data.Exit) { continue }
            if (-not ($item.Data.Action -or $item.Data.Captured -or $item.Data.Native)) { continue }
            $rows.Add(@{ Item = $item; Section = [string]$source.Section; PathKeys = [string[]]@($source.PathKeys) })
        }
    }
    return $rows.ToArray()
}

function Reset-WtAssistantIndexCache { $script:WtAssistantIndexCache = $null; $script:WtAssistantSectionEnumCache = $null; $script:WtAssistantIdfCache = $null }

function Get-WtAssistantSearchSections {
    <#
    .SYNOPSIS
        The search tool's `section` enum: every apply-section key (the
        stateless per-app screen excluded), then the three kind filters.
        Cached per process since the registry asks for it on every dispatch.
    #>
    param([AllowNull()][array]$Sections = $null)
    if ($null -eq $Sections -and $null -ne $script:WtAssistantSectionEnumCache) { return [string[]]$script:WtAssistantSectionEnumCache }
    $catalog = $(if ($null -ne $Sections) { @($Sections) } else { @(Get-WtApplySectionCatalog) })
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($section in $catalog) {
        $key = [string]$section.Key
        if ([string]::Equals($key, 'PerAppPermissions', [System.StringComparison]::Ordinal)) { continue }
        if (-not $keys.Contains($key)) { $keys.Add($key) }
    }
    foreach ($kind in @('Tools', 'Screens', 'Winget')) { $keys.Add($kind) }
    $result = [string[]]$keys.ToArray()
    if ($null -eq $Sections) { $script:WtAssistantSectionEnumCache = $result }
    return $result
}

function Get-WtAssistantToolIndex {
    <#
    .SYNOPSIS
        Builds (or returns the cached) index; injecting a source or
        -NoCache bypasses the cache. Returns via the unary comma - assign
        bare. Winget rows are suggestion-only, never run by the assistant.
    #>
    param(
        [AllowNull()][array]$Sections = $null,
        [AllowNull()][array]$ActionGroups = $null,
        [AllowNull()][array]$InfoGroups = $null,
        [AllowNull()][array]$WingetCatalog = $null,
        [AllowNull()][array]$NavRows = $null,
        [switch]$NoCache
    )
    $injected = ($null -ne $Sections -or $null -ne $ActionGroups -or $null -ne $InfoGroups -or $null -ne $WingetCatalog -or $null -ne $NavRows)
    if (-not $injected -and -not $NoCache -and $null -ne $script:WtAssistantIndexCache) { return , $script:WtAssistantIndexCache }
    if ($null -eq $Sections) { $Sections = @(Get-WtApplySectionCatalog) }
    if ($null -eq $ActionGroups) { $ActionGroups = @(Get-WtActionToolGroups) }
    if ($null -eq $InfoGroups) { $InfoGroups = @(Get-WtInfoToolGroups) }
    if ($null -eq $WingetCatalog) { $WingetCatalog = @(Get-WtWingetStoreCatalog) }
    if ($null -eq $NavRows) { $NavRows = @(Get-WtAssistantNavRows) }
    $en = $script:Translations['EN']
    $tr = $script:Translations['TR']
    $tagTable = Get-WtAssistantSearchTagTable
    $twinTable = Get-WtAssistantTwinTable
    $index = New-Object System.Collections.Generic.List[object]

    foreach ($section in @($Sections)) {
        $key = [string]$section.Key
        if ($key -eq 'PerAppPermissions') { continue }
        $catalog = @()
        try { $catalog = @(& $section.GetCatalog) } catch { $catalog = @() }
        $stageOnly = [bool](($section.PSObject.Properties.Name -contains 'StageOnly') -and $section.StageOnly)
        foreach ($entry in $catalog) {
            $props = @($entry.PSObject.Properties.Name)
            $name = [string]$entry.Name
            $labelEn = Get-WtAssistantCatalogText -Entry $entry -KeyProperty 'LabelKey' -TextProperty 'DisplayLabel' -Language 'EN'
            $labelTr = Get-WtAssistantCatalogText -Entry $entry -KeyProperty 'LabelKey' -TextProperty 'DisplayLabel' -Language 'TR'
            if (-not $labelEn) { $labelEn = $name }
            if (-not $labelTr) { $labelTr = $labelEn }
            if ([string]::Equals($key, 'Packages', [System.StringComparison]::Ordinal)) {
                $labelEn = Remove-WtAssistantLabelPrefix -Label $labelEn -Prefix ($name + ' - ')
                $labelTr = Remove-WtAssistantLabelPrefix -Label $labelTr -Prefix ($name + ' - ')
            }
            if ([string]::Equals($key, 'DnsPreset', [System.StringComparison]::Ordinal)) {
                $dnsLabel = $name + ' DNS (' + [string]$entry.IPv4Primary + ', ' + [string]$entry.IPv4Secondary + ')'
                $labelEn = $dnsLabel
                $labelTr = $dnsLabel
            }
            $removable = $false
            if ($section.TurnOff) {
                $removable = $true
                if ($section.IsRemovable) { try { $removable = [bool](& $section.IsRemovable $entry) } catch { $removable = $false } }
            }
            $tagArgs = Get-WtAssistantTagArgs -Id ($key + ':' + $name) -Table $tagTable
            $twinId = $(if ($twinTable.ContainsKey($key + ':' + $name)) { [string]$twinTable[$key + ':' + $name] } else { '' })
            $index.Add((New-WtAssistantIndexEntry @tagArgs -Id ($key + ':' + $name) -Kind 'Toggle' -SectionKey $key -Section ([string]$section.TitleKey) `
                -LabelEn $labelEn -LabelTr $labelTr -PathEn ([string]$en[[string]$section.TitleKey]) -PathTr ([string]$tr[[string]$section.TitleKey]) `
                -Risk $(if ($props -contains 'Risk' -and $entry.Risk) { [string]$entry.Risk } else { '' }) `
                -ConsequenceEn (Get-WtAssistantCatalogText -Entry $entry -KeyProperty 'ConsequenceKey' -TextProperty 'Consequence' -Language 'EN') `
                -ConsequenceTr (Get-WtAssistantCatalogText -Entry $entry -KeyProperty 'ConsequenceKey' -TextProperty 'Consequence' -Language 'TR') `
                -Removable $removable -Runnable (-not $stageOnly) -Screen $(if ($stageOnly) { 'SystemSettings' } else { '' }) -Twin $twinId -Entry $entry))
        }
    }

    foreach ($pair in @(@{ Groups = $ActionGroups; Kind = 'Action'; RootKey = 'ActionTools' }, @{ Groups = $InfoGroups; Kind = 'Info'; RootKey = 'InformationTools' })) {
        foreach ($group in @($pair.Groups)) {
            $rows = @()
            try { $rows = @(& $group.GetRows) } catch { $rows = @() }
            foreach ($row in $rows) {
                $name = [string]$row.Name
                $tagArgs = Get-WtAssistantTagArgs -Id $name -Table $tagTable
                $index.Add((New-WtAssistantIndexEntry @tagArgs -Id $name -Kind $pair.Kind -Section ([string]$group.HeaderKey) `
                    -LabelEn ([string]$en[$name]) -LabelTr ([string]$tr[$name]) `
                    -PathEn ([string]$en[[string]$pair.RootKey] + ' > ' + [string]$en[[string]$group.HeaderKey]) `
                    -PathTr ([string]$tr[[string]$pair.RootKey] + ' > ' + [string]$tr[[string]$group.HeaderKey]) `
                    -Risk $(if ([string]$row.Risk) { [string]$row.Risk } elseif ([string]::Equals([string]$pair.Kind, 'Info', [System.StringComparison]::Ordinal)) { 'SAFE' } else { '' }) `
                    -Runnable (Test-WtAssistantRowRunnable -Row $row) -Item $row))
            }
        }
    }

    foreach ($nav in @($NavRows)) {
        $row = $nav.Item
        $name = [string]$row.Name
        $pathEn = @($nav.PathKeys | ForEach-Object { [string]$en[[string]$_] }) -join ' > '
        $pathTr = @($nav.PathKeys | ForEach-Object { [string]$tr[[string]$_] }) -join ' > '
        $tagArgs = Get-WtAssistantTagArgs -Id $name -Table $tagTable
        $index.Add((New-WtAssistantIndexEntry @tagArgs -Id $name -Kind 'Action' -Section ([string]$nav.Section) `
            -LabelEn ([string]$en[$name]) -LabelTr ([string]$tr[$name]) -PathEn $pathEn -PathTr $pathTr `
            -Risk ([string]$row.Risk) -Runnable (Test-WtAssistantRowRunnable -Row $row) -Item $row))
    }

    foreach ($screen in @(
        @{ Id = 'Screen:BasicTools'; Key = 'BasicTools'; Screen = 'BasicTools'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:ActionTools'; Key = 'ActionTools'; Screen = 'ActionTools'; PathKeys = @('MainMenu', 'BasicTools') }
        @{ Id = 'Screen:InfoTools'; Key = 'InformationTools'; Screen = 'InfoTools'; PathKeys = @('MainMenu', 'BasicTools') }
        @{ Id = 'Screen:Services'; Key = 'ServicesManagement'; Screen = 'Services'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:SystemSettings'; Key = 'SystemSettings'; Screen = 'SystemSettings'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:Privacy'; Key = 'PrivacySettings'; Screen = 'Privacy'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:PerApp'; Key = 'PerAppPermissions'; Screen = 'PerApp'; PathKeys = @('MainMenu', 'PrivacySettings', 'PrivacyAppPermissionsScreen') }
        @{ Id = 'Screen:Packages'; Key = 'AppsMenu'; Screen = 'Packages'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:WingetStore'; Key = 'WingetStore'; Screen = 'WingetStore'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:Language'; Key = 'Language'; Screen = 'Language'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:Undo'; Key = 'UndoLastChange'; Screen = 'Undo'; PathKeys = @('MainMenu') }
        @{ Id = 'Screen:Profiles'; Key = 'ConfigProfiles'; Screen = 'Profiles'; PathKeys = @('MainMenu') }
    )) {
        $tagArgs = Get-WtAssistantTagArgs -Id ([string]$screen.Id) -Table $tagTable
        $index.Add((New-WtAssistantIndexEntry @tagArgs -Id ([string]$screen.Id) -Kind 'Screen' -LabelEn ([string]$en[[string]$screen.Key]) -LabelTr ([string]$tr[[string]$screen.Key]) `
            -PathEn (@($screen.PathKeys | ForEach-Object { [string]$en[[string]$_] }) -join ' > ') `
            -PathTr (@($screen.PathKeys | ForEach-Object { [string]$tr[[string]$_] }) -join ' > ') -Screen ([string]$screen.Screen)))
    }

    $categoryKeys = @{}
    foreach ($category in @(Get-WtWingetStoreCategories)) { $categoryKeys[[string]$category.Key] = [string]$category.LabelKey }
    foreach ($package in @($WingetCatalog)) {
        $categoryKey = [string]$categoryKeys[[string]$package.Category]
        $index.Add((New-WtAssistantIndexEntry -Id ('Winget:' + [string]$package.Id) -Kind 'Winget' -Section ([string]$package.Category) `
            -LabelEn ([string]$package.Name) -LabelTr ([string]$package.Name) `
            -PathEn ([string]$en['WingetStore'] + ' > ' + [string]$en[$categoryKey]) -PathTr ([string]$tr['WingetStore'] + ' > ' + [string]$tr[$categoryKey]) `
            -Screen 'WingetStore' -ExtraSearchText ([string]$package.Tags)))
    }

    $built = $index.ToArray()
    if (-not $injected -and -not $NoCache) { $script:WtAssistantIndexCache = $built }
    return , $built
}

function Get-WtAssistantIndexEntry {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [AllowNull()][array]$Index = $null
    )
    $entries = if ($null -ne $Index) { @($Index) } else { Get-WtAssistantToolIndex }
    foreach ($entry in $entries) {
        if ([string]::Equals([string]$entry.Id, $Id, [System.StringComparison]::Ordinal)) { return $entry }
    }
    return $null
}

function Get-WtAssistantIndexLabel {
    param([Parameter(Mandatory)]$Entry)
    if ($script:Language -eq 'TR') { return [string]$Entry.LabelTr }
    return [string]$Entry.LabelEn
}

function Get-WtAssistantTokenHit {
    <#
    .SYNOPSIS
        2 = the word is a token; 1 = word and token share a 5+ char
        prefix in either direction (matches Turkish suffixes, e.g.
        "telemetriyi" finds "telemetri"); 0 = nothing. Ordinal only.
    #>
    param([AllowEmptyCollection()][string[]]$Tokens = @(), [Parameter(Mandatory)][string]$Word)
    $best = 0
    foreach ($token in @($Tokens)) {
        if ([string]::Equals($token, $Word, [System.StringComparison]::Ordinal)) { return 2 }
        if ($best -eq 0 -and $Word.Length -ge 5 -and $token.Length -ge 5) {
            if ($token.StartsWith($Word, [System.StringComparison]::Ordinal) -or $Word.StartsWith($token, [System.StringComparison]::Ordinal)) { $best = 1 }
        }
    }
    return $best
}

function Get-WtAssistantSearchStopWords {
    <#
    .SYNOPSIS
        Words a user types that name no entry - generic verbs and product
        words. They neither score nor count toward the two-word rule, so
        'telemetri kapat' is a one-word query about telemetry.
    #>
    return [string[]]@('kapat', 'kapatma', 'ac', 'acik', 'kapali', 'sil', 'silme', 'temizle', 'goster', 'ayar', 'ayari', 'ayarlari', 'ayarlar',
        'windows', 'microsoft', 'bilgisayar', 'bilgisayarim', 'pc', 'computer', 'disable', 'enable', 'turn', 'off', 'on', 'remove', 'delete', 'clean',
        'settings', 'setting', 'the', 'my', 'bir', 've', 'and', 'icin', 'for', 'nasil', 'how', 'to', 'ne', 'yapmaliyim', 'istiyorum', 'lutfen', 'please')
}

function Get-WtAssistantIndexIdf {
    <#
    .SYNOPSIS
        token -> inverse document frequency over the index, smoothed so
        every value is >= 1: ln((N + 1) / (df + 1)) + 1. Cached against
        the index ARRAY REFERENCE so an injected test index stays
        separate. Uses ordinal-comparer Hashtables, not bare @{}, so
        token keys never culture-fold on a tr-TR host.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Index)
    if ($null -ne $script:WtAssistantIdfCache -and [object]::ReferenceEquals($script:WtAssistantIdfCache.Ref, $Index)) { return $script:WtAssistantIdfCache.Table }
    $df = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($Index)) {
        foreach ($token in @($entry.Tokens)) {
            if ($df.ContainsKey($token)) { $df[$token] = [int]$df[$token] + 1 } else { $df[$token] = 1 }
        }
    }
    $n = @($Index).Count
    $table = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    foreach ($token in $df.Keys) { $table[$token] = [Math]::Log(($n + 1.0) / ([int]$df[$token] + 1.0)) + 1.0 }
    $script:WtAssistantIdfCache = @{ Ref = $Index; Table = $table }
    return $table
}

function Get-WtAssistantEntryScore {
    <#
    .SYNOPSIS
        PURE: one entry against the query words. Per word the best field
        hit wins - label/tag/id x2, consequence/description x1, menu path
        x0.5 - times the word's idf. Hits counts words that hit anywhere;
        ExactLabelHit says whether any word named the label exactly
        (the winget rule).
    #>
    param([Parameter(Mandatory)]$Entry, [AllowEmptyCollection()][string[]]$Words = @(), [Parameter(Mandatory)][hashtable]$Idf)
    $score = 0.0
    $hits = 0
    $exactLabel = $false
    foreach ($word in @($Words)) {
        $best = 0.0
        $labelHit = Get-WtAssistantTokenHit -Tokens ([string[]]@($Entry.LabelTokens)) -Word $word
        if ($labelHit -eq 2) { $exactLabel = $true }
        if ($labelHit -gt 0) { $best = [Math]::Max($best, $labelHit * 2.0) }
        $descHit = Get-WtAssistantTokenHit -Tokens ([string[]]@($Entry.DescTokens)) -Word $word
        if ($descHit -gt 0) { $best = [Math]::Max($best, $descHit * 1.0) }
        $pathHit = Get-WtAssistantTokenHit -Tokens ([string[]]@($Entry.PathTokens)) -Word $word
        if ($pathHit -gt 0) { $best = [Math]::Max($best, $pathHit * 0.5) }
        if ($best -le 0) { continue }
        $hits++
        $weight = 1.0
        if ($Idf.ContainsKey($word)) { $weight = [double]$Idf[$word] }
        $score += $best * $weight
    }
    return @{ Score = $score; Hits = $hits; ExactLabelHit = $exactLabel }
}

function Test-WtAssistantEntryInSection {
    <#
    .SYNOPSIS
        PURE: the section filter - a kind word (Tools / Screens / Winget) or a SectionKey, ordinal, case-insensitive.
    #>
    param([Parameter(Mandatory)]$Entry, [AllowEmptyString()][string]$Section)
    if (-not $Section) { return $true }
    $kind = [string]$Entry.Kind
    if ([string]::Equals($Section, 'Tools', [System.StringComparison]::OrdinalIgnoreCase)) { return ($kind -eq 'Action' -or $kind -eq 'Info') }
    if ([string]::Equals($Section, 'Screens', [System.StringComparison]::OrdinalIgnoreCase)) { return ($kind -eq 'Screen') }
    if ([string]::Equals($Section, 'Winget', [System.StringComparison]::OrdinalIgnoreCase)) { return ($kind -eq 'Winget') }
    return [string]::Equals([string]$Entry.SectionKey, $Section, [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-WtAssistantEntries {
    <#
    .SYNOPSIS
        The ranked search. Effective words = query words minus stop words
        (all of them when nothing is left); an entry needs min(2,
        effective) hits, or 1 on a relaxed retry when nothing hits both
        (flagged Relaxed). Winget entries qualify only on an exact label
        hit. Order: score, then kind, then id - Sort-Object is not stable.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [AllowNull()][AllowEmptyString()][string]$Section = '',
        [AllowNull()][array]$Index = $null
    )
    $entries = if ($null -ne $Index) { @($Index) } else { Get-WtAssistantToolIndex }
    $words = @(ConvertTo-WtAssistantSearchTokens -Text $Query)
    $empty = @{ Entries = @(); Relaxed = $false; MatchedWords = [string[]]@(); EffectiveWords = [string[]]@() }
    if ($words.Count -eq 0) { return $empty }
    $stop = @(Get-WtAssistantSearchStopWords)
    $effective = @(foreach ($word in $words) {
        $isStop = $false
        foreach ($s in $stop) { if ((Get-WtAssistantTokenHit -Tokens @($s) -Word $word) -gt 0) { $isStop = $true; break } }
        if (-not $isStop) { $word }
    })
    if ($effective.Count -eq 0) { $effective = $words }
    $idf = Get-WtAssistantIndexIdf -Index $entries
    $candidates = @($entries | Where-Object { Test-WtAssistantEntryInSection -Entry $_ -Section ([string]$Section) })
    $kindRank = { param($Kind) if ($Kind -eq 'Screen') { 1 } elseif ($Kind -eq 'Winget') { 2 } else { 0 } }
    $pass = { param([int]$Needed)
        $scored = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $candidates) {
            $s = Get-WtAssistantEntryScore -Entry $entry -Words $effective -Idf $idf
            if ($s.Hits -lt $Needed) { continue }
            if ([string]$entry.Kind -eq 'Winget' -and -not $s.ExactLabelHit) { continue }
            $scored.Add([PSCustomObject]@{ Entry = $entry; Score = [double]$s.Score; Rank = [int](& $kindRank ([string]$entry.Kind)); Id = [string]$entry.Id })
        }
        return @($scored.ToArray() | Sort-Object -Property @{ Expression = { -[double]$_.Score } }, @{ Expression = { [int]$_.Rank } }, @{ Expression = { $_.Id } })
    }
    $needed = [Math]::Min(2, $effective.Count)
    $ranked = @(& $pass $needed)
    $relaxed = $false
    if ($ranked.Count -eq 0 -and $needed -gt 1) {
        $ranked = @(& $pass 1)
        $relaxed = ($ranked.Count -gt 0)
    }
    $matched = @(foreach ($word in $effective) {
        $hit = $false
        foreach ($r in $ranked) { if ((Get-WtAssistantEntryScore -Entry $r.Entry -Words @($word) -Idf $idf).Hits -gt 0) { $hit = $true; break } }
        if ($hit) { $word }
    })
    return @{ Entries = @($ranked | ForEach-Object { $_.Entry }); Relaxed = $relaxed; MatchedWords = [string[]]$matched; EffectiveWords = [string[]]$effective }
}

function Resolve-WtAssistantSuggestions {
    <#
    .SYNOPSIS
        Validates the ids the model suggested: unknown ids come back as
        Invalid (an error the model can correct), duplicates collapse,
        the list caps at 9 - the digit shortcuts end there - and twins
        collapse into the preferred side.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Ids = @(),
        [AllowNull()][array]$Index = $null
    )
    $entries = if ($null -ne $Index) { @($Index) } else { Get-WtAssistantToolIndex }
    $byId = @{}
    foreach ($entry in $entries) { $byId[[string]$entry.Id] = $entry }
    $requested = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($id in @($Ids)) { [void]$requested.Add([string]$id) }
    $valid = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $invalid = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($Ids)) {
        $key = [string]$id
        if (-not $byId.ContainsKey($key)) { $invalid.Add($key); continue }
        $twin = [string]$byId[$key].Twin
        if ($twin -and $requested.Contains($twin)) { continue }
        if ($seen.Add($key) -and $valid.Count -lt 9) { $valid.Add($byId[$key]) }
    }
    return @{ Valid = @($valid.ToArray()); Invalid = [string[]]$invalid.ToArray() }
}

function Get-WtAssistantEntryState {
    <#
    .SYNOPSIS
        The live state of ONE toggle, read on demand through its section's
        GetState (Applied / NotApplied / NotPresent). Never at index build:
        a full pass costs 2.4-3.6 s and goes stale; 12 matched entries
        cost 46 ms.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [AllowNull()][array]$Sections = $null
    )
    if ([string]$Entry.Kind -ne 'Toggle' -or $null -eq $Entry.Entry) { return '' }
    if ($null -eq $Sections) { $Sections = @(Get-WtApplySectionCatalog) }
    $section = $null
    foreach ($s in @($Sections)) { if ([string]$s.Key -eq [string]$Entry.SectionKey) { $section = $s; break } }
    if ($null -eq $section -or -not $section.GetState) { return '' }
    try { return [string](& $section.GetState $Entry.Entry) } catch { return 'Unknown' }
}

function ConvertTo-WtAssistantStateCode {
    <#
    .SYNOPSIS
        The live-state word (Applied/NotApplied/NotPresent/Unknown) as the
        row column's short code: on, off, n/a, ? or -.
    #>
    param([AllowNull()][AllowEmptyString()][string]$State)
    switch -CaseSensitive ([string]$State) {
        'Applied' { return 'on' }
        'NotApplied' { return 'off' }
        'NotPresent' { return 'n/a' }
        'Unknown' { return '?' }
    }
    return '-'
}

function ConvertTo-WtAssistantRiskCode {
    <#
    .SYNOPSIS
        The catalog Risk word (SAFE/CAUTION/ADVANCED) as its single-letter
        row code: S/C/A/-.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Risk)
    switch -CaseSensitive ([string]$Risk) {
        'SAFE' { return 'S' }
        'CAUTION' { return 'C' }
        'ADVANCED' { return 'A' }
    }
    return '-'
}

function Get-WtAssistantEntryWhat {
    <#
    .SYNOPSIS
        The one free-text field a row may carry: the consequence, else the description, in the active language, cut at -Max.
    #>
    param([Parameter(Mandatory)]$Entry, [int]$Max = 120)
    $isTurkish = ($script:Language -eq 'TR')
    $text = [string]$(if ($isTurkish) { $Entry.ConsequenceTr } else { $Entry.ConsequenceEn })
    if (-not $text) { $text = [string]$(if ($isTurkish) { $Entry.DescriptionTr } else { $Entry.DescriptionEn }) }
    $text = $text.Trim()
    if ($Max -gt 1 -and $text.Length -gt $Max) { $text = $text.Substring(0, $Max - 1) + '~' }
    return $text
}

function ConvertTo-WtAssistantSearchRow {
    <#
    .SYNOPSIS
        search_wintoolify's row: id | label | state | risk, plus a 'what'
        column only when the caller asked for it (a narrow result or
        -Detail). The label is capped at 70 characters.
    #>
    param([Parameter(Mandatory)]$Entry, [AllowEmptyString()][string]$State = '', [AllowNull()][AllowEmptyString()][string]$What = '')
    $label = (Get-WtAssistantIndexLabel -Entry $Entry).Trim()
    if ($label.Length -gt 70) { $label = $label.Substring(0, 69) + '~' }
    $row = [ordered]@{ id = [string]$Entry.Id; label = $label; state = (ConvertTo-WtAssistantStateCode -State $State); risk = (ConvertTo-WtAssistantRiskCode -Risk ([string]$Entry.Risk)) }
    if ($What) { $row['what'] = [string]$What }
    return [PSCustomObject]$row
}

function Get-WtAssistantSearchFacetLine {
    <#
    .SYNOPSIS
        PURE: 'N (Section 12, Tools 3, ...) - narrow with section=' for the matches beyond the rows shown; '' when nothing is hidden. The caller's 'more' field name already supplies the word - the value never repeats it.
    #>
    param([AllowEmptyCollection()][array]$Entries = @(), [int]$Shown = 0)
    $all = @($Entries)
    if ($all.Count -le $Shown) { return '' }
    $counts = [ordered]@{}
    foreach ($entry in $all) {
        $kind = [string]$entry.Kind
        $bucket = $(if ($kind -eq 'Toggle') { [string]$entry.SectionKey } elseif ($kind -eq 'Screen') { 'Screens' } elseif ($kind -eq 'Winget') { 'Winget' } else { 'Tools' })
        if ($counts.Contains($bucket)) { $counts[$bucket] = [int]$counts[$bucket] + 1 } else { $counts[$bucket] = 1 }
    }
    $top = @($counts.Keys | Sort-Object -Property @{ Expression = { -[int]$counts[$_] } }, @{ Expression = { $_ } } | Select-Object -First 5 | ForEach-Object { [string]$_ + ' ' + [int]$counts[$_] })
    return [string]($all.Count - $Shown) + ' (' + ($top -join ', ') + ') - narrow with section='
}

function Get-WtAssistantFoldedHits {
    <#
    .SYNOPSIS
        PURE: collapses the pair onto the preferred entry at the better
        of the two ranks, remembering the fold so its what column can say
        '(twin: <id>)'. A dropped side whose twin did not match (a
        section filter, say) stays. Returns @{ Entries; Folded }.
    #>
    param([AllowEmptyCollection()][array]$Entries = @())
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $byId = @{}
    foreach ($e in @($Entries)) { [void]$ids.Add([string]$e.Id); $byId[[string]$e.Id] = $e }
    $emitted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $folded = @{}
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Entries)) {
        $id = [string]$e.Id
        if ($emitted.Contains($id)) { continue }
        $twin = [string]$e.Twin
        if ($twin -and $ids.Contains($twin)) {
            $folded[$twin] = $id
            if (-not $emitted.Contains($twin)) { $kept.Add($byId[$twin]); [void]$emitted.Add($twin) }
            continue
        }
        $kept.Add($e)
        [void]$emitted.Add($id)
    }
    return @{ Entries = @($kept.ToArray()); Folded = $folded }
}

function Get-WtAssistantSearchResult {
    <#
    .SYNOPSIS
        search_wintoolify: up to -Take rows of id | label | state | risk.
        'what' is added for a narrow result or -Detail; 'more:' names
        remaining matches; a relaxed match says which words it honoured;
        an HKLM/HKCU twin pair collapses into the preferred row. Uses
        $rowLimit, not $take, since PS variable names are case-insensitive.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Query = '',
        [AllowNull()][AllowEmptyString()][string]$Section = '',
        [bool]$Detail = $false,
        [int]$Take = 8,
        [AllowNull()][array]$Index = $null,
        [AllowNull()][array]$Sections = $null
    )
    $found = Find-WtAssistantEntries -Query ([string]$Query) -Section ([string]$Section) -Index $Index
    $fold = Get-WtAssistantFoldedHits -Entries @($found.Entries)
    $hits = @($fold.Entries)
    $rowLimit = $(if ($Detail) { [Math]::Min(5, [Math]::Max(1, $Take)) } else { [Math]::Max(1, $Take) })
    $withWhat = ($Detail -or $hits.Count -le 3)
    $rows = New-Object System.Collections.Generic.List[object]
    $stateReads = 0
    foreach ($entry in $hits) {
        if ($rows.Count -ge $rowLimit -or $stateReads -ge 36) { break }
        $state = Get-WtAssistantEntryState -Entry $entry -Sections $Sections
        $stateReads++
        $what = ''
        if ($withWhat) {
            $twinNote = $(if ($fold.Folded.ContainsKey([string]$entry.Id)) { ' (twin: ' + [string]$fold.Folded[[string]$entry.Id] + ')' } else { '' })
            $what = ((Get-WtAssistantEntryWhat -Entry $entry -Max (120 - $twinNote.Length)) + $twinNote).Trim()
        }
        $rows.Add((ConvertTo-WtAssistantSearchRow -Entry $entry -State $state -What $what))
    }
    $result = [ordered]@{}
    if ($rows.Count -eq 0) { $result['rows'] = 'none' } else { $result['rows'] = @($rows.ToArray()) }
    $more = Get-WtAssistantSearchFacetLine -Entries $hits -Shown $rows.Count
    if ($more) { $result['more'] = $more }
    if ($found.Relaxed) { $result['hint'] = 'no entry matched all words; showing matches for: ' + (@($found.MatchedWords) -join ', ') }
    elseif ($rows.Count -eq 0) { $result['hint'] = 'try other words (a symptom or a setting name) or a section=' }
    return $result
}

function Get-WtAssistantWintoolifyStatus {
    <#
    .SYNOPSIS
        read_system topic=wintoolify_status: "N/M applied" per section,
        read on demand (2.4-3.6 s for the whole catalog - the tool trace
        row covers it).
    #>
    param(
        [AllowNull()][array]$Index = $null,
        [AllowNull()][array]$Sections = $null
    )
    $entries = if ($null -ne $Index) { @($Index) } else { Get-WtAssistantToolIndex }
    if ($null -eq $Sections) { $Sections = @(Get-WtApplySectionCatalog) }
    $bySection = [ordered]@{}
    foreach ($entry in @($entries | Where-Object { $_.Kind -eq 'Toggle' -and $_.Runnable })) {
        $key = [string]$entry.SectionKey
        if (-not $bySection.Contains($key)) { $bySection[$key] = @{ Title = [string](Get-Translation ([string]$entry.Section)); Applied = 0; Total = 0; NotPresent = 0 } }
        $state = Get-WtAssistantEntryState -Entry $entry -Sections $Sections
        $bySection[$key].Total++
        if ($state -eq 'Applied') { $bySection[$key].Applied++ }
        elseif ($state -eq 'NotPresent') { $bySection[$key].NotPresent++ }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $appliedTotal = 0
    $total = 0
    foreach ($key in $bySection.Keys) {
        $s = $bySection[$key]
        $appliedTotal += $s.Applied
        $total += $s.Total
        $rows.Add([PSCustomObject]@{ section = $key; title = $s.Title; applied = $s.Applied; total = $s.Total; not_present = $s.NotPresent })
    }
    return [PSCustomObject]@{ sections = @($rows.ToArray()); applied_total = $appliedTotal; total = $total }
}
