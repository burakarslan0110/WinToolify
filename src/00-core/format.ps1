# Byte-size and path formatting, Save-WtReport.
# Covered by: tests/SystemHealth.Tests.ps1

# ---------------------------------------------------------------------------
# Disk & System Health bundle - shared helpers
# ---------------------------------------------------------------------------

function Format-WtByteSize {
    <#
    .SYNOPSIS
        Renders a byte count as a 1024-based size with one decimal
        (invariant culture): "512 B", "1.5 KB", "245.3 MB", "1.2 GB",
        "2.0 TB". Used by every report in the bundle so sizes read the same
        everywhere.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [long]$Bytes
    )

    if ($Bytes -lt 1024) {
        return "$Bytes B"
    }

    $units = @('KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes / 1024
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex++
    }

    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0} {1}', $value, $units[$unitIndex])
}

function Format-WtLeftTruncatedPath {
    <#
    .SYNOPSIS
        PURE: a path cut from the LEFT to fit a column. The tail is the
        half that identifies a file, so "C:\Users\..." is what may go -
        cutting from the right would leave every row reading the same.
        A path that already fits comes back untouched.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][int]$Width
    )
    $text = [string]$Path
    if ($Width -le 0) { return '' }
    if ($Width -le 3) { return '...'.Substring(0, $Width) }
    if ($text.Length -le $Width) { return $text }
    return '...' + $text.Substring($text.Length - ($Width - 3))
}

function Save-WtReport {
    <#
    .SYNOPSIS
        Writes rendered report lines to LOCALAPPDATA\WinToolify\reports\
        <name>-yyyyMMdd-HHmmss.txt (UTF8) and returns the full path. The
        lines are exactly what the console showed - the file is the
        hand-off for long reports (duplicate lists) rather than a second
        format. AllowEmptyString is required: a mandatory [string[]]
        otherwise rejects a blank line as an empty element.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [string]$TestRootOverride,

        [datetime]$Timestamp = (Get-Date)
    )

    $dataPathArgs = @{ Scope = 'User'; SubPath = 'reports' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    $reportDir = Get-WtDataPath @dataPathArgs

    $path = Join-Path $reportDir ('{0}-{1}.txt' -f $Name, $Timestamp.ToString('yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $path -Value ($Lines -join [Environment]::NewLine) -Encoding UTF8
    return $path
}
