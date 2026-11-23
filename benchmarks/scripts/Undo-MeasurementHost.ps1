# Undo-MeasurementHost.ps1 - takes back exactly what Setup-MeasurementHost.ps1
# recorded in its state file. Needs an elevated PowerShell.

param([string]$StateFile = (Join-Path $PSScriptRoot 'measurement-host.state.json'))

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $StateFile)) { throw "State file not found: $StateFile" }
$state = Get-Content -Raw $StateFile | ConvertFrom-Json

foreach ($url in $state.urlacls) {
    & netsh http delete urlacl url=$url | Out-Host
}
if ($state.firewall_rule) {
    Remove-NetFirewallRule -DisplayName $state.firewall_rule -ErrorAction SilentlyContinue
}
if ($state.previous_power_scheme) {
    & powercfg /setactive $state.previous_power_scheme
}
if ($state.PSObject.Properties['duplicated_power_scheme'] -and $state.duplicated_power_scheme) {
    & powercfg -delete $state.duplicated_power_scheme
}
Rename-Item -Path $StateFile -NewName ((Split-Path -Leaf $StateFile) + '.undone')
Write-Host 'Measurement host restored.'
