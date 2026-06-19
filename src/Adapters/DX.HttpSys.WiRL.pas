/// <summary>
///   DX.HttpSys.WiRL — WiRL server engine backed by the kernel HTTP.sys listener.
/// </summary>
/// <remarks>
///   Registers itself with the WiRL server registry under the name 'HttpSys', so
///   an application swaps the Indy engine for HTTP.sys by changing one uses line:
///
///     uses DX.HttpSys.WiRL;   // instead of WiRL.http.Server.Indy
///     ...
///     FServer := TWiRLServer.Create(nil);
///     FServer.ServerPort := 8080;
///     FServer.ServerEngine := 'HttpSys';   // select this engine
///     FServer.Active := True;
///
///   IMPORTANT — not built or tested in this repository. WiRL is an external
///   dependency that is intentionally NOT vendored here (it stays a consumer's
///   dependency, used only when someone actually wires WiRL up). This unit is
///   written against the published WiRL API (delphi-blocks/WiRL) but has not been
///   compiled against it locally; treat it as best-effort until verified on a
///   machine with WiRL installed. See docs/DECISIONS.md (A-10).
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
  // WiRL
  WiRL.http.Core,
  WiRL.http.Cookie,
  WiRL.http.Headers,
  WiRL.http.Request,
  WiRL.http.Response,
  WiRL.http.Server.Interfaces,
  WiRL.Core.Context.Server,
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
    function GetConnection: TWiRLConnection; override;
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
    FOwnsStream:    Boolean;
  protected
    function GetContentStream: TStream; override;
    procedure SetContentStream(const Value: TStream); override;
    function GetStatusCode: Integer; override;
    procedure SetStatusCode(const Value: Integer); override;
    function GetReasonString: string; override;
    procedure SetReasonString(const Value: string); override;
    function GetHeaders: IWiRLHeaders; override;
    function GetConnection: TWiRLConnection; override;
  public
    constructor Create(ADXResponse: TDXHttpSysResponse);
    destructor Destroy; override;

    procedure SendHeaders(AImmediate: Boolean); override;

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
  end;

implementation

uses
  WiRL.http.Accept.MediaType;

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
  // HTTP.sys doesn't surface the port in the parsed request; derive from Host.
  Result := StrToIntDef(Copy(FDXRequest.Host, Pos(':', FDXRequest.Host) + 1, MaxInt), 80);
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

function TWiRLHttpRequestHttpSys.GetConnection: TWiRLConnection;
begin
  // No streaming/SSE support in this engine yet; WiRL only needs this for
  // chunked responses, which the HTTP.sys engine does not implement.
  Result := nil;
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
  FOwnsStream := True;
end;

destructor TWiRLHttpResponseHttpSys.Destroy;
begin
  if FOwnsStream then
    FContentStream.Free;
  inherited;
end;

function TWiRLHttpResponseHttpSys.GetContentStream: TStream;
begin
  Result := FContentStream;
end;

procedure TWiRLHttpResponseHttpSys.SetContentStream(const Value: TStream);
begin
  if FOwnsStream then
    FContentStream.Free;
  FContentStream := Value;
  FOwnsStream := False; // WiRL owns a stream it sets explicitly
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

function TWiRLHttpResponseHttpSys.GetConnection: TWiRLConnection;
begin
  Result := nil;
end;

procedure TWiRLHttpResponseHttpSys.SendHeaders(AImmediate: Boolean);
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
  LContext:  TWiRLContext;
  LRequest:  TWiRLHttpRequestHttpSys;
  LResponse: TWiRLHttpResponseHttpSys;
begin
  LContext := TWiRLContext.Create;
  try
    LRequest  := TWiRLHttpRequestHttpSys.Create(ARequest);
    try
      LResponse := TWiRLHttpResponseHttpSys.Create(AResponse);
      try
        // The context registers these as non-owning containers
        // (ContextOwned=False), so we still free them ourselves below.
        LContext.Request := LRequest;
        LContext.Response := LResponse;

        if LResponse.Server = '' then
          LResponse.Server := 'WiRL Server (DX.HttpSys)';

        FListener.HandleRequest(LContext, LRequest, LResponse);

        // The listener filled the WiRL response; push it to HTTP.sys.
        if not AResponse.Sent then
          LResponse.Flush;
      finally
        LResponse.Free;
      end;
    finally
      LRequest.Free;
    end;
  finally
    LContext.Free;
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
  FServer := TDXHttpSysServer.Create;
end;

destructor TWiRLHttpSysServer.Destroy;
begin
  FServer.Free;
  inherited;
end;

procedure TWiRLHttpSysServer.Startup;
begin
  if not Assigned(FListener) then
    raise Exception.Create('[DX.HttpSys.WiRL] Listener must be set before Startup');

  FBridge := TDXToWiRLBridge.Create(FListener);
  FServer.Port := FPort;
  FServer.Handler := FBridge;
  if FThreadPoolSize > 0 then
    FServer.ThreadCount := FThreadPoolSize;
  FServer.UseLocalhost; // safe default; use UseAllInterfaces for http://+:port/
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
