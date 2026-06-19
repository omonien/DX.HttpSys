<div align="center">

# DX.HttpSys

### The native Windows kernel HTTP stack — for *any* Delphi web framework

**A standalone, framework-agnostic Delphi library that exposes the Windows kernel-mode HTTP listener ([HTTP.sys](https://learn.microsoft.com/en-us/windows/win32/http/http-api-start-page) / `httpapi.dll` v2.0) as a clean, reusable component — plus thin adapters for WiRL and WebBroker.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Delphi 11.3+](https://img.shields.io/badge/Delphi-11.3%2B-E62431.svg?logo=delphi&logoColor=white)](https://www.embarcadero.com/products/delphi)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%20x86%20%7C%20x64-0078D6.svg?logo=windows&logoColor=white)](#requirements)
[![Status: In Development](https://img.shields.io/badge/Status-In%20Development-orange.svg)](#roadmap)
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

---

## Architecture

A clean three-layer design — the core never sees a framework, the framework never sees the WinAPI.

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3 — Framework Adapters                                │
│  DX.HttpSys.WiRL.pas        DX.HttpSys.WebBroker.pas         │
│  TWiRLHttpSysServer         TWebBrokerHttpSysDispatcher      │
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

> ⚠️ **Work in progress.** The API below is the target design from the [PRD](docs/PRD.md). Code is being implemented along the [roadmap](#roadmap).

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

### WiRL — swap Indy for HTTP.sys in one line

```pascal
uses
  DX.HttpSys.WiRL,   // <-- instead of WiRL.http.Server.Indy
  WiRL.http.Server;

FServer := TWiRLServer.Create(nil);
FServer.ServerPort := 8080;
// ... your existing WiRL engine configuration ...
FServer.Active := True;
```

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

---

## Requirements

- **Delphi 11.3 or newer**
- **Windows** (x86 and x64) — `httpapi.dll` v2.0
- The core units compile on non-Windows targets under `{$IFDEF MSWINDOWS}` guards; calling `Start` there raises `EDXHttpSysNotSupported`.

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

**DX.HttpSys** is the first to provide HTTP.sys as a reusable, framework-neutral open-source component — and brings it to frameworks (WiRL, WebBroker, and prospectively Horse) that previously had no access to it.

---

## Roadmap

- [ ] **M1 — API foundation:** WinAPI structures, `GetProcAddress` loader, smoke test
- [ ] **M2 — Core server (single-threaded):** Request/Response/Server, Hello-World demo
- [ ] **M3 — Threading:** receiver + worker thread pool, load test
- [ ] **M4 — WiRL adapter:** REST resource served via HTTP.sys
- [ ] **M5 — WebBroker adapter:** WebModule served via HTTP.sys
- [ ] **M6 — Test suite & hardening:** DUnitX, integration, stress/soak, leak checks, perf baseline
- [ ] **M7 — Packaging & docs:** Delphi packages, full README, XML doc comments

See the full [Product Requirements Document](docs/PRD.md) for the complete design.

---

## Documentation

- 📄 [Product Requirements Document (PRD)](docs/PRD.md) — full architecture, API surface, and non-functional requirements.

---

## Contributing

Contributions, issues and feature requests are welcome. The project targets a very high test bar (unit, integration, concurrency/stress, soak and leak tests) — see section 9.6 of the [PRD](docs/PRD.md) for the quality goals.

---

## License

Released under the [MIT License](LICENSE) — © 2026 Olaf Monien (Developer Experts LLC).
