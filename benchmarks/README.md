# M0 Benchmark-Basis

Reproduzierbare Ausgangswerte für DX.HttpSys auf Windows, bevor am Kern etwas geändert wird.
Gemessen wird HTTP/1.1 ohne TLS. Fremdcode (Horse, mORMot 2) wird nur für diese Messungen
geklont, nie eingecheckt und von keiner Kern-Unit referenziert.

## Kandidaten

| Name | Programm | Version | Konfiguration |
|---|---|---|---|
| `indy-plain` | BenchIndyPlain | Indy aus Delphi | TIdHTTPServer, KeepAlive an, ListenQueue 1024, Nagle aus, MaxConnections 0 |
| `horse2-indy-default` | BenchHorseIndy2 `--profile default` | Horse 2.0.14 | unverändert: Indy KeepAlive aus, ListenQueue 15, WebBroker MaxConnections 32 |
| `horse2-indy-tuned` | BenchHorseIndy2 `--profile tuned` | Horse 2.0.14 | ListenQueue 1024, MaxConnections 4096, KeepAlive an (siehe unten) |
| `horse33-indy-default` | BenchHorseIndy `--profile default` | Horse 3.3.16 | unverändert (3.3 schaltet KeepAlive selbst ein) |
| `horse33-indy-tuned` | BenchHorseIndy `--profile tuned` | Horse 3.3.16 | KeepConnectionAlive, ListenQueue 1024, MaxConnections 4096 |
| `dxhttpsys-plain` | BenchDXHttpSysPlain | DX.HttpSys dieses Branches | TDXHttpSysServer mit direktem Handler, ThreadCount 2 x CPU, QueueLength 1000 |
| `horse2-dxhttpsys` | BenchHorseDXHttpSys | Horse 2.0.14 + `DX.HttpSys.Horse` | heute einziger Weg für Horse auf DX.HttpSys |
| `horse33-httpsys` | BenchHorseHttpSys33 | Horse 3.3.16 | eigener HttpSys-Provider, Define `HORSE_PROVIDER_HTTPSYS`, Standardwerte |
| `mormot2-async` | BenchMormot2Async | mORMot 2.4-stable | THttpAsyncServer, Threadpool 32, Keep-Alive 30 s (Messlatte) |

Ports und Programmnamen stehen in `candidates.json` (8081 bis 8089).

Horse 2.0.14 hat keinen öffentlichen Schalter für KeepAlive, die Bridge ist eine private
Klassenvariable. Das Profil `tuned` setzt KeepAlive deshalb einmalig in einer Middleware über
den Indy-Server der aktuellen Verbindung (`TIdServerContext.Server`). Indy liest KeepAlive pro
Request, ab dem zweiten Request (also nach dem Warmup) bleiben die Verbindungen offen.

## Endpunkte

Alle Server bedienen dieselben Endpunkte; die Logik liegt in `servers/Common/Bench.Endpoints.pas`.

| Endpunkt | Antwort |
|---|---|
| `GET /plaintext` | `Hello, World!`, text/plain, 13 Byte |
| `GET /json` | `{"message":"Hello, World!"}`, pro Request mit System.JSON serialisiert |
| `GET /bytes/64k`, `GET /bytes/1m` | statischer Puffer 64 KiB bzw. 1 MiB |
| `POST /echo` | liest den Body vollständig, antwortet mit seiner Länge |

Horse-Kandidaten nutzen die für Horse übliche Form (`Res.Send(string)`, bei Horse 3 `Send(TBytes)`,
bei Horse 2 `RawWebResponse.ContentStream`), mORMot vergleicht die Pfade als RawUtf8.

## Matrix

| Eintrag | Szenario | VUs | Keep-Alive |
|---|---|---|---|
| `plaintext-ka1` | plaintext | 1, 16, 64, 256, 1024 | an |
| `plaintext-ka0` | plaintext | 16, 64, 256 | aus |
| `json-ka1` | json | 16, 64, 256, 1024 | an |
| `bytes64k-ka1`, `bytes1m-ka1` | bytes | 16, 64 | an |
| `echo16k-ka1`, `echo1m-ka1` | echo | 16, 64 | an |
| `rate-ka1` | plaintext, feste Rate 5000/s | 256 vorab | an |

Ablauf je Kandidat und Eintrag: Warmup 15 s (verworfen), 3 Läufe zu 30 s mit 10 s Pause.
Berichtet wird der Median, Min und Max der Requests pro Sekunde zeigen die Streuung.
Im lokalen Modus startet `Run-Matrix.ps1` den Server pro Wiederholung neu und rotiert die
Reihenfolge der Kandidaten.

## HTTP/1.1 erzwingen

* Bei `http://` spricht k6 ohnehin HTTP/1.1, h2c nutzt es nicht.
* Die Skripte setzen trotzdem `GODEBUG=http2client=0` für jeden k6-Prozess (wichtig für spätere TLS-Läufe).
* `k6/run.js` prüft jede Antwort auf `res.proto === 'HTTP/1.1'`; alles andere zählt als Fehler
  (`bench_errors`, `bench_proto_errors`).

## Bauen

Voraussetzung: RAD Studio 11.3 oder neuer, Win64.

```powershell
./build-scripts/FetchThirdParty.ps1 -Manifest ./benchmarks/thirdparty.manifest.json
./benchmarks/scripts/Build-Servers.ps1
```

Ausgabe: `build/benchmarks/Win64/Release`. Die `.dproj`-Dateien erwarten den Fremdcode unter
`build/thirdparty/Horse2`, `Horse3` und `mORMot2`. Horse bringt eine eigene `Web.WebConst.pas` mit,
die die RTL-Unit verdeckt; das Manifest schließt sie aus.

## Prüfen

```powershell
# Sprachmittel neuer als Delphi 11.3 und Gedankenstriche
./benchmarks/scripts/Lint-Delphi113.ps1

# DUnitX: Endpunktlogik und HTTP-Rundlauf gegen den DX.HttpSys-Handler (localhost, ohne URL-ACL)
./build/benchmarks/Win64/Release/BenchSmokeTests.exe --exitbehavior:Continue

# Alle Server starten, jeden Endpunkt über HTTP/1.1 prüfen, kurze Mini-Last auf Loopback
./benchmarks/scripts/Smoke-Servers.ps1 bindir=./build/benchmarks/Win64/Release
```

Die Mini-Last der Smoke-Tests läuft auf derselben Maschine und ist keine Messung.

## Messen

### Getrennt (Standard): Server auf Windows, k6 auf dem Lastgenerator

Einmalig auf dem Messhost, als Administrator (wird in einer Zustandsdatei protokolliert):

```powershell
./benchmarks/scripts/Setup-MeasurementHost.ps1 -User "$env:COMPUTERNAME\$env:USERNAME"
# Rücknahme: ./benchmarks/scripts/Undo-MeasurementHost.ps1
```

Das richtet URL-ACLs `http://+:8086/` bis `http://+:8088/` für die http.sys-Kandidaten, eine
Firewall-Regel für TCP 8081 bis 8089 und den Energieplan Höchstleistung ein. Defender, Registry,
Zertifikate und Neustarts bleiben unberührt.

Pro Kandidat (Teilläufe, falls ein Werkzeug wie die Forge nach 600 s abbricht):

```powershell
# Messhost
./benchmarks/scripts/Start-Server.ps1 -Candidate dxhttpsys-plain -BinDir C:\bench\bin -Seconds 560
```

```bash
# Lastgenerator (PowerShell 7 und k6 installiert)
pwsh ./benchmarks/scripts/Run-Matrix.ps1 -Mode LoadOnly -Target http://messhost:8086 \
  -Candidates dxhttpsys-plain -Entries plaintext-ka1 -OutDir results/2026-11-23_mac
```

Die Prozess-CSV des Servers anschließend in den Ergebnisordner kopieren.

### Notlösung auf einem Host

```powershell
./benchmarks/scripts/Run-Matrix.ps1 -Mode Local -BinDir ./build/benchmarks/Win64/Release
```

Ergebnisse werden als `loopback` markiert und dürfen nicht mit getrennten Läufen gemischt werden.
k6 sollte nicht über 70 Prozent CPU kommen; sonst misst man den Lastgenerator.

### Auswerten

```powershell
./benchmarks/scripts/Collect-Results.ps1 -ResultDir ./benchmarks/results/<ordner>
```

| Datei | Inhalt |
|---|---|
| `<kandidat>_<szenario>_ka<k>_<vus>_<lauf>.json` | k6-Zusammenfassung pro Lauf (handleSummary) |
| `*.meta.json` | Start und Ende des Laufs in UTC |
| `*_process*.csv` | CPU, Working Set, Threads, Handles des Servers pro Sekunde |
| `environment.json` | OS, CPU, RAM, vCPU, Energieplan, Git-Commit, k6-Version, Kandidaten |
| `summary.csv` | date, git_sha, host, mode, candidate, candidate_version, scenario, keepalive, vus, run, rps, p50_ms, p95_ms, p99_ms, max_ms, err_pct, cpu_avg_pct, rss_peak_mb, threads_peak |
| `summary_median.csv` | Median über die Läufe, dazu Min und Max der req/s |

## Hinweise

* Die Forge ist eine VM unter Parallels; ihre Werte taugen für den Vergleich der Kandidaten
  untereinander, nicht als absolute Zahlen.
* Mehr als 256 VUs ohne Keep-Alive begrenzen auf Windows TIME_WAIT und Ephemeral Ports.
* Code-Regeln: Delphi 11.3 kompatibel (keine mehrzeiligen Strings, keine bedingten Ausdrücke,
  kein `is not`, kein `NameOf`), kein Assembler.
