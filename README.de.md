<div align="center">

# DX.HttpSys

### Der native Windows-Kernel-HTTP-Stack — für *jedes* Delphi-Webframework

**Eine eigenständige, framework-neutrale Delphi-Bibliothek, die den Kernel-Mode-HTTP-Listener von Windows ([HTTP.sys](https://learn.microsoft.com/en-us/windows/win32/http/http-api-start-page) / `httpapi.dll` v2.0) als saubere, wiederverwendbare Komponente bereitstellt — plus dünne Adapter für WiRL und WebBroker.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Delphi 11.3+](https://img.shields.io/badge/Delphi-11.3%2B-E62431.svg?logo=delphi&logoColor=white)](https://www.embarcadero.com/products/delphi)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%20x86%20%7C%20x64-0078D6.svg?logo=windows&logoColor=white)](#voraussetzungen)
[![Status: In Entwicklung](https://img.shields.io/badge/Status-In%20Entwicklung-orange.svg)](#roadmap)
[![Keine externen Abhängigkeiten](https://img.shields.io/badge/Abh%C3%A4ngigkeiten-keine-brightgreen.svg)](#warum-httpsys)

[English](README.md) · **Deutsch**

</div>

---

## Warum HTTP.sys?

HTTP.sys ist der Kernel-Mode-HTTP-Listener, der seit Windows XP SP2 / Server 2003 in **jeder** Windows-Version steckt. Er ist die Basis von IIS, WCF und ASP.NET Core unter Windows. In der Delphi-Welt war er bislang jedoch nie als *eigenständige, wiederverwendbare* Komponente verfügbar — immer fest in einem Framework oder einem kommerziellen Produkt eingebettet.

**DX.HttpSys schließt diese Lücke.** Der Kern ist unabhängig, die Adapter sind dünn.

| Merkmal | HTTP.sys (DX.HttpSys) | User-Mode-Listener (Indy, …) |
|---|:---:|:---:|
| Port-Sharing (mehrere Prozesse auf :80/:443) | ✅ | ❌ exklusiv |
| Kernel-Mode Request Queue | ✅ | ❌ User-Mode |
| TLS/SSL | ✅ kernel-delegiert (`netsh http add sslcert`) | ⚠️ OpenSSL-Abhängigkeit |
| URL-ACL-Steuerung | ✅ `netsh http add urlacl` | ❌ |
| Externe Abhängigkeiten | ✅ **keine** (`httpapi.dll` immer vorhanden) | ⚠️ OpenSSL-DLLs mitliefern & pflegen |
| Deployment | ✅ Zero-Deploy | ⚠️ DLLs bündeln |
| Verbindungs-Caching / Keep-Alive | ✅ Kernel-Level | ❌ |

---

## Highlights

- 🧩 **Framework-neutraler Kern** — direkt nutzbar oder in das Framework deiner Wahl eingebunden.
- 🪶 **Keine externen Abhängigkeiten** — `httpapi.dll` ist Bestandteil jedes Windows. Keine OpenSSL-DLLs zum Mitliefern oder Patchen.
- ⚡ **Kernel-Performance** — reicht den Durchsatz- und Latenzvorteil des Kernel-Stacks mit vernachlässigbarem Overhead durch.
- 🛡️ **Stabilität als Primärziel** — ausgelegt auf leak- und race-freien Betrieb unter Dauerhochlast, abgesichert durch Unit-, Integrations-, Last- und Soak-Tests.
- 🔌 **Drop-in-Adapter** — WiRL von Indy auf HTTP.sys umstellen heißt: eine einzige `uses`-Zeile ändern.
- 🖥️ **UI-neutral** — Console, Windows-Service, VCL oder FMX. Bei Bedarf einen Kernel-HTTP-Server direkt in eine Desktop-App einbetten.

---

## Architektur

Sauberes Drei-Schichten-Design — der Kern sieht nie ein Framework, das Framework nie die WinAPI.

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3 — Framework-Adapter                                │
│  DX.HttpSys.WiRL.pas        DX.HttpSys.WebBroker.pas         │
│  TWiRLHttpSysServer         TWebBrokerHttpSysDispatcher      │
└───────────────────────────┬─────────────────────────────────┘
                            │ nutzt
┌───────────────────────────▼─────────────────────────────────┐
│  LAYER 2 — Server-Core (framework-agnostisch)               │
│  Server · Request · Response · ThreadPool                    │
│  IDXHttpSysRequestHandler  (das zentrale Callback-Interface) │
└───────────────────────────┬─────────────────────────────────┘
                            │ kapselt
┌───────────────────────────▼─────────────────────────────────┐
│  LAYER 1 — Win32-API-Translation                            │
│  Dünne Pascal-Header für httpapi.dll v2.0                    │
│  Geladen via GetProcAddress — keine harte Linkabhängigkeit   │
└─────────────────────────────────────────────────────────────┘
```

Das einzige Interface, das ein Adapter implementieren muss:

```pascal
IDXHttpSysRequestHandler = interface
  procedure HandleRequest(
    const ARequest:  TDXHttpSysRequest;
    const AResponse: TDXHttpSysResponse);
end;
```

---

## Schnellstart

> ⚠️ **In Arbeit.** Die API unten ist das Zieldesign aus dem [PRD](docs/PRD.md). Der Code entsteht entlang der [Roadmap](#roadmap).

### Standalone (nur Core, kein Framework)

```pascal
uses
  DX.HttpSys.Server;

var
  Server: TDXHttpSysServer;
begin
  Server := TDXHttpSysServer.Create;
  Server.AddUrlPrefix('http://localhost:8080/');
  Server.Handler := TMyHandler.Create;   // implementiert IDXHttpSysRequestHandler
  Server.Start;
  // ...
  Server.Stop;
end;
```

### WiRL — Indy gegen HTTP.sys tauschen, eine Zeile

```pascal
uses
  DX.HttpSys.WiRL,   // <-- statt WiRL.http.Server.Indy
  WiRL.http.Server;

FServer := TWiRLServer.Create(nil);
FServer.ServerPort := 8080;
// ... deine bestehende WiRL-Engine-Konfiguration ...
FServer.Active := True;
```

---

## URL-ACLs & Berechtigungen

Die Wildcard-Notation `http://+:8080/` (alle Interfaces) erfordert **Administrator-Rechte** oder eine vorab registrierte URL-ACL:

```cmd
netsh http add urlacl url=http://+:8080/ user=DOMAIN\Username
```

Für **reine Loopback**-URLs (`http://localhost:8080/`) sind keine erhöhten Rechte nötig.

Für **TLS** das Zertifikat vorab binden:

```cmd
netsh http add sslcert ipport=0.0.0.0:443 certhash=THUMBPRINT appid={GUID}
```

---

## Voraussetzungen

- **Delphi 11.3 oder neuer**
- **Windows** (x86 und x64) — `httpapi.dll` v2.0
- Die Core-Units kompilieren auf Nicht-Windows-Zielen unter `{$IFDEF MSWINDOWS}`-Guards; ein `Start` wirft dort `EDXHttpSysNotSupported`.

---

## Einordnung

Im Delphi-Ökosystem gibt es bislang **keine eigenständige, quelloffene HTTP.sys-Bibliothek**. Vorhandene Implementierungen sind an ein Framework gebunden oder kommerziell:

| Lösung | Lizenz | HTTP.sys | Eigenständig nutzbar |
|---|---|:---:|:---:|
| mORMot 1 / 2 (`THttpApiServer`) | Open Source | ✅ | ⚠️ nur mit mORMot-Netzwerk-Layer |
| DelphiMVCFramework ≥ 3.5 | Open Source | ✅ | ❌ Engine ist DMVC-intern |
| xxm (`httpapi2.pas`) | Open Source | ✅ | ⚠️ an xxm-Modulkonzept gebunden |
| TMS Sparkle | Kommerziell | ✅ | ⚠️ innerhalb TMS BIZ/Web Core |
| RemObjects Remoting SDK | Kommerziell | ✅ | ❌ an das SDK gebunden |
| WiRL / Horse / MARS-Curiosity | Open Source | ❌ | — nur Indy |

**DX.HttpSys** ist die erste Lösung, die HTTP.sys als wiederverwendbare, framework-neutrale Open-Source-Komponente bereitstellt — und sie Frameworks (WiRL, WebBroker, perspektivisch Horse) erschließt, die bisher keinen Zugang dazu hatten.

---

## Roadmap

- [ ] **M1 — API-Fundament:** WinAPI-Strukturen, `GetProcAddress`-Loader, Smoke-Test
- [ ] **M2 — Core-Server (Single-Threaded):** Request/Response/Server, Hello-World-Demo
- [ ] **M3 — Threading:** Receiver- + Worker-Thread-Pool, Last-Test
- [ ] **M4 — WiRL-Adapter:** REST-Resource via HTTP.sys
- [ ] **M5 — WebBroker-Adapter:** WebModule via HTTP.sys
- [ ] **M6 — Test-Suite & Härtung:** DUnitX, Integration, Stress/Soak, Leak-Checks, Performance-Baseline
- [ ] **M7 — Packaging & Doku:** Delphi-Packages, vollständige README, XML-Doku-Kommentare

Das vollständige Design steht im [Product Requirements Document](docs/PRD.md).

---

## Dokumentation

- 📄 [Product Requirements Document (PRD)](docs/PRD.md) — vollständige Architektur, API-Oberfläche und nicht-funktionale Anforderungen.

---

## Mitwirken

Beiträge, Issues und Feature-Wünsche sind willkommen. Das Projekt zielt auf einen sehr hohen Testanspruch (Unit-, Integrations-, Concurrency-/Stress-, Soak- und Leak-Tests) — siehe Abschnitt 9.6 des [PRD](docs/PRD.md).

---

## Lizenz

Veröffentlicht unter der [MIT-Lizenz](LICENSE) — © 2026 Olaf Monien (Developer Experts LLC).
