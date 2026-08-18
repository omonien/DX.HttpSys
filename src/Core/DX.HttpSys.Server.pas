/// <summary>
///   DX.HttpSys.Server — public API of the DX.HttpSys core layer, wrapping the
///   Windows HTTP Server API (HTTP.sys) behind the <c>TDXHttpSysServer</c> class.
/// </summary>
/// <remarks>
///   The server owns the HTTP.sys session, URL group, request queue and worker
///   pool, and dispatches incoming requests to an <c>IDXHttpSysRequestHandler</c>.
///   Usage example (direct use without a framework):
///   <code>
///   var
///     Server: TDXHttpSysServer;
///
///   Server := TDXHttpSysServer.Create;
///   Server.Handler := TMyHandler.Create; // implements IDXHttpSysRequestHandler
///   Server.AddUrlPrefix('http://localhost:8080/'); // the single bind mechanism
///   Server.Start;
///   // ...
///   Server.Stop;
///   Server.Free;
///   </code>
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>

unit DX.HttpSys.Server;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool;

{$SCOPEDENUMS ON}
type
  /// <summary>
  ///   URL scheme for a bind prefix. Shared by the Core and the adapters so a
  ///   single type expresses <c>http</c> vs <c>https</c>. (A <c>Https</c> bind
  ///   additionally needs a kernel-delegated certificate registered separately
  ///   via <c>netsh http add sslcert</c> — standard HTTP.sys; the server only
  ///   emits the scheme text into the prefix.)
  /// </summary>
  TDXScheme = (Http, Https);
{$SCOPEDENUMS OFF}

  TDXUrlPrefix = record
    Prefix:  string;
    Context: HTTP_URL_CONTEXT;
  end;

  /// <summary>
  ///   The public face of the engine: a kernel-mode HTTP.sys server. Configure
  ///   the worker count and URL prefixes, assign an
  ///   <see cref="IDXHttpSysRequestHandler"/>, then call <c>Start</c>.
  /// </summary>
  /// <remarks>
  ///   Configuration properties may only be changed while the server is stopped.
  ///   After <c>Start</c> the server is thread-safe for reading properties; each
  ///   request is handled on a worker thread.
  ///
  ///   <c>AddUrlPrefix</c> is the single, explicit way to configure where the
  ///   server binds — it takes a complete URL such as
  ///   <c>'http://localhost:80/api/'</c> or <c>'https://+:1223/api/'</c>. There is
  ///   no separate <c>Port</c> property and no hidden host translation: the URL
  ///   says everything. Use <see cref="BuildPrefix"/> to assemble a complete URL
  ///   from scheme/host/port/path parts (e.g. from an adapter), then pass the
  ///   result to <c>AddUrlPrefix</c>.
  /// </remarks>
  TDXHttpSysServer = class
  private
    FApi:             TDXHttpSysApi;
    FSessionId:       HTTP_SERVER_SESSION_ID;
    FUrlGroupId:      HTTP_URL_GROUP_ID;
    FReqQueueHandle:  THandle;
    FWorkerPool:      TDXHttpSysWorkerPool;
    FHandler:         IDXHttpSysRequestHandler;
    FUrlPrefixes:     TList<TDXUrlPrefix>;

    FQueueLength:     Cardinal;
    FThreadCount:     Integer;
    FServerHeader:    string;
    FActive:          Boolean;
    FOnError:         TOnHttpSysError;

    procedure CheckNotActive(const AProperty: string);
    procedure SetupUrlGroup;
    procedure TeardownUrlGroup;
    procedure SetQueueLength(AValue: Cardinal);
    procedure SetThreadCount(AValue: Integer);
    procedure SetServerHeader(const AValue: string);
    procedure SetHandler(const AValue: IDXHttpSysRequestHandler);
  public
    constructor Create;
    destructor  Destroy; override;

    // --- Configuration (set before Start) ---

    // Length of the kernel request queue (default: 1000).
    // Configure before Start; takes effect on the next Start. (Live application
    // while active arrives in Phase 2 — see docs/DECISIONS.md A-3.)
    property QueueLength:  Cardinal read FQueueLength   write SetQueueLength;

    // Number of worker threads (default: System.CPUCount * 2)
    property ThreadCount:  Integer  read FThreadCount   write SetThreadCount;

    // Server header value (default: 'DX.HttpSys/1.0')
    // HTTP.sys automatically appends ' Microsoft-HTTPAPI/2.0'
    property ServerHeader: string   read FServerHeader  write SetServerHeader;

    // The handler interface – must be set before Start
    property Handler:      IDXHttpSysRequestHandler
                                    read FHandler       write SetHandler;

    // Optional error callback for logging
    property OnError:      TOnHttpSysError
                                    read FOnError       write FOnError;

    // --- URL management ---

    // The single, explicit bind mechanism. Takes a COMPLETE prefix, validated at
    // call time: it must start with 'http://' or 'https://' and end with '/'
    // (HTTP.sys requires the trailing slash). An invalid shape raises
    // EDXHttpSysError here, not a cryptic Win32 error at Start.
    // Examples:
    //   'http://+:8080/'         – all interfaces (requires admin/urlacl)
    //   'http://localhost:8080/' – loopback only (no elevated rights)
    //   'https://+:443/myapi/'   – TLS (bind certificate via netsh beforehand)
    procedure AddUrlPrefix(const APrefix: string; AContext: HTTP_URL_CONTEXT = 0);
    procedure RemoveUrlPrefix(const APrefix: string);
    procedure ClearUrlPrefixes;

    // Formats a complete HTTP.sys prefix from its parts (the shared host/scheme
    // translation used by adapters). It only builds the string; binding still
    // goes through AddUrlPrefix. Rules:
    //   scheme   – TDXScheme.Http/Https → 'http'/'https'
    //   host     – '0.0.0.0' / empty → '+' (wildcard, needs urlacl/admin);
    //              'localhost' / '127.0.0.1' → 'localhost' (loopback, no rights);
    //              any other host used verbatim
    //   path     – normalised to a single leading and trailing '/'
    // Example: BuildPrefix(Http, 'localhost', 80, '/rest') = 'http://localhost:80/rest/'
    class function BuildPrefix(AScheme: TDXScheme; const AHost: string;
      APort: Word; const APath: string): string; static;

    // Formats the actionable message shown when a bind fails with
    // ERROR_ACCESS_DENIED: it names the exact prefix and the one-time netsh
    // reservation command to run as Administrator. Exposed as a seam so the test
    // can assert the message shape without an actual privileged-port bind.
    class function FormatAccessDeniedMessage(const APrefix: string;
      AErrorCode: Cardinal): string; static;

    // --- Lifecycle ---

    procedure Start;
    procedure Stop;

    property Active: Boolean read FActive;

    // Direct access to the internal TDXHttpSysApi record (for power users)
    function GetServerImplementation: TObject;
  end;

implementation

uses
  System.Math;

// -----------------------------------------------------------------------------
// TDXHttpSysServer
// -----------------------------------------------------------------------------

constructor TDXHttpSysServer.Create;
begin
  inherited;
  FQueueLength  := 1000;
  FThreadCount  := Max(2, System.CPUCount * 2);
  FServerHeader := 'DX.HttpSys/1.0';
  FActive       := False;
  FUrlPrefixes  := TList<TDXUrlPrefix>.Create;
  FReqQueueHandle := INVALID_HANDLE_VALUE;
end;

destructor TDXHttpSysServer.Destroy;
begin
  if FActive then
    Stop;
  FreeAndNil(FUrlPrefixes);
  inherited;
end;

procedure TDXHttpSysServer.CheckNotActive(const AProperty: string);
begin
  if FActive then
    raise EDXHttpSysError.CreateWin32(0,
      Format('Property "%s" can only be changed before Start', [AProperty]));
end;

procedure TDXHttpSysServer.SetThreadCount(AValue: Integer);
begin
  CheckNotActive('ThreadCount');
  // The worker pool sizes its queue and spawns threads from this count, so a
  // zero/negative value would leave the server unable to process requests.
  if AValue < 1 then
    raise EDXHttpSysError.CreateWin32(0, 'ThreadCount must be at least 1');
  FThreadCount := AValue;
end;

procedure TDXHttpSysServer.SetServerHeader(const AValue: string);
begin
  CheckNotActive('ServerHeader');
  FServerHeader := AValue;
end;

procedure TDXHttpSysServer.SetHandler(const AValue: IDXHttpSysRequestHandler);
begin
  CheckNotActive('Handler');
  FHandler := AValue;
end;

// --- URL management ---

procedure TDXHttpSysServer.AddUrlPrefix(
  const APrefix: string;
  AContext:      HTTP_URL_CONTEXT);
var
  Item:      TDXUrlPrefix;
  LHostPart: Integer; // index just past '://'
begin
  // Validate the one true bind mechanism so it isn't a raw-string trap: a clear
  // error here beats a cryptic Win32 error at Start.
  if APrefix.StartsWith('http://', True) then
    LHostPart := Length('http://')
  else if APrefix.StartsWith('https://', True) then
    LHostPart := Length('https://')
  else
    raise EDXHttpSysError.CreateWin32(0,
      Format('Invalid URL prefix "%s": must start with "http://" or "https://"', [APrefix]));

  // Require a non-empty host after the scheme: 'http:///x/' and 'http://:80/x/'
  // pass the scheme+slash checks but would still fail cryptically at Start.
  if (Length(APrefix) <= LHostPart) or
     CharInSet(APrefix[LHostPart + 1], ['/', ':']) then  // string is 1-based
    raise EDXHttpSysError.CreateWin32(0,
      Format('Invalid URL prefix "%s": missing host after the scheme', [APrefix]));

  if not APrefix.EndsWith('/') then
    raise EDXHttpSysError.CreateWin32(0,
      Format('Invalid URL prefix "%s": must end with "/" (HTTP.sys requires the trailing slash)',
        [APrefix]));

  Item.Prefix  := APrefix;
  Item.Context := AContext;
  FUrlPrefixes.Add(Item);

  // If the server is already active: register immediately
  if FActive and (FUrlGroupId <> 0) then
    TDXHttpSysApi.CheckResult(
      FApi.AddUrlToUrlGroup(FUrlGroupId, PWideChar(APrefix), AContext, 0),
      'AddUrlToUrlGroup: ' + APrefix);
end;

procedure TDXHttpSysServer.RemoveUrlPrefix(const APrefix: string);
var
  I: Integer;
begin
  for I := FUrlPrefixes.Count - 1 downto 0 do
    if FUrlPrefixes[I].Prefix = APrefix then
      FUrlPrefixes.Delete(I);

  if FActive and (FUrlGroupId <> 0) then
    FApi.RemoveUrlFromUrlGroup(FUrlGroupId, PWideChar(APrefix), 0);
end;

procedure TDXHttpSysServer.ClearUrlPrefixes;
begin
  FUrlPrefixes.Clear;
end;

class function TDXHttpSysServer.BuildPrefix(AScheme: TDXScheme;
  const AHost: string; APort: Word; const APath: string): string;
var
  LScheme: string;
  LHost:   string;
  LPath:   string;
begin
  case AScheme of
    TDXScheme.Https: LScheme := 'https';
  else
    LScheme := 'http';
  end;

  // Host translation: wildcard for 0.0.0.0/empty, loopback for localhost/127.0.0.1,
  // anything else verbatim. Wildcard ('+') needs a urlacl / admin; loopback does not.
  if (AHost = '') or SameText(AHost, '0.0.0.0') then
    LHost := '+'
  else if SameText(AHost, 'localhost') or SameText(AHost, '127.0.0.1') then
    LHost := 'localhost'
  else
    LHost := AHost;

  // Normalise the path to exactly one leading and one trailing '/'.
  LPath := APath.Trim(['/']);
  if LPath = '' then
    LPath := '/'
  else
    LPath := '/' + LPath + '/';

  Result := Format('%s://%s:%d%s', [LScheme, LHost, APort, LPath]);
end;

class function TDXHttpSysServer.FormatAccessDeniedMessage(
  const APrefix: string; AErrorCode: Cardinal): string;
var
  LDomain: string;
  LUser:   string;
  LWho:    string;
begin
  // Build a "DOMAIN\User" hint from the environment; fall back to a placeholder
  // when the variables are absent (e.g. a service account without USERDOMAIN).
  LDomain := GetEnvironmentVariable('USERDOMAIN');
  LUser   := GetEnvironmentVariable('USERNAME');
  if LUser = '' then
    LWho := '<DOMAIN\User>'
  else if LDomain <> '' then
    LWho := LDomain + '\' + LUser
  else
    LWho := LUser;

  Result := Format(
    '[DX.HttpSys] Cannot bind ''%s'' – access denied (Win32 Error %d).'#13#10 +
    'This URL needs a one-time reservation. Run as Administrator:'#13#10 +
    '  netsh http add urlacl url=%s user=%s',
    [APrefix, AErrorCode, APrefix, LWho]);
end;

// --- SetupUrlGroup / TeardownUrlGroup ---

procedure TDXHttpSysServer.SetupUrlGroup;
var
  BindingInfo: HTTP_BINDING_INFO;
  Item:        TDXUrlPrefix;
  LResult:     ULONG;
begin
  // Server session
  TDXHttpSysApi.CheckResult(
    FApi.CreateServerSession(HTTPAPI_VERSION_2, FSessionId, 0),
    'CreateServerSession');

  // URL group
  TDXHttpSysApi.CheckResult(
    FApi.CreateUrlGroup(FSessionId, FUrlGroupId, 0),
    'CreateUrlGroup');

  // Request queue
  TDXHttpSysApi.CheckResult(
    FApi.CreateRequestQueue(
      HTTPAPI_VERSION_2,
      nil,     // no named queue
      nil,     // default security
      0,
      FReqQueueHandle),
    'CreateRequestQueue');

  // Apply the queue length to the request-queue handle (a request-queue
  // property, set via HttpSetRequestQueueProperty — not the URL group).
  if Assigned(FApi.SetRequestQueueProperty) then
    TDXHttpSysApi.CheckResult(
      FApi.SetRequestQueueProperty(
        FReqQueueHandle,
        HttpServerQueueLengthProperty,
        @FQueueLength,
        SizeOf(FQueueLength),
        0,
        nil),
      'SetRequestQueueProperty (QueueLength)');

  // Bind URL group to request queue
  FillChar(BindingInfo, SizeOf(BindingInfo), 0);
  BindingInfo.Flags              := HTTP_PROPERTY_FLAG_PRESENT;
  BindingInfo.RequestQueueHandle := FReqQueueHandle;
  TDXHttpSysApi.CheckResult(
    FApi.SetUrlGroupProperty(
      FUrlGroupId,
      HttpServerBindingProperty,
      @BindingInfo,
      SizeOf(BindingInfo)),
    'SetUrlGroupProperty (Binding)');

  // Register URL prefixes. On ERROR_ACCESS_DENIED raise an actionable error that
  // names the exact prefix and the netsh reservation command; other codes keep
  // the generic CheckResult message (no netsh noise).
  for Item in FUrlPrefixes do
  begin
    LResult := FApi.AddUrlToUrlGroup(FUrlGroupId, PWideChar(Item.Prefix), Item.Context, 0);
    if LResult = ERROR_ACCESS_DENIED then
      // Pass AErrorCode=0 so CreateWin32 uses our message verbatim; the formatted
      // text already names "Win32 Error 5" and the netsh command.
      raise EDXHttpSysError.CreateWin32(0,
        FormatAccessDeniedMessage(Item.Prefix, LResult));
    TDXHttpSysApi.CheckResult(LResult, 'AddUrlToUrlGroup: ' + Item.Prefix);
  end;
end;

procedure TDXHttpSysServer.TeardownUrlGroup;
var
  Item: TDXUrlPrefix;
begin
  // FApi may be nil if Start failed before the API was loaded; the HTTP.sys
  // handles are then still zero, but guard explicitly so a future caller order
  // cannot dereference a nil API.
  // Remove URL prefixes
  if Assigned(FApi) and (FUrlGroupId <> 0) then
  begin
    for Item in FUrlPrefixes do
      FApi.RemoveUrlFromUrlGroup(FUrlGroupId, PWideChar(Item.Prefix), 0);

    FApi.CloseUrlGroup(FUrlGroupId);
    FUrlGroupId := 0;
  end;

  // Close request queue
  if FReqQueueHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FReqQueueHandle);
    FReqQueueHandle := INVALID_HANDLE_VALUE;
  end;

  // Close server session
  if Assigned(FApi) and (FSessionId <> 0) then
  begin
    FApi.CloseServerSession(FSessionId);
    FSessionId := 0;
  end;
end;

procedure TDXHttpSysServer.SetQueueLength(AValue: Cardinal);
begin
  // Applied to the request queue at Start via HttpSetRequestQueueProperty.
  // A live update while active is possible in principle but not exposed yet;
  // configure before Start.
  CheckNotActive('QueueLength');
  FQueueLength := AValue;
end;

// --- Lifecycle ---

procedure TDXHttpSysServer.Start;
var
  LInitialized: Boolean;
begin
  if FActive then
    Exit;

  if not Assigned(FHandler) then
    raise EDXHttpSysError.CreateWin32(0,
      'Handler must be set before Start');

  if FUrlPrefixes.Count = 0 then
    raise EDXHttpSysError.CreateWin32(0,
      'At least one URL prefix must be registered via AddUrlPrefix');

  // Load API
  FApi := TDXHttpSysApi.Create;
  if not FApi.Load then
  begin
    FreeAndNil(FApi);
    raise EDXHttpSysError.CreateWin32(GetLastError,
      'httpapi.dll could not be loaded');
  end;

  // Everything from HttpInitialize onwards is guarded, so a failure at any step
  // (including HttpInitialize itself) tears the partial startup back down.
  LInitialized := False;
  try
    TDXHttpSysApi.CheckResult(
      FApi.InitializeV2(HTTP_INITIALIZE_SERVER),
      'HttpInitialize');
    LInitialized := True;

    SetupUrlGroup;

    // Start worker pool
    FWorkerPool := TDXHttpSysWorkerPool.Create(
      FApi, FReqQueueHandle, FThreadCount, FHandler, FServerHeader);
    FWorkerPool.OnError := FOnError;
    FWorkerPool.Start;

    FActive := True;
  except
    // Tear the worker pool down FIRST: if Create/Start partly succeeded, its
    // threads use FApi and the queue handle, so they must be stopped before
    // either is released — otherwise a running worker would use freed state.
    if Assigned(FWorkerPool) then
    begin
      FWorkerPool.Stop;
      FreeAndNil(FWorkerPool);
    end;
    TeardownUrlGroup;
    if LInitialized then
      FApi.Terminate(HTTP_INITIALIZE_SERVER, nil);
    FreeAndNil(FApi);
    raise;
  end;
end;

procedure TDXHttpSysServer.Stop;
begin
  if not FActive then
    Exit;

  FActive := False;

  // Stop worker pool (receiver thread is blocked in ReceiveHttpRequest)
  // CloseHandle on the queue wakes up the blocking call
  if Assigned(FWorkerPool) then
  begin
    // Signal cooperative cancellation first: long-running handlers observe
    // Response.Cancelled and unwind before the pool waits for the workers.
    FWorkerPool.SignalShutdown;

    // Closing the queue wakes up the receiver thread
    if FReqQueueHandle <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(FReqQueueHandle);
      FReqQueueHandle := INVALID_HANDLE_VALUE;
    end;

    FWorkerPool.Stop;
    FreeAndNil(FWorkerPool);
  end;

  TeardownUrlGroup;

  if Assigned(FApi) then
  begin
    FApi.Terminate(HTTP_INITIALIZE_SERVER, nil);
    FreeAndNil(FApi);
  end;
end;

function TDXHttpSysServer.GetServerImplementation: TObject;
begin
  Result := Self;
end;

end.
