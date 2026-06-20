# Third-party integration tests (optional)

These tests exercise the DX.HttpSys **adapters that target external frameworks** —
currently **WiRL** and **Horse** — end to end: a real framework resource served over
the kernel HTTP.sys engine.

> WiRL ships **two** adapters because its `IWiRLListener` signature changed across
> versions: `DX.HttpSys.WiRL` for the 4.x release API (verified here against WiRL
> v4.6.0) and `DX.HttpSys.WiRL.REST` for the master branch. The integration test
> targets the release adapter; point the manifest `ref` at master and switch the
> test's uses clause to exercise the REST one.

They are **optional and opt-in**. DX.HttpSys itself has **no submodules** and
**vendors no third-party code**: a normal clone and the standard build
(`DX.HttpSys.groupproj`, the `tests/` suite) never fetch or need any of this. The
adapter *source* (e.g. `src/Adapters/DX.HttpSys.WiRL.pas`) ships with the library,
but the framework it targets is only required to *build these tests*.

## How it works

1. [`build-scripts/thirdparty.manifest.json`](../build-scripts/thirdparty.manifest.json)
   lists each dependency: name, git repo, ref, and the source paths to put on the
   Delphi unit search path.
2. [`FetchThirdParty.ps1`](../build-scripts/FetchThirdParty.ps1) shallow-clones each
   dependency into `build/thirdparty/<name>` (which is git-ignored) and writes the
   resolved search paths to `build/thirdparty/searchpaths.txt`.
3. [`BuildIntegrationTests.ps1`](../build-scripts/BuildIntegrationTests.ps1) runs the
   fetch, injects those paths as the `$(ThirdPartyPaths)` MSBuild property, and
   builds `DX.HttpSys.IntegrationTests.dproj` (optionally running it).

## Run them

```powershell
# Fetch WiRL, build, and run the integration tests:
build-scripts\BuildIntegrationTests.ps1 -Run

# Win64 / Release, re-fetching sources:
build-scripts\BuildIntegrationTests.ps1 -Platform Win64 -Config Release -Force -Run
```

Requirements: a recent Delphi (the build script auto-detects it) and `git` on PATH.
The tests bind to `http://localhost:<port>/`, so no admin rights or URL ACL are
needed.

## Adding another wrapper

When DX.HttpSys gains another adapter (mORMot, …), add the dependency to
`thirdparty.manifest.json` and a `Test.*.pas` fixture here — no submodule, no
change to the standard build. If the upstream `src` ships a file that shadows an
RTL unit (as Horse does with `Web.WebConst.pas`), list it under `excludeFiles` in
the manifest entry — `FetchThirdParty.ps1` removes it after cloning.
