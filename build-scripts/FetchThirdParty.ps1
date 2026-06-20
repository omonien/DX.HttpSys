# =============================================================================
# FetchThirdParty.ps1 — fetch third-party sources for the optional integration
# tests (tests-integration/), driven by thirdparty.manifest.json.
# =============================================================================
# DX.HttpSys deliberately has NO submodules and NO vendored third-party code.
# The adapters (e.g. WiRL) ship as source under src/Adapters, but the libraries
# they target are only needed to BUILD the optional integration tests. This
# script shallow-clones each dependency listed in the manifest into a git-ignored
# build folder, so a normal clone of DX.HttpSys never pulls anything extra.
#
# Output: each dependency lands in  build/thirdparty/<name>
# It also writes the resolved Delphi unit search paths to
#   build/thirdparty/searchpaths.txt   (one path per line)
# which BuildIntegrationTests.ps1 consumes.
#
# USAGE:
#   ./build-scripts/FetchThirdParty.ps1
#   ./build-scripts/FetchThirdParty.ps1 -Manifest path/to/manifest.json -Force
#
#   -Force   re-fetch even if a dependency folder already exists.
# =============================================================================

param(
    [string]$Manifest = (Join-Path $PSScriptRoot 'thirdparty.manifest.json'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "============================================="
Write-Host "| DX.HttpSys - Fetch third-party sources    |"
Write-Host "============================================="

if (-not (Test-Path $Manifest)) {
    throw "Manifest not found: $Manifest"
}

# git is required to fetch sources.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required but was not found on PATH."
}

$repoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..')
$targetRoot = Join-Path $repoRoot 'build\thirdparty'
New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

try {
    $config = Get-Content -Raw -Path $Manifest | ConvertFrom-Json
}
catch {
    throw "Invalid JSON in manifest '$Manifest': $($_.Exception.Message)"
}
if (-not $config.dependencies) {
    throw "Manifest '$Manifest' has no 'dependencies' array."
}

$searchPaths = @()

foreach ($dep in $config.dependencies) {
    $name = $dep.name
    $dest = Join-Path $targetRoot $name

    Write-Host ""
    Write-Host "--- $name ($($dep.repo) @ $($dep.ref)) ---"

    # A present-but-incomplete clone (e.g. an interrupted previous run) is treated
    # as missing and re-fetched: a bare folder without .git/HEAD must not be
    # trusted as "already present".
    $looksComplete = (Test-Path $dest) -and (Test-Path (Join-Path $dest '.git\HEAD'))

    if (Test-Path $dest) {
        if ($Force -or (-not $looksComplete)) {
            if (-not $looksComplete) {
                Write-Host "  incomplete clone detected; re-fetching"
            } else {
                Write-Host "  -Force: removing existing clone"
            }
            Remove-Item -Recurse -Force $dest
        }
        else {
            Write-Host "  already present (use -Force to re-fetch); skipping clone"
        }
    }

    if (-not (Test-Path $dest)) {
        Write-Host "  shallow-cloning..."
        # git writes progress to stderr; don't let that surface as a terminating
        # PowerShell error. Suppress the native stderr redirection and judge
        # success by the exit code only.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git clone --depth 1 --branch $dep.ref $dep.repo $dest
        }
        finally {
            $ErrorActionPreference = $prevEAP
        }
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed for $name (exit $LASTEXITCODE)"
        }
        if (-not (Test-Path (Join-Path $dest '.git\HEAD'))) {
            throw "git clone for $name finished but the repo looks incomplete"
        }
    }

    foreach ($sp in $dep.sourcePaths) {
        $full = Join-Path $dest ($sp -replace '/', '\')
        if (-not (Test-Path $full)) {
            Write-Warning "  source path not found: $full"
        }
        $searchPaths += $full
    }
}

# Persist the resolved search paths for the build step.
$searchPathsFile = Join-Path $targetRoot 'searchpaths.txt'
$searchPaths | Set-Content -Path $searchPathsFile -Encoding ASCII

Write-Host ""
Write-Host "Done. Search paths written to: $searchPathsFile"
$searchPaths | ForEach-Object { Write-Host "  $_" }
