/// <summary>
///   DX.HttpSys.WiRL — WiRL server engine backed by the kernel HTTP.sys listener,
///   for the WiRL 4.x RELEASE API (two-argument IWiRLListener, WiRL.Core.Engine).
/// </summary>
/// <remarks>
///   Registers itself with the WiRL server registry under the name 'HttpSys', so
///   an application swaps the Indy engine for HTTP.sys by selecting this vendor:
///
///     uses DX.HttpSys.WiRL;
///     ...
///     FServer := TWiRLServer.Create(nil);
///     FServer.Port := 8080;
///     FServer.ServerVendor := 'HttpSys';   // select this engine
///     FServer.Active := True;
///
///   For the WiRL master branch (three-argument IWiRLListener with TWiRLContext,
///   WiRL.Engine.REST) use DX.HttpSys.WiRL.REST instead. See docs/DECISIONS.md
///   (A-10) and the optional integration tests under tests-integration/.
///
///   WiRL is an external dependency that is intentionally NOT vendored here; this
///   unit only compiles where WiRL is on the library path. Verified against WiRL
///   v4.6.0 via the integration-test harness.
///
///   Structure mirrors WiRL.http.Server.Indy:
///     TWiRLHttpRequestHttpSys  : TWiRLRequest  over TDXHttpSysRequest
///     TWiRLHttpResponseHttpSys : TWiRLResponse over TDXHttpSysResponse
///     TWiRLHttpSysServer       : IWiRLServer holding a TDXHttpSysServer
///     TDXToWiRLBridge          : IDXHttpSysRequestHandler -> IWiRLListener
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.WiRL;

interface

uses
  System.SysUtils,
  System.Classes,
  // WiRL (4.x release API)
  WiRL.http.Core,
  WiRL.http.Cookie,
  WiRL.http.Headers,
  WiRL.http.Request,
  WiRL.http.Response,
  WiRL.http.Server.Interfaces,
  WiRL.http.Server,      // TWiRLServer.Engines — read each engine's BasePath
  WiRL.Core.Engine,      // TWiRLCustomEngine.BasePath
  // DX.HttpSys Core
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  // ---------------------------------------------------------------------------
  // TWiRLHttpRequestHttpSys — TWiRLRequest over a TDXHttpSysRequest
  // ---------------------------------------------------------------------------

  TWiRLHttpRequestHttpSys = class(TWiRLRequest)
  private
    FDXRequest: TDXHttpSysRequest;  // reference, not owned
    FHeaders:   IWiRLHeaders;
    FQueryFields:   TWiRLParam;
    FContentFields: TWiRLParam;
    FCookieFields:  TWiRLCookies;
  protected
    function GetHttpPathInfo: string; override;
    function GetHttpQuery: string; override;
    function GetRemoteIP: string; override;
    function GetServerPort: Integer; override;
    function GetHeaders: IWiRLHeaders; override;
    function GetQueryFields: TWiRLParam; override;
    function GetContentFields: TWiRLParam; override;
    function GetCookieFields: TWiRLCookies; override;
    function GetContentStream: TStream; override;
    procedure SetContentStream(const Value: TStream); override;
  public
    constructor Create(ADXRequest: TDXHttpSysRequest);
    destructor Destroy; override;
  end;

  // ---------------------------------------------------------------------------
  // TWiRLHttpResponseHttpSys — TWiRLResponse over a TDXHttpSysResponse
  // ---------------------------------------------------------------------------

  TWiRLHttpResponseHttpSys = class(TWiRLResponse)
  private
    FDXResponse:    TDXHttpSysResponse;  // reference, not owned
    FHeaders:       IWiRLHeaders;
    FStatusCode:    Integer;
    FReason:        string;
    FContentStream: TStream;
  protected
    function GetContentStream: TStream; override;
    procedure SetContentStream(const Value: TStream); override;
    function GetStatusCode: Integer; override;
    procedure SetStatusCode(const Value: Integer); override;
    function GetReasonString: string; override;
    procedure SetReasonString(const Value: string); override;
    function GetHeaders: IWiRLHeaders; override;
  public
    constructor Create(ADXResponse: TDXHttpSysResponse);
    destructor Destroy; override;

    procedure SendHeaders; override;

    // Flushes status, headers and the content stream onto the DX.HttpSys
    // response and sends it. Called by the bridge after the listener returns.
    procedure Flush;
  end;

  // ---------------------------------------------------------------------------
  // TDXToWiRLBridge — IDXHttpSysRequestHandler that drives the WiRL listener
  // ---------------------------------------------------------------------------

  TDXToWiRLBridge = class(TInterfacedObject, IDXHttpSysRequestHandler)
  private
    FListener: IWiRLListener;
  public
    constructor Create(const AListener: IWiRLListener);
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

  // ---------------------------------------------------------------------------
  // TWiRLHttpSysServer — IWiRLServer backed by TDXHttpSysServer
  // ---------------------------------------------------------------------------

  TWiRLHttpSysServer = class(TInterfacedObject, IWiRLServer)
  private
    FServer:         TDXHttpSysServer;  // owned
    FBridge:         IDXHttpSysRequestHandler;
    FListener:       IWiRLListener;
    FPort:           Word;
    FThreadPoolSize: Integer;
    FHost:           string;
    FScheme:         TDXScheme;
  public
    constructor Create;
    destructor Destroy; override;

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

    // The host/scheme the HTTP.sys prefix binds on; the path comes from each
    // WiRL engine's BasePath. Defaults: 'localhost' + Http (admin-free). Set
    // before Active := True to bind '+' / an IP, or https. The port is WiRL's
    // own TWiRLServer.Port (mirrored into FPort via SetPort).
    property Host:   string    read FHost   write FHost;
    property Scheme: TDXScheme read FScheme write FScheme;
  end;

implementation

uses
  WiRL.http.Accept.MediaType;

// Extracts the port from a Host header, IPv6-aware. Returns 80 when absent.
// Examples: "host:8080" -> 8080; "[::1]:8080" -> 8080; "host" / "[::1]" -> 80.
function PortFromHost(const AHost: string): Integer;
var
  LSep: Integer; // 0-based index of the ':' that precedes the port, or -1
begin
  if AHost.StartsWith('[') then
  begin
    LSep := AHost.IndexOf(']:');
    if LSep >= 0 then
      Inc(LSep); // move from ']' to the following ':'
  end
  else if AHost.CountChar(':') = 1 then
    LSep := AHost.IndexOf(':')
  else
    LSep := -1; // bare IPv6 (multiple colons, no brackets) or no port at all
  if LSep >= 0 then
    Result := StrToIntDef(AHost.Substring(LSep + 1), 80)
  else
    Result := 80;
end;

// -----------------------------------------------------------------------------
// TWiRLHttpRequestHttpSys
// -----------------------------------------------------------------------------

constructor TWiRLHttpRequestHttpSys.Create(ADXRequest: TDXHttpSysRequest);
begin
  inherited Create;
  FDXRequest := ADXRequest;
  FMethod := FDXRequest.Method;
end;

destructor TWiRLHttpRequestHttpSys.Destroy;
begin
  FQueryFields.Free;
  FContentFields.Free;
  FCookieFields.Free;
  inherited;
end;

function TWiRLHttpRequestHttpSys.GetHttpPathInfo: string;
begin
  Result := FDXRequest.Path;
end;

function TWiRLHttpRequestHttpSys.GetHttpQuery: string;
begin
  Result := FDXRequest.QueryString;
end;

function TWiRLHttpRequestHttpSys.GetRemoteIP: string;
begin
  Result := FDXRequest.RemoteIP;
end;

function TWiRLHttpRequestHttpSys.GetServerPort: Integer;
begin
  // HTTP.sys doesn't surface the port in the parsed request; derive it from the
  // Host header. Handle bracketed IPv6 ("[::1]:8080") by looking for "]:" first;
  // otherwise a single ':' separates an IPv4/host name from its port.
  Result := PortFromHost(FDXRequest.Host);
end;

function TWiRLHttpRequestHttpSys.GetHeaders: IWiRLHeaders;
begin
  if not Assigned(FHeaders) then
  begin
    FHeaders := TWiRLHeaders.Create;
    FDXRequest.Headers.EnumHeaders(
      procedure(AName, AValue: string)
      begin
        FHeaders.AddHeader(TWiRLHeader.Create(AName, AValue));
      end);
  end;
  Result := FHeaders;
end;

function TWiRLHttpRequestHttpSys.GetQueryFields: TWiRLParam;
begin
  if not Assigned(FQueryFields) then
  begin
    FQueryFields := TWiRLParam.Create;
    FQueryFields.Delimiter := '&';
    FQueryFields.DelimitedText := FDXRequest.QueryString;
  end;
  Result := FQueryFields;
end;

function TWiRLHttpRequestHttpSys.GetContentFields: TWiRLParam;
begin
  if not Assigned(FContentFields) then
    FContentFields := TWiRLParam.Create;
  Result := FContentFields;
end;

function TWiRLHttpRequestHttpSys.GetCookieFields: TWiRLCookies;
begin
  if not Assigned(FCookieFields) then
    FCookieFields := TWiRLCookies.Create;
  Result := FCookieFields;
end;

function TWiRLHttpRequestHttpSys.GetContentStream: TStream;
begin
  Result := FDXRequest.Body; // may be nil for empty bodies
end;

procedure TWiRLHttpRequestHttpSys.SetContentStream(const Value: TStream);
begin
  // The request body is owned by the DX.HttpSys request; setting is a no-op.
end;

// -----------------------------------------------------------------------------
// TWiRLHttpResponseHttpSys
// -----------------------------------------------------------------------------

constructor TWiRLHttpResponseHttpSys.Create(ADXResponse: TDXHttpSysResponse);
begin
  inherited Create;
  FDXResponse := ADXResponse;
  FHeaders := TWiRLHeaders.Create;
  FStatusCode := 200;
  FContentStream := TMemoryStream.Create;
end;

destructor TWiRLHttpResponseHttpSys.Destroy;
begin
  // This response owns its content stream (like the Indy adapter, which hands
  // ownership to Indy via FreeContentStream := True). Nothing else frees it.
  FreeAndNil(FContentStream);
  inherited;
end;

function TWiRLHttpResponseHttpSys.GetContentStream: TStream;
begin
  Result := FContentStream;
end;

procedure TWiRLHttpResponseHttpSys.SetContentStream(const Value: TStream);
begin
  // Take over the stream WiRL sets, freeing the one we created. We keep
  // ownership so the destructor releases it — WiRL does not free it for us.
  if FContentStream <> Value then
    FreeAndNil(FContentStream);
  FContentStream := Value;
end;

function TWiRLHttpResponseHttpSys.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

procedure TWiRLHttpResponseHttpSys.SetStatusCode(const Value: Integer);
begin
  FStatusCode := Value;
end;

function TWiRLHttpResponseHttpSys.GetReasonString: string;
begin
  Result := FReason;
end;

procedure TWiRLHttpResponseHttpSys.SetReasonString(const Value: string);
begin
  FReason := Value;
end;

function TWiRLHttpResponseHttpSys.GetHeaders: IWiRLHeaders;
begin
  Result := FHeaders;
end;

procedure TWiRLHttpResponseHttpSys.SendHeaders;
begin
  inherited;
  // Headers are flushed onto the DX.HttpSys response in Flush, after the
  // listener has finished. Nothing immediate is required for a buffered engine.
end;

procedure TWiRLHttpResponseHttpSys.Flush;
var
  LHeader: TWiRLHeader;
begin
  FDXResponse.StatusCode := FStatusCode;
  if FReason <> '' then
    FDXResponse.ReasonPhrase := FReason;

  // Copy WiRL headers onto the DX.HttpSys response.
  for LHeader in FHeaders do
    FDXResponse.Headers[LHeader.Name] := LHeader.Value;

  if ContentType <> '' then
    FDXResponse.Headers['content-type'] := ContentType;

  // Copy the response body.
  if Assigned(FContentStream) and (FContentStream.Size > 0) then
  begin
    FContentStream.Position := 0;
    FDXResponse.Body.Clear;
    FDXResponse.Body.CopyFrom(FContentStream, 0);
  end;

  FDXResponse.Send;
end;

// -----------------------------------------------------------------------------
// TDXToWiRLBridge
// -----------------------------------------------------------------------------

constructor TDXToWiRLBridge.Create(const AListener: IWiRLListener);
begin
  inherited Create;
  FListener := AListener;
end;

procedure TDXToWiRLBridge.HandleRequest(const ARequest: TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
var
  LRequest:  TWiRLHttpRequestHttpSys;
  LResponse: TWiRLHttpResponseHttpSys;
begin
  // WiRL 4.x: IWiRLListener.HandleRequest takes (request, response) — no context.
  LRequest := TWiRLHttpRequestHttpSys.Create(ARequest);
  try
    LResponse := TWiRLHttpResponseHttpSys.Create(AResponse);
    try
      if LResponse.Server = '' then
        LResponse.Server := 'WiRL Server (DX.HttpSys)';

      FListener.HandleRequest(LRequest, LResponse);

      // The listener filled the WiRL response; push it to HTTP.sys.
      if not AResponse.Sent then
        LResponse.Flush;
    finally
      LResponse.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

// -----------------------------------------------------------------------------
// TWiRLHttpSysServer
// -----------------------------------------------------------------------------

constructor TWiRLHttpSysServer.Create;
begin
  inherited Create;
  FPort := 8080;
  FThreadPoolSize := 0; // 0 => Core default (CPUCount * 2)
  FHost := 'localhost'; // admin-free default; set to '+' / an IP for a wildcard bind
  FScheme := TDXScheme.Http;
  FServer := TDXHttpSysServer.Create;
end;

destructor TWiRLHttpSysServer.Destroy;
begin
  FServer.Free;
  inherited;
end;

procedure TWiRLHttpSysServer.Startup;
var
  LServer: TWiRLServer;
  LEngine: TWiRLCustomEngine;
begin
  if not Assigned(FListener) then
    raise Exception.Create('[DX.HttpSys.WiRL] Listener must be set before Startup');

  FBridge := TDXToWiRLBridge.Create(FListener);
  FServer.Handler := FBridge;
  if FThreadPoolSize > 0 then
    FServer.ThreadCount := FThreadPoolSize;

  // One HTTP.sys prefix per WiRL engine: the engine's BasePath is the single
  // source of truth for the path; scheme/host/port come from this adapter. The
  // listener IS the TWiRLServer (engines are started before our Startup).
  LServer := FListener as TWiRLServer;
  for LEngine in LServer.Engines do
    FServer.AddUrlPrefix(
      TDXHttpSysServer.BuildPrefix(FScheme, FHost, FPort, LEngine.BasePath));

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
  Result := FThreadPoolSize;
end;

procedure TWiRLHttpSysServer.SetThreadPoolSize(AValue: Integer);
begin
  FThreadPoolSize := AValue;
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
  Result := FServer; // power users can configure QueueLength / extra prefixes
end;

initialization
  // Make this engine selectable by name, exactly like the Indy engine.
  TWiRLServerRegistry.Instance.RegisterServer<TWiRLHttpSysServer>('HttpSys');

end.
