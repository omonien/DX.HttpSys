# Bench.Common.ps1 - shared helpers for the M0 benchmark scripts.
# Dot-source it:  . "$PSScriptRoot/Bench.Common.ps1"
# Works with PowerShell 7 (Windows, macOS, Linux); server related functions need Windows.

Set-StrictMode -Version 3.0

$script:BenchRoot = Split-Path -Parent $PSScriptRoot

function Get-BenchCandidates {
    param([string[]]$Names)
    $all = (Get-Content -Raw (Join-Path $script:BenchRoot 'candidates.json') | ConvertFrom-Json).candidates
    if ($Names -and $Names.Count -gt 0) {
        $result = @()
        foreach ($n in $Names) {
            $c = $all | Where-Object { $_.name -eq $n }
            if (-not $c) { throw "Unknown candidate '$n'. Known: $($all.name -join ', ')" }
            $result += $c
        }
        return ,$result
    }
    return ,@($all)
}

# The M0 load matrix (see benchmarks/README.md). id = scenario plus keep-alive flag.
function Get-BenchMatrix {
    return @(
        [pscustomobject]@{ id = 'plaintext-ka1'; scenario = 'plaintext'; keepalive = 1; vus = @(1, 16, 64, 256, 1024) }
        [pscustomobject]@{ id = 'plaintext-ka0'; scenario = 'plaintext'; keepalive = 0; vus = @(16, 64, 256) }
        [pscustomobject]@{ id = 'json-ka1';      scenario = 'json';      keepalive = 1; vus = @(16, 64, 256, 1024) }
        [pscustomobject]@{ id = 'bytes64k-ka1';  scenario = 'bytes64k';  keepalive = 1; vus = @(16, 64) }
        [pscustomobject]@{ id = 'bytes1m-ka1';   scenario = 'bytes1m';   keepalive = 1; vus = @(16, 64) }
        [pscustomobject]@{ id = 'echo16k-ka1';   scenario = 'echo16k';   keepalive = 1; vus = @(16, 64) }
        [pscustomobject]@{ id = 'echo1m-ka1';    scenario = 'echo1m';    keepalive = 1; vus = @(16, 64) }
        [pscustomobject]@{ id = 'rate-ka1';      scenario = 'rate';      keepalive = 1; vus = @(256) }
    )
}

function Get-BenchGitSha {
    try {
        $sha = (& git -C $script:BenchRoot rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $sha) { return $sha.Trim() }
    } catch { }
    return 'unknown'
}

function Get-BenchEnvironment {
    $info = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        host          = [Environment]::MachineName
        os            = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        arch          = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        logical_cpus  = [Environment]::ProcessorCount
        git_sha       = Get-BenchGitSha
        powershell    = $PSVersionTable.PSVersion.ToString()
    }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        try {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $cs = Get-CimInstance Win32_ComputerSystem
            $os = Get-CimInstance Win32_OperatingSystem
            $info.cpu = $cpu.Name.Trim()
            $info.cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
            $info.ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            $info.os_build = "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
            $info.model = "$($cs.Manufacturer) $($cs.Model)"
            $scheme = (& powercfg /getactivescheme 2>$null) -join ' '
            $info.power_scheme = $scheme.Trim()
        } catch { $info.cim_error = $_.Exception.Message }
    }
    return $info
}

# Starts a candidate server and waits until /plaintext answers 200.
# Returns a pscustomobject with Process, StdOut, StdErr, BaseUrl.
function Start-BenchServer {
    param(
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)] [string]$BinDir,
        [string]$BindHost = 'localhost',
        [int]$Port = 0,
        [int]$Seconds = 600,
        [string]$LogDir = $env:TEMP,
        [int]$HealthTimeoutSec = 30
    )
    if ($Port -le 0) { $Port = [int]$Candidate.port }
    $exe = Join-Path $BinDir $Candidate.exe
    if (-not (Test-Path $exe)) { throw "Server binary not found: $exe" }
    if (-not $LogDir) { $LogDir = [IO.Path]::GetTempPath() }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $stdout = Join-Path $LogDir "$($Candidate.name)_server_stdout.log"
    $stderr = Join-Path $LogDir "$($Candidate.name)_server_stderr.log"
    $argList = @('--port', "$Port", '--host', $BindHost, '--seconds', "$Seconds") + @($Candidate.args)
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $probeHost = $BindHost
    if ($probeHost -in @('all', '+', '0.0.0.0', '*')) { $probeHost = 'localhost' }
    $base = "http://$($probeHost):$Port"
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSec)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { break }
        try {
            $r = Invoke-WebRequest -Uri "$base/plaintext" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ok = $true; break }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ok) {
        $out = if (Test-Path $stdout) { Get-Content -Raw $stdout } else { '' }
        $err = if (Test-Path $stderr) { Get-Content -Raw $stderr } else { '' }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        throw "Server $($Candidate.name) did not become healthy on $base. stdout: $out stderr: $err"
    }
    return [pscustomobject]@{ Process = $proc; StdOut = $stdout; StdErr = $stderr; BaseUrl = $base; Port = $Port }
}

function Stop-BenchServer {
    param([Parameter(Mandatory)] $Server)
    if ($Server.Process -and -not $Server.Process.HasExited) {
        Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
        $Server.Process.WaitForExit(10000) | Out-Null
    }
}

# Samples CPU, working set, threads and handles of a process once per second
# into a CSV file, in a background job. Returns the job.
function Start-BenchSampler {
    param([Parameter(Mandatory)] [int]$ProcessId, [Parameter(Mandatory)] [string]$CsvPath)
    return Start-Job -ArgumentList $ProcessId, $CsvPath -ScriptBlock {
        param($ProcessId, $CsvPath)
        'timestamp_utc,cpu_pct,working_set_mb,private_mb,threads,handles' | Set-Content -Path $CsvPath -Encoding utf8
        $cpus = [Environment]::ProcessorCount
        $prev = $null; $prevTime = $null
        while ($true) {
            $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $p) { break }
            $now = Get-Date
            $cpuTime = $p.TotalProcessorTime.TotalMilliseconds
            $pct = ''
            if ($null -ne $prev) {
                $wall = ($now - $prevTime).TotalMilliseconds
                if ($wall -gt 0) { $pct = [math]::Round(100.0 * ($cpuTime - $prev) / ($wall * $cpus), 1) }
            }
            $prev = $cpuTime; $prevTime = $now
            $line = '{0},{1},{2},{3},{4},{5}' -f $now.ToUniversalTime().ToString('o'), $pct,
                [math]::Round($p.WorkingSet64 / 1MB, 1), [math]::Round($p.PrivateMemorySize64 / 1MB, 1),
                $p.Threads.Count, $p.HandleCount
            Add-Content -Path $CsvPath -Value $line
            Start-Sleep -Seconds 1
        }
    }
}

# Runs one k6 invocation. Returns the path of the JSON summary (or $null for warmup).
function Invoke-BenchK6 {
    param(
        [Parameter(Mandatory)] [string]$K6,
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$Candidate,
        [Parameter(Mandatory)] [string]$Scenario,
        [Parameter(Mandatory)] [int]$Vus,
        [Parameter(Mandatory)] [int]$KeepAlive,
        [Parameter(Mandatory)] [string]$Run,
        [Parameter(Mandatory)] [int]$DurationSec,
        [Parameter(Mandatory)] [string]$OutDir,
        [int]$Rate = 5000
    )
    $script = Join-Path $script:BenchRoot 'k6/run.js'
    $name = '{0}_{1}_ka{2}_{3}_{4}' -f $Candidate, $Scenario, $KeepAlive, $Vus, $Run
    $json = Join-Path $OutDir "$name.json"
    $meta = Join-Path $OutDir "$name.meta.json"
    $env:GODEBUG = 'http2client=0'
    $start = (Get-Date).ToUniversalTime()
    & $K6 run --quiet --no-color `
        --env "TARGET=$Target" --env "SCENARIO=$Scenario" --env "VUS=$Vus" `
        --env "KEEPALIVE=$KeepAlive" --env "DURATION=$($DurationSec)s" --env "RATE=$Rate" `
        --env "CANDIDATE=$Candidate" --env "RUN=$Run" --env "OUT=$json" $script
    $exit = $LASTEXITCODE
    $end = (Get-Date).ToUniversalTime()
    if ($Run -eq 'warmup') {
        Remove-Item -Force -ErrorAction SilentlyContinue $json
        return $null
    }
    [ordered]@{ start_utc = $start.ToString('o'); end_utc = $end.ToString('o'); k6_exit = $exit } |
        ConvertTo-Json | Set-Content -Path $meta -Encoding utf8
    return $json
}
