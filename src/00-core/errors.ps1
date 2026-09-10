# The error log: unexpected exceptions from the navigation loop and the
# entry point are appended here so a crashed console still leaves a trace.
# Covered by: tests/Storage.Tests.ps1

function Get-WtErrorLogPath {
    <#
    .SYNOPSIS
        <User data root>\errors.log. User scope on purpose: the log is
        for the person in front of the console, like settings.json.
        $script:WtErrorLogPath, when set, overrides it (tests point it
        at a temp file so a deliberately thrown test error never lands
        in the real log).
    #>
    param([string]$TestRootOverride)
    if ($script:WtErrorLogPath) { return [string]$script:WtErrorLogPath }
    $dataPathArgs = @{ Scope = 'User' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    return Join-Path (Get-WtDataPath @dataPathArgs) 'errors.log'
}

function Write-WtErrorLog {
    <#
    .SYNOPSIS
        Appends one exception to the error log - when, where it was
        caught, the type, the message, the script position and the
        script stack - and returns the log path ('' when even that
        failed). NEVER throws: it runs inside the catch blocks whose one
        job is to keep the app alive. A log past 1 MB is started over.
    #>
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [AllowEmptyString()][string]$Context = '',
        [string]$Path = ''
    )
    try {
        if (-not $Path) { $Path = Get-WtErrorLogPath }
        $exception = $(if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord })
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('==== ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Context)
        $lines.Add('Type: ' + $(if ($null -ne $exception) { $exception.GetType().FullName } else { '' }))
        $lines.Add('Message: ' + [string]$(if ($null -ne $exception) { $exception.Message } else { $ErrorRecord }))
        if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            if ($ErrorRecord.InvocationInfo) { $lines.Add('At: ' + ([string]$ErrorRecord.InvocationInfo.PositionMessage).Trim()) }
            if ($ErrorRecord.ScriptStackTrace) { $lines.Add('Stack: ' + [string]$ErrorRecord.ScriptStackTrace) }
        }
        $lines.Add('')
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 1MB) { Remove-Item -LiteralPath $Path -Force }
        Add-Content -LiteralPath $Path -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
        return $Path
    }
    catch { return '' }
}

function Get-WtErrorSummaryLines {
    <#
    .SYNOPSIS
        PURE: the two lines a screen shows for an error - the message,
        then the first line of the script position ("At line:12 char:5")
        when there is one. A Windows error message can run to several
        sentences; the panel wraps it, this only picks what to show.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    $exception = $(if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord })
    $lines = New-Object System.Collections.Generic.List[string]
    $message = [string]$(if ($null -ne $exception) { $exception.Message } else { $ErrorRecord })
    if (-not $message) { $message = [string]$ErrorRecord }
    $lines.Add($message)
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord] -and $ErrorRecord.InvocationInfo) {
        $position = [string]$ErrorRecord.InvocationInfo.PositionMessage
        $firstLine = ($position -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($firstLine) { $lines.Add(([string]$firstLine).Trim()) }
    }
    return [string[]]$lines.ToArray()
}
