<div align="center">

# DX.HttpSys

## Der native Windows-Kernel-HTTP-Stack — für *jedes* Delphi-Webframework

**Eine eigenständige, framework-neutrale Delphi-Bibliothek, die den Kernel-Mode-HTTP-Listener von Windows ([HTTP.sys](https://learn.microsoft.com/en-us/windows/win32/http/http-api-start-page) / `httpapi.dll` v2.0) als saubere, wiederverwendbare Komponente bereitstellt — plus dünne Adapter für WiRL und WebBroker.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Delphi 11.3+](https://img.shields.io/badge/Delphi-11.3%2B-E62431.svg?logo=delphi&logoColor=white)](https://www.embarcadero.com/products/delphi)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%20x86%20%7C%20x64-0078D6.svg?logo=windows&logoColor=white)](#voraussetzungen)
[![Status: Core fertig](https://img.shields.io/badge/Status-Core%20fertig%20%C2%B7%20getestet-brightgreen.svg)](#roadmap)
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

## Hintergrund — erprobt im Produktiveinsatz, nicht neu erfunden

Das hier ist kein frisches Experiment. Eine HTTP.sys-Anbindung für Delphi setze ich bereits **seit über zehn Jahren in mehreren produktiven Anwendungen** ein. Sie läuft stabil und trägt seitdem reale Lasten.

Diese ursprüngliche Bibliothek ist allerdings unter Zeitdruck gewachsen. Sie war eng an Indy angelehnt — im Kern eine HTTP.sys-WebBroker-Bridge, fest an ein einzelnes Framework gekoppelt — und enthält Designentscheidungen, die aus heutiger Sicht schwierig sind. Eine Open-Source-Veröffentlichung war immer angedacht, scheiterte aber an der Komplexität der HTTP.sys-API und am entsprechend suboptimalen Code.

**DX.HttpSys ist der bewusste Neuansatz:** dieselbe erprobte Grundlage, neu gebaut als stark abstrahierter, framework-neutraler Kern, den beliebige Produkte (WiRL, WebBroker, Horse, …) als Server-Engine nutzen können. Keine neue Idee — über ein Jahrzehnt Produktionserfahrung, destilliert in eine saubere, wiederverwendbare Bibliothek.

---

## Highlights

- 🧩 **Framework-neutraler Kern** — direkt nutzbar oder in das Framework deiner Wahl eingebunden.
- 🪶 **Keine externen Abhängigkeiten** — `httpapi.dll` ist Bestandteil jedes Windows. Keine OpenSSL-DLLs zum Mitliefern oder Patchen.
- ⚡ **Kernel-Performance** — reicht den Durchsatz- und Latenzvorteil des Kernel-Stacks mit vernachlässigbarem Overhead durch.
- 🛡️ **Stabilität als Primärziel** — ausgelegt auf leak- und race-freien Betrieb unter Dauerhochlast, abgesichert durch Unit-, Integrations-, Last- und Soak-Tests.
- 🔌 **Drop-in-Adapter** — WiRL von Indy auf HTTP.sys umstellen heißt: eine einzige `uses`-Zeile ändern.
- 🖥️ **UI-neutral** — Console, Windows-Service, VCL oder FMX. Bei Bedarf einen Kernel-HTTP-Server direkt in eine Desktop-App einbetten.
- 📡 **Chunked Streaming (SSE)** — `BeginStream`/`SendChunk`/`EndStream` liefern `text/event-stream`-Antworten über die Chunked-Transfer-Encoding von HTTP.sys — Server-Sent Events ohne jede Abhängigkeit (siehe [`demo/07.Sse`](demo/07.Sse)).

---

## Architektur

Sauberes Drei-Schichten-Design — der Kern sieht nie ein Framework, das Framework nie die WinAPI.

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3 — Framework-Adapter                                │
│  DX.HttpSys.WiRL.pas   DX.HttpSys.WebBroker.pas             │
│  DX.HttpSys.Horse.pas  (Horse-Provider über WebBroker)      │
│  TWiRLHttpSysServer    TWebBrokerHttpSysDispatcher          │
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

> Der Core und der WebBroker-Adapter sind implementiert und getestet. Die folgenden Snippets
> zeigen die echte API; lauffähige Beispiele liegen unter [`demo/`](demo/).

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

### Server-Sent Events (Chunked Streaming)

```pascal
uses
  DX.HttpSys.Response;

// innerhalb deiner IDXHttpSysRequestHandler.HandleRequest:
AResponse.Headers['content-type']  := 'text/event-stream';
AResponse.Headers['cache-control'] := 'no-cache';
AResponse.BeginStream;                       // Header, ohne Content-Length → chunked
AResponse.SendChunk(TEncoding.UTF8.GetBytes('data: hello'#10#10));  // ein Event
AResponse.SendChunk(TEncoding.UTF8.GetBytes('data: world'#10#10));
AResponse.EndStream;                         // schließt die Antwort ab
```

`SendChunk` liefert `False`, wenn der Client die Verbindung getrennt hat — ein langlebiger
Stream kann damit sauber enden. Siehe [`demo/07.Sse`](demo/07.Sse) für ein vollständiges,
lauffähiges Beispiel (zehn Events im Sekundentakt — Test: `curl -N http://localhost:8123/sse`).

### WebBroker — dein WebModule auf HTTP.sys

```pascal
uses
  DX.HttpSys.Server, DX.HttpSys.WebBroker, Web.WebReq;

// WebModule wie gewohnt bei WebBroker registrieren, dann auf HTTP.sys hosten:
Server := TDXHttpSysServer.Create;
Server.Handler := TWebBrokerHttpSysDispatcher.Create;
Server.AddUrlPrefix('http://localhost:8080/');
Server.Start;
```

Ein vollständiges, lauffähiges Beispiel liegt unter [`demo/03.WebBroker`](demo/03.WebBroker).

### WiRL — die HTTP.sys-Engine auswählen

```pascal
uses
  DX.HttpSys.WiRL,   // registriert die WiRL-Server-Engine 'HttpSys' (WiRL 4.x)
  WiRL.http.Server;

FServer := TWiRLServer.Create(nil);
FServer.Port := 8080;
FServer.ServerVendor := 'HttpSys';   // HTTP.sys statt Indy
// ... deine bestehende WiRL-Engine-/Application-Konfiguration ...
FServer.Active := True;
```

> ℹ️ WiRL ist eine externe Abhängigkeit, die bewusst **nicht mitgeliefert** wird, daher
> kompiliert dieser Adapter nur, wenn WiRL im Suchpfad liegt. Es gibt zwei Adapter:
> `DX.HttpSys.WiRL` für die WiRL-4.x-Release-API (gegen WiRL v4.6.0 **verifiziert**) und
> `DX.HttpSys.WiRL.REST` für den master-Branch. Optionale Integrationstests laden die
> nötigen Quellen herunter — siehe [`tests-integration/`](tests-integration/) und
> [`docs/DECISIONS.md`](docs/DECISIONS.md) (A-10).

### Horse — deine Horse-App auf HTTP.sys betreiben

```pascal
uses
  Horse,
  DX.HttpSys.Horse;   // ein Horse-Provider auf Basis von HTTP.sys

THorse.Get('/ping',
  procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
  begin
    ARes.Send('pong');
  end);

// Über diesen Provider statt Horses Standard-Indy-Provider starten.
// Host/Scheme sind localhost/Http (ohne Adminrechte); für '+' / https setzen.
THorseProviderHttpSys<THorse>.Port := 8080;
THorseProviderHttpSys<THorse>.Listen;
```

> ℹ️ Routen wie gewohnt mit `THorse` definieren; nur der `Listen`-Aufruf ändert sich. Horse
> basiert auf WebBroker, daher ist dieser Adapter ein dünner Provider über
> `TWebBrokerHttpSysDispatcher`. Horse wird nicht mitgeliefert — gegen Horse v2.0.14 über die
> Integrationstests verifiziert. Siehe [`demo/04.Horse`](demo/04.Horse).

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

- [x] **M1 — API-Fundament:** WinAPI-Strukturen, `GetProcAddress`-Loader, Smoke-Tests
- [x] **M2 — Core-Server:** Request/Response/Server, Header-Übertragung, Hello-World-Demo
- [x] **M3 — Threading:** Receiver- + Worker-Thread-Pool, Concurrency-/Stress-Harness
- [ ] **M4 — WiRL-Adapter:** gegen die WiRL-API geschrieben, hier aber *nicht gebaut/getestet* —
      WiRL ist eine externe Abhängigkeit, die bewusst nicht mitgeliefert wird; der Adapter wird
      als Best-Effort-Quelle ausgeliefert (siehe [`docs/DECISIONS.md`](docs/DECISIONS.md) A-10).
      Optionale Integrationstests dafür liegen unter [`tests-integration/`](tests-integration/)
- [x] **M5 — WebBroker-Adapter:** echtes WebModule via HTTP.sys, mit E2E-Tests + Demo
- [x] **M6 — Test-Suite & Härtung:** DUnitX Unit + Integration + Concurrency-Stress + Soak
      sowie Leak-/Handle-Checks (18 Tests, 0 Leaks)
- [x] **M7 — Packaging & Doku:** Delphi-Packages, CI-Workflow, README, XML-Doku-Kommentare

Der Core und der WebBroker-Adapter sind implementiert, bauen sauber unter Win32 + Win64 und
sind durch eine grüne Test-Suite abgedeckt. Der WiRL-Adapter wartet auf die Verifikation auf
einer Maschine mit installiertem WiRL. Das vollständige Design steht im
[Product Requirements Document](docs/PRD.md), die Architekturentscheidungen in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

---

## Dokumentation

- 📄 [Product Requirements Document (PRD)](docs/PRD.md) — vollständige Architektur, API-Oberfläche und nicht-funktionale Anforderungen.

---

## Mitwirken

Beiträge, Issues und Feature-Wünsche sind willkommen. Das Projekt zielt auf einen sehr hohen Testanspruch (Unit-, Integrations-, Concurrency-/Stress-, Soak- und Leak-Tests) — siehe Abschnitt 9.6 des [PRD](docs/PRD.md).

---

## Lizenz

Veröffentlicht unter der [MIT-Lizenz](LICENSE) — © 2026 Olaf Monien (Developer Experts LLC).
