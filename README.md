<div align="center">

# DX.HttpSys

## The native Windows kernel HTTP stack — for *any* Delphi web framework

**A standalone, framework-agnostic Delphi library that exposes the Windows kernel-mode HTTP listener ([HTTP.sys](https://learn.microsoft.com/en-us/windows/win32/http/http-api-start-page) / `httpapi.dll` v2.0) as a clean, reusable component — plus thin adapters for WiRL, WebBroker and Horse.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Delphi 11.3+](https://img.shields.io/badge/Delphi-11.3%2B-E62431.svg)](https://www.embarcadero.com/products/delphi)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%20x86%20%7C%20x64-0078D6.svg?logo=windows&logoColor=white)](#requirements)
[![Status: Core complete](https://img.shields.io/badge/Status-Core%20complete%20%C2%B7%20tested-brightgreen.svg)](#roadmap)
[![No external dependencies](https://img.shields.io/badge/Dependencies-none-brightgreen.svg)](#why-httpsys)

**English** · [Deutsch](README.de.md)

</div>

---

## Why HTTP.sys?

HTTP.sys is the kernel-mode HTTP listener that has shipped with **every** version of Windows since XP SP2 / Server 2003. It is the foundation of IIS, WCF, and ASP.NET Core on Windows. Yet in the Delphi world it has never been available as a *standalone, reusable* component — it's always been locked inside a specific framework or a commercial product.

**DX.HttpSys closes that gap.** The core is independent; the adapters are thin.

| Feature | HTTP.sys (DX.HttpSys) | User-mode listeners (Indy, …) |
|---|:---:|:---:|
| Port sharing (multiple processes on :80/:443) | ✅ | ❌ exclusive |
| Kernel-mode request queue | ✅ | ❌ user-mode |
| TLS/SSL | ✅ kernel-delegated (`netsh http add sslcert`) | ⚠️ OpenSSL dependency |
| URL-ACL control | ✅ `netsh http add urlacl` | ❌ |
| External dependencies | ✅ **none** (`httpapi.dll` always present) | ⚠️ ship & version OpenSSL DLLs |
| Deployment | ✅ zero-deploy | ⚠️ bundle DLLs |
| Connection caching / keep-alive | ✅ kernel-level | ❌ |
| HTTP/2 | ✅ negotiated by the kernel on TLS listeners (Windows 10 / Server 2016+) — see [HTTP/2](#http2) | ❌ HTTP/1.x only |

---

## Background — proven in production, not invented yesterday

This isn't a fresh experiment. I have run an HTTP.sys binding for Delphi in **several production applications for over ten years**. It works, it's stable, and it has been carrying real workloads that entire time.

That original library, though, grew under time pressure. It was modelled closely on Indy — essentially a HTTP.sys-to-WebBroker bridge, tightly coupled to a single framework — and it carries design decisions that are hard to defend today. An open-source release was always on my mind, but it kept stalling on the complexity of the HTTP.sys API and the correspondingly awkward code.

**DX.HttpSys is the deliberate redo:** the same battle-tested foundation, rebuilt as a strongly abstracted, framework-neutral core that any product (WiRL, WebBroker, Horse, …) can use as its server engine. Not a brand-new idea — a decade of production experience distilled into a clean, reusable library.

---

## Highlights

- 🧩 **Framework-neutral core** — use it directly, or plug it into your framework of choice.
- 🪶 **Zero external dependencies** — `httpapi.dll` is part of every Windows install. No OpenSSL DLLs to ship or keep patched.
- ⚡ **Kernel-grade performance** — passes the throughput and latency advantage of the kernel stack through with negligible overhead.
- 🛡️ **Stability as a first-class goal** — designed for leak-free, race-free operation under sustained high load, backed by unit, integration, load and soak tests.
- 🔌 **Drop-in adapters** — switch WiRL from Indy to HTTP.sys by changing a single `uses` line.
- 🖥️ **UI-neutral** — Console, Windows Service, VCL or FMX. Embed a kernel HTTP server straight into a desktop app if you want.
- 📡 **Streaming responses (SSE)** — `BeginStream`/`SendChunk`/`EndStream` push `text/event-stream` (or any long-lived) responses: Server-Sent Events with zero dependencies (see [`demo/07.Sse`](demo/07.Sse)).
- 🔀 **Protocol-aware framing** — the stream framing follows the protocol the client spoke (`TDXHttpSysRequest.ProtocolVersion`): HTTP/1.1 chunked (framed by DX.HttpSys), HTTP/2 and HTTP/3 framed by HTTP.sys itself, HTTP/1.0 close-delimited. Connection-specific headers are stripped from HTTP/2 responses. Handler code is identical for all of them (see [HTTP/2](#http2)).
- 🔗 **Shared ports** — `AddUrlPrefix` takes a complete URL (`http://localhost:80/api/`), so several servers and processes can share one port under different path prefixes; HTTP.sys routes by longest-prefix match. Bind failures name the exact `netsh http add urlacl` command to run.
- 🧵 **Fixed worker pool** — one receiver thread plus `ThreadCount` workers (default `2 × CPUCount`, at least 2); a crashed worker is restarted, unhandled handler exceptions become `500` responses.

---

## Architecture

A clean three-layer design — the core never sees a framework, the framework never sees the WinAPI.

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3 — Framework Adapters                                │
│  DX.HttpSys.WiRL.pas   DX.HttpSys.WebBroker.pas             │
│  DX.HttpSys.Horse.pas  (Horse provider over WebBroker)      │
│  TWiRLHttpSysServer    TWebBrokerHttpSysDispatcher          │
└───────────────────────────┬─────────────────────────────────┘
                            │ uses
┌───────────────────────────▼─────────────────────────────────┐
│  LAYER 2 — Server Core (framework-agnostic)                  │
│  Server · Request · Response · ThreadPool                    │
│  IDXHttpSysRequestHandler  (the single callback interface)   │
└───────────────────────────┬─────────────────────────────────┘
                            │ wraps
┌───────────────────────────▼─────────────────────────────────┐
│  LAYER 1 — Win32 API Translation                             │
│  Thin Pascal headers for httpapi.dll v2.0                    │
│  Loaded via GetProcAddress — no hard link dependency         │
└─────────────────────────────────────────────────────────────┘
```

The single interface an adapter implements:

```pascal
IDXHttpSysRequestHandler = interface
  procedure HandleRequest(
    const ARequest:  TDXHttpSysRequest;
    const AResponse: TDXHttpSysResponse);
end;
```

---

## Quick start

> The core engine and the WebBroker, WiRL and Horse adapters are implemented; the snippets
> below are the real API. See [Demos](#demos) for runnable examples.

### Standalone (core only, no framework)

```pascal
uses
  DX.HttpSys.Server;

var
  Server: TDXHttpSysServer;
begin
  Server := TDXHttpSysServer.Create;
  Server.AddUrlPrefix('http://localhost:8080/');
  Server.Handler := TMyHandler.Create;   // implements IDXHttpSysRequestHandler
  Server.Start;
  // ...
  Server.Stop;
end;
```

### Server-Sent Events (chunked streaming)

```pascal
uses
  DX.HttpSys.Response;

// inside your IDXHttpSysRequestHandler.HandleRequest:
AResponse.Headers['content-type']  := 'text/event-stream';
AResponse.Headers['cache-control'] := 'no-cache';
AResponse.BeginStream;                       // headers, no Content-Length → chunked
for var LEvent in ['data: hello'#10#10, 'data: world'#10#10] do
  if not AResponse.SendChunk(TEncoding.UTF8.GetBytes(LEvent)) then
    Exit;                                    // stream is over — just return
AResponse.EndStream;                         // completes the response
```

`SendChunk` returns `False` when the stream is over — the client disconnected or the server
is shutting down — so a long-lived stream stops cleanly; genuine send failures raise
`EDXHttpSysError` instead. `EndStream` is a safe no-op once the stream ended, and a stream
your handler began but did not end is completed by the worker (including on exceptions).

The body framing follows the protocol the client spoke (`ARequest.ProtocolVersion`):
**HTTP/1.1** gets `Transfer-Encoding: chunked` with the chunk framing written by DX.HttpSys
(HTTP.sys does not frame on its own); **HTTP/2** — which HTTP.sys negotiates via ALPN on
`https` listeners by default — gets the data unframed in HTTP/2 DATA frames, without
`Transfer-Encoding` (forbidden in HTTP/2); **HTTP/1.0** gets the plain data and the connection
is closed to end the body. Connection-specific headers (`Connection`, `Keep-Alive`, `Upgrade`, …)
are dropped from HTTP/2 responses. Your handler code is the same for all of them — never set
framing headers by hand. Details: [HTTP/2](#http2).

Two things to keep in mind for long-lived streams:

- **Each stream occupies one pooled worker thread** for its whole duration. The pool is
  fixed at `ThreadCount` (default `2 × CPUCount`, at least 2; settable before `Start`), so
  size it for the number of concurrent streams you expect — otherwise streams starve
  ordinary requests.
- **Poll `AResponse.Cancelled` between events** (and avoid long blind `Sleep`s): it turns
  `True` when the server is shutting down, so `Stop` does not have to wait out your stream.

See [`demo/07.Sse`](demo/07.Sse) for a complete, runnable example (ten events, one
per second — try `curl -N http://localhost:80/sse/`).

### WebBroker — run your WebModule on HTTP.sys

```pascal
uses
  DX.HttpSys.Server, DX.HttpSys.WebBroker, Web.WebReq;

// Register your WebModule with WebBroker as usual, then host it on HTTP.sys:
Server := TDXHttpSysServer.Create;
Server.Handler := TWebBrokerHttpSysDispatcher.Create;
Server.AddUrlPrefix('http://localhost:8080/');
Server.Start;
```

See [`demo/03.WebBroker`](demo/03.WebBroker) for a complete, runnable example.

### WiRL — select the HTTP.sys engine

```pascal
uses
  DX.HttpSys.WiRL,   // registers the 'HttpSys' WiRL server engine (WiRL 4.x)
  WiRL.http.Server;

FServer := TWiRLServer.Create(nil);
FServer.Port := 8080;
FServer.ServerVendor := 'HttpSys';   // use HTTP.sys instead of Indy
// ... your existing WiRL engine/application configuration ...
FServer.Active := True;
```

> ℹ️ WiRL is an external dependency that is intentionally **not vendored**, so this adapter
> only compiles where WiRL is on the library path. There are two adapters: `DX.HttpSys.WiRL`
> for the WiRL 4.x release API (**verified** against WiRL v4.6.0) and `DX.HttpSys.WiRL.REST`
> for the master branch (see [`docs/DECISIONS.md`](docs/DECISIONS.md) A-10).
> Optional integration tests against downloaded third-party sources live in
> [`tests-integration/`](tests-integration/).

### Horse — run your Horse app on HTTP.sys

```pascal
uses
  Horse,
  DX.HttpSys.Horse;   // a Horse provider backed by HTTP.sys

THorse.Get('/ping',
  procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
  begin
    ARes.Send('pong');
  end);

// Start through this provider instead of Horse's default Indy provider.
// Host/Scheme default to localhost/Http (admin-free); set them for '+' / https.
THorseProviderHttpSys<THorse>.Port := 8080;
THorseProviderHttpSys<THorse>.Listen;
```

> ℹ️ Define routes with `THorse` as usual; only the `Listen` call changes. Horse is
> WebBroker-based, so this adapter is a thin provider over `TWebBrokerHttpSysDispatcher`.
> Horse is not vendored — verified against Horse v2.0.14 by the integration harness.
> See [`demo/04.Horse`](demo/04.Horse).

---

## Binding and sharing a port

`AddUrlPrefix` is the **single bind mechanism**. It takes a complete URL, validated at call time
(it must start with `http://` or `https://` and end with `/`), and may be called several times:

```pascal
Server.AddUrlPrefix('http://localhost:80/api/');
Server.AddUrlPrefix('https://+:443/api/');
```

There is no separate `Port` property. Because the path is part of the prefix, **several servers
— in one process or in different processes — can share one port** under different path
prefixes; HTTP.sys routes each request to the longest matching prefix. All demos use this to run
side by side on port 80. The adapters assemble their prefix from scheme, host, port and path
with `TDXHttpSysServer.BuildPrefix(...)` (WiRL: the engine `BasePath`; Horse: the provider
`BasePath`); `TDXScheme = (Http, Https)` selects the scheme. When a bind fails with *access
denied*, the error names the exact prefix and the `netsh http add urlacl` command to run once
as administrator (see [URL ACLs & permissions](#url-acls--permissions)).

Other settings (all before `Start`): `ThreadCount` (default `2 × CPUCount`, at least 2),
`QueueLength` (kernel request queue, default 1000), `ServerHeader` (default `DX.HttpSys/1.0`;
HTTP.sys appends `Microsoft-HTTPAPI/2.0`) and the `OnError` callback.

---

## Demos

All demos are console programs under [`demo/`](demo/) that bind below `http://localhost:80/`
(no elevation needed), each under its own path prefix, so they can run simultaneously.

| Demo | What it shows | URL |
|---|---|---|
| [`01.StandaloneServer`](demo/01.StandaloneServer) | The smallest possible server — Core only, no framework | `/standalone/` |
| [`02.WiRL`](demo/02.WiRL) | A WiRL REST resource on HTTP.sys (source only: WiRL is not vendored, put it on your library path) | `/rest/app/hello` |
| [`03.WebBroker`](demo/03.WebBroker) | A WebBroker WebModule on `TWebBrokerHttpSysDispatcher` | `/webbroker/`, `/webbroker/time` |
| [`04.Horse`](demo/04.Horse) | A Horse app via `THorseProviderHttpSys<THorse>` (source only: Horse is not vendored) | `/horse/ping` |
| [`07.Sse`](demo/07.Sse) | Server-Sent Events: ten events, one per second (`curl -N`); an optional first parameter replaces the URL prefix | `/sse/` |

---

## HTTP/2

HTTP.sys negotiates **HTTP/2 via ALPN on every TLS (`https`) listener by default** (Windows 10 /
Server 2016 and later, TLS 1.2+); plain `http` listeners stay on HTTP/1.x, and older systems fall
back to HTTP/1.1. DX.HttpSys needs no configuration for this — what it does:

- **`TDXHttpSysRequest.ProtocolVersion`** reports the protocol the request arrived over (1.0, 1.1,
  2.0 or 3.0). The HTTP.sys HTTP/2 and HTTP/3 request flags are authoritative; otherwise the
  request-line version is used.
- **Streaming** (`BeginStream`/`SendChunk`/`EndStream`) frames the body per protocol:

  | Request protocol | Body framing | `EndStream` |
  |---|---|---|
  | HTTP/1.1 | `Transfer-Encoding: chunked`, chunk framing written by DX.HttpSys | terminal chunk |
  | HTTP/2, HTTP/3 | data handed to HTTP.sys unframed (it emits the DATA frames), no `Transfer-Encoding` | empty send with the disconnect flag (ends the stream, not the connection) |
  | HTTP/1.0 | plain data, `Connection: close` | empty send with the disconnect flag; the close ends the body |

- **Headers the client's protocol forbids are dropped** when the response is sent: `Connection`,
  `Keep-Alive`, `Proxy-Connection`, `Transfer-Encoding` and `Upgrade` on HTTP/2 and HTTP/3
  (RFC 9113 §8.2.2), `Transfer-Encoding` on HTTP/1.0. This also covers headers that handlers or
  adapters set themselves (e.g. `Connection: keep-alive` in an SSE handler). HTTP/1.1 responses go
  out exactly as before.

**Switching HTTP/2 off** (normally not needed — handlers behave the same either way): per TLS
binding with `disablehttp2=enable`, or machine-wide with the registry value `EnableHttp2Tls = 0`
(`HKLM\SYSTEM\CurrentControlSet\Services\HTTP\Parameters`, then restart the HTTP service or reboot):

```cmd
netsh http add sslcert ipport=0.0.0.0:443 certhash=THUMBPRINT appid={GUID} disablehttp2=enable
```

**Live check.** HTTP/2 needs a TLS binding, and binding a certificate needs administrator rights,
so the wire behaviour is not part of the unit-test suite (which pins the framing decisions and the
exact HTTP.sys send calls through fakes). Instead, run
[`tests-integration\Http2StreamingCheck.ps1`](tests-integration/Http2StreamingCheck.ps1) from an
**elevated PowerShell 7.2+**:

```powershell
tests-integration\Http2StreamingCheck.ps1             # default port 44399, Win64 Debug
tests-integration\Http2StreamingCheck.ps1 -NoTls      # unelevated plumbing self-test (HTTP/1.1 only)
```

It builds `demo/07.Sse`, creates a temporary self-signed certificate and binds it to
`127.0.0.1:<Port>`, streams `/sse/` once over HTTP/2 and once over HTTP/1.1, and asserts that
HTTP/2 was really negotiated with no `Transfer-Encoding` and no chunk-framing bytes in the body,
and that HTTP/1.1 carries the exact chunk framing. Afterwards it removes the binding and the
certificate (including its private key) — also on failure — and it refuses to run if the port
already has an sslcert binding. Rationale and open points: [`docs/DECISIONS.md`](docs/DECISIONS.md) A-21.

---

## URL ACLs & permissions

The wildcard notation `http://+:8080/` (all interfaces) requires **administrator rights** or a pre-registered URL ACL:

```cmd
netsh http add urlacl url=http://+:8080/ user=DOMAIN\Username
```

For **loopback-only** URLs (`http://localhost:8080/`), no elevated rights are needed.

For **TLS**, bind the certificate up front:

```cmd
netsh http add sslcert ipport=0.0.0.0:443 certhash=THUMBPRINT appid={GUID}
```

Such `https` listeners also serve HTTP/2 — see [HTTP/2](#http2).

---

## Requirements

- **Delphi 11.3 or newer**
- **Windows** (x86 and x64) — `httpapi.dll` v2.0
- Windows only: HTTP.sys is a Windows kernel facility, so the units are Windows code (no cross-platform compile guards).
- HTTP/2 additionally needs Windows 10 / Server 2016 or later and a TLS binding (see [HTTP/2](#http2)).

---

## Where it fits

There is currently **no standalone, open-source HTTP.sys library** in the Delphi ecosystem. Existing implementations are tied to a framework or sold commercially:

| Solution | License | HTTP.sys | Usable standalone |
|---|---|:---:|:---:|
| mORMot 1 / 2 (`THttpApiServer`) | Open Source | ✅ | ⚠️ only with mORMot's network layer |
| DelphiMVCFramework ≥ 3.5 | Open Source | ✅ | ❌ engine is DMVC-internal |
| xxm (`httpapi2.pas`) | Open Source | ✅ | ⚠️ bound to xxm module concept |
| TMS Sparkle | Commercial | ✅ | ⚠️ within TMS BIZ/Web Core |
| RemObjects Remoting SDK | Commercial | ✅ | ❌ bound to the SDK |
| WiRL / Horse / MARS-Curiosity | Open Source | ❌ | — Indy only |

**DX.HttpSys** is the first to provide HTTP.sys as a reusable, framework-neutral open-source component — and brings it to frameworks (WiRL, WebBroker, Horse) that previously had no access to it.

---

## Testing

- **Unit and in-process integration tests** — the DUnitX suite [`tests/`](tests/)
  (`DX.HttpSys.Tests.dproj`, DUnitX as a git submodule: `git submodule update --init --recursive`).
  89 tests, green on Win32 and Win64 with no leaks. Fixtures: API smoke, server integration,
  URL/bind API, WebBroker adapter, concurrency stress, soak/longevity (bounded memory and
  handles) and streaming (live SSE over the wire, the pure framing decisions per protocol
  version, and the exact HTTP.sys send calls per protocol through recording fakes — which
  exercises the HTTP/2 path without elevation). Everything binds to `http://localhost:<port>/`,
  so no administrator rights are needed.

  ```powershell
  build-scripts\DelphiBuildDPROJ.ps1 -ProjectFile tests\DX.HttpSys.Tests.dproj -Platform Win64
  build\Win64\Debug\DX.HttpSys.Tests.exe --exitbehavior:Continue    # exit code <> 0 = failures
  ```

- **Third-party integration tests (optional)** — [`tests-integration/`](tests-integration/)
  fetch WiRL and Horse on demand and serve a real framework resource over HTTP.sys
  (`build-scripts\BuildIntegrationTests.ps1 -Run`). Nothing is vendored or needed for a normal build.
- **HTTP/2 live check (elevated)** — `tests-integration\Http2StreamingCheck.ps1`, see [HTTP/2](#http2).
- **CI** — [`.github/workflows/build-and-test.yml`](.github/workflows/build-and-test.yml) builds the
  Core (Win32 + Win64), the WebBroker package and the test runner and runs the suite on every push
  and same-repository PR to `main`. Delphi is commercial and not available on GitHub-hosted
  runners, so the job runs on a **self-hosted** Windows runner labelled
  `self-hosted, windows, delphi` ([`docs/DECISIONS.md`](docs/DECISIONS.md) A-12); PRs from forks
  are deliberately not run on it.

---

## Roadmap

- [x] **M1 — API foundation:** WinAPI structures, `GetProcAddress` loader, smoke tests
- [x] **M2 — Core server:** Request/Response/Server, header transmission, Hello-World demo
- [x] **M3 — Threading:** receiver + worker thread pool, concurrency/stress harness
- [x] **M4 — WiRL adapter:** `DX.HttpSys.WiRL` for the WiRL 4.x release API, verified against
      WiRL v4.6.0 by the optional integration harness; `DX.HttpSys.WiRL.REST` for the master
      branch is best-effort. WiRL is an external dependency that is intentionally not vendored
      (see [`docs/DECISIONS.md`](docs/DECISIONS.md) A-10)
- [x] **M5 — WebBroker adapter:** real WebModule served via HTTP.sys, with E2E tests + demo
- [x] **M6 — Test suite & hardening:** DUnitX unit + integration + concurrency stress + soak
      and leak/handle checks (89 tests, 0 leaks)
- [x] **M7 — Packaging & docs:** Delphi packages, CI workflow, README, XML doc comments
- [x] **M8 — Horse adapter:** `DX.HttpSys.Horse` provider over the WebBroker dispatcher,
      verified against Horse v2.0.14
- [x] **M9 — Shared-port bind API:** `AddUrlPrefix` as the single, validated bind mechanism;
      demos share port 80 via path prefixes
- [x] **M10 — Streaming & HTTP/2:** `BeginStream`/`SendChunk`/`EndStream` (SSE), protocol-aware
      framing, `ProtocolVersion`. The HTTP/2 wire check is a separate, elevated script (see
      [HTTP/2](#http2))

The core engine and all three adapters are implemented, build clean on Win32 + Win64, and are
covered by a green test suite. See the full [Product Requirements Document](docs/PRD.md) for the
complete design and [`docs/DECISIONS.md`](docs/DECISIONS.md) for the architecture decisions
taken along the way.

---

## Documentation

- 📄 [Product Requirements Document (PRD)](docs/PRD.md) — full architecture, API surface, and non-functional requirements (German; the original design document).
- 🧭 [Architecture & process decisions](docs/DECISIONS.md) — why the code looks the way it does (e.g. A-20 bind API, A-21 stream framing per protocol).
- 🧪 [Third-party integration tests and the HTTP/2 live check](tests-integration/README.md).

---

## Contributing

Contributions, issues and feature requests are welcome. The project targets a very high test bar (unit, integration, concurrency/stress, soak and leak tests) — see section 9.6 of the [PRD](docs/PRD.md) for the quality goals.

---

## License

Released under the [MIT License](LICENSE) — © 2026 Olaf Monien (Developer Experts LLC).

---

## Trademarks

Delphi and Embarcadero are trademarks or registered trademarks of Embarcadero
Technologies, Inc. or its affiliates in the United States and/or other countries.
All other trademarks are the property of their respective owners. This project is
not affiliated with, endorsed by, or sponsored by Embarcadero Technologies, Inc.
