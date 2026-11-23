# Query-MeasurementHost.ps1 - read only: reports URL ACLs, firewall rules and the
# active power plan relevant for M0. Changes nothing, needs no elevation.

. "$PSScriptRoot/Bench.Common.ps1"
$ports = (Get-BenchCandidates) | ForEach-Object { [int]$_.port }
Write-Host '=== URL ACLs for the candidate ports'
$acl = (& netsh http show urlacl) -join "`n"
foreach ($p in $ports) {
    $hits = @($acl -split "`n" | Where-Object { $_ -match ":$p/" })
    if ($hits.Count -gt 0) { $hits | ForEach-Object { Write-Host "  $($_.Trim())" } } else { Write-Host "  port $($p): none" }
}
Write-Host '=== Firewall rules named DX.HttpSys M0 Bench'
$rules = @(Get-NetFirewallRule -DisplayName 'DX.HttpSys M0 Bench' -ErrorAction SilentlyContinue)
if ($rules.Count -eq 0) { Write-Host '  none' } else { $rules | ForEach-Object { Write-Host "  $($_.DisplayName) enabled=$($_.Enabled)" } }
Write-Host '=== Inbound allow rules covering candidate ports'
try {
    $pf = Get-NetFirewallPortFilter -Protocol TCP -ErrorAction Stop | Where-Object { $lp = $_.LocalPort; $ports | Where-Object { $lp -contains "$_" } }
    if (-not $pf) { Write-Host '  none' } else { $pf | ForEach-Object { $r = $_ | Get-NetFirewallRule; Write-Host "  $($r.DisplayName) ports=$($_.LocalPort)" } }
} catch { Write-Host "  query failed: $($_.Exception.Message)" }
Write-Host '=== Power plan'
Write-Host ("  " + ((& powercfg /getactivescheme) -join ' '))
Write-Host '=== Elevated'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
Write-Host ("  " + $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
