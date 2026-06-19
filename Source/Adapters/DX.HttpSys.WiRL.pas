// =============================================================================
// DX.HttpSys.WiRL.pas
// WiRL-Adapter für DX.HttpSys
//
// Implementiert IWiRLServer via TDXHttpSysServer.
// Registriert sich selbst beim WiRL-Server-Registry mit dem Namen 'HttpSys'.
//
// Verwendung (Anwendungsseite):
//
//   uses
//     DX.HttpSys.WiRL,        // <-- statt WiRL.http.Server.Indy
//     WiRL.http.Server,
//     WiRL.Core.Engine,
//     WiRL.Core.Application;
//
//   FServer := TWiRLServer.Create(nil);
//   FServer.ServerPort := 8080;
//   // ... WiRL-Engine-Konfiguration wie gewohnt ...
//   FServer.Active := True;
//
// KEIN weiterer Konfigurationsaufwand – Drop-in-Replacement für Indy.
//
// (c) Developer Experts LLC – MIT License
// =============================================================================

unit DX.HttpSys.WiRL;

{$IFDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  // WiRL
  WiRL.http.Server.Interfaces,
  WiRL.http.Request,
  WiRL.http.Response,
  // DX.HttpSys Core
  DX.HttpSys.Api.Types,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  // ---------------------------------------------------------------------------
  // TDXToWiRLHandlerBridge
  // Übersetzt DX.HttpSys-Request/Response ↔ WiRL-Request/Response
  // ---------------------------------------------------------------------------

  TDXToWiRLHandlerBridge = class(TInterfacedObject, IDXHttpSysRequestHandler)
  private
    FListener: IWiRLListener;

    // Erzeugt einen TWiRLRequest aus TDXHttpSysRequest
    function  CreateWiRLRequest(ADXRequest: TDXHttpSysRequest): TWiRLRequest;

    // Erzeugt einen TWiRLResponse aus TDXHttpSysResponse
    function  CreateWiRLResponse(ADXResponse: TDXHttpSysResponse): TWiRLResponse;

    // Überträgt WiRL-Response-Daten zurück auf TDXHttpSysResponse
    procedure SyncResponseBack(
      AWiRLResponse: TWiRLResponse;
      ADXResponse:   TDXHttpSysResponse);
  public
    constructor Create(AListener: IWiRLListener);

    { IDXHttpSysRequestHandler }
    procedure HandleRequest(
      const ARequest:  TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

  // ---------------------------------------------------------------------------
  // TWiRLHttpSysServer
  // Implementiert IWiRLServer – das einzige Interface, das WiRL sieht
  // ---------------------------------------------------------------------------

  TWiRLHttpSysServer = class(TInterfacedObject, IWiRLServer)
  private
    FServer:        TDXHttpSysServer;   // owned
    FBridge:        TDXToWiRLHandlerBridge;
    FListener:      IWiRLListener;
    FPort:          Word;
    FThreadCount:   Integer;
  public
    constructor Create;
    destructor  Destroy; override;

    { IWiRLServer }
    procedure Startup;
    procedure Shutdown;

    function  GetPort: Word;
    procedure SetPort(AValue: Word);

    function  GetThreadPoolSize: Integer;
    procedure SetThreadPoolSize(AValue: Integer);

    function  GetListener: IWiRLListener;
    procedure SetListener(AValue: IWiRLListener);

    function  GetServerImplementation: TObject;
  end;

implementation

uses
  System.Net.HttpClient; // für Header-Konstanten falls benötigt

// -----------------------------------------------------------------------------
// TDXToWiRLHandlerBridge
// -----------------------------------------------------------------------------

constructor TDXToWiRLHandlerBridge.Create(AListener: IWiRLListener);
begin
  inherited Create;
  FListener := AListener;
end;

function TDXToWiRLHandlerBridge.CreateWiRLRequest(
  ADXRequest: TDXHttpSysRequest): TWiRLRequest;
begin
  // TODO: Konkrete TWiRLRequest-Subklasse erzeugen
  // WiRL erwartet eine Framework-spezifische Subklasse von TWiRLRequest.
  // Die genaue Implementierung hängt von der WiRL-Interna ab:
  //   - Entweder eine eigene TDXHttpSysWiRLRequest-Klasse ableiten
  //   - Oder die interne WiRL-Mechanik für Request-Injection nutzen
  // Placeholder – wird in Milestone 4 vollständig implementiert.
  Result := nil; // TODO
end;

function TDXToWiRLHandlerBridge.CreateWiRLResponse(
  ADXResponse: TDXHttpSysResponse): TWiRLResponse;
begin
  // TODO: Analog zu CreateWiRLRequest
  // Placeholder – wird in Milestone 4 vollständig implementiert.
  Result := nil; // TODO
end;

procedure TDXToWiRLHandlerBridge.SyncResponseBack(
  AWiRLResponse: TWiRLResponse;
  ADXResponse:   TDXHttpSysResponse);
begin
  // TODO: WiRL-Response-Daten (StatusCode, Headers, Body) auf
  // ADXResponse übertragen, bevor Send() aufgerufen wird.
  // Placeholder – wird in Milestone 4 vollständig implementiert.
end;

procedure TDXToWiRLHandlerBridge.HandleRequest(
  const ARequest:  TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
var
  WiRLReq:  TWiRLRequest;
  WiRLResp: TWiRLResponse;
begin
  WiRLReq  := nil;
  WiRLResp := nil;
  try
    WiRLReq  := CreateWiRLRequest(ARequest);
    WiRLResp := CreateWiRLResponse(AResponse);

    // WiRL-Dispatcher aufrufen
    FListener.HandleRequest(WiRLReq, WiRLResp);

    // Response zurückübertragen
    SyncResponseBack(WiRLResp, AResponse);
  finally
    WiRLReq.Free;
    WiRLResp.Free;
  end;
end;

// -----------------------------------------------------------------------------
// TWiRLHttpSysServer
// -----------------------------------------------------------------------------

constructor TWiRLHttpSysServer.Create;
begin
  inherited;
  FPort        := 8080;
  FThreadCount := 0; // 0 = Default (CPUCount * 2) in TDXHttpSysServer
  FServer      := TDXHttpSysServer.Create;
end;

destructor TWiRLHttpSysServer.Destroy;
begin
  FServer.Free;
  // FBridge: Interfaced, kein manuelles Free
  inherited;
end;

procedure TWiRLHttpSysServer.Startup;
begin
  if not Assigned(FListener) then
    raise Exception.Create('[DX.HttpSys.WiRL] Listener muss vor Startup gesetzt sein');

  // Bridge erzeugen
  FBridge := TDXToWiRLHandlerBridge.Create(FListener);

  // Server konfigurieren
  FServer.Port    := FPort;
  FServer.Handler := FBridge;
  if FThreadCount > 0 then
    FServer.ThreadCount := FThreadCount;

  // Default-Prefix: localhost (ohne Admin-Rechte nutzbar)
  // Für '+'-Prefix: FServer.UseAllInterfaces aufrufen (erfordert Admin/urlacl)
  FServer.UseLocalhost;

  FServer.Start;
end;

procedure TWiRLHttpSysServer.Shutdown;
begin
  FServer.Stop;
  FBridge := nil;
end;

function TWiRLHttpSysServer.GetPort: Word;
begin
  Result := FPort;
end;

procedure TWiRLHttpSysServer.SetPort(AValue: Word);
begin
  FPort := AValue;
end;

function TWiRLHttpSysServer.GetThreadPoolSize: Integer;
begin
  Result := FThreadCount;
end;

procedure TWiRLHttpSysServer.SetThreadPoolSize(AValue: Integer);
begin
  FThreadCount := AValue;
end;

function TWiRLHttpSysServer.GetListener: IWiRLListener;
begin
  Result := FListener;
end;

procedure TWiRLHttpSysServer.SetListener(AValue: IWiRLListener);
begin
  FListener := AValue;
end;

function TWiRLHttpSysServer.GetServerImplementation: TObject;
begin
  // Power-User können über diesen Weg direkt auf TDXHttpSysServer zugreifen,
  // z.B. um QueueLength oder weitere Prefixes zu konfigurieren.
  Result := FServer;
end;

// -----------------------------------------------------------------------------
// Self-Registration – identisch zum WiRL.http.Server.Indy-Pattern
// Einfach diese Unit in die Uses-Klausel aufnehmen, fertig.
// -----------------------------------------------------------------------------

initialization
  TWiRLServerRegistry.Instance.RegisterServer<TWiRLHttpSysServer>('HttpSys');

{$ENDIF MSWINDOWS}

end.
