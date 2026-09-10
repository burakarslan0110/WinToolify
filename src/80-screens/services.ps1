# Services screen and start-type cycling.
# Covered by: tests/Screens.Tests.ps1

function Format-WtServiceStateLabel {
    <#
    .SYNOPSIS
        PURE: "Status/StartType" for the Services screen with both words
        localized (SvcStatus.<Status> / SvcStart.<StartType>); an unknown
        word is shown as-is.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StartType
    )
    $st = Get-Translation ('SvcStatus.' + $Status); if (-not $st) { $st = $Status }
    $sm = Get-Translation ('SvcStart.' + $StartType); if (-not $sm) { $sm = $StartType }
    return '{0}/{1}' -f $st, $sm
}

function Get-WtServiceCycleTargets {
    <#
    .SYNOPSIS
        PURE: the order Space walks a Services row through. Disabled
        first - it is what the screen has always done and what a single
        press should still mean - then the two ways back on.
    #>
    return [string[]]@('Disabled', 'Manual', 'Automatic')
}

function Get-WtServiceCycleLabels {
    <#
    .SYNOPSIS
        Target -> the word the row shows after "->", reusing the same
        SvcStart.* strings the live state column already prints, so
        "Calisiyor/Otomatik" and "-> Otomatik" never disagree.
    #>
    $labels = @{}
    foreach ($target in (Get-WtServiceCycleTargets)) {
        $text = Get-Translation ('SvcStart.' + $target)
        $labels[$target] = $(if ($text) { [string]$text } else { $target })
    }
    return $labels
}

function Invoke-WtServicesScreen {
    <#
    .SYNOPSIS
        The Services screen, where Space cycles a row through its start
        types instead of only disabling it. One Get-Service per build feeds
        a name index: enumerating per row cost a quarter second on entry,
        and a Where-Object per row another 200 ms. GetCatalog refreshes the
        snapshot before GetEntryState reads it, so an applied start type
        shows live on the rebuild that follows.
    #>
    $group = @{
        SectionKey = 'Services'; HeaderKey = $null
        Data = @{ Services = @(); ByName = @{} }
        GetCatalog = {
            param($g)
            $g.Data.Services = @(Get-Service -ErrorAction SilentlyContinue)
            $byName = @{}
            foreach ($svc in $g.Data.Services) { $byName[[string]$svc.Name] = $svc }
            $g.Data.ByName = $byName
            $targets = Get-WtServiceCycleTargets
            return @(Get-WtServiceCatalog | ForEach-Object { $_ | Add-Member -NotePropertyName 'CycleTargets' -NotePropertyValue $targets -Force -PassThru })
        }
        GetEntryState = {
            param($e, $g)
            $hit = $null
            if ($e.IsPerUser) {
                $prefix = [string]$e.Name + '_*'
                foreach ($svc in $g.Data.Services) { if ([string]$svc.Name -like $prefix) { $hit = $svc; break } }
            }
            elseif ($g.Data.ByName.ContainsKey([string]$e.Name)) { $hit = $g.Data.ByName[[string]$e.Name] }
            $s = Get-WtServiceState -Name $e.Name -IsPerUser $e.IsPerUser -GetServiceAction { if ($null -ne $hit) { @($hit) } else { @() } }
            $label = if ($s.Present) { Format-WtServiceStateLabel -Status ([string]$s.Status) -StartType ([string]$s.StartType) } else { Get-Translation 'StateNotPresent' }
            @{ Applied = $false; Available = [bool]$s.Present; StateLabel = $label }
        }
    }
    return Invoke-WtApplyScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'ServicesManagement') -Groups @($group) `
        -FooterKey 'ServicesFooter' -CycleLabels (Get-WtServiceCycleLabels)
}
