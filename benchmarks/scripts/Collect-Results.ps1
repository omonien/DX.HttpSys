# Collect-Results.ps1 - aggregates k6 JSON summaries of one result folder into
# summary.csv (one row per run) and summary_median.csv (median over the runs,
# with min and max of the requests per second as spread).
#
#   ./Collect-Results.ps1 -ResultDir ../results/2026-11-23_1200_FORGE_local
#
# CPU, working set and thread figures come from the process CSV files of
# Run-Matrix.ps1 (Local mode) or Start-Server.ps1 (copy them into the folder),
# restricted to the time window of each run (.meta.json).

param([Parameter(Mandatory)] [string]$ResultDir)

. "$PSScriptRoot/Bench.Common.ps1"
$ErrorActionPreference = 'Stop'

$envFile = Join-Path $ResultDir 'environment.json'
$envInfo = if (Test-Path $envFile) { Get-Content -Raw $envFile | ConvertFrom-Json } else { $null }
$hostName = if ($envInfo) { $envInfo.host } else { 'unknown' }
$gitSha = if ($envInfo) { $envInfo.git_sha } else { 'unknown' }
$mode = if ($envInfo -and $envInfo.PSObject.Properties['mode']) { $envInfo.mode } else { 'unknown' }
$versions = @{}
foreach ($c in (Get-BenchCandidates)) { $versions[$c.name] = $c.version }

# Process samples per candidate.
$samples = @{}
foreach ($f in Get-ChildItem -Path $ResultDir -Filter '*_process*.csv' -ErrorAction SilentlyContinue) {
    $cand = $f.Name -replace '_process.*$', ''
    if (-not $samples.ContainsKey($cand)) { $samples[$cand] = @() }
    $samples[$cand] += Import-Csv $f.FullName
}

function ConvertTo-Utc($value) {
    if ($value -is [DateTime]) { return $value.ToUniversalTime() }
    return [DateTime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-Metric($data, [string]$name, [string]$field) {
    $m = $data.metrics.PSObject.Properties[$name]
    if (-not $m) { return $null }
    $v = $m.Value.values.PSObject.Properties[$field]
    if (-not $v) { return $null }
    return [double]$v.Value
}

$rows = @()
foreach ($f in Get-ChildItem -Path $ResultDir -Filter '*.json' | Where-Object { $_.Name -notlike '*.meta.json' -and $_.Name -ne 'environment.json' -and $_.Name -ne 'smoke.json' }) {
    $data = Get-Content -Raw $f.FullName | ConvertFrom-Json
    if (-not $data.PSObject.Properties['bench']) { continue }
    $b = $data.bench
    $durationMs = [double]$data.state.testRunDurationMs
    $count = Get-Metric $data 'http_reqs' 'count'
    $rps = if ($durationMs -gt 0) { $count / ($durationMs / 1000.0) } else { 0 }
    $err = Get-Metric $data 'bench_errors' 'rate'
    $cpu = ''; $rss = ''; $threads = ''
    $metaFile = $f.FullName -replace '\.json$', '.meta.json'
    if ((Test-Path $metaFile) -and $samples.ContainsKey($b.candidate)) {
        $meta = Get-Content -Raw $metaFile | ConvertFrom-Json
        $from = ConvertTo-Utc $meta.start_utc
        $to = ConvertTo-Utc $meta.end_utc
        $win = @($samples[$b.candidate] | Where-Object {
            $t = ConvertTo-Utc $_.timestamp_utc; $t -ge $from -and $t -le $to -and $_.cpu_pct -ne '' })
        if ($win.Count -gt 0) {
            $cpu = [math]::Round(($win | ForEach-Object { [double]$_.cpu_pct } | Measure-Object -Average).Average, 1)
            $rss = ($win | ForEach-Object { [double]$_.working_set_mb } | Measure-Object -Maximum).Maximum
            $threads = ($win | ForEach-Object { [int]$_.threads } | Measure-Object -Maximum).Maximum
        }
    }
    $rows += [pscustomobject]([ordered]@{
        date = $f.LastWriteTimeUtc.ToString('yyyy-MM-dd'); git_sha = $gitSha; host = $hostName; mode = $mode
        candidate = $b.candidate; candidate_version = $versions[$b.candidate]; scenario = $b.scenario
        keepalive = $b.keepalive; vus = $b.vus; run = $b.run
        rps = [math]::Round($rps, 1)
        p50_ms = [math]::Round((Get-Metric $data 'http_req_duration' 'p(50)'), 3)
        p95_ms = [math]::Round((Get-Metric $data 'http_req_duration' 'p(95)'), 3)
        p99_ms = [math]::Round((Get-Metric $data 'http_req_duration' 'p(99)'), 3)
        max_ms = [math]::Round((Get-Metric $data 'http_req_duration' 'max'), 3)
        err_pct = if ($null -ne $err) { [math]::Round($err * 100, 3) } else { '' }
        cpu_avg_pct = $cpu; rss_peak_mb = $rss; threads_peak = $threads
    })
}
if ($rows.Count -eq 0) { throw "No k6 summaries found in $ResultDir" }
$rows | Sort-Object candidate, scenario, keepalive, vus, run | Export-Csv -Path (Join-Path $ResultDir 'summary.csv') -NoTypeInformation -Encoding utf8

function Get-Median([double[]]$v) {
    $s = @($v | Sort-Object)
    $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return $s[[int][math]::Floor($n / 2)] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

$median = foreach ($g in ($rows | Group-Object candidate, scenario, keepalive, vus)) {
    $r0 = $g.Group[0]
    [pscustomobject]([ordered]@{
        candidate = $r0.candidate; scenario = $r0.scenario; keepalive = $r0.keepalive; vus = $r0.vus; runs = $g.Count
        rps_median = [math]::Round((Get-Median ($g.Group | ForEach-Object { [double]$_.rps })), 1)
        rps_min = ($g.Group | ForEach-Object { [double]$_.rps } | Measure-Object -Minimum).Minimum
        rps_max = ($g.Group | ForEach-Object { [double]$_.rps } | Measure-Object -Maximum).Maximum
        p99_ms_median = [math]::Round((Get-Median ($g.Group | ForEach-Object { [double]$_.p99_ms })), 3)
        err_pct_max = ($g.Group | ForEach-Object { if ($_.err_pct -ne '') { [double]$_.err_pct } else { 0 } } | Measure-Object -Maximum).Maximum
    })
}
$median | Sort-Object scenario, keepalive, vus, @{ Expression = 'rps_median'; Descending = $true } |
    Export-Csv -Path (Join-Path $ResultDir 'summary_median.csv') -NoTypeInformation -Encoding utf8
Write-Host "Wrote summary.csv ($($rows.Count) rows) and summary_median.csv to $ResultDir"
