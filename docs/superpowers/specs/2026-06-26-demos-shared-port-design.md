# Design: Demos share one port via path prefixes + actionable bind errors

**Date:** 2026-06-26
**Branch:** `feat/demos-shared-port` (off `fix/win64-enum-size`, merge after PR #10)
**Status:** Approved

## Goal

Make all four demos bind under a distinct path prefix on a **single shared port (80)** so they
can run **simultaneously** — demonstrating HTTP.sys's kernel-mode port sharing (multiple
processes on the same port, routed by longest-prefix match). Plus: when a bind fails for lack
of rights, emit an actionable error showing the exact `netsh` command to run as Administrator.

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

### WiRL adapter (`src/Adapters/DX.HttpSys.WiRL.pas:427`, `.REST.pas:448`)
Replace `FServer.UseLocalhost` with a loop over the server's engines, binding each engine's
`BasePath` as a localhost prefix:

```pascal
LServer := FListener as TWiRLServer;            // add WiRL.http.Server to uses
for LEngine in LServer.Engines do
  FServer.AddUrlPrefix(Format('http://localhost:%d%s/', [FPort, LEngine.BasePath]));
```

Verified against fetched WiRL source: `TWiRLServer.Engines: TWiRLEngineList` is public;
`TWiRLCustomEngine.BasePath` (single-segment, always leading `/`) holds `/rest`. Engines are
started before the adapter's `Startup`, so the path is available. Same API for 4.x and master.
Multi-engine servers bind one prefix per engine (the loop handles it); the single-engine demo
is unaffected.

### Horse adapter (`src/Adapters/DX.HttpSys.Horse.pas:150-175`)
Horse routes match on absolute registered paths (dispatch uses `AUsePrefix := False`), so there
is no provider-readable base path. Add a settable `class property BasePath` backed by
`class var FBasePath` (mirroring the existing `Host`/`Port` pattern), folded into the three
`AddUrlPrefix` Format branches. The **demo** sets `BasePath := 'horse'` before `Listen` and
registers routes under `/horse/...`.

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
- Existing suite must stay green on Win32 + Win64 (21/21, 0 leaks) — verified locally via
  `DelphiBuildDPROJ.ps1` (our CI).
- WiRL/Horse demos build only with fetched deps; verify as far as possible without the external
  frameworks, and document the manual verification steps for the live multi-server demo.

## Decisions log

Add **A-20** to `docs/DECISIONS.md`: the single-source-of-truth path principle for port sharing
(framework owns the path, adapter reads it; Standalone sets it at HTTP.sys level), and the
central access-denied → netsh guidance.

## Out of scope (YAGNI)

- A generic `BasePath` abstraction with per-framework implementations (the user explicitly
  deferred this — "später können wir überlegen, ob man das noch eleganter lösen kann").
- netsh guidance for non-access-denied errors (port-in-use etc.).
- `+:80` / all-interfaces binding in the demos (localhost keeps them admin-free).
