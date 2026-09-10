# Registry-driven tool dispatch: binds the model's argument JSON to a
# handler by schema type and serializes the result to masked plain text.
# Covered by: tests/AssistantRegistry.Tests.ps1

function ConvertTo-WtAssistantHashtable {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @{} }
    if ($Value -is [hashtable]) { return $Value }
    $table = @{}
    foreach ($property in $Value.PSObject.Properties) { $table[[string]$property.Name] = $property.Value }
    return $table
}

function ConvertTo-WtAssistantHandlerArgs {
    <#
    .SYNOPSIS
        Schema property -> handler parameter splat. Absent and unknown
        properties are left out so the handler's own defaults apply. A
        failed cast or bad enum value throws ArgumentException naming the
        argument. MaskArgs strings are masked here, once for every backend.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [AllowNull()]$ToolArgs,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $bound = @{}
    $present = @()
    if ($null -ne $ToolArgs) { $present = @($ToolArgs.PSObject.Properties.Name) }
    foreach ($p in @($Record.Parameters)) {
        $name = [string]$p.Name
        if ($present -notcontains $name) { continue }
        $raw = $ToolArgs.$name
        if ($null -eq $raw) { continue }
        $value = $null
        $typeName = [string]$p.Type
        try {
            switch -CaseSensitive ($typeName) {
                'boolean' { $value = ConvertTo-WtAssistantBool -Value $raw }
                'integer' { $value = [int]$raw }
                'array'   { $value = [string[]]@(@($raw) | ForEach-Object { [string]$_ }) }
                'object'  { $value = ConvertTo-WtAssistantHashtable -Value $raw }
                default   { $value = [string]$raw }
            }
        }
        catch {
            $expected = $(if ($typeName -eq 'integer') { 'an integer' } else { 'a ' + $typeName })
            throw (New-Object System.ArgumentException(('argument ' + $name + ' must be ' + $expected + ' (got "' + [string]$raw + '")')))
        }
        if ($p.ContainsKey('Enum')) {
            $allowed = $false
            foreach ($option in @($p.Enum)) {
                if ([string]::Equals([string]$option, [string]$value, [System.StringComparison]::Ordinal)) { $allowed = $true }
            }
            if (-not $allowed) { throw (New-Object System.ArgumentException(('argument ' + $name + ' must be one of: ' + (@($p.Enum) -join ', ')))) }
        }
        if ($p.Type -eq 'string' -and (@($Record.MaskArgs) -contains $name)) {
            $value = Protect-WtAssistantText -Text $value -Mask $Context.Mask -SkipIpMask
        }
        $bound[[string]$p.Param] = $value
    }
    if ($Record.PassContext) { $bound['Context'] = $Context }
    return $bound
}

function Invoke-WtAssistantToolCall {
    <#
    .SYNOPSIS
        Runs one registered tool, turning every failure - unknown name,
        broken JSON, a bad cast, a handler that throws - into an answer
        the model can read, never an exception. A present-but-null or
        blank required argument still counts as missing, since an unbound
        mandatory parameter would prompt on the console behind the painted
        frame and block the UI thread.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$ArgumentsJson,
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowNull()][array]$Registry = $null
    )
    $fail = { param($Value) Protect-WtAssistantText -Text (ConvertTo-WtAssistantToolText -Value $Value) -Mask $Context.Mask }
    $record = Get-WtAssistantToolRecord -Name $Name -Registry $Registry
    if ($null -eq $record) { return [string](& $fail @{ error = ('unknown tool: ' + $Name) }) }
    if ($Context.ContainsKey('Disabled') -and (Test-WtAssistantToolDisabled -Name $Name -Disabled ([string[]]@($Context.Disabled)))) {
        return [string](& $fail ([ordered]@{ error = ('tool disabled by the user: ' + $Name); hint = 'do not call it again in this conversation' }))
    }
    $argumentText = ([string]$ArgumentsJson).Trim()
    $parsedArgs = $null
    if ($argumentText) {
        try { $parsedArgs = $argumentText | ConvertFrom-Json } catch { $parsedArgs = $null }
        if ($null -eq $parsedArgs) { return [string](& $fail ([ordered]@{ error = 'arguments are not valid JSON'; hint = 'send one JSON object with the parameters from the tool schema' })) }
        if (-not ($parsedArgs -is [System.Management.Automation.PSCustomObject])) { return [string](& $fail @{ error = 'arguments must be a JSON object' }) }
    }
    $present = @()
    if ($null -ne $parsedArgs) { $present = @($parsedArgs.PSObject.Properties.Name) }
    foreach ($required in @($record.Required)) {
        $found = $false
        foreach ($p in $present) { if ([string]::Equals([string]$p, [string]$required, [System.StringComparison]::Ordinal)) { $found = $true } }
        if ($found) {
            $requiredValue = $parsedArgs.$required
            if ($null -eq $requiredValue) { $found = $false }
            elseif ($requiredValue -is [string] -and ([string]$requiredValue).Trim().Length -eq 0) { $found = $false }
        }
        if (-not $found) { return [string](& $fail @{ error = ('missing required argument: ' + [string]$required) }) }
    }
    $bound = $null
    try { $bound = ConvertTo-WtAssistantHandlerArgs -Record $record -ToolArgs $parsedArgs -Context $Context }
    catch { return [string](& $fail @{ error = [string]$_.Exception.Message }) }
    $value = $null
    try { $value = & ([string]$record.Handler) @bound }
    catch { return [string](& $fail ([ordered]@{ error = ('tool failed: ' + $Name); detail = [string]$_.Exception.Message })) }
    $maxChars = [int]$record.MaxChars
    if ($value -is [System.Collections.IDictionary] -and $value.Contains('_max_chars')) {
        $topicMaxChars = [int]$value['_max_chars']
        $value.Remove('_max_chars')
        if ($topicMaxChars -gt 0) { $maxChars = $topicMaxChars }
    }
    $hint = $(if ($record.ContainsKey('Hint')) { [string]$record.Hint } else { '' })
    $text = ConvertTo-WtAssistantToolText -Value $value -MaxChars $maxChars -Hint $hint
    if ($record.SkipIpMask) { return [string](Protect-WtAssistantText -Text $text -Mask $Context.Mask -SkipIpMask) }
    return [string](Protect-WtAssistantText -Text $text -Mask $Context.Mask)
}
