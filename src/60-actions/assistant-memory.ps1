# The assistant's persistent memory under LOCALAPPDATA\WinToolify\assistant
# (permissions, profile cache, notes) - /unut wipes it all.
# Covered by: tests/AssistantMemory.Tests.ps1

function Get-WtAssistantMemoryPath {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$TestRootOverride
    )
    $dataPathArgs = @{ Scope = 'User'; SubPath = 'assistant' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    return Join-Path (Get-WtDataPath @dataPathArgs) $FileName
}

function Read-WtAssistantPermissions {
    <#
    .SYNOPSIS
        @{ v; endpoints = @(@{ endpoint; at }); disabled = @() } - a
        missing or corrupt file returns the empty shape, never throws.
        Unrecognized keys in an older file are simply not read.
    #>
    param([string]$TestRootOverride)
    $empty = @{ v = 1; endpoints = @(); disabled = @() }
    $path = Get-WtAssistantMemoryPath -FileName 'permissions.json' -TestRootOverride $TestRootOverride
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    $raw = $null
    try { $raw = Read-WtJson -Path $path -WarningAction SilentlyContinue } catch { $raw = $null }
    if ($null -eq $raw) { return $empty }
    $disabled = New-Object System.Collections.Generic.List[string]
    if ($raw.PSObject.Properties.Name -contains 'disabled') {
        foreach ($name in @($raw.disabled | ForEach-Object { [string]$_ } | Where-Object { $_ })) { $disabled.Add($name) }
    }
    $endpoints = New-Object System.Collections.Generic.List[object]
    if ($raw.PSObject.Properties.Name -contains 'endpoints') {
        foreach ($row in @($raw.endpoints | Where-Object { $_ })) {
            $endpoints.Add(@{ endpoint = [string]$row.endpoint; at = (ConvertTo-WtIsoText -Value $row.at) })
        }
    }
    return @{ v = 1; endpoints = @($endpoints.ToArray()); disabled = @($disabled.ToArray()) }
}

function Test-WtAssistantEndpointAllowed {
    <#
    .SYNOPSIS
        PURE: ordinal comparison - never -eq on a URL under tr-TR - and
        the empty endpoint is never "allowed".
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$Permissions
    )
    if (-not $Endpoint) { return $false }
    foreach ($row in @($Permissions.endpoints)) {
        if ($null -ne $row -and [string]::Equals([string]$row.endpoint, $Endpoint, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Add-WtAssistantEndpointAllowed {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$Permissions,
        [datetime]$Now = (Get-Date)
    )
    if (-not (Test-WtAssistantEndpointAllowed -Endpoint $Endpoint -Permissions $Permissions)) {
        $Permissions.endpoints = @($Permissions.endpoints) + @(@{ endpoint = $Endpoint; at = $Now.ToString('o') })
    }
    return $Permissions
}

function Save-WtAssistantPermissions {
    param(
        [Parameter(Mandatory)][hashtable]$Permissions,
        [string]$TestRootOverride
    )
    $path = Get-WtAssistantMemoryPath -FileName 'permissions.json' -TestRootOverride $TestRootOverride
    $disabled = @($(if ($Permissions.ContainsKey('disabled')) { $Permissions.disabled } else { @() }) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    Write-WtJson -Path $path -InputObject ([PSCustomObject]@{ v = 1; endpoints = @($Permissions.endpoints); disabled = @($disabled) })
}

function Read-WtAssistantProfileCache {
    <#
    .SYNOPSIS
        The cached machine profile: $null when the file is missing or
        corrupt, otherwise its five fields as strings.
    #>
    param([string]$TestRootOverride)
    $path = Get-WtAssistantMemoryPath -FileName 'profile.json' -TestRootOverride $TestRootOverride
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = $null
    try { $raw = Read-WtJson -Path $path -WarningAction SilentlyContinue } catch { $raw = $null }
    if ($null -eq $raw) { return $null }
    $props = @($raw.PSObject.Properties.Name)
    $get = { param($Name) if ($props -contains $Name) { ConvertTo-WtIsoText -Value $raw.$Name } else { '' } }
    return @{ v = 1; BuiltAt = (& $get 'BuiltAt'); BootTime = (& $get 'BootTime'); NewestChangeId = (& $get 'NewestChangeId'); ShortJson = (& $get 'ShortJson'); FullJson = (& $get 'FullJson') }
}

function Save-WtAssistantProfileCache {
    param([Parameter(Mandatory)][hashtable]$Cache, [string]$TestRootOverride)
    $path = Get-WtAssistantMemoryPath -FileName 'profile.json' -TestRootOverride $TestRootOverride
    Write-WtJson -Path $path -InputObject ([PSCustomObject]@{ v = 1; BuiltAt = (ConvertTo-WtIsoText -Value $Cache.BuiltAt); BootTime = (ConvertTo-WtIsoText -Value $Cache.BootTime); NewestChangeId = [string]$Cache.NewestChangeId; ShortJson = [string]$Cache.ShortJson; FullJson = [string]$Cache.FullJson })
}

function Remove-WtAssistantProfileCache {
    param([string]$TestRootOverride)
    $path = Get-WtAssistantMemoryPath -FileName 'profile.json' -TestRootOverride $TestRootOverride
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Read-WtAssistantNotes {
    <#
    .SYNOPSIS
        @(@{ text; at }) from facts.json - a missing or corrupt file is
        the empty list, never a throw.
    #>
    param([string]$TestRootOverride)
    $path = Get-WtAssistantMemoryPath -FileName 'facts.json' -TestRootOverride $TestRootOverride
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $raw = $null
    try { $raw = Read-WtJson -Path $path -WarningAction SilentlyContinue } catch { $raw = $null }
    if ($null -eq $raw -or -not ($raw.PSObject.Properties.Name -contains 'notes')) { return @() }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($raw.notes | Where-Object { $null -ne $_ -and [string]$_.text })) {
        $rows.Add(@{ text = [string]$row.text; at = (ConvertTo-WtIsoText -Value $row.at) })
    }
    return @($rows.ToArray())
}

function Save-WtAssistantNotes {
    param([AllowEmptyCollection()][array]$Notes = @(), [string]$TestRootOverride)
    $path = Get-WtAssistantMemoryPath -FileName 'facts.json' -TestRootOverride $TestRootOverride
    Write-WtJson -Path $path -InputObject ([PSCustomObject]@{ v = 1; notes = @($Notes | ForEach-Object { [PSCustomObject]@{ text = [string]$_.text; at = (ConvertTo-WtIsoText -Value $_.at) } }) })
}

function Add-WtAssistantNote {
    <#
    .SYNOPSIS
        At most MaxNotes notes of MaxChars each. A repeated text refreshes
        its date instead of doubling; the eleventh note drops the oldest
        and says so.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text = '',
        [string]$TestRootOverride,
        [datetime]$Now = (Get-Date),
        [int]$MaxNotes = 10,
        [int]$MaxChars = 200
    )
    $text = ([string]$Text).Trim()
    if (-not $text) { return @{ Saved = $false; Text = ''; Dropped = $false; Count = @(Read-WtAssistantNotes -TestRootOverride $TestRootOverride).Count } }
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }
    $notes = New-Object System.Collections.Generic.List[object]
    foreach ($row in @(Read-WtAssistantNotes -TestRootOverride $TestRootOverride)) {
        if (-not [string]::Equals([string]$row.text, $text, [System.StringComparison]::Ordinal)) { $notes.Add($row) }
    }
    $dropped = $false
    while ($notes.Count -ge $MaxNotes) { $notes.RemoveAt(0); $dropped = $true }
    $notes.Add(@{ text = $text; at = $Now.ToString('o') })
    Save-WtAssistantNotes -Notes @($notes.ToArray()) -TestRootOverride $TestRootOverride
    return @{ Saved = $true; Text = $text; Dropped = $dropped; Count = $notes.Count }
}

function Remove-WtAssistantNote {
    param([Parameter(Mandatory)][int]$Index, [string]$TestRootOverride)
    $notes = @(Read-WtAssistantNotes -TestRootOverride $TestRootOverride)
    if ($Index -lt 1 -or $Index -gt $notes.Count) { return $false }
    $keep = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $notes.Count; $i++) { if ($i -ne ($Index - 1)) { $keep.Add($notes[$i]) } }
    Save-WtAssistantNotes -Notes @($keep.ToArray()) -TestRootOverride $TestRootOverride
    return $true
}

function Clear-WtAssistantMemory {
    <#
    .SYNOPSIS
        /unut: deletes the memory files. settings.json (and the DPAPI key
        inside it) stays - /anahtar with an empty line clears that.
        Returns how many existed before the wipe. chat.json is no longer
        written, but one left behind by an older build is still wiped here.
    #>
    param([string]$TestRootOverride)
    $deleted = 0
    $profilePath = Get-WtAssistantMemoryPath -FileName 'profile.json' -TestRootOverride $TestRootOverride
    if (Test-Path -LiteralPath $profilePath) { $deleted++ }
    Remove-WtAssistantProfileCache -TestRootOverride $TestRootOverride
    foreach ($name in @('chat.json', 'permissions.json', 'facts.json')) {
        $path = Get-WtAssistantMemoryPath -FileName $name -TestRootOverride $TestRootOverride
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; $deleted++ }
    }
    return $deleted
}
