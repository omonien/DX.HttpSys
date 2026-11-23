# Start-Server.ps1 - starts one M0 candidate on the Windows measurement host for a
# separate load generator, samples its process once per second and stops it after
# -Seconds. Pair it with Run-Matrix.ps1 -Mode LoadOnly on the load generator.
#
#   ./Start-Server.ps1 -Candidate dxhttpsys-plain -BinDir C:\bench\bin -Seconds 560
#
# Binds to all interfaces (--host all): socket servers on 0.0.0.0, http.sys servers
# on http://+:PORT/, which needs the URL ACL from Setup-MeasurementHost.ps1.
# Output (default $env:FORGE_OUT or results/server_<date>): server logs,
# <candidate>_process.csv, environment.json.

param(
    [Parameter(Mandatory)] [string]$Candidate,
    [Parameter(Mandatory)] [string]$BinDir,
    [int]$Seconds = 560,
    [string]$BindHost = 'all',
    [string]$OutDir
)

. "$PSScriptRoot/Bench.Common.ps1"
$ErrorActionPreference = 'Stop'

if (-not $OutDir) {
    $OutDir = if ($env:FORGE_OUT) { $env:FORGE_OUT } else { Join-Path $script:BenchRoot ("results/server_{0}" -f (Get-Date).ToString('yyyy-MM-dd_HHmm')) }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$c = (Get-BenchCandidates @($Candidate))[0]
$envInfo = Get-BenchEnvironment
$envInfo.role = 'server'
$envInfo.candidate = $c
$envInfo | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutDir 'environment.json') -Encoding utf8

$server = Start-BenchServer -Candidate $c -BinDir $BinDir -BindHost $BindHost -Seconds $Seconds -LogDir $OutDir
Write-Host "READY $($c.name) on port $($server.Port) for $Seconds s"
$sampler = Start-BenchSampler -ProcessId $server.Process.Id -CsvPath (Join-Path $OutDir "$($c.name)_process.csv")
try {
    $server.Process.WaitForExit(($Seconds + 10) * 1000) | Out-Null
} finally {
    Stop-BenchServer $server
    Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue
}
Write-Host "Server $($c.name) stopped. Output in $OutDir"
