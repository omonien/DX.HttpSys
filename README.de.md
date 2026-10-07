<div align="center">

# DX.HttpSys

## Der native Windows-Kernel-HTTP-Stack — für *jedes* Delphi-Webframework

**Eine eigenständige, framework-neutrale Delphi-Bibliothek, die den Kernel-Mode-HTTP-Listener von Windows ([HTTP.sys](https://learn.microsoft.com/en-us/windows/win32/http/http-api-start-page) / `httpapi.dll` v2.0) als saubere, wiederverwendbare Komponente bereitstellt — plus dünne Adapter für WiRL, WebBroker und Horse.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Delphi 11.3+](https://img.shields.io/badge/Delphi-11.3%2B-E62431.svg)](https://www.embarcadero.com/products/delphi)
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
| HTTP/2 | ✅ vom Kernel auf TLS-Listenern ausgehandelt (Windows 10 / Server 2016+) — siehe [HTTP/2](#http2) | ❌ nur HTTP/1.x |

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
- 📡 **Streaming-Antworten (SSE)** — `BeginStream`/`SendChunk`/`EndStream` liefern `text/event-stream`- (oder beliebige langlebige) Antworten: Server-Sent Events ohne jede Abhängigkeit (siehe [`demo/07.Sse`](demo/07.Sse)).
- 🔀 **Protokollbewusstes Framing** — das Stream-Framing folgt dem Protokoll des Clients (`TDXHttpSysRequest.ProtocolVersion`): HTTP/1.1 chunked (Framing durch DX.HttpSys), HTTP/2 und HTTP/3 framt HTTP.sys selbst, HTTP/1.0 close-delimited. Verbindungsspezifische Header entfallen in HTTP/2-Antworten. Der Handler-Code ist für alle Fälle identisch (siehe [HTTP/2](#http2)).
- 🔗 **Gemeinsame Ports** — `AddUrlPrefix` nimmt eine vollständige URL (`http://localhost:80/api/`); mehrere Server und Prozesse können sich so einen Port unter verschiedenen Pfadpräfixen teilen, HTTP.sys routet nach dem längsten passenden Präfix. Schlägt das Binden fehl, nennt der Fehler das genaue `netsh http add urlacl`-Kommando.
- 🧵 **Fester Worker-Pool** — ein Receiver-Thread plus `ThreadCount` Worker (Default `2 × CPUCount`, mindestens 2); ein abgestürzter Worker wird neu gestartet, unbehandelte Handler-Exceptions werden zu `500`-Antworten.

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

> Der Core sowie die Adapter für WebBroker, WiRL und Horse sind implementiert; die folgenden
> Snippets zeigen die echte API. Lauffähige Beispiele: siehe [Demos](#demos).

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
for var LEvent in ['data: hello'#10#10, 'data: world'#10#10] do
  if not AResponse.SendChunk(TEncoding.UTF8.GetBytes(LEvent)) then
    Exit;                                    // Stream ist vorbei — einfach zurückkehren
AResponse.EndStream;                         // schließt die Antwort ab
```

`SendChunk` liefert `False`, wenn der Stream vorbei ist — der Client hat die Verbindung
getrennt oder der Server fährt herunter —, ein langlebiger Stream endet damit sauber; echte
Sendefehler lösen stattdessen `EDXHttpSysError` aus. `EndStream` ist nach Stream-Ende ein
sicherer No-op, und einen Stream, den der Handler begonnen, aber nicht beendet hat, schließt
der Worker ab (auch bei Exceptions).

Das Framing des Bodys folgt dem Protokoll des Clients (`ARequest.ProtocolVersion`):
**HTTP/1.1** erhält `Transfer-Encoding: chunked` mit dem Chunk-Framing von DX.HttpSys (HTTP.sys
framt nicht selbst); **HTTP/2** — das HTTP.sys auf `https`-Listenern standardmäßig per ALPN
aushandelt — erhält die Daten ungeframt in HTTP/2-DATA-Frames, ohne `Transfer-Encoding` (in
HTTP/2 verboten); **HTTP/1.0** erhält die reinen Daten, das Body-Ende markiert das Schließen der
Verbindung. Verbindungsspezifische Header (`Connection`, `Keep-Alive`, `Upgrade`, …) entfallen in
HTTP/2-Antworten. Der Handler-Code ist für alle Fälle derselbe — Framing-Header nie von Hand
setzen. Details: [HTTP/2](#http2).

Zwei Dinge sind bei langlebigen Streams zu beachten:

- **Jeder Stream belegt einen Worker-Thread des Pools** für seine gesamte Dauer. Der Pool
  ist fix auf `ThreadCount` dimensioniert (Default `2 × CPUCount`, mindestens 2; vor `Start`
  einstellbar) — für viele gleichzeitige Streams entsprechend größer wählen, sonst verhungern
  gewöhnliche Requests.
- **`AResponse.Cancelled` zwischen den Events abfragen** (und lange blinde `Sleep`s
  vermeiden): die Property wird `True`, sobald der Server herunterfährt, damit `Stop` nicht
  die volle Stream-Dauer abwarten muss.

Siehe [`demo/07.Sse`](demo/07.Sse) für ein vollständiges, lauffähiges Beispiel (zehn Events
im Sekundentakt — Test: `curl -N http://localhost:80/sse/`).

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

## Binden und Port teilen

`AddUrlPrefix` ist der **einzige Bind-Mechanismus**. Es nimmt eine vollständige URL, die schon
beim Aufruf geprüft wird (Beginn mit `http://` oder `https://`, Ende mit `/`), und darf mehrfach
aufgerufen werden:

```pascal
Server.AddUrlPrefix('http://localhost:80/api/');
Server.AddUrlPrefix('https://+:443/api/');
```

Eine separate `Port`-Property gibt es nicht. Weil der Pfad Teil des Präfixes ist, können sich
**mehrere Server — im selben Prozess oder in verschiedenen Prozessen — einen Port teilen**, solange
ihre Pfadpräfixe verschieden sind; HTTP.sys routet jeden Request zum längsten passenden Präfix.
Alle Demos nutzen das, um parallel auf Port 80 zu laufen. Die Adapter bauen ihr Präfix aus Schema,
Host, Port und Pfad mit `TDXHttpSysServer.BuildPrefix(...)` zusammen (WiRL: `BasePath` der Engine;
Horse: `BasePath` des Providers); `TDXScheme = (Http, Https)` wählt das Schema. Scheitert das Binden
mit „Zugriff verweigert“, nennt der Fehler das genaue Präfix und das einmalig als Administrator
auszuführende `netsh http add urlacl`-Kommando (siehe
[URL-ACLs & Berechtigungen](#url-acls--berechtigungen)).

Weitere Einstellungen (alle vor `Start`): `ThreadCount` (Default `2 × CPUCount`, mindestens 2),
`QueueLength` (Kernel-Request-Queue, Default 1000), `ServerHeader` (Default `DX.HttpSys/1.0`;
HTTP.sys hängt `Microsoft-HTTPAPI/2.0` an) und der `OnError`-Callback.

---

## Demos

Alle Demos sind Konsolenprogramme unter [`demo/`](demo/), die unterhalb von `http://localhost:80/`
binden (keine erhöhten Rechte nötig), jeweils unter einem eigenen Pfadpräfix — sie können also
gleichzeitig laufen.

| Demo | Zeigt | URL |
|---|---|---|
| [`01.StandaloneServer`](demo/01.StandaloneServer) | Der kleinstmögliche Server — nur Core, kein Framework | `/standalone/` |
| [`02.WiRL`](demo/02.WiRL) | Eine WiRL-REST-Ressource auf HTTP.sys (nur Quelltext: WiRL wird nicht mitgeliefert, in den Bibliothekspfad aufnehmen) | `/rest/app/hello` |
| [`03.WebBroker`](demo/03.WebBroker) | Ein WebBroker-WebModule über `TWebBrokerHttpSysDispatcher` | `/webbroker/`, `/webbroker/time` |
| [`04.Horse`](demo/04.Horse) | Eine Horse-App über `THorseProviderHttpSys<THorse>` (nur Quelltext: Horse wird nicht mitgeliefert) | `/horse/ping` |
| [`07.Sse`](demo/07.Sse) | Server-Sent Events: zehn Events im Sekundentakt (`curl -N`); ein optionaler erster Parameter ersetzt das URL-Präfix | `/sse/` |

---

## HTTP/2

HTTP.sys handelt **HTTP/2 per ALPN auf jedem TLS-Listener (`https`) standardmäßig aus** (Windows 10 /
Server 2016 und neuer, TLS 1.2+); reine `http`-Listener bleiben bei HTTP/1.x, ältere Systeme fallen
auf HTTP/1.1 zurück. DX.HttpSys braucht dafür keine Konfiguration — das macht die Bibliothek:

- **`TDXHttpSysRequest.ProtocolVersion`** meldet das Protokoll, über das der Request kam (1.0, 1.1,
  2.0 oder 3.0). Maßgeblich sind die HTTP/2- und HTTP/3-Request-Flags von HTTP.sys, sonst die
  Version der Request-Zeile.
- **Streaming** (`BeginStream`/`SendChunk`/`EndStream`) framt den Body je Protokoll:

  | Request-Protokoll | Body-Framing | `EndStream` |
  |---|---|---|
  | HTTP/1.1 | `Transfer-Encoding: chunked`, Chunk-Framing von DX.HttpSys | Terminal-Chunk |
  | HTTP/2, HTTP/3 | Daten ungeframt an HTTP.sys (das die DATA-Frames erzeugt), kein `Transfer-Encoding` | leerer Send mit Disconnect-Flag (beendet den Stream, nicht die Verbindung) |
  | HTTP/1.0 | reine Daten, `Connection: close` | leerer Send mit Disconnect-Flag; das Schließen beendet den Body |

- **Header, die das Protokoll des Clients verbietet, entfallen** beim Senden: `Connection`,
  `Keep-Alive`, `Proxy-Connection`, `Transfer-Encoding` und `Upgrade` bei HTTP/2 und HTTP/3
  (RFC 9113 §8.2.2), `Transfer-Encoding` bei HTTP/1.0. Das betrifft auch Header, die Handler oder
  Adapter selbst setzen (z. B. `Connection: keep-alive` in einem SSE-Handler). HTTP/1.1-Antworten
  gehen unverändert hinaus.

**HTTP/2 abschalten** (normalerweise unnötig — Handler verhalten sich in beiden Fällen gleich): je
TLS-Bindung mit `disablehttp2=enable` oder maschinenweit über den Registry-Wert `EnableHttp2Tls = 0`
(`HKLM\SYSTEM\CurrentControlSet\Services\HTTP\Parameters`, danach den HTTP-Dienst neu starten
oder neu booten):

```cmd
netsh http add sslcert ipport=0.0.0.0:443 certhash=THUMBPRINT appid={GUID} disablehttp2=enable
```

**Live-Check.** HTTP/2 braucht eine TLS-Bindung, und das Binden eines Zertifikats erfordert
Administratorrechte; das Wire-Verhalten gehört deshalb nicht zur Unit-Test-Suite (die die
Framing-Entscheidungen und die exakten HTTP.sys-Sendeaufrufe über Fakes absichert). Stattdessen
[`tests-integration\Http2StreamingCheck.ps1`](tests-integration/Http2StreamingCheck.ps1) in einer
**erhöhten PowerShell 7.2+** ausführen:

```powershell
tests-integration\Http2StreamingCheck.ps1             # Standardport 44399, Win64 Debug
tests-integration\Http2StreamingCheck.ps1 -NoTls      # Selbsttest der Infrastruktur ohne Elevation (nur HTTP/1.1)
```

Das Skript baut `demo/07.Sse`, erzeugt ein temporäres selbstsigniertes Zertifikat, bindet es an
`127.0.0.1:<Port>`, streamt `/sse/` einmal über HTTP/2 und einmal über HTTP/1.1 und prüft, dass
HTTP/2 tatsächlich ausgehandelt wurde, ohne `Transfer-Encoding` und ohne Chunk-Framing-Bytes im
Body, und dass HTTP/1.1 das exakte Chunk-Framing trägt. Danach entfernt es Bindung und Zertifikat
(samt privatem Schlüssel) — auch bei Fehlern — und weigert sich zu laufen, wenn der Port bereits
eine sslcert-Bindung hat. Begründung und offene Punkte: [`docs/DECISIONS.md`](docs/DECISIONS.md) A-21.

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

Solche `https`-Listener bedienen auch HTTP/2 — siehe [HTTP/2](#http2).

---

## Voraussetzungen

- **Delphi 11.3 oder neuer**
- **Windows** (x86 und x64) — `httpapi.dll` v2.0
- Nur Windows: HTTP.sys ist eine Windows-Kernel-Funktion, die Units sind daher reiner Windows-Code (keine plattformübergreifenden Compile-Guards).
- HTTP/2 erfordert zusätzlich Windows 10 / Server 2016 oder neuer und eine TLS-Bindung (siehe [HTTP/2](#http2)).

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

**DX.HttpSys** ist die erste Lösung, die HTTP.sys als wiederverwendbare, framework-neutrale Open-Source-Komponente bereitstellt — und sie Frameworks (WiRL, WebBroker, Horse) erschließt, die bisher keinen Zugang dazu hatten.

---

## Tests

- **Unit- und In-Process-Integrationstests** — die DUnitX-Suite [`tests/`](tests/)
  (`DX.HttpSys.Tests.dproj`, DUnitX als Git-Submodul: `git submodule update --init --recursive`).
  89 Tests, grün unter Win32 und Win64, ohne Leaks. Fixtures: API-Smoke, Server-Integration,
  URL-/Bind-API, WebBroker-Adapter, Concurrency-Stress, Soak/Longevity (begrenzter Speicher- und
  Handle-Verbrauch) und Streaming (echtes SSE über die Leitung, die reinen Framing-Entscheidungen je
  Protokollversion sowie die exakten HTTP.sys-Sendeaufrufe je Protokoll über aufzeichnende Fakes —
  damit läuft der HTTP/2-Pfad ohne Elevation). Alles bindet an `http://localhost:<port>/`, es sind
  keine Administratorrechte nötig.

  ```powershell
  build-scripts\DelphiBuildDPROJ.ps1 -ProjectFile tests\DX.HttpSys.Tests.dproj -Platform Win64
  build\Win64\Debug\DX.HttpSys.Tests.exe --exitbehavior:Continue    # Exitcode <> 0 = Fehler
  ```

- **Integrationstests mit Fremd-Frameworks (optional)** — [`tests-integration/`](tests-integration/)
  laden WiRL und Horse bei Bedarf herunter und liefern eine echte Framework-Ressource über HTTP.sys
  aus (`build-scripts\BuildIntegrationTests.ps1 -Run`). Für einen normalen Build wird nichts
  mitgeliefert oder benötigt.
- **HTTP/2-Live-Check (erhöht)** — `tests-integration\Http2StreamingCheck.ps1`, siehe [HTTP/2](#http2).
- **CI** — [`.github/workflows/build-and-test.yml`](.github/workflows/build-and-test.yml) baut bei
  jedem Push und jedem PR aus demselben Repository auf `main` den Core (Win32 + Win64), das
  WebBroker-Package und den Test-Runner und führt die Suite aus. Delphi ist kommerziell und auf
  GitHub-gehosteten Runnern nicht verfügbar; der Job läuft daher auf einem **selbst gehosteten**
  Windows-Runner mit den Labels `self-hosted, windows, delphi`
  ([`docs/DECISIONS.md`](docs/DECISIONS.md) A-12); PRs aus Forks laufen dort bewusst nicht.

---

## Roadmap

- [x] **M1 — API-Fundament:** WinAPI-Strukturen, `GetProcAddress`-Loader, Smoke-Tests
- [x] **M2 — Core-Server:** Request/Response/Server, Header-Übertragung, Hello-World-Demo
- [x] **M3 — Threading:** Receiver- + Worker-Thread-Pool, Concurrency-/Stress-Harness
- [x] **M4 — WiRL-Adapter:** `DX.HttpSys.WiRL` für die WiRL-4.x-Release-API, über den optionalen
      Integrations-Harness gegen WiRL v4.6.0 verifiziert; `DX.HttpSys.WiRL.REST` für den
      master-Branch ist Best-Effort. WiRL ist eine externe Abhängigkeit, die bewusst nicht
      mitgeliefert wird (siehe [`docs/DECISIONS.md`](docs/DECISIONS.md) A-10)
- [x] **M5 — WebBroker-Adapter:** echtes WebModule via HTTP.sys, mit E2E-Tests + Demo
- [x] **M6 — Test-Suite & Härtung:** DUnitX Unit + Integration + Concurrency-Stress + Soak
      sowie Leak-/Handle-Checks (89 Tests, 0 Leaks)
- [x] **M7 — Packaging & Doku:** Delphi-Packages, CI-Workflow, README, XML-Doku-Kommentare
- [x] **M8 — Horse-Adapter:** `DX.HttpSys.Horse`-Provider über dem WebBroker-Dispatcher,
      gegen Horse v2.0.14 verifiziert
- [x] **M9 — Bind-API für gemeinsame Ports:** `AddUrlPrefix` als einziger, geprüfter
      Bind-Mechanismus; die Demos teilen sich Port 80 über Pfadpräfixe
- [x] **M10 — Streaming & HTTP/2:** `BeginStream`/`SendChunk`/`EndStream` (SSE),
      protokollbewusstes Framing, `ProtocolVersion`. Der HTTP/2-Wire-Check ist ein separates,
      erhöht auszuführendes Skript (siehe [HTTP/2](#http2))

Der Core und alle drei Adapter sind implementiert, bauen sauber unter Win32 + Win64 und sind durch
eine grüne Test-Suite abgedeckt. Das vollständige Design steht im
[Product Requirements Document](docs/PRD.md), die Architekturentscheidungen in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

---

## Dokumentation

- 📄 [Product Requirements Document (PRD)](docs/PRD.md) — vollständige Architektur, API-Oberfläche und nicht-funktionale Anforderungen (das ursprüngliche Designdokument).
- 🧭 [Architektur- und Prozessentscheidungen](docs/DECISIONS.md) — warum der Code so aussieht (z. B. A-20 Bind-API, A-21 Stream-Framing je Protokoll).
- 🧪 [Integrationstests mit Fremd-Frameworks und der HTTP/2-Live-Check](tests-integration/README.md).

---

## Mitwirken

Beiträge, Issues und Feature-Wünsche sind willkommen. Das Projekt zielt auf einen sehr hohen Testanspruch (Unit-, Integrations-, Concurrency-/Stress-, Soak- und Leak-Tests) — siehe Abschnitt 9.6 des [PRD](docs/PRD.md).

---

## Lizenz

Veröffentlicht unter der [MIT-Lizenz](LICENSE) — © 2026 Olaf Monien (Developer Experts LLC).

---

## Marken

Delphi und Embarcadero sind Marken oder eingetragene Marken der Embarcadero Technologies, Inc.
oder ihrer Tochtergesellschaften in den Vereinigten Staaten und/oder anderen Ländern. Alle
übrigen Marken sind Eigentum ihrer jeweiligen Inhaber. Dieses Projekt steht in keiner
Verbindung zu Embarcadero Technologies, Inc. und wird von dieser weder unterstützt noch
gesponsert.
