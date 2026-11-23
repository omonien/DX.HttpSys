# Setup-MeasurementHost.ps1 - prepares the Windows measurement host for a separate
# load generator. Needs an elevated PowerShell. Every change is recorded in a
# state file so that Undo-MeasurementHost.ps1 can take it back exactly.
#
#   ./Setup-MeasurementHost.ps1 -User "MACHINE\User" [-RemoteAddress 10.211.55.0/24]
#
# Changes:
#   1. URL ACL  http://+:PORT/  for the http.sys candidates (ports from candidates.json)
#   2. Firewall rule "DX.HttpSys M0 Bench" inbound TCP for all candidate ports
#   3. Power plan "High performance" (the previous plan is recorded)
# Not touched: Defender, registry (EnableHttp3), certificate bindings, reboots.

param(
    [Parameter(Mandatory)] [string]$User,
    [string]$RemoteAddress = 'Any',
    [string]$StateFile = (Join-Path $PSScriptRoot 'measurement-host.state.json')
)

. "$PSScriptRoot/Bench.Common.ps1"
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script elevated (URL ACL, firewall and power plan need administrator rights).'
}

$state = [ordered]@{ created_utc = (Get-Date).ToUniversalTime().ToString('o'); user = $User; urlacls = @(); firewall_rule = $null; previous_power_scheme = $null; power_scheme = $null }
$cands = Get-BenchCandidates

# 1. URL ACLs
foreach ($c in $cands | Where-Object { $_.transport -eq 'httpsys' }) {
    $url = "http://+:$($c.port)/"
    $existing = (& netsh http show urlacl url=$url) -join "`n"
    if ($existing -match [regex]::Escape($url)) {
        Write-Host "URL ACL already present, left unchanged: $url"
        continue
    }
    & netsh http add urlacl url=$url user=$User | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "netsh http add urlacl failed for $url" }
    $state.urlacls += $url
}

# 2. Firewall
$ports = ($cands | ForEach-Object { [string]$_.port }) -join ','
$ruleName = 'DX.HttpSys M0 Bench'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort ($ports -split ',') `
        -RemoteAddress $RemoteAddress -Action Allow -Profile Any | Out-Null
    $state.firewall_rule = $ruleName
} else {
    Write-Host "Firewall rule already present, left unchanged: $ruleName"
}

# 3. Power plan
$active = (& powercfg /getactivescheme) -join ' '
if ($active -match '([0-9a-fA-F-]{36})') { $state.previous_power_scheme = $Matches[1] }
$high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
& powercfg /setactive $high 2>$null
if ($LASTEXITCODE -ne 0) {
    # Not visible on this machine: duplicate the built-in scheme first.
    $dup = (& powercfg -duplicatescheme $high) -join ' '
    if ($dup -match '([0-9a-fA-F-]{36})') { $high = $Matches[1]; $state.duplicated_power_scheme = $high }
    & powercfg /setactive $high
}
$state.power_scheme = $high

$state | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding utf8
Write-Host "Done. State recorded in $StateFile"
