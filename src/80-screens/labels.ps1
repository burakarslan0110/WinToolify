# Undo entry, undo action and risk labels.
# Covered by: tests/Screens.Tests.ps1

function Format-WtUndoEntryLabel {
    <#
    .SYNOPSIS
        Display label for one undo entry: timestamp, action, and a
        pluralized item count, with an "[previously restored]" note when
        RestoredAt is set.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Entry
    )

    $displayTime = ([datetime]$Entry.Timestamp).ToString('yyyy-MM-dd HH:mm:ss')
    $itemCount = @(Get-WtUndoOpenItemKeys -Entry $Entry).Count
    $countText = (Get-Translation $(if ($itemCount -eq 1) { 'UndoItemOne' } else { 'UndoItemMany' })) -f $itemCount
    $restoredNote = if ($Entry.PSObject.Properties.Name -contains 'RestoredAt' -and $Entry.RestoredAt) { ' ' + (Get-Translation 'UndoPreviouslyRestored') } else { '' }

    return "$displayTime - $(Get-WtUndoActionLabel -Action ([string]$Entry.Action)) ($countText)$restoredNote"
}

function Get-WtUndoActionLabel {
    <#
    .SYNOPSIS
        Localized display name for an undo entry's Action. The Action is
        the English identifier baked into the entry file name, so it is
        never translated at write time; the lookup key is
        "UndoAction.<Action>" and an unknown action falls back to the
        raw string rather than blanking the row.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Action)
    $label = Get-Translation ('UndoAction.' + $Action)
    if ($label) { return [string]$label }
    return $Action
}

function Get-WtRiskLabel {
    <#
    .SYNOPSIS
        Localized text for a SAFE / CAUTION / ADVANCED risk tag. The risk
        value itself stays the English constant everywhere else (catalog
        matching, colors, guards) - only what the row prints changes.
    #>
    param([AllowEmptyString()][string]$Risk = '')
    if (-not $Risk) { return '' }
    $label = Get-Translation ('Risk' + $Risk)
    if ($label) { return [string]$label }
    return $Risk
}

function Get-WtUndoItemKey {
    <#
    .SYNOPSIS
        PURE: the identity of one undo-record item AS THE USER SEES IT,
        without opening a catalog. Items that share a CatalogEntry are
        one thing the user picked (a catalog entry writing two registry
        values) - except a firewall profile, which is one thing per
        profile because the panel names each. Everything else is its own
        thing: a service by template name, a package by name, a DNS
        record by adapter, a blocklist layer by tier, a bare registry
        value by path. A shape nothing here knows (the plain numbers the
        tests use) counts by position. The row counter and the confirm
        panel both group by this, so they can never disagree.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [int]$Index = 0
    )
    $names = @($Item.PSObject.Properties.Name)
    $field = { param($Name) if (($names -contains $Name) -and $null -ne $Item.$Name) { [string]$Item.$Name } else { '' } }
    $type = & $field 'ItemType'
    $entry = & $field 'CatalogEntry'
    if ($entry) {
        if ($type -eq 'FirewallProfile') { return ('Catalog|{0}|{1}' -f $entry, (& $field 'ProfileName')) }
        return ('Catalog|' + $entry)
    }
    switch ($type) {
        'Service' { $t = & $field 'Template'; if (-not $t) { $t = & $field 'Name' }; return ('Service|' + $t) }
        'Package' { return ('Package|' + (& $field 'Name')) }
        'DnsConfig' { return ('Dns|' + (& $field 'InterfaceIndex')) }
        'HostsBlock' { return ('HostsBlock|' + (& $field 'Tier')) }
        'FirewallBlock' { return ('FirewallBlock|' + (& $field 'Tier')) }
        'Registry' { return ('Registry|{0}\{1}' -f (& $field 'Path'), (& $field 'Name')) }
        'RegistryKey' { return ('RegistryKey|{0}\{1}' -f (& $field 'Hive'), (& $field 'SubKey')) }
        'RegistryKeyTree' { return ('RegistryKeyTree|{0}\{1}' -f (& $field 'Hive'), (& $field 'SubKey')) }
    }
    return ('Item|' + $Index)
}

function Get-WtUndoOpenItemKeys {
    <#
    .SYNOPSIS
        PURE: the distinct Get-WtUndoItemKey of every item in the record
        that a restore would still touch (not RestoredAt / RetiredAt),
        in first-seen order. The row counter counts these; the confirm
        panel prints one line per key.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Entry)
    $keys = New-Object System.Collections.Generic.List[string]
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    $i = 0
    foreach ($item in @($Entry.Items)) {
        $i++
        if ($null -eq $item) { continue }
        if (Test-WtUndoItemClosed -Item $item) { continue }
        $key = Get-WtUndoItemKey -Item $item -Index $i
        if ($seen.Add($key)) { $keys.Add($key) }
    }
    return [string[]]$keys.ToArray()
}

function Get-WtUndoItemLabel {
    <#
    .SYNOPSIS
        PURE: one line saying what a single undo-record item changed, for
        the confirm panel and the result list. The catalog label - what
        the user picked on the apply screen, "Show file
        extensions" - beats every raw identifier; it comes through
        -CatalogLabel so the tests never open a catalog. The fallbacks are
        the same names Restore-WtUndoEntry reports. A service adds
        "previous -> target" because its label alone does not say which
        way it went; an old Disable Services record has no TargetStartType
        and always meant Disabled. A DNS record names the servers restore
        will put back (DHCP when it had none) because the preset that was
        applied is not in the file.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [scriptblock]$CatalogLabel = { param($Item) '' }
    )
    $names = @($Item.PSObject.Properties.Name)
    $field = { param($Name) if (($names -contains $Name) -and $null -ne $Item.$Name) { [string]$Item.$Name } else { '' } }
    $startLabel = { param($StartType) $t = Get-Translation ('SvcStart.' + $StartType); if ($t) { [string]$t } else { [string]$StartType } }
    $label = ''
    try { $label = [string](& $CatalogLabel $Item) } catch { $label = '' }
    $type = [string]$Item.ItemType
    switch ($type) {
        'Service' {
            $name = $(if ($label) { $label } else { & $field 'Name' })
            $target = & $field 'TargetStartType'
            if (-not $target) { $target = 'Disabled' }
            return ((Get-Translation 'UndoDetailService') -f $name, (& $startLabel (& $field 'PreviousStartType')), (& $startLabel $target))
        }
        'Package' { if ($label) { return $label }; return (& $field 'Name') }
        'DnsConfig' {
            $servers = @(@($Item.PreviousIPv4) + @($Item.PreviousIPv6) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $text = $(if ($servers.Count -gt 0) { $servers -join ', ' } else { Get-Translation 'UndoDetailDnsDhcp' })
            return ((Get-Translation 'UndoDetailDns') -f (& $field 'InterfaceIndex'), $text)
        }
        'HostsBlock' { return ((Get-Translation 'UndoDetailHosts') -f (& $field 'Tier'), @($Item.Lines).Count) }
        'FirewallBlock' { return ((Get-Translation 'UndoDetailFirewallBlock') -f (& $field 'Tier'), @($Item.RuleNames).Count) }
        'FirewallProfile' {
            $name = $(if ($label) { $label } else { & $field 'Name' })
            $profile = & $field 'ProfileName'
            if ($profile) { return ('{0} ({1})' -f $name, $profile) }
            return $name
        }
    }
    if ($label) { return $label }
    switch ($type) {
        'Registry' { return ('{0}\{1}' -f (& $field 'Path'), (& $field 'Name')) }
        'RegistryKey' { return ('{0}\{1}' -f (& $field 'Hive'), (& $field 'SubKey')) }
        'RegistryKeyTree' { return ('{0}\{1}' -f (& $field 'Hive'), (& $field 'SubKey')) }
        'HibernationState' { return (& $field 'Name') }
    }
    $entry = & $field 'CatalogEntry'
    if ($entry) { return $entry }
    return $type
}

function Get-WtUndoEntryDetailLines {
    <#
    .SYNOPSIS
        PURE: the confirm panel's text for one undo record - the row's
        own label, a blank, the "what was changed" header, one indented
        line per item still open (an item already put back one-by-one
        from an apply screen, or retired, is not what Enter would touch),
        a blank, and the note that restoring means the state from before
        the change. One line per Get-WtUndoItemKey - the same grouping
        the row counter uses - so a catalog entry with two registry values
        is one line, and "Turn off SmartScreen" never repeats.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Entry,
        [scriptblock]$CatalogLabel = { param($Item) '' }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Format-WtUndoEntryLabel -Entry $Entry))
    $lines.Add('')
    $lines.Add((Get-Translation 'UndoDetailHeader'))
    $listed = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    $i = 0
    foreach ($item in @($Entry.Items)) {
        $i++
        if ($null -eq $item) { continue }
        if (Test-WtUndoItemClosed -Item $item) { continue }
        if (-not $listed.Add((Get-WtUndoItemKey -Item $item -Index $i))) { continue }
        $lines.Add('  - ' + (Get-WtUndoItemLabel -Item $item -CatalogLabel $CatalogLabel))
    }
    $lines.Add('')
    $lines.Add((Get-Translation 'UndoDetailRestoreNote'))
    return [string[]]$lines.ToArray()
}
