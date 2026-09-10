# Get-WtApplySectionCatalog - section key -> apply/remove function dispatch table.
# Covered by: tests/ApplyEngine.Tests.ps1

function Get-WtApplySectionCatalog {
    <#
    .SYNOPSIS
        The apply engine's section table: every profile section plus the
        stage-only sections whose state is not cleanly diffable the way
        profiles need (DNS preset choice, downloaded blocklists, per-app
        permission sets). Stage-only rows carry StageOnly=$true and a
        $null GetState; profile export/import never sees them. Apply
        delegates here take (Names, Data) - profile rows ignore the
        second argument via $args.
    #>
    $stageOnly = @(
        [PSCustomObject]@{
            Key = 'DnsPreset'; TitleKey = 'DnsPreset'; RestartsExplorer = $false; StageOnly = $true
            GetCatalog = { Get-WtDnsPresetCatalog }; GetState = $null
            Apply = { param([string[]]$Names, $Data) Invoke-WtApplyDnsPreset -PresetName $Names[0] -SkipConfirmation }
        }
        [PSCustomObject]@{
            Key = 'Blocklist'; TitleKey = 'BlocklistSection'; RestartsExplorer = $false; StageOnly = $true
            GetCatalog = { Get-WtBlocklistTierCatalog }; GetState = $null
            Apply = { param([string[]]$Names, $Data) Invoke-WtApplyBlocklistSelection -SelectedTiers $Names -Mechanism $Data.Mechanism }
        }
        [PSCustomObject]@{
            Key = 'PerAppPermissions'; TitleKey = 'PerAppPermissions'; RestartsExplorer = $false; StageOnly = $true
            GetCatalog = { @() }; GetState = $null
            Apply = { param([string[]]$Names, $Data) Invoke-WtApplyPerAppPermissionGroups -Names $Names -Sid $Data.Sid }
            TurnOff = { param([string[]]$Names, $Data) Invoke-WtApplyPerAppPermissionGroups -Names $Names -Sid $Data.Sid -Value 'Allow' }
        }
    )

    $result = New-Object System.Collections.Generic.List[object]
    $spliced = $false
    foreach ($row in @(Get-WtProfileSectionCatalog)) {
        if (-not $spliced -and $row.RestartsExplorer) {
            foreach ($s in $stageOnly) { $result.Add($s) }
            $spliced = $true
        }
        $result.Add($row)
    }
    if (-not $spliced) { foreach ($s in $stageOnly) { $result.Add($s) } }
    return $result.ToArray()
}
