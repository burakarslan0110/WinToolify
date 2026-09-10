# Blocklist tier catalog.
# Covered by: tests/Blocklist.Tests.ps1

function Get-WtBlocklistTierCatalog {
    <#
    .SYNOPSIS
        The 3-tier WindowsSpyBlocker blocklist catalog - risk tags follow
        upstream's own warnings verbatim:
        Spy is upstream's "Recommended" tier (SAFE), Update blocks Windows
        Update (CAUTION), Extra carries upstream's own "ONLY use if you
        know what you do" danger warning and can block Office/Skype/
        Outlook/NCSI (ADVANCED).
    #>
    return Resolve-WtCatalogText -KeyPrefix 'BlocklistTier' -Catalog @(
        [PSCustomObject]@{
            Name         = 'Spy'
            Risk         = 'SAFE'
            Consequence  = $null
            DisplayLabel = 'Spy - telemetry and tracking hosts'
            HostsUrl     = 'https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt'
            FirewallUrl  = 'https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/firewall/spy.txt'
        }
        [PSCustomObject]@{
            Name         = 'Update'
            Risk         = 'CAUTION'
            Consequence  = "Blocks Windows Update; you'll need to remove this tier (Undo Last Change) to receive OS updates again"
            DisplayLabel = 'Update - Windows Update hosts'
            HostsUrl     = 'https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/update.txt'
            FirewallUrl  = 'https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/firewall/update.txt'
        }
        [PSCustomObject]@{
            Name         = 'Extra'
            Risk         = 'ADVANCED'
            Consequence  = 'Can block Office, Skype, Outlook, and NCSI - upstream''s own "ONLY use if you know what you do" warning. Applying can take several minutes (thousands of addresses, chunked).'
            DisplayLabel = 'Extra - third-party and extra hosts (Office, Skype, NCSI)'
            HostsUrl     = 'https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/extra.txt'
            FirewallUrl  = 'https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/firewall/extra.txt'
        }
    )
}
