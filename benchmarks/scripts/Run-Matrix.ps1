# Run-Matrix.ps1 - runs the M0 load matrix with k6.
#
# Two modes:
#   -Mode Local     server and k6 on the same Windows host (fallback; results are
#                   marked "loopback" and must not be mixed with separate runs).
#                   Starts every candidate itself, rotates the candidate order per
#                   repetition, samples the server process once per second.
#   -Mode LoadOnly  only k6, against a server started elsewhere with Start-Server.ps1
#                   (e.g. k6 on the Mac, server on the Windows measurement host).
#                   Give -Target and exactly one -Candidates name.
#
# Examples:
#   ./Run-Matrix.ps1 -Mode Local -BinDir ..\..\build\benchmarks\Win64\Release
#   ./Run-Matrix.ps1 -Mode LoadOnly -Target http://messhost:8086 -Candidates dxhttpsys-plain
#   ./Run-Matrix.ps1 -Mode LoadOnly -Target http://messhost:8086 -Candidates dxhttpsys-plain -Entries plaintext-ka1 -Vus 256
#   -Quick: warmup 5 s, 10 s per run, 2 s pause (smoke of the pipeline, not for results)
#
# Per candidate and matrix entry: warmup (discarded), then -Runs measured runs with
# -Pause seconds between them. Output: <OutDir>/<candidate>_<scenario>_ka<k>_<vus>_<run>.json
# plus .meta.json (start/end UTC), environment.json and process CSVs (Local mode).
# Aggregate afterwards with Collect-Results.ps1.

param(
    [ValidateSet('Local', 'LoadOnly')] [string]$Mode = 'Local',
    [string]$BinDir,
    [string]$Target,
    [string[]]$Candidates,
    [string[]]$Entries,
    [string[]]$Vus,
    [int]$Runs = 3,
    [int]$WarmupSec = 15,
    [int]$DurationSec = 30,
    [int]$PauseSec = 10,
    [int]$Rate = 5000,
    [string]$K6 = 'k6',
    [string]$OutDir,
    [switch]$Quick
)

. "$PSScriptRoot/Bench.Common.ps1"
$ErrorActionPreference = 'Stop'

# Accept comma separated lists also with pwsh -File (one string argument).
function Split-List([string[]]$Value) { if ($Value) { return @($Value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } return $null }
$Candidates = Split-List $Candidates
$Entries = Split-List $Entries
$VusFilter = $null
if ($Vus) { $VusFilter = @(Split-List $Vus | ForEach-Object { [int]$_ }) }

if ($Quick) { $WarmupSec = 5; $DurationSec = 10; $PauseSec = 2 }
if (-not $OutDir) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmm')
    $OutDir = Join-Path $script:BenchRoot ("results/{0}_{1}_{2}" -f $stamp, [Environment]::MachineName, $Mode.ToLower())
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$k6Version = (& $K6 version 2>&1 | Select-Object -First 1)
$envInfo = Get-BenchEnvironment
$envInfo.mode = if ($Mode -eq 'Local') { 'loopback' } else { 'separate' }
$envInfo.k6_version = "$k6Version"
$envInfo.runs = $Runs; $envInfo.warmup_sec = $WarmupSec; $envInfo.duration_sec = $DurationSec; $envInfo.pause_sec = $PauseSec
$envInfo.target = $Target
$envInfo.candidates = Get-BenchCandidates $Candidates
$envInfo | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutDir 'environment.json') -Encoding utf8

$matrix = Get-BenchMatrix
if ($Entries) { $matrix = @($matrix | Where-Object { $Entries -contains $_.id }) }
if ($matrix.Count -eq 0) { throw 'No matrix entries selected.' }
$cands = Get-BenchCandidates $Candidates

function Invoke-CandidateMatrix {
    param($Candidate, [string]$BaseUrl, [string[]]$RunIds)
    foreach ($m in $matrix) {
        $vusList = $m.vus
        if ($VusFilter) { $vusList = @($m.vus | Where-Object { $VusFilter -contains $_ }) }
        foreach ($v in $vusList) {
            Write-Host ("--- {0} {1} vus={2}" -f $Candidate.name, $m.id, $v)
            Invoke-BenchK6 -K6 $K6 -Target $BaseUrl -Candidate $Candidate.name -Scenario $m.scenario -Vus $v `
                -KeepAlive $m.keepalive -Run 'warmup' -DurationSec $WarmupSec -OutDir $OutDir -Rate $Rate | Out-Null
            foreach ($r in $RunIds) {
                Start-Sleep -Seconds $PauseSec
                Invoke-BenchK6 -K6 $K6 -Target $BaseUrl -Candidate $Candidate.name -Scenario $m.scenario -Vus $v `
                    -KeepAlive $m.keepalive -Run $r -DurationSec $DurationSec -OutDir $OutDir -Rate $Rate | Out-Null
            }
        }
    }
}

if ($Mode -eq 'LoadOnly') {
    if (-not $Target) { throw '-Target is required in LoadOnly mode.' }
    if ($cands.Count -ne 1) { throw 'LoadOnly mode needs exactly one -Candidates name.' }
    Invoke-CandidateMatrix -Candidate $cands[0] -BaseUrl $Target.TrimEnd('/') -RunIds (1..$Runs | ForEach-Object { "$_" })
} else {
    if (-not $BinDir) { throw '-BinDir is required in Local mode.' }
    for ($rep = 1; $rep -le $Runs; $rep++) {
        # Rotate the candidate order per repetition.
        $shift = ($rep - 1) % $cands.Count
        $order = @($cands[$shift..($cands.Count - 1)]) + @(if ($shift -gt 0) { $cands[0..($shift - 1)] })
        foreach ($c in $order) {
            $server = Start-BenchServer -Candidate $c -BinDir $BinDir -BindHost 'localhost' -Seconds 86400 -LogDir $OutDir
            $sampler = Start-BenchSampler -ProcessId $server.Process.Id -CsvPath (Join-Path $OutDir ("{0}_process_rep{1}.csv" -f $c.name, $rep))
            try {
                Invoke-CandidateMatrix -Candidate $c -BaseUrl $server.BaseUrl -RunIds @("$rep")
            } finally {
                Stop-BenchServer $server
                Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
Write-Host "Results in $OutDir"
