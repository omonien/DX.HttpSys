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
///   Server.Port := 8080;
///   Server.Handler := TMyHandler.Create; // implements IDXHttpSysRequestHandler
///   Server.AddUrlPrefix('http://localhost:8080/');
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

type
  TDXUrlPrefix = record
    Prefix:  string;
    Context: HTTP_URL_CONTEXT;
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysServer
  // ---------------------------------------------------------------------------

  TDXHttpSysServer = class
  private
    FApi:             TDXHttpSysApi;
    FSessionId:       HTTP_SERVER_SESSION_ID;
    FUrlGroupId:      HTTP_URL_GROUP_ID;
    FReqQueueHandle:  THandle;
    FWorkerPool:      TDXHttpSysWorkerPool;
    FHandler:         IDXHttpSysRequestHandler;
    FUrlPrefixes:     TList<TDXUrlPrefix>;

    FPort:            Word;
    FQueueLength:     Cardinal;
    FThreadCount:     Integer;
    FServerHeader:    string;
    FActive:          Boolean;
    FOnError:         TOnHttpSysError;

    procedure CheckNotActive(const AProperty: string);
    procedure SetupUrlGroup;
    procedure TeardownUrlGroup;
    procedure SetPort(AValue: Word);
    procedure SetQueueLength(AValue: Cardinal);
    procedure SetThreadCount(AValue: Integer);
    procedure SetServerHeader(const AValue: string);
    procedure SetHandler(const AValue: IDXHttpSysRequestHandler);
  public
    constructor Create;
    destructor  Destroy; override;

    // --- Configuration (set before Start) ---

    // Listening port (default: 8080)
    // Only used for automatic prefix generation by UseLocalhost /
    // UseAllInterfaces when AddUrlPrefix is not called explicitly.
    property Port:         Word     read FPort         write SetPort;

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

    // Adds a URL prefix.
    // Examples:
    //   'http://+:8080/'         – all interfaces (requires admin/urlacl)
    //   'http://localhost:8080/' – loopback only (no elevated rights)
    //   'https://+:443/myapi/'   – TLS (bind certificate via netsh beforehand)
    procedure AddUrlPrefix(const APrefix: string; AContext: HTTP_URL_CONTEXT = 0);
    procedure RemoveUrlPrefix(const APrefix: string);
    procedure ClearUrlPrefixes;

    // Convenience: adds 'http://localhost:<Port>/'
    procedure UseLocalhost;

    // Convenience: adds 'http://+:<Port>/' (requires elevated rights)
    procedure UseAllInterfaces;

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
  FPort         := 8080;
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

procedure TDXHttpSysServer.SetPort(AValue: Word);
begin
  CheckNotActive('Port');
  FPort := AValue;
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
  Item: TDXUrlPrefix;
begin
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

procedure TDXHttpSysServer.UseLocalhost;
begin
  AddUrlPrefix(Format('http://localhost:%d/', [FPort]));
end;

procedure TDXHttpSysServer.UseAllInterfaces;
begin
  AddUrlPrefix(Format('http://+:%d/', [FPort]));
end;

// --- SetupUrlGroup / TeardownUrlGroup ---

procedure TDXHttpSysServer.SetupUrlGroup;
var
  BindingInfo: HTTP_BINDING_INFO;
  Item:        TDXUrlPrefix;
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

  // Register URL prefixes
  for Item in FUrlPrefixes do
    TDXHttpSysApi.CheckResult(
      FApi.AddUrlToUrlGroup(FUrlGroupId, PWideChar(Item.Prefix), Item.Context, 0),
      'AddUrlToUrlGroup: ' + Item.Prefix);
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
      FApi, FReqQueueHandle, FThreadCount, FHandler);
    FWorkerPool.OnError := FOnError;
    FWorkerPool.ServerHeader := FServerHeader;
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
