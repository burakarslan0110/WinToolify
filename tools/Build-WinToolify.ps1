<#
.SYNOPSIS
    Concatenates the layered sources under src/ into one runnable
    WinToolify.ps1, in ordinal path order (00-core, 10-i18n, ... 90-main),
    each part wrapped in "#region src/<path>" / "#endregion src/<path>"
    so a line in the built file can be traced back to its source. Output
    is UTF-8 with BOM and CRLF; the result is parsed and a parse error or
    a function defined in two parts fails the build. Upward calls between
    layers are reported (never fatal) with -ReportLayerViolations. Needs
    nothing but Windows PowerShell 5.1 (or pwsh) - no modules, no GitHub
    Actions; CI calls this same script. Dot-source this file to load
    Build-WinToolify / Get-WtBuildParts / Get-WtLayerViolations without
    running the CLI (the InvocationName guard below).
#>
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$OutputPath,
    [string]$Version = 'dev',
    [switch]$ReportLayerViolations
)

function Get-WtBuildParts {
    <#
    .SYNOPSIS
        Lists the *.ps1 parts under -SourceRoot in ordinal relative-path
        order - sorted with an Ordinal comparer, not Sort-Object, since a
        culture-sensitive sort would order tr-TR's dotted/dotless i
        differently and the build order must be identical on every
        machine. Layer is the two-digit prefix of the first path segment
        ("40-catalogs/power-plan.ps1" -> 40) or $null when there is none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $root = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1')

    $byPath = @{}
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        $byPath[$relative] = $file.FullName
    }

    $keys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $byPath.Keys) { $keys.Add($k) }
    $keys.Sort([System.StringComparer]::Ordinal)

    $parts = foreach ($relative in $keys) {
        $layer = $null
        $firstSegment = ($relative -split '/')[0]
        if ($firstSegment -match '^(\d{2})-') { $layer = [int]$Matches[1] }
        [pscustomobject]@{
            RelativePath = $relative
            FullName     = $byPath[$relative]
            Layer        = $layer
            StartLine    = 0
            EndLine      = 0
        }
    }
    return @($parts)
}

function Get-WtLayerViolations {
    <#
    .SYNOPSIS
        Finds top-level functions that call a function defined in a HIGHER
        layer. Only CommandAst call sites count, so names carried as strings
        (dispatch tables, "& $name") never produce a false positive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,

        [Parameter(Mandatory)]
        [object[]]$Parts
    )

    function Find-WtPartForLine {
        param([int]$Line)
        foreach ($p in $Parts) {
            if ($Line -ge $p.StartLine -and $Line -le $p.EndLine) { return $p }
        }
        return $null
    }

    $functions = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))

    $layerOf = @{}
    foreach ($fn in $functions) {
        $part = Find-WtPartForLine -Line $fn.Extent.StartLineNumber
        if ($null -ne $part -and $null -ne $part.Layer) { $layerOf[$fn.Name] = [int]$part.Layer }
    }

    $violations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($fn in $functions) {
        if (-not $layerOf.ContainsKey($fn.Name)) { continue }
        $callerLayer = $layerOf[$fn.Name]
        $callerPart = Find-WtPartForLine -Line $fn.Extent.StartLineNumber
        $calls = @($fn.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        foreach ($call in $calls) {
            $name = $call.GetCommandName()
            if (-not $name -or -not $layerOf.ContainsKey($name)) { continue }
            $calleeLayer = $layerOf[$name]
            if ($calleeLayer -le $callerLayer) { continue }
            $violations.Add([pscustomobject]@{
                Caller      = $fn.Name
                CallerLayer = $callerLayer
                Callee      = $name
                CalleeLayer = $calleeLayer
                SourceFile  = 'src/' + $callerPart.RelativePath
                SourceLine  = $call.Extent.StartLineNumber - $callerPart.StartLine
            })
        }
    }
    return @($violations.ToArray())
}

function Build-WinToolify {
    <#
    .SYNOPSIS
        Builds one WinToolify.ps1 from the parts under -SourceRoot, reading
        each with ReadAllText(UTF8) so a source file's own BOM is honoured
        and stripped rather than landing mid-file. Throws on parse errors
        or a function defined in two parts. Returns OutputPath, PartCount,
        FunctionCount, LineCount and Violations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$Version = 'dev'
    )

    $parts = @(Get-WtBuildParts -SourceRoot $SourceRoot)
    if ($parts.Count -eq 0) {
        throw "Build-WinToolify: no *.ps1 parts found under '$SourceRoot'."
    }

    $crlf = "`r`n"
    $builder = New-Object System.Text.StringBuilder
    $lineNumber = 0
    foreach ($part in $parts) {
        $text = [System.IO.File]::ReadAllText($part.FullName, [System.Text.Encoding]::UTF8)
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n").Replace("`n", $crlf)

        $part.StartLine = $lineNumber + 1
        [void]$builder.Append('#region src/').Append($part.RelativePath).Append($crlf)
        [void]$builder.Append($text).Append($crlf)
        $bodyLines = ([regex]::Matches($text, "`r`n")).Count + 1
        $lineNumber += 1 + $bodyLines
        $part.EndLine = $lineNumber + 1
        [void]$builder.Append('#endregion src/').Append($part.RelativePath).Append($crlf).Append($crlf)
        $lineNumber += 2
    }

    $versionText = $Version -replace '^[vV]', ''
    $output = $builder.ToString().Replace('__WT_VERSION__', $versionText)

    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputPath, $output, (New-Object System.Text.UTF8Encoding($true)))

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($OutputPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $messages = foreach ($e in $parseErrors) {
            $line = $e.Extent.StartLineNumber
            $where = "line $line"
            foreach ($p in $parts) {
                if ($line -ge $p.StartLine -and $line -le $p.EndLine) { $where = "src/$($p.RelativePath):$($line - $p.StartLine)"; break }
            }
            "$where $($e.Message)"
        }
        throw ("Build-WinToolify: parse errors in the built file:`n - " + ($messages -join "`n - "))
    }

    $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
    $seen = @{}
    $duplicates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($fn in $functions) {
        $owner = 'unknown'
        foreach ($p in $parts) {
            if ($fn.Extent.StartLineNumber -ge $p.StartLine -and $fn.Extent.StartLineNumber -le $p.EndLine) { $owner = $p.RelativePath; break }
        }
        $key = $fn.Name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $duplicates.Add("$($fn.Name) is defined in both $($seen[$key]) and $owner")
        }
        else {
            $seen[$key] = $owner
        }
    }
    if ($duplicates.Count -gt 0) {
        throw ("Build-WinToolify: duplicate function definitions:`n - " + ($duplicates -join "`n - "))
    }

    $violations = @(Get-WtLayerViolations -Ast $ast -Parts $parts)

    return [pscustomobject]@{
        OutputPath    = $OutputPath
        PartCount     = $parts.Count
        FunctionCount = $functions.Count
        LineCount     = $lineNumber
        Version       = $versionText
        Violations    = $violations
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    if (-not $SourceRoot) { $SourceRoot = Join-Path $repoRoot 'src' }
    if (-not $OutputPath) { $OutputPath = Join-Path (Join-Path $repoRoot 'dist') 'WinToolify.ps1' }

    try {
        $result = Build-WinToolify -SourceRoot $SourceRoot -OutputPath $OutputPath -Version $Version
    }
    catch {
        Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host ("Build: OK -> {0} ({1} parts, {2} functions, {3} lines, version {4})" -f `
        $result.OutputPath, $result.PartCount, $result.FunctionCount, $result.LineCount, $result.Version) -ForegroundColor Green

    if ($ReportLayerViolations) {
        $v = @($result.Violations)
        if ($v.Count -eq 0) {
            Write-Host 'Layer report: no upward calls' -ForegroundColor Green
        }
        else {
            Write-Host "Layer report: $($v.Count) upward call(s) (report only)" -ForegroundColor Yellow
            foreach ($item in $v) {
                Write-Host (" - {0}:{1} {2} ({3}) -> {4} ({5})" -f $item.SourceFile, $item.SourceLine, $item.Caller, $item.CallerLayer, $item.Callee, $item.CalleeLayer) -ForegroundColor Yellow
            }
        }
    }

    exit 0
}
