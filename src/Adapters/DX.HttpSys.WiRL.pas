/// <summary>
///   DX.HttpSys.WiRL — WiRL adapter that implements IWiRLServer on top of HTTP.sys via TDXHttpSysServer.
/// </summary>
/// <remarks>
///   Registers itself with the WiRL server registry under the name 'HttpSys'. It is a drop-in replacement
///   for the Indy-based WiRL server and requires no additional configuration.
///
///   Usage (application side):
///
///     uses
///       DX.HttpSys.WiRL,        // <-- instead of WiRL.http.Server.Indy
///       WiRL.http.Server,
///       WiRL.Core.Engine,
///       WiRL.Core.Application;
///
///     FServer := TWiRLServer.Create(nil);
///     FServer.ServerPort := 8080;
///     // ... WiRL engine configuration as usual ...
///     FServer.Active := True;
///
///   NO further configuration effort — a drop-in replacement for Indy.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
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
  // Translates DX.HttpSys request/response ↔ WiRL request/response
  // ---------------------------------------------------------------------------

  TDXToWiRLHandlerBridge = class(TInterfacedObject, IDXHttpSysRequestHandler)
  private
    FListener: IWiRLListener;

    // Creates a TWiRLRequest from a TDXHttpSysRequest
    function  CreateWiRLRequest(ADXRequest: TDXHttpSysRequest): TWiRLRequest;

    // Creates a TWiRLResponse from a TDXHttpSysResponse
    function  CreateWiRLResponse(ADXResponse: TDXHttpSysResponse): TWiRLResponse;

    // Transfers WiRL response data back onto the TDXHttpSysResponse
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
  // Implements IWiRLServer — the only interface that WiRL sees
  // ---------------------------------------------------------------------------

  TWiRLHttpSysServer = class(TInterfacedObject, IWiRLServer)
  private
    FServer:        TDXHttpSysServer;   // owned instance
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
  System.Net.HttpClient; // for header constants if needed

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
  // TODO: Create a concrete TWiRLRequest subclass
  // WiRL expects a framework-specific subclass of TWiRLRequest.
  // The exact implementation depends on the WiRL internals:
  //   - Either derive a dedicated TDXHttpSysWiRLRequest class
  //   - Or use the internal WiRL mechanism for request injection
  // Placeholder — to be fully implemented in milestone 4.
  Result := nil; // TODO
end;

function TDXToWiRLHandlerBridge.CreateWiRLResponse(
  ADXResponse: TDXHttpSysResponse): TWiRLResponse;
begin
  // TODO: Analogous to CreateWiRLRequest
  // Placeholder — to be fully implemented in milestone 4.
  Result := nil; // TODO
end;

procedure TDXToWiRLHandlerBridge.SyncResponseBack(
  AWiRLResponse: TWiRLResponse;
  ADXResponse:   TDXHttpSysResponse);
begin
  // TODO: Transfer WiRL response data (StatusCode, Headers, Body) onto
  // ADXResponse before Send() is called.
  // Placeholder — to be fully implemented in milestone 4.
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

    // Invoke the WiRL dispatcher
    FListener.HandleRequest(WiRLReq, WiRLResp);

    // Transfer the response back
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
  FThreadCount := 0; // 0 = default (CPUCount * 2) in TDXHttpSysServer
  FServer      := TDXHttpSysServer.Create;
end;

destructor TWiRLHttpSysServer.Destroy;
begin
  FServer.Free;
  // FBridge: interfaced, no manual Free
  inherited;
end;

procedure TWiRLHttpSysServer.Startup;
begin
  if not Assigned(FListener) then
    raise Exception.Create('[DX.HttpSys.WiRL] Listener must be set before Startup');

  // Create the bridge
  FBridge := TDXToWiRLHandlerBridge.Create(FListener);

  // Configure the server
  FServer.Port    := FPort;
  FServer.Handler := FBridge;
  if FThreadCount > 0 then
    FServer.ThreadCount := FThreadCount;

  // Default prefix: localhost (usable without admin rights)
  // For a '+' prefix: call FServer.UseAllInterfaces (requires admin/urlacl)
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
  // Power users can access TDXHttpSysServer directly via this route,
  // e.g. to configure QueueLength or additional prefixes.
  Result := FServer;
end;

// -----------------------------------------------------------------------------
// Self-registration — identical to the WiRL.http.Server.Indy pattern
// Simply add this unit to the uses clause, done.
// -----------------------------------------------------------------------------

initialization
  TWiRLServerRegistry.Instance.RegisterServer<TWiRLHttpSysServer>('HttpSys');

{$ENDIF MSWINDOWS}

end.
