# Registry value/key primitives, key creation plans and key-tree restore.
# Covered by: tests/RegistryPrimitives.Tests.ps1, tests/RegistryKeyUndo.Tests.ps1

function ConvertTo-WtRegistryHivePath {
    <#
    .SYNOPSIS
        PURE: a provider path ('HKLM:\...', 'HKCU:\...',
        'Registry::HKEY_LOCAL_MACHINE\...') as the .NET hive key plus the
        sub-key path under it: @{ Hive; SubKey }. $null when the prefix
        is not one of the six hives.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    if ($p.StartsWith('Registry::', [System.StringComparison]::OrdinalIgnoreCase)) { $p = $p.Substring(10) }
    $cut = $p.IndexOfAny([char[]]@('\', '/'))
    $prefix = $(if ($cut -lt 0) { $p } else { $p.Substring(0, $cut) })
    $subKey = $(if ($cut -lt 0) { '' } else { $p.Substring($cut + 1).Trim([char[]]@('\', '/')) })
    $hive = switch ($prefix.TrimEnd(':').ToUpperInvariant()) {
        'HKLM'                { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_LOCAL_MACHINE'  { [Microsoft.Win32.Registry]::LocalMachine }
        'HKCU'                { [Microsoft.Win32.Registry]::CurrentUser }
        'HKEY_CURRENT_USER'   { [Microsoft.Win32.Registry]::CurrentUser }
        'HKCR'                { [Microsoft.Win32.Registry]::ClassesRoot }
        'HKEY_CLASSES_ROOT'   { [Microsoft.Win32.Registry]::ClassesRoot }
        'HKU'                 { [Microsoft.Win32.Registry]::Users }
        'HKEY_USERS'          { [Microsoft.Win32.Registry]::Users }
        'HKCC'                { [Microsoft.Win32.Registry]::CurrentConfig }
        'HKEY_CURRENT_CONFIG' { [Microsoft.Win32.Registry]::CurrentConfig }
        default               { $null }
    }
    if ($null -eq $hive) { return $null }
    return @{ Hive = $hive; SubKey = $subKey }
}

function Get-WtRegistryProperty {
    <#
    .SYNOPSIS
        The real read behind every GetPropertyAction default: what
        Get-ItemProperty -Name would return, via the .NET registry API,
        because Get-ItemProperty -ErrorAction SilentlyContinue costs
        ~20ms per missing key, and an unapplied setting is a missing key.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )
    $split = ConvertTo-WtRegistryHivePath -Path $Path
    if ($null -eq $split) { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue) }
    $valueName = $(if ($Name -eq '(default)') { '' } else { $Name })
    $key = $null
    try {
        $key = $split.Hive.OpenSubKey([string]$split.SubKey)
        if ($null -eq $key) { return $null }
        $value = $key.GetValue($valueName, $null)
        if ($null -eq $value) { return $null }
        return [PSCustomObject]@{ $Name = $value }
    }
    catch { return $null }
    finally { if ($null -ne $key) { $key.Close() } }
}

function Get-WtRegistryValue {
    <#
    .SYNOPSIS
        Reads one registry value, reporting Present=$false (not a throw)
        when the key or the value itself is missing. Runs entirely behind
        -GetPropertyAction because the Registry PSProvider does not exist
        on the macOS dev host.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    $result = & $GetPropertyAction $Path $Name

    if ($null -eq $result -or $result.PSObject.Properties.Name -notcontains $Name) {
        return [PSCustomObject]@{ Present = $false; Value = $null }
    }

    return [PSCustomObject]@{ Present = $true; Value = $result.$Name }
}

function Set-WtRegistryValue {
    <#
    .SYNOPSIS
        Writes one registry value, creating the key chain first if needed.
        Entirely behind -SetValueAction for the same reason as
        Get-WtRegistryValue - no registry PSProvider on this dev host.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RegType,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [scriptblock]$SetValueAction = {
            param($p, $n, $t, $v)
            if (-not (Test-Path -LiteralPath $p)) {
                New-Item -Path $p -Force | Out-Null
            }
            New-ItemProperty -LiteralPath $p -Name $n -PropertyType $t -Value $v -Force | Out-Null
        }
    )

    & $SetValueAction $Path $Name $RegType $Value
}

function Remove-WtRegistryValue {
    <#
    .SYNOPSIS
        Removes one registry value. Removing a value that is already
        absent is a no-op, not an error. Entirely behind
        -RemoveValueAction for the same reason as Get-WtRegistryValue.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [scriptblock]$RemoveValueAction = {
            param($p, $n)
            Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction SilentlyContinue
        }
    )

    & $RemoveValueAction $Path $Name
}

function Get-WtRegistryKeyValue {
    <#
    .SYNOPSIS
        Reads one value from a key addressed by hive + subkey through
        Microsoft.Win32.Registry, not the PSProvider (no HKCR: drive, and
        New-Item cannot address a key name containing '*'). Distinguishes
        "key absent" from "key present, value absent" via KeyPresent.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory)]
        [string]$SubKey,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [scriptblock]$GetKeyValueAction = {
            param($h, $s, $n)
            $key = [Microsoft.Win32.Registry]::$h.OpenSubKey($s)
            if ($null -eq $key) { return $null }
            try {
                $v = $key.GetValue($n, $null)
                return [PSCustomObject]@{ Present = ($null -ne $v); Value = $v }
            }
            finally {
                $key.Close()
            }
        }
    )

    $result = & $GetKeyValueAction $Hive $SubKey $Name

    if ($null -eq $result) {
        return [PSCustomObject]@{ KeyPresent = $false; Present = $false; Value = $null }
    }

    return [PSCustomObject]@{ KeyPresent = $true; Present = [bool]$result.Present; Value = $result.Value }
}

function Set-WtRegistryKeyValues {
    <#
    .SYNOPSIS
        Creates the key (CreateSubKey opens an existing one unchanged) and
        writes every value in -Values, each @{ Name; Kind; Value } with
        Kind a Microsoft.Win32.RegistryValueKind name. One action call per
        key, not per value, so a fake can assert the whole write at once.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory)]
        [string]$SubKey,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Values,

        [scriptblock]$SetKeyValuesAction = {
            param($h, $s, $v)
            $key = [Microsoft.Win32.Registry]::$h.CreateSubKey($s)
            try {
                foreach ($entry in @($v)) {
                    $key.SetValue($entry.Name, $entry.Value, [Microsoft.Win32.RegistryValueKind]$entry.Kind)
                }
            }
            finally {
                $key.Close()
            }
        }
    )

    & $SetKeyValuesAction $Hive $SubKey $Values
}

function Remove-WtRegistryKeyValue {
    <#
    .SYNOPSIS
        Removes one value from a key. A missing key (OpenSubKey returns
        $null - it does NOT throw) or a missing value (DeleteValue's
        throwOnMissingValue=$false) is a no-op, never an error, so a second
        undo of the same entry succeeds.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory)]
        [string]$SubKey,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [scriptblock]$RemoveKeyValueAction = {
            param($h, $s, $n)
            $key = [Microsoft.Win32.Registry]::$h.OpenSubKey($s, $true)
            if ($null -eq $key) { return }
            try {
                $key.DeleteValue($n, $false)
            }
            finally {
                $key.Close()
            }
        }
    )

    & $RemoveKeyValueAction $Hive $SubKey $Name
}

function Remove-WtRegistryKeyTree {
    <#
    .SYNOPSIS
        Deletes a key and everything under it; a no-op if it is already
        gone. Only ever called with a CreatedRoot from
        Get-WtRegistryKeyCreationPlan or a removal root from
        Get-WtRegistryKeyRemovalRoot - never an arbitrary path.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory)]
        [string]$SubKey,

        [scriptblock]$RemoveKeyTreeAction = {
            param($h, $s)
            [Microsoft.Win32.Registry]::$h.DeleteSubKeyTree($s, $false)
        }
    )

    & $RemoveKeyTreeAction $Hive $SubKey
}

function Get-WtRegistryKeyCreationPlan {
    <#
    .SYNOPSIS
        Capture-time answer to "which key tree will writing -SubKey
        create?": the first (highest) segment under -RootBoundary that
        does not exist yet, or $null if every segment already exists.
        Throws if -SubKey is not strictly under -RootBoundary.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory)]
        [string]$SubKey,

        [Parameter(Mandatory)]
        [string]$RootBoundary,

        [scriptblock]$TestKeyAction = {
            param($h, $s)
            $key = [Microsoft.Win32.Registry]::$h.OpenSubKey($s)
            if ($null -eq $key) { return $false }
            $key.Close()
            return $true
        }
    )

    $boundary = $RootBoundary.TrimEnd('\')
    $prefix = $boundary + '\'
    if (-not $SubKey.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or $SubKey.Length -le $prefix.Length) {
        throw "Get-WtRegistryKeyCreationPlan: '$SubKey' is not under root boundary '$RootBoundary'"
    }

    $current = $boundary
    foreach ($segment in $SubKey.Substring($prefix.Length).Split('\')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $current = $current + '\' + $segment
        if (-not (& $TestKeyAction $Hive $current)) {
            return $current
        }
    }

    return $null
}

function Get-WtRegistryKeyRemovalRoot {
    <#
    .SYNOPSIS
        PURE: the key a removal deletes for one KeyChanges item - the
        first segment below RootBoundary (the verb key; its \command
        child goes with it). Throws when SubKey is not strictly under
        the boundary.
    #>
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$RootBoundary
    )
    $boundary = $RootBoundary.TrimEnd('\')
    $prefix = $boundary + '\'
    if (-not $SubKey.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or $SubKey.Length -le $prefix.Length) {
        throw "Get-WtRegistryKeyRemovalRoot: '$SubKey' is not under root boundary '$RootBoundary'"
    }
    $first = ($SubKey.Substring($prefix.Length).Split('\') | Where-Object { $_ } | Select-Object -First 1)
    if ([string]::IsNullOrEmpty($first)) {
        throw "Get-WtRegistryKeyRemovalRoot: '$SubKey' has no segment under '$RootBoundary'"
    }
    return $boundary + '\' + $first
}

function Restore-WtRegistryKeyTreeItem {
    <#
    .SYNOPSIS
        Undo for a RegistryKeyTree item (a context-menu verb removed from
        an apply screen): re-writes, from the live catalog, every
        KeyChanges entry at or below the removed root. Returns 'Restored',
        or 'NotRestorable' when the catalog no longer knows the entry.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [array]$Catalog = (Get-WtContextMenuCatalog),
        [scriptblock]$SetKeyValuesAction
    )
    $entry = $Catalog | Where-Object Name -eq $Item.CatalogEntry | Select-Object -First 1
    if (-not $entry) { return 'NotRestorable' }
    $setArgs = @{}
    if ($SetKeyValuesAction) { $setArgs['SetKeyValuesAction'] = $SetKeyValuesAction }
    $root = [string]$Item.SubKey
    $wrote = $false
    foreach ($change in @($entry.KeyChanges)) {
        if ($change.Hive -ne $Item.Hive) { continue }
        $sub = [string]$change.SubKey
        if (-not ($sub.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or $sub.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase))) { continue }
        $values = @($change.Values | ForEach-Object { @{ Name = $_.Name; Kind = $_.Kind; Value = $_.Value } })
        Set-WtRegistryKeyValues -Hive $change.Hive -SubKey $change.SubKey -Values $values @setArgs
        $wrote = $true
    }
    if (-not $wrote) { return 'NotRestorable' }
    return 'Restored'
}

function Restore-WtRegistryKeyItem {
    <#
    .SYNOPSIS
        Undo for a RegistryKey item: a recorded CreatedRoot means this
        run created the whole tree, so deleting it restores the exact
        pre-change state; otherwise only the recorded PreviousValues are
        put back, and the key itself is never deleted.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Item,

        [scriptblock]$RemoveKeyTreeAction,
        [scriptblock]$SetKeyValuesAction,
        [scriptblock]$RemoveKeyValueAction
    )

    if (-not [string]::IsNullOrEmpty($Item.CreatedRoot)) {
        $treeArgs = @{}
        if ($RemoveKeyTreeAction) { $treeArgs['RemoveKeyTreeAction'] = $RemoveKeyTreeAction }
        Remove-WtRegistryKeyTree -Hive $Item.Hive -SubKey $Item.CreatedRoot @treeArgs
        return
    }

    foreach ($previous in @($Item.PreviousValues)) {
        if ($previous.Present) {
            $setArgs = @{}
            if ($SetKeyValuesAction) { $setArgs['SetKeyValuesAction'] = $SetKeyValuesAction }
            Set-WtRegistryKeyValues -Hive $Item.Hive -SubKey $Item.SubKey -Values @(@{ Name = $previous.Name; Kind = $previous.Kind; Value = $previous.Value }) @setArgs
        }
        else {
            $removeArgs = @{}
            if ($RemoveKeyValueAction) { $removeArgs['RemoveKeyValueAction'] = $RemoveKeyValueAction }
            Remove-WtRegistryKeyValue -Hive $Item.Hive -SubKey $Item.SubKey -Name $previous.Name @removeArgs
        }
    }
}
