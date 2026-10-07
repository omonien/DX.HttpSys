# Product Requirements Document: DX.HttpSys

**Version:** 1.0.0-draft  
**Datum:** 2025-06  
**Autor:** Olaf (Developer Experts LLC)  
**Status:** Draft (Stand der Umsetzung: siehe Abschnitt 10; Architekturentscheidungen und spätere Änderungen: [`DECISIONS.md`](DECISIONS.md))

---

## 1. Zusammenfassung

`DX.HttpSys` ist eine framework-agnostische Delphi-Bibliothek, die den Windows-Kernel-HTTP-Stack (**HTTP.sys / httpapi.dll v2.0**) als vollständig abstrahierte, eigenständige Komponente zugänglich macht. Darüber hinaus werden dünne Adapter-Units bereitgestellt, die `DX.HttpSys` als Server-Engine in bestehende Delphi-Webframeworks einbinden – initial für **WiRL** und **WebBroker** (inzwischen zusätzlich **Horse**).

Das Projekt folgt dem Prinzip: Der Kern ist unabhängig, die Adapter sind dünn.

---

## 2. Motivation und Kontext

### 2.1 Was ist HTTP.sys?

HTTP.sys ist ein Kernel-Mode-HTTP-Listener, der seit Windows XP SP2 / Server 2003 fester Bestandteil aller Windows-Versionen ist. Er ist die Basis von IIS, WCF (netHttpBinding) und ASP.NET Core auf Windows.

**Entscheidende Eigenschaften gegenüber User-Mode-Listenern (Indy, Synapse, etc.):**

| Merkmal | HTTP.sys | Indy TIdHTTPServer |
|---|---|---|
| URL-Port-Sharing | ✅ Mehrere Prozesse auf Port 80/443 | ❌ Exklusiv |
| Kernel-Mode Request Queue | ✅ | ❌ User-Mode |
| TLS/SSL | ✅ Kernel-delegiert (`netsh http add sslcert`) | ⚠️ OpenSSL-Abhängigkeit |
| URL-ACL-Steuerung | ✅ `netsh http add urlacl` | ❌ |
| Externe Abhängigkeiten | ✅ Keine (httpapi.dll immer vorhanden) | ⚠️ OpenSSL-DLLs für TLS (Indy selbst wird einkompiliert) |
| Deployment-Komplexität | ✅ Zero-Deploy | ⚠️ OpenSSL-DLLs mitliefern und versioniert aktuell halten |
| Verbindungs-Caching | ✅ Kernel-Level Keep-Alive | ❌ |

### 2.2 Marktüberblick: HTTP.sys in der Delphi-Welt

HTTP.sys ist in Delphi keineswegs unbekannt – mehrere Frameworks und Produkte nutzen es. In nahezu allen Fällen ist die Anbindung jedoch fest an ein Framework oder ein kommerzielles Produkt gebunden. Eine **eigenständige, framework-neutrale HTTP.sys-Bibliothek**, die bewusst zur Wiederverwendung in beliebigen Frameworks konzipiert ist, fehlt.

| Lösung | Lizenz | HTTP.sys | Eigenständig nutzbar | Anmerkung |
|---|---|---|---|---|
| **mORMot 1 / 2** (`THttpApiServer`) | Open Source | ✅ | ⚠️ nur mit mORMot-Netzwerk-Layer | Reife Implementierung, fest im Framework |
| **DelphiMVCFramework ≥ 3.5** | Open Source | ✅ (Engine-Option) | ❌ | http.sys-Engine ist DMVC-intern |
| **xxm** (`httpapi2.pas`) | Open Source | ✅ | ⚠️ | an xxm-Modulkonzept gebunden |
| **TMS Sparkle** | Kommerziell | ✅ | ⚠️ innerhalb TMS BIZ/Web Core | Basis vieler TMS-Webprodukte |
| **IntraWeb** (Atozed) | Kommerziell | ✅ (Deployment-Target) | ❌ | http.sys als Hosting-Variante |
| **RemObjects Remoting SDK** | Kommerziell | ✅ (HttpAPI-Server) | ❌ | an das SDK gebunden |
| **RAD Server / EMS** (Embarcadero) | Kommerziell | ⚠️ nur indirekt via IIS/ISAPI | ❌ | kein eigener http.sys-Stack; Dev-Server = Indy |
| **WebStencils** (Embarcadero, ab 12.2) | Kommerziell | ❌ | – | neue Template-Engine auf WebBroker/RAD-Server-Basis; erbt deren Hosting (Indy/IIS/Apache), kein eigener http.sys-Stack |
| **WiRL** | Open Source | ❌ | – | nur Indy (`WiRL.http.Server.Indy`) |
| **Horse** | Open Source | ❌ | – | Indy-Default; Community-Provider CrossSocket / mORMot (Socket) |
| **MARS-Curiosity** | Open Source | ❌ | – | nur Indy bzw. WebBroker/ISAPI/Apache |

Zwei Konsequenzen ergeben sich daraus:

1. **Es gibt keine isoliert einsetzbare Open-Source-HTTP.sys-Bibliothek.** Die quelloffenen Implementierungen (mORMot, DMVCFramework, xxm) sind jeweils tief in ihr eigenes Ökosystem eingebettet und lassen sich nicht ohne dieses verwenden.
2. **Für WiRL, Horse und MARS-Curiosity existiert keine HTTP.sys-Anbindung.** Diese Frameworks laufen ausschließlich über Indy. Auch die Delphi-RTL liefert für WebBroker nur Indy-basierte Stand-alone-Server – einen WebBroker-Adapter über HTTP.sys gibt es weder in der RTL noch quelloffen.

Genau diese Lücke schließt `DX.HttpSys`: ein eigenständiger Kern plus dünne Adapter, der HTTP.sys erstmals als wiederverwendbare, framework-neutrale Open-Source-Komponente bereitstellt und damit Frameworks wie WiRL und WebBroker (perspektivisch Horse) erschließt, die bislang keinen Zugang hatten.

### 2.3 Entstehung und persönlicher Hintergrund

Eine HTTP.sys-Anbindung für Delphi setze ich bereits seit über zehn Jahren in mehreren produktiven Anwendungen ein. Diese Bibliothek läuft stabil, ist aber unter Zeitdruck gewachsen und enthält Designentscheidungen, die aus heutiger Sicht schwierig sind. Eine Open-Source-Veröffentlichung war zwar immer angedacht, scheiterte aber an der Komplexität der HTTP.sys-API und am entsprechend suboptimalen Code.

Der ursprüngliche Entwurf war analog zu Indy konzipiert: So wie Indy eine WebBroker-Bridge bereitstellt, baute ich eine HTTP.sys-WebBroker-Bridge. Diese enge Kopplung an ein Framework ist genau das, was die Wiederverwendung erschwert.

Die existierenden Alternativen (siehe 2.2) leiden unter vergleichbaren Einschränkungen: Sie sind entweder kommerziell oder fest in ein Framework eingebettet, mit ähnlichen Komplexitäts- und Designentscheidungen wie meine eigene Ausgangsbibliothek – und damit schwer auf eine moderne, isoliert nutzbare Basis zu heben.

`DX.HttpSys` ist der Neuansatz: ein bewusst stark abstrahierter, framework-neutraler Kern, der sich in unterschiedlichen Produkten (WiRL, WebBroker, Horse u. a.) als Server-Engine einsetzen lässt und Delphi-Anwendungen unter Windows einen direkten Zugang zur kernel-optimierten HTTP-Schnittstelle bietet.

### 2.4 Ziele dieses Projekts

1. Eine **standalone, framework-neutrale** HTTP.sys-Bibliothek für Delphi schaffen.
2. **Keine externen Abhängigkeiten** außer der HTTP.sys-API (`httpapi.dll`) selbst, die fester Bestandteil jedes Windows ist – kein Mitliefern oder Pflegen von DLLs (anders als die OpenSSL-Problematik bei Indy/TLS).
3. **Hoch-performant:** Den nativen Durchsatz- und Latenzvorteil des Kernel-Stacks ohne nennenswerten Overhead an die Anwendung durchreichen.
4. **100 % stabil:** Auch unter Dauer- und Hochlast keine Memory-Leaks, Handle-Leaks, Races oder Abstürze. Abgesichert durch eine **sehr hohe Testabdeckung** inklusive Integrations-, Last- und Stresstests, die die Implementierung mit vielen gleichzeitigen Requests dauerhaft „hämmern" (siehe Abschnitt 9.5/9.6).
5. Einen **WiRL-Adapter** als primäres Integrationsziel bereitstellen.
6. Einen **WebBroker-Adapter** als zweites Integrationsziel bereitstellen.
7. Die Architektur so gestalten, dass weitere Adapter (Horse, mORMot, etc.) einfach ergänzt werden können.

---

## 3. Architekturübersicht

### 3.1 Drei-Schichten-Modell

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3 – Framework-Adapter                                │
│                                                             │
│  DX.HttpSys.WiRL.pas          DX.HttpSys.WebBroker.pas     │
│  TWiRLHttpSysServer            TWebBrokerHttpSysDispatcher  │
│  (implementiert IWiRLServer)   (ersetzt TWebBrokerBridge)   │
└────────────────────┬────────────────────────────────────────┘
                     │ nutzt
┌────────────────────▼────────────────────────────────────────┐
│  LAYER 2 – Server-Core (framework-agnostisch)               │
│                                                             │
│  DX.HttpSys.Server.pas                                      │
│  DX.HttpSys.Request.pas                                     │
│  DX.HttpSys.Response.pas                                    │
│  DX.HttpSys.ThreadPool.pas                                  │
│                                                             │
│  IDXHttpSysRequestHandler (das zentrale Callback-Interface) │
└────────────────────┬────────────────────────────────────────┘
                     │ wraps
┌────────────────────▼────────────────────────────────────────┐
│  LAYER 1 – Win32 API-Translation                            │
│                                                             │
│  DX.HttpSys.Api.pas                                         │
│  DX.HttpSys.Api.Types.pas                                   │
│                                                             │
│  Thin Pascal-Header für httpapi.dll v2.0                    │
│  Keine harte Linkabhängigkeit (GetProcAddress-Laden)        │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Datenfluss: Request-Lifecycle

```
  Kernel
  HTTP.sys Request Queue
        │
        │ HttpReceiveHttpRequest (blockierend)
        ▼
  TDXHttpSysReceiverThread
        │
        │ PostRequest(work item)
        ▼
  TDXHttpSysPendingQueue (thread-safe)
        │
        │ DequeueRequest
        ▼
  TDXHttpSysWorkerThread (1..N)
        │
        │ TDXHttpSysRequest befüllen
        │ TDXHttpSysResponse vorbereiten
        ▼
  IDXHttpSysRequestHandler.HandleRequest(Req, Resp)
        │ (implementiert durch den jeweiligen Framework-Adapter)
        │
        ▼
  TDXHttpSysResponse.Send
        │
        │ HttpSendHttpResponse
        ▼
  Kernel → Client
```

---

## 4. Layer 1: DX.HttpSys.Api

### 4.1 Ziel

Saubere, typsichere Pascal-Deklarationen für die `httpapi.dll v2.0` WinAPI. Alle Funktionen werden via `GetProcAddress` zur Laufzeit geladen – kein harter Import-Link. Die Unit kompiliert auch auf Nicht-Windows-Plattformen (die Funktionspointer sind dann `nil`); ein Laufzeitfehler tritt erst bei `TDXHttpSysApi.Load` auf.

### 4.2 Kerntypen und -strukturen

```
HTTP_VERSION (Major=2, Minor=0 für V2)
HTTP_SERVER_SESSION_ID (UInt64)
HTTP_URL_GROUP_ID (UInt64)
HTTP_REQUEST_ID (UInt64)
HTTP_URL_CONTEXT (UInt64)
HTTP_SERVER_PROPERTY (Enum)

HTTP_REQUEST          – eingehender Request (CookedUrl, Headers, Entity)
HTTP_RESPONSE         – ausgehender Response (StatusCode, Headers, Body)
HTTP_DATA_CHUNK       – Body-Payload (Inline, FileHandle, Fragment)
HTTP_COOKED_URL       – vorgeparste URL (pFullUrl, pHost, pAbsPath, pQueryString)
HTTP_KNOWN_HEADER     – Standardheader per Enum-Index
HTTP_UNKNOWN_HEADER   – Custom-Header (Name + Value als PCSTR)
```

### 4.3 Funktionspointer-Record

```pascal
TDXHttpSysApi = record
  Initialize, Terminate,
  CreateServerSession, CloseServerSession,
  CreateUrlGroup, CloseUrlGroup,
  AddUrlToUrlGroup, RemoveUrlFromUrlGroup,
  CreateRequestQueue,
  SetUrlGroupProperty,
  ReceiveHttpRequest,
  ReceiveRequestEntityBody,
  SendHttpResponse: {function pointer types};

  class function  Load: Boolean; static;
  class procedure CheckResult(AResult: ULONG; const AContext: string); static;
end;
```

`CheckResult` wirft bei `ERROR_SUCCESS = 0` nichts, sonst eine `EDXHttpSysError` mit Win32-Fehlermeldung und Kontext-String.

### 4.4 Wichtige Designentscheidungen

- **CookedUrl statt RawUrl**: `HTTP_REQUEST.CookedUrl` ist immer zu bevorzugen. `pRawUrl` ist ausschließlich für Logging/Tracking gedacht und darf nicht für Routing verwendet werden.
- **Puffergröße**: Mindestens 4 KB für den primären Request-Buffer. Bei Authentication-Headers werden bis zu 16 KB empfohlen. Der Default-Wert ist konfigurierbar.
- **`HTTPAPI_VERSION`**: Explizit `{2, 0}` übergeben. V1 (`{1, 0}`) unterstützt keine Server Sessions und URL Groups.

---

## 5. Layer 2: DX.HttpSys.Server (Core)

### 5.1 Öffentliche Schnittstellen

#### IDXHttpSysRequestHandler

Das einzige Interface, das Framework-Adapter implementieren müssen:

```pascal
IDXHttpSysRequestHandler = interface
  ['{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}']
  procedure HandleRequest(
    const ARequest:  TDXHttpSysRequest;
    const AResponse: TDXHttpSysResponse);
end;
```

#### TDXHttpSysServer

```pascal
TDXHttpSysServer = class
  // Konfiguration (vor Start setzen)
  property QueueLength:   Cardinal;   // Default: 1000
  property ThreadCount:   Integer;    // Default: Max(2, CPUCount * 2)
  property ServerHeader:  string;     // Default: 'DX.HttpSys/1.0'
  property Handler:       IDXHttpSysRequestHandler;
  property OnError:       TOnHttpSysError;

  // URL-Management – der einzige Bind-Mechanismus (es gibt keine Port-Property)
  procedure AddUrlPrefix(const APrefix: string; AContext: HTTP_URL_CONTEXT = 0);
  procedure RemoveUrlPrefix(const APrefix: string);
  procedure ClearUrlPrefixes;
  class function BuildPrefix(AScheme: TDXScheme; const AHost: string;
    APort: Word; const APath: string): string;   // formatiert nur, bindet nicht

  // Lifecycle
  procedure Start;
  procedure Stop;
  property  Active: Boolean;
end;
```

**URL-Prefix-Formate:**
- `http://+:8080/` – alle Netzwerkinterfaces (erfordert URL-ACL oder Admin-Rechte)
- `http://localhost:8080/` – nur loopback (keine erhöhten Rechte nötig)
- `https://+:443/myapi/` – TLS, Zertifikat via `netsh http add sslcert` vorab binden

`AddUrlPrefix` nimmt ein **vollständiges** Präfix und prüft es sofort (Beginn mit `http://`/`https://`, nicht-leerer Host, abschließendes `/`). Da der Pfad Teil des Präfixes ist, können sich mehrere Server – auch in verschiedenen Prozessen – einen Port teilen; HTTP.sys routet nach dem längsten passenden Präfix. Schlägt das Binden mit „Zugriff verweigert“ fehl, nennt die Fehlermeldung das Präfix und das einmalig auszuführende `netsh http add urlacl`-Kommando (siehe `DECISIONS.md` A-20).

### 5.2 TDXHttpSysRequest

Lazy-Loading der Body-Daten: `HttpReceiveRequestEntityBody` wird erst beim ersten Zugriff auf `Body` aufgerufen.

```pascal
TDXHttpSysRequest = class
  property Method:       string;
  property Url:          string;         // aus CookedUrl.pFullUrl
  property Path:         string;         // aus CookedUrl.pAbsPath
  property QueryString:  string;         // aus CookedUrl.pQueryString
  property Host:         string;         // aus CookedUrl.pHost
  property Headers:      TDXHttpHeaders; // KnownHeaders + UnknownHeaders
  property Body:         TStream;        // lazy-loaded
  property ContentLength: Int64;
  property RemoteIP:     string;
  property RequestId:    HTTP_REQUEST_ID;  // intern für Response benötigt
  property UrlContext:   HTTP_URL_CONTEXT; // Routing-Hint vom UrlGroup-Setup
  property ProtocolVersion: THTTP_VERSION; // 1.0 / 1.1 / 2.0 (HTTP/2) / 3.0 (HTTP/3)
end;
```

`ProtocolVersion` wird aus den HTTP.sys-Request-Flags (`HTTP_REQUEST_FLAG_HTTP3`/`_HTTP2`, maßgeblich) bzw. der Version der Request-Zeile abgeleitet. HTTP.sys handelt HTTP/2 auf TLS-Listenern per ALPN standardmäßig aus (Windows 10 / Server 2016+), auf reinen `http`-Listenern bleibt es bei HTTP/1.x.

### 5.3 TDXHttpSysResponse

```pascal
TDXHttpSysResponse = class
  property StatusCode:    Word;           // Default: 200
  property ReasonPhrase:  string;
  property Headers:       TDXHttpHeaders;
  property Body:          TStream;        // oder direkt SetBody(const AText: string)

  procedure SetBody(const AText: string; const AContentType: string = 'text/plain; charset=utf-8');
  procedure Send;     // ruft HttpSendHttpResponse; darf nur einmal aufgerufen werden
  property  Sent: Boolean;

  // Streaming (z. B. Server-Sent Events) – Abschnitt 5.3.1
  procedure BeginStream;                          // Header ohne Content-Length
  function  SendChunk(const AData: TBytes): Boolean;  // False = Stream vorbei
  procedure EndStream;
  property  Streaming: Boolean;
  property  Cancelled: Boolean;                   // True beim Herunterfahren
  property  ProtocolVersion: THTTP_VERSION;       // Protokoll des beantworteten Requests
end;
```

#### 5.3.1 Streaming und Protokollversionen (HTTP/2)

`BeginStream`/`SendChunk`/`EndStream` liefern langlebige Antworten ohne `Content-Length` (z. B. `text/event-stream`). Das Body-Framing richtet sich nach `ProtocolVersion` des Requests; Handler-Code ist für alle Fälle identisch:

| Protokoll | Framing | Header | Stream-Ende |
|---|---|---|---|
| HTTP/1.1 | `Transfer-Encoding: chunked`, Chunk-Framing schreibt DX.HttpSys selbst (HTTP.sys framt nicht) | `Transfer-Encoding: chunked` | Terminal-Chunk `0\r\n\r\n` |
| HTTP/2, HTTP/3 | Daten unverändert an HTTP.sys (erzeugt die DATA-Frames) | kein `Transfer-Encoding`, keine verbindungsspezifischen Header | leerer Send mit `DISCONNECT` (beendet den Stream, nicht die Verbindung) |
| HTTP/1.0 | Close-delimited | kein `Transfer-Encoding`, `Connection: close` | leerer Send mit `DISCONNECT` |

Header, die das Protokoll des Clients verbietet, werden beim Senden verworfen: `Connection`, `Keep-Alive`, `Proxy-Connection`, `Transfer-Encoding`, `Upgrade` bei HTTP/2+ (RFC 9113 §8.2.2), `Transfer-Encoding` bei HTTP/1.0. `SendChunk` liefert `False`, wenn der Client die Verbindung getrennt hat oder der Server herunterfährt; echte Sendefehler lösen `EDXHttpSysError` aus. Ein vom Handler begonnener, aber nicht beendeter Stream wird vom Worker abgeschlossen. Jeder Stream belegt einen Worker-Thread für seine gesamte Dauer. HTTP/2 lässt sich bei Bedarf je TLS-Bindung (`netsh http add sslcert … disablehttp2=enable`) oder global (`EnableHttp2Tls = 0`) abschalten. Details und Begründung: `DECISIONS.md` A-21; der Live-Check über echtes HTTP/2 (erhöhte Rechte nötig): `tests-integration/Http2StreamingCheck.ps1`.

### 5.4 Threading-Modell

```
TDXHttpSysServer
  └── TDXHttpSysWorkerPool
        ├── TDXHttpSysReceiverThread   (1x, blockierender HttpReceiveHttpRequest-Loop)
        │     │  PostRequest → TDXHttpSysPendingQueue
        └── TDXHttpSysWorkerThread[]   (N×, konfigurierbar, default: Max(2, CPUCount*2))
              └── Dequeue → IDXHttpSysRequestHandler.HandleRequest
```

**Warum dieser Ansatz:**  
HTTP.sys legt Requests in eine Kernel-Queue. Ein einzelner Receiver-Thread kann diese effizient per blockierendem API-Call leeren und die Arbeit an Worker-Threads weitergeben. Das vermeidet Busy-Waiting und nutzt den Kernel-Queue-Vorteil vollständig aus.

**Fehlerbehandlung in Worker-Threads:**  
Unbehandelte Exceptions führen zu einem `500 Internal Server Error`-Response, werden geloggt (via `OnError`-Callback) und lassen den Worker-Thread weiterlaufen. Ein abgestürzter Worker-Thread wird neu gestartet.

---

## 6. Layer 3a: DX.HttpSys.WiRL

### 6.1 Ziel

Minimaler Adapter, der `TDXHttpSysServer` als `IWiRLServer` exponiert. WiRL sieht keine HTTP.sys-spezifischen Details.

### 6.2 Komponenten

**`TDXToWiRLHandlerBridge`** – implementiert `IDXHttpSysRequestHandler`:
- Übersetzt `TDXHttpSysRequest` → `TWiRLRequest`
- Übersetzt `TDXHttpSysResponse` → `TWiRLResponse`
- Ruft `IWiRLListener.HandleRequest` auf
- Überträgt den WiRL-Response zurück auf `TDXHttpSysResponse`

**`TWiRLHttpSysServer`** – implementiert `IWiRLServer`:
- Hält intern eine `TDXHttpSysServer`-Instanz
- Delegiert alle `IWiRLServer`-Properties an den Core

**Self-Registration:**
```pascal
initialization
  TWiRLServerRegistry.Instance.RegisterServer<TWiRLHttpSysServer>('HttpSys');
```

### 6.3 Verwendung (Anwendungsseite)

```pascal
uses
  DX.HttpSys.WiRL,          // statt WiRL.http.Server.Indy
  WiRL.http.Server,
  WiRL.Core.Engine,
  WiRL.Core.Application;

procedure TForm1.StartServer;
begin
  FServer := TWiRLServer.Create(nil);
  FServer.ServerPort := 8080;
  // ... WiRL-Engine-Konfiguration ...
  FServer.Active := True;
end;
```

Ein Austausch von Indy gegen HTTP.sys reduziert sich auf den Austausch einer `uses`-Zeile.

---

## 7. Layer 3b: DX.HttpSys.WebBroker

### 7.1 Ziel

WebBroker verwendet einen anderen Dispatching-Mechanismus (WebModule, `DispatchAction`). Der Adapter erzeugt `TWebRequest`/`TWebResponse`-Subklassen, die intern auf `TDXHttpSysRequest`/`TDXHttpSysResponse` delegieren.

### 7.2 Komponenten

**`TDXHttpSysWebRequest`** – erbt von `TWebRequest`:
- Überschreibt alle abstrakten Getter/Setter
- Delegiert an die gekapselte `TDXHttpSysRequest`-Instanz

**`TDXHttpSysWebResponse`** – erbt von `TWebResponse`:
- Delegiert `Send` an `TDXHttpSysResponse.Send`

**`TWebBrokerHttpSysDispatcher`** – implementiert `IDXHttpSysRequestHandler`:
- Erzeugt `TDXHttpSysWebRequest`/`TDXHttpSysWebResponse`-Paare
- Ruft `WebReq.DispatchAction(WebRequest, WebResponse)` auf

---

## 8. Paketstruktur

> Hinweis: Das Projekt folgt den globalen Delphi-Projektregeln (Kleinschreibung
> `src/`, `demo/`, `tests/`, `build/`, `build-scripts/`, `libs/`). Package-Dateien
> liegen in `src/`, der Build-Output ausschließlich unter `build/`.

```
DX.HttpSys/
├── README.md                                 ← Projekt-Übersicht (EN)
├── README.de.md                              ← Projekt-Übersicht (DE)
├── LICENSE                                    ← MIT
├── CLAUDE.md / delphi.md                      ← Agenten-/Coding-Regeln
├── .gitattributes / .gitignore                ← Delphi-Standard (CRLF, Output-Ignores)
├── DX.HttpSys.groupproj                       ← Projektgruppe (Packages + Tests)
├── docs/
│   ├── PRD.md                                ← dieses Dokument
│   ├── DECISIONS.md                          ← Architektur-/Prozessentscheidungen (A-1 …)
│   └── Delphi Style Guide EN.md
├── src/
│   ├── DX.HttpSys.Core.dpk / .dproj          ← Core-Package (kein Framework-Dep, RTL only)
│   ├── DX.HttpSys.WiRL.dpk / .dproj          ← WiRL-Adapter-Package
│   ├── DX.HttpSys.WebBroker.dpk / .dproj     ← WebBroker-Adapter-Package
│   ├── DX.HttpSys.Horse.dpk / .dproj         ← Horse-Adapter-Package
│   ├── Core/
│   │   ├── DX.HttpSys.Api.Types.pas          ← HTTP_* Records, Enums, Constants
│   │   ├── DX.HttpSys.Api.pas                ← httpapi.dll Wrapper (GetProcAddress)
│   │   ├── DX.HttpSys.Request.pas            ← TDXHttpSysRequest
│   │   ├── DX.HttpSys.Response.pas           ← TDXHttpSysResponse
│   │   ├── DX.HttpSys.ThreadPool.pas         ← Receiver + Worker Threads
│   │   └── DX.HttpSys.Server.pas             ← TDXHttpSysServer (öffentliche API)
│   └── Adapters/
│       ├── DX.HttpSys.WiRL.pas               ← WiRL-Adapter (WiRL-4.x-Release-API)
│       ├── DX.HttpSys.WiRL.REST.pas          ← WiRL-Adapter (master-API)
│       ├── DX.HttpSys.WebBroker.pas          ← WebBroker-Adapter
│       └── DX.HttpSys.Horse.pas              ← Horse-Provider (über dem WebBroker-Dispatcher)
├── tests/
│   ├── DX.HttpSys.Tests.dpr / .dproj         ← DUnitX-Console-Runner
│   └── Test.DX.HttpSys.*.pas                 ← Api, Server, Url, WebBroker, Stress, Soak, Streaming
├── tests-integration/                          ← optionale Tests mit Fremd-Frameworks (WiRL, Horse)
│   └── Http2StreamingCheck.ps1               ← HTTP/2-Live-Check (erhöhte Rechte)
├── demo/                                       ← Demos (teilen sich Port 80 über Pfadpräfixe)
│   ├── 01.StandaloneServer/                  ← Layer 2 direkt, kein Framework
│   ├── 02.WiRL/                              ← WiRL + DX.HttpSys
│   ├── 03.WebBroker/                         ← WebBroker + DX.HttpSys
│   ├── 04.Horse/                             ← Horse + DX.HttpSys
│   └── 07.Sse/                               ← Server-Sent Events (Streaming)
├── libs/
│   └── DUnitX/                                ← Test-Framework (Git-Submodul)
├── build-scripts/
│   └── DelphiBuildDPROJ.ps1
└── build/                                      ← Build-Output (git-ignoriert)
    └── $(Platform)/$(Config)/[dcu]
```

---

## 9. Nicht-funktionale Anforderungen

### 9.1 Plattform

- **Zielplattform:** Windows (32-bit und 64-bit), Delphi 11.3+
- **UI-Framework-neutral:** Der Core hängt an keinem GUI-Framework und ist damit in jeder Windows-Anwendungsart einsetzbar – Console, Windows-Service, **VCL** und **FMX**. Bei klassischen „headless" Server-Anwendungen spielt das eine untergeordnete Rolle, ermöglicht aber z. B. einen eingebetteten HTTP.sys-Server direkt in einer VCL- oder FMX-Desktop-Anwendung.
- **Nur Windows:** Die Core-Units sind reiner Windows-Code. Die ursprünglich vorgesehenen `{$IFDEF MSWINDOWS}`-Guards für eine Compilierbarkeit auf Nicht-Windows-Zielen wurden bewusst entfernt (`DECISIONS.md` A-1).
- **Keine externen Abhängigkeiten** im Core (httpapi.dll ist Bestandteil von Windows).

### 9.2 Threading

- Thread-Safety: `TDXHttpSysServer` ist nach `Start` thread-safe für lesende Property-Zugriffe.
- `TDXHttpSysRequest` und `TDXHttpSysResponse` sind **nicht** thread-safe und dürfen nur im zugehörigen Worker-Thread verwendet werden.

### 9.3 URL-ACL-Hinweise (Dokumentationspflicht)

Die `+`-Wildcard-Notation (`http://+:80/`) erfordert entweder Administrator-Rechte oder eine vorab registrierte URL-ACL:

```cmd
netsh http add urlacl url=http://+:8080/ user=DOMAIN\Username
```

Für reine `localhost`-URLs (`http://localhost:8080/`) sind keine erhöhten Rechte erforderlich. Dies muss in der README prominent dokumentiert sein.

### 9.4 Server-Header

HTTP.sys setzt standardmäßig `Microsoft-HTTPAPI/2.0` als `Server`-Header. Eigene Werte werden vorangestellt. `TDXHttpSysServer` exponiert `property ServerHeader: string` um das zu konfigurieren (Default: `DX.HttpSys/1.0`).

### 9.5 Performance (Kernziel „hoch-performant")

Die Bibliothek soll den Performancevorteil des Kernel-Stacks möglichst verlustfrei weiterreichen. Der Eigen-Overhead des Cores gegenüber einem rohen `HttpReceiveHttpRequest`/`HttpSendHttpResponse`-Zyklus soll vernachlässigbar bleiben.

- **Zero-/Low-Copy:** Request-/Response-Bodies werden ohne unnötige Pufferkopien verarbeitet; vorhandene HTTP.sys-Strukturen werden direkt überlagert statt umkopiert.
- **Thread-Pool:** Konfigurierbarer Worker-Pool (`ThreadCount`, Default `Max(2, CPUCount * 2)`), keine Thread-Erzeugung pro Request.
- **Keep-Alive:** Nutzung des Kernel-Level-Connection-Cachings von HTTP.sys.
- **Messbare Zielwerte:** Reproduzierbare Benchmarks (z. B. `wrk`/`bombardier`) als Teil der CI; Richtwert: Durchsatz und p99-Latenz auf dem Niveau von `THttpApiServer` (mORMot) bzw. TMS Sparkle, da alle denselben Kernel-Stack nutzen. Regressionen gegenüber der Baseline lassen den Benchmark-Lauf fehlschlagen.

### 9.6 Stabilität & Qualitätssicherung (Kernziel „100 % stabil")

Stabilität ist explizites Primärziel. Die Implementierung muss unter Dauer- und Hochlast frei von Leaks, Races und Abstürzen sein. Abgesichert wird das durch eine **sehr hohe Testabdeckung** auf mehreren Ebenen:

- **Unit-Tests (DUnitX):** Vollständige Abdeckung der API-Translation (Layer 1), des Request-/Response-Parsings und der Core-Zustandsautomaten. Zielmarke: hohe Zeilen-/Zweigabdeckung der öffentlichen und kritischen internen Pfade.
- **Integrationstests:** End-to-End über echte HTTP.sys-Sockets gegen einen real laufenden `TDXHttpSysServer` (GET/POST/PUT, große Bodies, Chunked, Header-Edge-Cases, fehlerhafte Requests, Timeouts, Client-Abbruch mitten im Response).
- **Concurrency-/Last-/Stresstests („Hämmern"):** Viele tausend gleichzeitige Verbindungen und Requests über längere Laufzeit, die den Server bewusst sättigen. Geprüft wird auf: stabile Antwortzeiten, keine verlorenen/vermischten Responses, korrektes Verhalten bei Pool-Erschöpfung und Backpressure. Werkzeuge z. B. `wrk`, `bombardier`, `h2load` sowie ein Delphi-seitiger paralleler Client-Harness.
- **Soak-/Longevity-Tests:** Mehrstündiger Dauerbetrieb unter Last zum Nachweis konstanten Speicher- und Handle-Verbrauchs (keine Leaks, keine Handle-Akkumulation).
- **Leak-/Ressourcen-Prüfung:** `ReportMemoryLeaksOnShutdown`, FastMM-Vollprüfung sowie Handle-Zählung vor/nach Testläufen; jeder Leak gilt als Testfehler.
- **CI-Gate:** Unit-, Integrations- und ein (verkürzter) Stresstestlauf sind verpflichtender Bestandteil der CI-Pipeline; ein roter Lauf blockiert das Merge.

---

## 10. Implementierungs-Roadmap

### Milestone 1 – API Foundation
- [x] `DX.HttpSys.Api.Types.pas` – alle WinAPI-Strukturen
- [x] `DX.HttpSys.Api.pas` – GetProcAddress-Loader + CheckResult
- [x] Minimaler Smoke-Test (httpapi.dll laden, Version abfragen)

### Milestone 2 – Core Server (Single-Threaded)
- [x] `DX.HttpSys.Request.pas`
- [x] `DX.HttpSys.Response.pas`
- [x] `DX.HttpSys.Server.pas` (synchron, ohne ThreadPool)
- [x] Demo 01: Hello-World GET-Response

### Milestone 3 – Threading
- [x] `DX.HttpSys.ThreadPool.pas`
- [x] Integration in `TDXHttpSysServer`
- [ ] Load-Test mit Artillery / wrk

### Milestone 4 – WiRL-Adapter
- [x] `DX.HttpSys.WiRL.pas`
- [x] Demo 02: WiRL REST-Resource via HTTP.sys

### Milestone 5 – WebBroker-Adapter
- [x] `DX.HttpSys.WebBroker.pas`
- [x] Demo 03: WebBroker-WebModule via HTTP.sys

### Milestone 6 – Test-Suite & Härtung (Stabilitätsnachweis)
- [x] DUnitX-Unit-Tests (Layer 1 + Core) mit hoher Abdeckung
- [x] Integrationstests gegen real laufenden `TDXHttpSysServer`
- [x] Concurrency-/Stress-Harness („Hämmern" mit vielen parallelen Requests)
- [x] Soak-Test + Leak-/Handle-Prüfung (FastMM)
- [ ] Performance-Baseline (`wrk`/`bombardier`) als CI-Gate

### Milestone 7 – Packaging & Dokumentation
- [x] Delphi-Packages (.dproj)
- [x] README mit netsh-Anleitung
- [x] XML-Inline-Dokumentation aller öffentlichen Symbole

### Milestone 8 – Horse-Adapter
- [x] `DX.HttpSys.Horse.pas` (Provider über dem WebBroker-Dispatcher), Demo 04

### Milestone 9 – Bind-API für gemeinsame Ports
- [x] `AddUrlPrefix` als einziger, geprüfter Bind-Mechanismus; Demos teilen sich Port 80 über Pfadpräfixe

### Milestone 10 – Streaming & HTTP/2
- [x] `BeginStream`/`SendChunk`/`EndStream` (SSE), Demo 07
- [x] Protokollbewusstes Framing (`ProtocolVersion`, HTTP/1.1 chunked, HTTP/2+ durch HTTP.sys, HTTP/1.0 close-delimited)
- [ ] HTTP/2-Wire-Check (`tests-integration/Http2StreamingCheck.ps1`, erhöhte Rechte) auf einem Rechner mit Administratorrechten durchführen (benötigt eine TLS-Bindung; bisher nicht Teil der CI)

---

## 11. Offene Fragen / Entscheidungen

| # | Frage | Tendenz |
|---|---|---|
| 1 | Lizenz: MIT oder MPL 2.0? | MIT (maximale Kompatibilität) |
| 2 | GitHub-Repo: unter `omonien` oder neuer Org? | `omonien/DX.HttpSys` |
| 3 | HTTP/2-Support via HTTP.sys v2? | Entschieden: HTTP.sys handelt HTTP/2 auf TLS-Listenern selbst aus (Win10/Server 2016+); die Bibliothek passt Streaming-Framing und Header je Protokoll an (Abschnitt 5.3.1, `DECISIONS.md` A-21). HTTP/3 wird mitgeführt, ist aber nicht getestet |
| 4 | SSL-Zertifikat-Management-API (netsh-Wrapper)? | Optional, separates Package |
| 5 | Horse-Adapter (3. Adapter nach WiRL + WebBroker)? | Umgesetzt (Milestone 8) |

---

*Ende des PRD*
