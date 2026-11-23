# Build-Servers.ps1 - local Win64 Release build of all M0 benchmark servers and
# the smoke tests with MSBuild (RAD Studio 11.3 or newer).
#
#   ./build-scripts/FetchThirdParty.ps1 -Manifest ./benchmarks/thirdparty.manifest.json
#   ./benchmarks/scripts/Build-Servers.ps1 [-Bds "C:\Program Files (x86)\Embarcadero\Studio\37.0"]
#
# Output: build/benchmarks/Win64/Release

param(
    [string]$Bds = $env:BDS,
    [string]$Config = 'Release',
    [string]$Platform = 'Win64'
)

$ErrorActionPreference = 'Stop'
if (-not $Bds) {
    $Bds = Get-ChildItem 'C:\Program Files (x86)\Embarcadero\Studio' -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Bds -or -not (Test-Path (Join-Path $Bds 'bin\rsvars.bat'))) { throw 'RAD Studio not found. Pass -Bds.' }

# Import the RAD Studio environment (rsvars.bat) into this process.
cmd /c "`"$(Join-Path $Bds 'bin\rsvars.bat')`" && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) }
}

$root = Split-Path -Parent $PSScriptRoot
$projects = @(
    'servers\IndyPlain\BenchIndyPlain.dproj',
    'servers\HorseIndy\BenchHorseIndy.dproj',
    'servers\HorseIndy2\BenchHorseIndy2.dproj',
    'servers\DXHttpSysPlain\BenchDXHttpSysPlain.dproj',
    'servers\HorseDXHttpSys\BenchHorseDXHttpSys.dproj',
    'servers\HorseHttpSys33\BenchHorseHttpSys33.dproj',
    'servers\Mormot2Async\BenchMormot2Async.dproj',
    'tests\BenchSmokeTests.dproj'
)
$failed = @()
foreach ($p in $projects) {
    Write-Host "=== $p"
    & msbuild (Join-Path $root $p) /t:Build /p:Config=$Config /p:Platform=$Platform /nologo /v:minimal
    if ($LASTEXITCODE -ne 0) { $failed += $p }
}
if ($failed.Count -gt 0) { throw "Build failed: $($failed -join ', ')" }
Write-Host 'All benchmark projects built.'
