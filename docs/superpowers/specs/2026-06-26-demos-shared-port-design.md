# Design: Demos share one port via path prefixes + actionable bind errors

**Date:** 2026-06-26
**Branch:** `feat/demos-shared-port` (off `fix/win64-enum-size`, merge after PR #10)
**Status:** Approved

## Goal

Make all four demos bind under a distinct path prefix on a **single shared port (80)** so they
can run **simultaneously** — demonstrating HTTP.sys's kernel-mode port sharing (multiple
processes on the same port, routed by longest-prefix match). Plus: when a bind fails for lack
of rights, emit an actionable error showing the exact `netsh` command to run as Administrator.

This now also includes a **breaking simplification of the Core URL API**: the vague
`Port` property and `UseLocalhost` / `UseAllInterfaces` convenience methods are **removed**.
The single, explicit way to configure where the server binds is `AddUrlPrefix(const APrefix:
string)` taking a complete URL. There is no second source of truth (no `Port` that only
sometimes matters), and no hidden host/path magic.

## Part 0 — Breaking Core API change: `AddUrlPrefix` is the only bind mechanism

**Remove** from `TDXHttpSysServer` (`src/Core/DX.HttpSys.Server.pas`):
- `property Port` (+ `FPort`, `SetPort`) — it was only consulted by the two convenience
  methods and was silently ignored when `AddUrlPrefix` was called directly (a real trap).
- `procedure UseLocalhost` and `procedure UseAllInterfaces` — they hid host translation,
  the `http://` scheme, the port, and the trailing `/`.

**Keep / strengthen** `AddUrlPrefix(const APrefix: string; AContext = 0)` as the single,
explicit configuration point. It takes a **complete** prefix, e.g.
`'http://localhost:80/standalone/'`, `'https://+:1223/api/'`. Add light validation so the one
true mechanism isn't a raw-string trap: reject a prefix that doesn't start with `http://` /
`https://` or doesn't end with `/` (HTTP.sys requires the trailing slash), raising a clear
`EDXHttpSysError` at call time rather than a cryptic Win32 error at `Start`.

**Each adapter builds its own complete URL** (the user's explicit choice — no shared host-build
helper in the Core; the small host translation lives where it's used):
- `0.0.0.0` / default host → `http://+:<port>/...` (wildcard, needs urlacl/admin)
- `localhost` / `127.0.0.1` → `http://localhost:<port>/...` (loopback, no rights)
- any other host → `http://<host>:<port>/...`

So **how the demos/adapters set "localhost" vs "https://+:1223"**: they pass the full string to
`AddUrlPrefix`. There is no separate host or port property anymore — the URL says everything.

### Impact surface (all call sites of the removed API)
- Core: `DX.HttpSys.Server.pas` — remove the members; update the class doc-comment (lines 14,
  56–58, 92–94, 128–131, 244–252).
- WiRL adapter `DX.HttpSys.WiRL.pas:423,427` and `DX.HttpSys.WiRL.REST.pas:444,448` —
  replace `FServer.Port := FPort; FServer.UseLocalhost` with a self-built prefix per engine
  (`http://localhost:<FPort><Engine.BasePath>/`), reading `BasePath` per Part A.
- Horse adapter `DX.HttpSys.Horse.pas` — already builds its own prefix from `FHost`/`FPort`
  and does **not** use `UseLocalhost`; its `Port`/`Host` are Horse-provider class properties,
  not the Core `Port`, so they stay. Only add `BasePath` (Part A).
- Tests (4 helpers) — `Test.DX.HttpSys.Server.pas:130-132`, `Test.DX.HttpSys.Stress.pas:114-117`,
  `Test.DX.HttpSys.WebBroker.pas:160-162`, `Test.DX.HttpSys.Soak.pas:169-172`:
  replace `Result.Port := APort; Result.UseLocalhost` with
  `Result.AddUrlPrefix(Format('http://localhost:%d/', [APort]))`.
- Demos — all four set their full prefix via `AddUrlPrefix` (Part A).

## Principle (no magic, single source of truth)

The routing path is configured in **exactly one place — the framework** — and the adapter reads
it to build the HTTP.sys prefix. No path stripping; HTTP.sys passes the full path through and the
framework routes on that same full path. Only the Standalone demo (which has no framework) sets
the path directly at the HTTP.sys level.

| Demo | Path source (single truth) | HTTP.sys prefix |
|---|---|---|
| 01 Standalone | direct on HTTP.sys via `AddUrlPrefix` | `http://localhost:80/standalone/` |
| 02 WiRL | `AddEngine<TWiRLEngine>('/rest')` → adapter reads `Engine.BasePath` | `http://localhost:80/rest/` |
| 03 WebBroker | demo registers actions under `/webbroker/...`; dispatcher passes full path | `http://localhost:80/webbroker/` |
| 04 Horse | demo registers routes under `/horse/...` (Horse has no base-path concept) | `http://localhost:80/horse/` |

All demos bind **localhost** (loopback needs no urlacl/admin), so they run out of the box. The
netsh help is the safety net if someone switches to `+:80` or the port is otherwise restricted.

## Part A — Adapter & demo changes

### WiRL adapter (`src/Adapters/DX.HttpSys.WiRL.pas:423-427`, `.REST.pas:444-448`)
Replace `FServer.Port := FPort; FServer.UseLocalhost` (both removed in Part 0) with a loop over
the server's engines, building a complete localhost prefix per engine's `BasePath`:

```pascal
LServer := FListener as TWiRLServer;            // add WiRL.http.Server to uses
for LEngine in LServer.Engines do
  FServer.AddUrlPrefix(Format('http://localhost:%d%s/', [FPort, LEngine.BasePath]));
```

`FPort` here is the adapter's own field (set from `TWiRLServer.Port`), not the removed Core
`Port`. The adapter builds the full URL itself (Part 0).

Verified against fetched WiRL source: `TWiRLServer.Engines: TWiRLEngineList` is public;
`TWiRLCustomEngine.BasePath` (single-segment, always leading `/`) holds `/rest`. Engines are
started before the adapter's `Startup`, so the path is available. Same API for 4.x and master.
Multi-engine servers bind one prefix per engine (the loop handles it); the single-engine demo
is unaffected.

### Horse adapter (`src/Adapters/DX.HttpSys.Horse.pas:150-175`)
Horse routes match on absolute registered paths (dispatch uses `AUsePrefix := False`), so there
is no provider-readable base path. Add a settable `class property BasePath` backed by
`class var FBasePath` (mirroring the existing Horse-provider `Host`/`Port` class properties —
these are Horse's own, unaffected by the Core `Port` removal), folded into the three
`AddUrlPrefix` Format branches the provider already builds itself. The **demo** sets
`BasePath := 'horse'` before `Listen` and registers routes under `/horse/...`.

### WebBroker demo (`demo/03.WebBroker/WebBrokerDemo.dpr`)
No adapter change. The demo binds `AddUrlPrefix('http://localhost:80/webbroker/')` and registers
WebModule actions under `/webbroker/...`. The dispatcher already passes `FDXRequest.Path` through
as `PathInfo` unmodified.

### Standalone demo (`demo/01.StandaloneServer/StandaloneServer.dpr`)
Bind `AddUrlPrefix('http://localhost:80/standalone/')` (replacing `UseLocalhost`). The handler
already answers every request; the path lives only at the HTTP.sys level here.

## Part B — Actionable bind error (Core, central)

In `TDXHttpSysServer.SetupUrlGroup` (`src/Core/DX.HttpSys.Server.pas:307`), the `AddUrlToUrlGroup`
loop currently calls `CheckResult` which raises a generic `EDXHttpSysError`. Wrap that one call so
that on **`ERROR_ACCESS_DENIED` (5)** it raises an error whose message names the exact prefix and
the `netsh` command to reserve it, with an "run as Administrator" note. Other error codes keep
their existing generic message (no netsh noise).

Message shape:
```
[DX.HttpSys] Cannot bind 'http://+:80/horse/' – access denied (Win32 Error 5).
This URL needs a one-time reservation. Run as Administrator:
  netsh http add urlacl url=http://+:80/horse/ user=<DOMAIN\User>
```

Central in the Core → every adapter and every consumer benefits, no duplication across demos.

## Tests

- Core unit test: a bind that fails with `ERROR_ACCESS_DENIED` produces a message containing
  `netsh http add urlacl`, the exact prefix, and an Administrator hint. Drive it through a small
  seam (e.g. a helper that formats the access-denied message from a prefix + code), so the test
  doesn't need an actual privileged-port bind.
- Core unit test for the new `AddUrlPrefix` validation: a prefix without a scheme or without a
  trailing `/` raises `EDXHttpSysError` at call time (not at `Start`).
- Update the existing tests that used the removed API (the 4 helpers in
  `Test.DX.HttpSys.{Server,Stress,WebBroker,Soak}.pas`) to `AddUrlPrefix`. The
  `ApiEnums_AreFourBytes` / `HttpResponse_IsV2Sized` tests are unaffected.
- Existing suite must stay green on Win32 + Win64 (was 21/21; count rises with the two new
  Core tests) — verified locally via `DelphiBuildDPROJ.ps1` (our CI), 0 leaks.
- WiRL/Horse demos build only with fetched deps; verify as far as possible without the external
  frameworks, and document the manual verification steps for the live multi-server demo.

## Decisions log

Add **A-20** to `docs/DECISIONS.md`: `AddUrlPrefix(complete-URL)` is the single, explicit bind
mechanism; `Port` / `UseLocalhost` / `UseAllInterfaces` removed (breaking) because they were a
vague second source of truth; each adapter builds its own full URL; `AddUrlPrefix` validates the
prefix shape. The single-source-of-truth path principle for port sharing (framework owns the
path, adapter reads it; Standalone sets it at HTTP.sys level), and the central access-denied →
netsh guidance.

Update the README quick-starts and `DX.HttpSys.Server.pas` class doc-comment that currently show
`Server.Port := 8080; Server.UseLocalhost` to the new `AddUrlPrefix` form.

## Out of scope (YAGNI)

- A generic `BasePath` abstraction with per-framework implementations (the user explicitly
  deferred this — "später können wir überlegen, ob man das noch eleganter lösen kann").
- netsh guidance for non-access-denied errors (port-in-use etc.).
- `+:80` / all-interfaces binding in the demos (localhost keeps them admin-free).
