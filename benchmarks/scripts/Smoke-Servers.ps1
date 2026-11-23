# Smoke-Servers.ps1 - starts every M0 benchmark server on localhost, checks all
# endpoints over HTTP/1.1 and runs a short loopback mini load (indicative only,
# NOT a benchmark: client and server share the machine).
#
# Usage (PowerShell 7, Windows):
#   ./Smoke-Servers.ps1 indy-plain=C:\path\BenchIndyPlain.exe dxhttpsys-plain=C:\path\BenchDXHttpSysPlain.exe ...
#   ./Smoke-Servers.ps1 bindir=C:\path\bin            (all candidates from candidates.json)
#   optional: out=C:\results\smoke   loadseconds=5   parallel=16
# Without out= the results go to $env:FORGE_OUT (Forge run_tool) or ./results/smoke.
# Exit code 0 when every server passed every check.

param([Parameter(ValueFromRemainingArguments = $true)] [string[]]$Pairs)

. "$PSScriptRoot/Bench.Common.ps1"
$ErrorActionPreference = 'Stop'

$exeMap = [ordered]@{}
$binDir = $null
$outDir = if ($env:FORGE_OUT) { $env:FORGE_OUT } else { Join-Path $script:BenchRoot 'results/smoke' }
$loadSeconds = 5
$parallel = 16
foreach ($p in $Pairs) {
    $i = $p.IndexOf('=')
    if ($i -lt 1) { throw "Expected name=value, got '$p'" }
    $k = $p.Substring(0, $i); $v = $p.Substring($i + 1)
    switch ($k) {
        'out' { $outDir = $v }
        'bindir' { $binDir = $v }
        'loadseconds' { $loadSeconds = [int]$v }
        'parallel' { $parallel = [int]$v }
        default { $exeMap[$k] = $v }
    }
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$candidates = Get-BenchCandidates
$targets = @()
foreach ($c in $candidates) {
    if ($exeMap.Contains($c.name)) {
        $targets += [pscustomobject]@{ Candidate = $c; Exe = $exeMap[$c.name] }
    } elseif ($binDir) {
        $targets += [pscustomobject]@{ Candidate = $c; Exe = (Join-Path $binDir $c.exe) }
    }
}
if ($targets.Count -eq 0) { throw 'No servers given.' }

Add-Type -AssemblyName System.Net.Http
function New-Http11Client {
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.MaxConnectionsPerServer = 1024
    $handler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(5)
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestVersion = [Version]'1.1'
    $client.DefaultVersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionExact
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    return $client
}

function Test-Endpoint {
    param($Client, [string]$Method, [string]$Url, [int]$BodySize, [int]$ExpectStatus, [int]$ExpectLength, [string]$ExpectText, [string]$ExpectType)
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
    $req.Version = [Version]'1.1'
    $req.VersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionExact
    if ($BodySize -gt 0) {
        $bytes = [byte[]]::new($BodySize)
        [System.Array]::Fill($bytes, [byte]120)
        $req.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
        $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
    }
    $resp = $Client.SendAsync($req).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $problems = @()
    if ([int]$resp.StatusCode -ne $ExpectStatus) { $problems += "status $([int]$resp.StatusCode) <> $ExpectStatus" }
    if ($resp.Version -ne [Version]'1.1') { $problems += "proto HTTP/$($resp.Version)" }
    if ($ExpectLength -ge 0 -and $body.Length -ne $ExpectLength) { $problems += "length $($body.Length) <> $ExpectLength" }
    if ($ExpectText) {
        $text = [System.Text.Encoding]::UTF8.GetString($body).Trim()
        if ($text -ne $ExpectText) { $problems += "body '$text' <> '$ExpectText'" }
    }
    $ctype = ''
    if ($resp.Content.Headers.ContentType) { $ctype = $resp.Content.Headers.ContentType.MediaType }
    if ($ExpectType -and $ctype -ne $ExpectType) { $problems += "content-type '$ctype' <> '$ExpectType'" }
    $connClose = $resp.Headers.ConnectionClose -eq $true
    return [pscustomobject]@{
        endpoint = "$Method $(([Uri]$Url).AbsolutePath)"; ok = ($problems.Count -eq 0); problems = ($problems -join '; ')
        status = [int]$resp.StatusCode; length = $body.Length; proto = "HTTP/$($resp.Version)"; content_type = $ctype; connection_close = $connClose
    }
}

function Invoke-MiniLoad {
    param([string]$Url, [int]$Seconds, [int]$Parallel)
    $client = New-Http11Client
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Synchronous parallel workers via runspaces (ForEach-Object -Parallel, PS 7).
    $results = 1..$Parallel | ForEach-Object -ThrottleLimit $Parallel -Parallel {
        $c = $using:client; $u = $using:Url; $end = $using:deadline
        $n = 0; $e = 0
        while ([DateTime]::UtcNow -lt $end) {
            try {
                $r = $c.GetAsync($u).GetAwaiter().GetResult()
                $null = $r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ([int]$r.StatusCode -eq 200) { $n++ } else { $e++ }
                $r.Dispose()
            } catch { $e++ }
        }
        [pscustomobject]@{ n = $n; e = $e }
    }
    $sw.Stop()
    $total = ($results | Measure-Object -Property n -Sum).Sum
    $errs = ($results | Measure-Object -Property e -Sum).Sum
    $client.Dispose()
    return [pscustomobject]@{ requests = $total; errors = $errs; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); rps = [math]::Round($total / $sw.Elapsed.TotalSeconds, 0); parallel = $Parallel }
}

$report = [ordered]@{ environment = (Get-BenchEnvironment); note = 'Loopback smoke test on one machine. Mini load numbers are indicative only and not M0 measurements.'; servers = @() }
$allOk = $true
foreach ($t in $targets) {
    $c = $t.Candidate
    Write-Host "=== $($c.name) ($($t.Exe))"
    $entry = [ordered]@{ candidate = $c.name; exe = $t.Exe; started = $false; checks = @(); ok = $false; keepalive = $null; load = $null }
    $server = $null
    try {
        $server = Start-BenchServer -Candidate $c -Exe $t.Exe -BindHost 'localhost' -Seconds 120 -LogDir $outDir
        $entry.started = $true
        $base = $server.BaseUrl
        $client = New-Http11Client
        $checks = @(
            (Test-Endpoint $client 'GET' "$base/plaintext" 0 200 13 'Hello, World!' 'text/plain'),
            (Test-Endpoint $client 'GET' "$base/json" 0 200 27 '{"message":"Hello, World!"}' 'application/json'),
            (Test-Endpoint $client 'GET' "$base/bytes/64k" 0 200 65536 '' 'application/octet-stream'),
            (Test-Endpoint $client 'GET' "$base/bytes/1m" 0 200 1048576 '' 'application/octet-stream'),
            (Test-Endpoint $client 'POST' "$base/echo" 16384 200 -1 '16384' 'text/plain'),
            (Test-Endpoint $client 'POST' "$base/echo" 1048576 200 -1 '1048576' 'text/plain'),
            (Test-Endpoint $client 'GET' "$base/nope" 0 404 -1 '' '')
        )
        $client.Dispose()
        $entry.checks = $checks
        $entry.ok = -not ($checks | Where-Object { -not $_.ok })
        $entry.keepalive = -not ($checks[0].connection_close)
        $entry.load = Invoke-MiniLoad -Url "$base/plaintext" -Seconds $loadSeconds -Parallel $parallel
        $p = Get-Process -Id $server.Process.Id -ErrorAction SilentlyContinue
        if ($p) {
            $entry.working_set_mb = [math]::Round($p.WorkingSet64 / 1MB, 1)
            $entry.threads = $p.Threads.Count
            $entry.handles = $p.HandleCount
        }
        if ($entry.load.errors -gt 0) { $entry.ok = $false }
    } catch {
        $entry.error = $_.Exception.Message
        $entry.ok = $false
    } finally {
        if ($server) { Stop-BenchServer $server }
    }
    if (-not $entry.ok) { $allOk = $false }
    $status = if ($entry.ok) { 'OK' } else { 'FAILED' }
    Write-Host "  $status keepalive=$($entry.keepalive) load=$($entry.load | ConvertTo-Json -Compress)"
    foreach ($ch in $entry.checks) { if (-not $ch.ok) { Write-Host "  check failed: $($ch.endpoint): $($ch.problems)" } }
    if ($entry.Contains('error')) { Write-Host "  error: $($entry.error)" }
    $report.servers += $entry
}

$report | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir 'smoke.json') -Encoding utf8
$md = @('| Kandidat | Checks | Keep-Alive | Mini-Last req/s (loopback) | Fehler | Working Set MB | Threads |', '|---|---|---|---|---|---|---|')
foreach ($s in $report.servers) {
    $passed = @($s.checks | Where-Object { $_.ok }).Count
    $rps = ''; $errs = ''
    if ($s.Contains('load') -and $s.load) { $rps = $s.load.rps; $errs = $s.load.errors }
    $ws = ''; $th = ''
    if ($s.Contains('working_set_mb')) { $ws = $s.working_set_mb; $th = $s.threads }
    $ka = ''
    if ($s.Contains('keepalive')) { $ka = $s.keepalive }
    $md += "| $($s.candidate) | $passed/7 | $ka | $rps | $errs | $ws | $th |"
}
$md | Set-Content -Path (Join-Path $outDir 'smoke.md') -Encoding utf8
$md | ForEach-Object { Write-Host $_ }
if (-not $allOk) { exit 1 }
exit 0
