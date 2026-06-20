# =============================================================================
# BuildIntegrationTests.ps1 — fetch third-party sources, then build (and
# optionally run) the optional integration tests in tests-integration/.
# =============================================================================
# This is the single entry point a user runs to exercise the third-party adapter
# tests (WiRL today). It:
#   1. runs FetchThirdParty.ps1 to shallow-clone the dependencies listed in
#      thirdparty.manifest.json into build/thirdparty/ (git-ignored),
#   2. reads the resolved unit search paths,
#   3. builds tests-integration/DX.HttpSys.IntegrationTests.dproj with those
#      paths injected as the $(ThirdPartyPaths) MSBuild property,
#   4. optionally runs the produced test executable.
#
# Nothing here touches the normal DX.HttpSys build — a plain clone + build never
# fetches or needs any of this.
#
# USAGE:
#   ./build-scripts/BuildIntegrationTests.ps1
#   ./build-scripts/BuildIntegrationTests.ps1 -Platform Win64 -Config Release
#   ./build-scripts/BuildIntegrationTests.ps1 -Run        # also run the tests
#   ./build-scripts/BuildIntegrationTests.ps1 -Force      # re-fetch sources
# =============================================================================

param(
    [string]$Platform = 'Win32',
    [string]$Config   = 'Debug',
    [switch]$Run,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot  = Resolve-Path (Join-Path $scriptDir '..')

Write-Host "============================================="
Write-Host "| DX.HttpSys - Integration test build        |"
Write-Host "============================================="

# 1. Fetch third-party sources.
& (Join-Path $scriptDir 'FetchThirdParty.ps1') -Force:$Force

# 2. Read the resolved search paths and join them for MSBuild (';'-separated).
$searchPathsFile = Join-Path $repoRoot 'build\thirdparty\searchpaths.txt'
if (-not (Test-Path $searchPathsFile)) {
    throw "Expected $searchPathsFile after fetch; did FetchThirdParty.ps1 run?"
}
# MSBuild treats ';' as a separator between /p: properties, so a multi-path value
# must escape its semicolons as %3B. MSBuild decodes %3B back to ';' before the
# Delphi compiler sees it, yielding a proper multi-path search path.
$rawPaths = (Get-Content -Path $searchPathsFile | Where-Object { $_ -ne '' }) -join ';'
$thirdPartyPaths = $rawPaths -replace ';', '%3B'

Write-Host ""
Write-Host "Injecting ThirdPartyPaths:"
Write-Host "  $rawPaths"

# 3. Build the integration test project with the paths injected.
$dproj = Join-Path $repoRoot 'tests-integration\DX.HttpSys.IntegrationTests.dproj'
& (Join-Path $scriptDir 'DelphiBuildDPROJ.ps1') `
    -ProjectFile $dproj `
    -Platform $Platform `
    -Config $Config `
    -ExtraProperties @{ ThirdPartyPaths = $thirdPartyPaths }

if ($LASTEXITCODE -ne 0) {
    throw "Integration test build failed."
}

# 4. Optionally run.
if ($Run) {
    $exe = Join-Path $repoRoot "build\$Platform\$Config\DX.HttpSys.IntegrationTests.exe"
    if (-not (Test-Path $exe)) {
        throw "Built executable not found: $exe"
    }
    Write-Host ""
    Write-Host "Running integration tests..."
    & $exe --exitbehavior:Continue
    if ($LASTEXITCODE -ne 0) {
        throw "Integration tests reported failures (exit $LASTEXITCODE)."
    }
}
