# Local LLM server discovery: the provider table, the models-list call, port
# scan, Ollama tool-capability probes, and "installed but not running" hints.
# Covered by: tests/AssistantDetect.Tests.ps1

function Get-WtLocalLlmProviderTable {
    <#
    .SYNOPSIS
        The four local servers the scan knows, with the URI that proves
        each one is up and the OpenAI-compatible endpoint to record.
        Ollama is probed on its native /api/tags (always present) but
        TALKED TO through its /v1 compatibility endpoint.
    #>
    return @(
        [PSCustomObject]@{ Provider = 'LM Studio'; ProbeUri = 'http://127.0.0.1:1234/v1/models'; Endpoint = 'http://127.0.0.1:1234/v1'; Kind = 'OpenAI' }
        [PSCustomObject]@{ Provider = 'Ollama'; ProbeUri = 'http://127.0.0.1:11434/api/tags'; Endpoint = 'http://127.0.0.1:11434/v1'; Kind = 'Ollama' }
        [PSCustomObject]@{ Provider = 'llama.cpp'; ProbeUri = 'http://127.0.0.1:8080/v1/models'; Endpoint = 'http://127.0.0.1:8080/v1'; Kind = 'OpenAI' }
        [PSCustomObject]@{ Provider = 'Jan'; ProbeUri = 'http://127.0.0.1:1337/v1/models'; Endpoint = 'http://127.0.0.1:1337/v1'; Kind = 'OpenAI' }
    )
}

function Test-WtLlmOllamaEndpoint {
    <#
    .SYNOPSIS
        PURE: whether an endpoint URL is Ollama's OpenAI-compatible port
        (11434, on any host) - the only server that reads options.num_ctx.
        Nothing about the endpoint KIND is persisted, so the port is the
        one durable signal; a hand-typed http://localhost:11434/v1 counts.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Endpoint)
    if (-not $Endpoint) { return $false }
    $uri = $null
    try { $uri = [uri]$Endpoint } catch { return $false }
    if ($null -eq $uri -or -not $uri.IsAbsoluteUri) { return $false }
    return ([int]$uri.Port -eq 11434)
}

function ConvertFrom-WtLlmModelsJson {
    <#
    .SYNOPSIS
        Model ids out of a models answer: OpenAI style { data: [ { id } ] }
        or Ollama tags { models: [ { name } ] }. Anything else -> empty.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Json,
        [ValidateSet('OpenAI', 'Ollama')][string]$Kind = 'OpenAI'
    )
    $obj = $null
    try { $obj = ([string]$Json) | ConvertFrom-Json } catch { return [string[]]@() }
    if ($null -eq $obj) { return [string[]]@() }
    $names = New-Object System.Collections.Generic.List[string]
    if ($Kind -eq 'Ollama') {
        if ($obj.PSObject.Properties.Name -contains 'models') {
            foreach ($m in @($obj.models)) { if ($null -ne $m -and $m.PSObject.Properties.Name -contains 'name' -and $m.name) { $names.Add([string]$m.name) } }
        }
    }
    elseif ($obj.PSObject.Properties.Name -contains 'data') {
        foreach ($m in @($obj.data)) { if ($null -ne $m -and $m.PSObject.Properties.Name -contains 'id' -and $m.id) { $names.Add([string]$m.id) } }
    }
    return [string[]]$names.ToArray()
}

function Get-WtLlmModelList {
    <#
    .SYNOPSIS
        GET /models against a configured endpoint - what the Settings
        screen's model picker shows.
    #>
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [AllowNull()][AllowEmptyString()][string]$ApiKey = '',
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $r = & $Transport @{ Uri = (Get-WtLlmModelsUri -Endpoint $Endpoint); Method = 'GET'; ApiKey = $ApiKey; Stream = $false; TimeoutSec = 15 }
    if (-not $r.Ok) {
        $kind = Get-WtLlmErrorKind -StatusCode ([int]$r.StatusCode) -Body ([string]$r.Body) -FailureKind ([string]$r.Failure)
        return @{ Ok = $false; Models = [string[]]@(); ErrorText = (Get-WtLlmErrorText -Kind $kind -Detail ([string]$r.Body)) }
    }
    return @{ Ok = $true; Models = @(ConvertFrom-WtLlmModelsJson -Json ([string]$r.Body) -Kind 'OpenAI'); ErrorText = '' }
}

function Find-WtLocalLlmServers {
    <#
    .SYNOPSIS
        Probes the provider table's four 127.0.0.1 URIs with a short timeout
        and returns every server that answered with models. Literal IPv4, not
        localhost: localhost resolves to ::1 first on this stack, and the
        short timeout dies before the IPv4 fallback. Never leaves the machine.
    #>
    param(
        [scriptblock]$Probe = { param($Uri)
            try { (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).Content } catch { $null }
        }
    )
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($provider in (Get-WtLocalLlmProviderTable)) {
        $raw = & $Probe ([string]$provider.ProbeUri)
        if (-not $raw) { continue }
        $models = @(ConvertFrom-WtLlmModelsJson -Json ([string]$raw) -Kind ([string]$provider.Kind))
        if ($models.Count -eq 0) { continue }
        $found.Add([PSCustomObject]@{ Provider = [string]$provider.Provider; Endpoint = [string]$provider.Endpoint; Models = $models })
    }
    return @($found.ToArray())
}

function Get-WtOllamaToolCapableModels {
    <#
    .SYNOPSIS
        Prefers Ollama models whose /api/show lists the "tools"
        capability. Deliberately fail-open: an older Ollama without the
        capabilities field, a failed call, or a list where NOTHING claims
        tools all return the input unchanged - the connection test is the
        real judge; this only improves the ordering.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Models,
        [scriptblock]$Probe = { param($Uri, $BodyJson)
            try { (Invoke-WebRequest -Uri $Uri -Method Post -Body $BodyJson -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop).Content } catch { $null }
        }
    )
    $capable = New-Object System.Collections.Generic.List[string]
    foreach ($model in @($Models)) {
        $raw = & $Probe 'http://127.0.0.1:11434/api/show' (@{ model = $model } | ConvertTo-Json -Depth 3 -Compress)
        if (-not $raw) { return [string[]]@($Models) }
        $obj = $null
        try { $obj = ([string]$raw) | ConvertFrom-Json } catch { return [string[]]@($Models) }
        if ($null -ne $obj -and ($obj.PSObject.Properties.Name -contains 'capabilities') -and (@($obj.capabilities) -contains 'tools')) {
            $capable.Add([string]$model)
        }
    }
    if ($capable.Count -eq 0) { return [string[]]@($Models) }
    return [string[]]$capable.ToArray()
}

function Test-WtOllamaModelToolCapable {
    <#
    .SYNOPSIS
        One /api/show for ONE model with a three-way verdict: 'Tools',
        'NoTools' (capabilities present, tools absent), or 'Unknown' (no
        answer, bad JSON, pre-capabilities Ollama). Only a firm 'NoTools'
        blocks the auto-pick; 'Unknown' stays fail-open.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [scriptblock]$Probe = { param($Uri, $BodyJson)
            try { (Invoke-WebRequest -Uri $Uri -Method Post -Body $BodyJson -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop).Content } catch { $null }
        }
    )
    $raw = & $Probe 'http://127.0.0.1:11434/api/show' (@{ model = $Model } | ConvertTo-Json -Depth 3 -Compress)
    if (-not $raw) { return 'Unknown' }
    $parsed = $null
    try { $parsed = ([string]$raw) | ConvertFrom-Json } catch { return 'Unknown' }
    if ($null -eq $parsed -or -not (@($parsed.PSObject.Properties.Name) -contains 'capabilities')) { return 'Unknown' }
    if (@($parsed.capabilities) -contains 'tools') { return 'Tools' }
    return 'NoTools'
}

function Get-WtLlmLocalHints {
    <#
    .SYNOPSIS
        "Installed but not running" hints for the two providers whose
        installs leave a findable trace: ollama on PATH, LM Studio in its
        known install folders.
    #>
    param(
        [scriptblock]$GetCommand = { param($Name) Get-Command $Name -ErrorAction SilentlyContinue },
        [scriptblock]$TestPath = { param($Path) Test-Path -LiteralPath $Path }
    )
    $hints = New-Object System.Collections.Generic.List[string]
    if (& $GetCommand 'ollama') { $hints.Add([string](Get-Translation 'AsHintOllamaInstalled')) }
    foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Programs\LM Studio'), (Join-Path $env:LOCALAPPDATA 'LM-Studio'))) {
        if (& $TestPath $root) { $hints.Add([string](Get-Translation 'AsHintLmStudioInstalled')); break }
    }
    return [string[]]$hints.ToArray()
}
