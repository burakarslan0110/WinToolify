# Blocklist download, hosts lines, firewall rule plan, apply.
# Covered by: tests/Blocklist.Tests.ps1

function Invoke-WtDownloadBlocklistTier {
    <#
    .SYNOPSIS
        Downloads one tier's list and strips blank lines and lines
        starting with # (the upstream files' own header-comment
        convention). Returns every remaining line VERBATIM - a
        hosts-tier call returns lines already shaped "0.0.0.0 <domain>",
        a firewall-tier call returns bare IPv4 lines; neither is
        re-parsed or recomposed, since that mismatch is exactly the bug
        this design avoids. Propagates the exception on a request
        failure rather than returning a partial/empty list - callers
        must fail closed, before any restore-point prompt or undo
        write.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [scriptblock]$GetWebRequestAction = {
            param($u)
            Invoke-WebRequest -Uri $u -UseBasicParsing
        }
    )

    $response = & $GetWebRequestAction $Url
    $rawLines = $response.Content -split "`r?`n"
    return @($rawLines | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') })
}

function Get-WtHostsLinesToAdd {
    <#
    .SYNOPSIS
        Pure, read-only diff: for each upstream line, computes the
        marker-suffixed form (the upstream line used VERBATIM, marker
        appended, never re-parsed) and returns only the ones not
        already present in the current hosts file. Read-only by design
        - Invoke-WtGuardedChange writes the undo entry after
        CaptureState returns and before Apply runs, so this must never
        touch the hosts file itself. Calling it twice after the first
        application landed returns an empty (or shorter) list, so
        re-applying a tier never duplicates lines and undoing never
        removes another tier's.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Tier,

        [scriptblock]$ReadHostsAction = {
            $hostsPath = Join-Path $env:WinDir 'System32\drivers\etc\hosts'
            [System.IO.File]::ReadAllText($hostsPath, [System.Text.Encoding]::UTF8)
        }
    )

    $currentContent = & $ReadHostsAction
    $currentLines = [System.Collections.Generic.HashSet[string]]::new([string[]]($currentContent -split "`r?`n"))

    $toAdd = foreach ($line in $Lines) {
        $marked = "$line`t# WinToolify ($Tier)"
        if (-not $currentLines.Contains($marked)) {
            $marked
        }
    }

    return @($toAdd)
}

function Remove-WtHostsBlocklistLines {
    <#
    .SYNOPSIS
        Pure content transformation: removes only the exact recorded
        lines from hosts-file content, leaving every other line
        (including the user's own entries) untouched. No I/O - the caller
        reads/writes the real file; this is the logic Restore-WtUndoEntry's
        default -RestoreHostsItem wraps, extracted so it is directly
        testable without touching a real file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string[]]$Lines
    )

    $toRemove = [System.Collections.Generic.HashSet[string]]::new([string[]]$Lines)
    $remaining = ($Content -split "`r?`n") | Where-Object { -not $toRemove.Contains($_) }
    return ($remaining -join "`n")
}

function Get-WtFirewallRulePlan {
    <#
    .SYNOPSIS
        Validates every IP with [System.Net.IPAddress]::TryParse (dropping
        and counting anything that fails, rather than handing an
        unparseable token to New-NetFirewallRule), then chunks the
        validated addresses into groups of ChunkSize (no documented hard
        limit exists for -RemoteAddress; 500 is a conservative default)
        and names each chunk deterministically
        (WinToolify-Block-<Tier>-<Index>) - pure, no rule is created here.
        A "start-end" range (New-NetFirewallRule's IPv4 Range form) also
        validates: WindowsSpyBlocker's update/extra lists carry such
        ranges, and dropping them silently left whole Microsoft subnets
        unblocked.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$IPs,

        [Parameter(Mandatory)]
        [string]$Tier,

        [int]$ChunkSize = 500
    )

    $valid = New-Object System.Collections.Generic.List[string]
    $droppedCount = 0
    foreach ($ip in $IPs) {
        $parsed = $null
        $ends = @($ip -split '-', 2)
        $isRange = ($ends.Count -eq 2) -and
            [System.Net.IPAddress]::TryParse($ends[0].Trim(), [ref]$parsed) -and
            [System.Net.IPAddress]::TryParse($ends[1].Trim(), [ref]$parsed)
        if ([System.Net.IPAddress]::TryParse($ip, [ref]$parsed) -or $isRange) {
            $valid.Add($ip)
        }
        else {
            $droppedCount++
        }
    }

    $chunks = New-Object System.Collections.Generic.List[object]
    $chunkIndex = 0
    for ($i = 0; $i -lt $valid.Count; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize, $valid.Count) - 1
        $chunks.Add([PSCustomObject]@{
            RuleName  = "WinToolify-Block-$Tier-$chunkIndex"
            Addresses = @($valid[$i..$end])
        })
        $chunkIndex++
    }

    return [PSCustomObject]@{ Chunks = $chunks.ToArray(); DroppedCount = $droppedCount }
}

function Invoke-WtApplyBlocklistSelection {
    <#
    .SYNOPSIS
        Wires the Network Privacy "Blocklist" action: downloads the
        selected tier(s) BEFORE any restore-point prompt or undo write
        (in its own try/catch - a download failure reports and returns,
        touching neither), then applies the chosen mechanism(s) (hosts
        file, firewall rules, or both) through Invoke-WtGuardedChange, one
        undo item per (tier, mechanism) pair. Uses the real
        [System.IO.File] hosts read/write and New-NetFirewallRule calls,
        exercised manually on Windows rather than unit-tested;
        Invoke-WtGuardedChange, Get-WtHostsLinesToAdd and
        Get-WtFirewallRulePlan carry the unit tests
        (tests/ApplyFlow.Tests.ps1, tests/Blocklist.Tests.ps1).
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedTiers,

        [Parameter(Mandatory)]
        [ValidateSet('Hosts', 'Firewall', 'Both')]
        [string]$Mechanism
    )

    $catalog = Get-WtBlocklistTierCatalog
    $useHosts = $Mechanism -in @('Hosts', 'Both')
    $useFirewall = $Mechanism -in @('Firewall', 'Both')

    $downloaded = @{}
    try {
        foreach ($tierName in $SelectedTiers) {
            $tier = $catalog | Where-Object Name -eq $tierName
            if (-not $tier) { continue }
            $entry = @{}
            if ($useHosts) { $entry.HostsLines = Invoke-WtDownloadBlocklistTier -Url $tier.HostsUrl }
            if ($useFirewall) { $entry.FirewallIPs = Invoke-WtDownloadBlocklistTier -Url $tier.FirewallUrl }
            $downloaded[$tierName] = $entry
        }
    }
    catch {
        return [PSCustomObject]@{ Aborted = $true; DownloadFailed = $true; Error = $_.Exception.Message; Results = @() }
    }

    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($tierName in $SelectedTiers) {
            if ($useHosts -and $downloaded[$tierName].HostsLines) {
                $linesToAdd = Get-WtHostsLinesToAdd -Lines $downloaded[$tierName].HostsLines -Tier $tierName
                $items.Add([PSCustomObject]@{ ItemType = 'HostsBlock'; Tier = $tierName; Lines = $linesToAdd })
            }
            if ($useFirewall -and $downloaded[$tierName].FirewallIPs) {
                $plan = Get-WtFirewallRulePlan -IPs $downloaded[$tierName].FirewallIPs -Tier $tierName
                $items.Add([PSCustomObject]@{ ItemType = 'FirewallBlock'; Tier = $tierName; RuleNames = @($plan.Chunks | ForEach-Object RuleName); Chunks = $plan.Chunks })
            }
        }
        return $items.ToArray()
    }

    $apply = {
        param($Item)
        if ($Item.ItemType -eq 'HostsBlock') {
            if (@($Item.Lines).Count -eq 0) { return }
            $hostsPath = Join-Path $env:WinDir 'System32\drivers\etc\hosts'
            $content = [System.IO.File]::ReadAllText($hostsPath, [System.Text.Encoding]::UTF8)
            $updated = ($content.TrimEnd("`r", "`n") + "`n" + ($Item.Lines -join "`n") + "`n")
            [System.IO.File]::WriteAllText($hostsPath, $updated, [System.Text.Encoding]::UTF8)
        }
        elseif ($Item.ItemType -eq 'FirewallBlock') {
            $chunkIndex = 0
            $totalChunks = @($Item.Chunks).Count
            foreach ($chunk in $Item.Chunks) {
                $chunkIndex++
                Write-Verbose "  rule $chunkIndex of $totalChunks..."
                New-NetFirewallRule -DisplayName $chunk.RuleName -Group 'WinToolify' -Direction Outbound -Action Block -RemoteAddress $chunk.Addresses | Out-Null
            }
        }
    }

    $reReadState = {
        param($Item)
        if ($Item.ItemType -eq 'HostsBlock') {
            if (@($Item.Lines).Count -eq 0) { return $true }
            $hostsPath = Join-Path $env:WinDir 'System32\drivers\etc\hosts'
            $content = [System.IO.File]::ReadAllText($hostsPath, [System.Text.Encoding]::UTF8)
            foreach ($line in $Item.Lines) {
                if ($content -notmatch [regex]::Escape($line)) { return $false }
            }
            return $true
        }
        elseif ($Item.ItemType -eq 'FirewallBlock') {
            $existingNames = @(Get-NetFirewallRule -Group 'WinToolify' | Select-Object -ExpandProperty DisplayName)
            foreach ($name in $Item.RuleNames) {
                if ($existingNames -notcontains $name) { return $false }
            }
            return $true
        }
        return $false
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope Machine -ActionName 'Apply Blocklist'
}
