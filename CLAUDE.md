# Project Instructions

Read @delphi.md for Delphi-specific coding standards. Project language is **English**
(except `docs/PRD.md`, which is the German design document).

## Project Overview

**DX.HttpSys** is a standalone, framework-agnostic Delphi library that exposes the Windows
kernel-mode HTTP listener (HTTP.sys / `httpapi.dll` v2.0) as a clean, reusable component,
plus thin adapters for WiRL and WebBroker. The core has **no external dependencies** and
targets Windows (Win32/Win64), Delphi 11.3+. See `docs/PRD.md` for the full specification.

## Structure

- `src/Core/` — framework-agnostic HTTP.sys engine (RTL only)
- `src/Adapters/` — WiRL and WebBroker adapters
- `src/*.dpk` / `*.dproj` — runtime packages: `DX.HttpSys.Core`, `DX.HttpSys.WiRL`, `DX.HttpSys.WebBroker`
- `demo/` — demo applications (planned: Standalone, WiRL, WebBroker)
- `tests/` — DUnitX console test runner (`DX.HttpSys.Tests.dproj`)
- `libs/DUnitX/` — test framework (git submodule)
- `build/` — build output only (git-ignored)
- `build-scripts/` — `DelphiBuildDPROJ.ps1`

The project group `DX.HttpSys.groupproj` ties the three packages and the test project together.

## Build

```powershell
build-scripts\DelphiBuildDPROJ.ps1 -ProjectFile src\DX.HttpSys.Core.dproj
```

The adapter packages additionally require their frameworks on the search path
(WiRL: external library; WebBroker: ships with Delphi).

## Test

Open `DX.HttpSys.groupproj` in the IDE and build/run `DX.HttpSys.Tests`, or build
`tests\DX.HttpSys.Tests.dproj` and run the produced console executable.

> First clone: run `git submodule update --init --recursive` to fetch DUnitX.
