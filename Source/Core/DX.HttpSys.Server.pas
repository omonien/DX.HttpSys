// =============================================================================
// DX.HttpSys.Server.pas
// TDXHttpSysServer – die öffentliche API des DX.HttpSys-Core-Layer
//
// Verwendungsbeispiel (direkter Einsatz ohne Framework):
//
//   var
//     Server: TDXHttpSysServer;
//
//   Server := TDXHttpSysServer.Create;
//   Server.Port := 8080;
//   Server.Handler := TMyHandler.Create; // implementiert IDXHttpSysRequestHandler
//   Server.AddUrlPrefix('http://localhost:8080/');
//   Server.Start;
//   // ...
//   Server.Stop;
//   Server.Free;
//
// (c) Developer Experts LLC – MIT License
// =============================================================================

unit DX.HttpSys.Server;

{$IFDEF MSWINDOWS}

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
    procedure CheckActive(const AOperation: string);
    procedure SetupUrlGroup;
    procedure TeardownUrlGroup;
    procedure SetQueueLength(AValue: Cardinal);
  public
    constructor Create;
    destructor  Destroy; override;

    // --- Konfiguration (vor Start setzen) ---

    // Listening-Port (Default: 8080)
    // Wird nur für automatische Prefix-Generierung verwendet wenn
    // AddUrlPrefix nicht explizit aufgerufen wird.
    property Port:         Word     read FPort         write FPort;

    // Länge der Kernel-Request-Queue (Default: 1000)
    property QueueLength:  Cardinal read FQueueLength   write FQueueLength;

    // Anzahl Worker-Threads (Default: System.CPUCount * 2)
    property ThreadCount:  Integer  read FThreadCount   write FThreadCount;

    // Server-Header-Wert (Default: 'DX.HttpSys/1.0')
    // HTTP.sys hängt automatisch ' Microsoft-HTTPAPI/2.0' an
    property ServerHeader: string   read FServerHeader  write FServerHeader;

    // Das Handler-Interface – muss vor Start gesetzt sein
    property Handler:      IDXHttpSysRequestHandler
                                    read FHandler       write FHandler;

    // Optionaler Error-Callback für Logging
    property OnError:      TOnHttpSysError
                                    read FOnError       write FOnError;

    // --- URL-Management ---

    // Fügt einen URL-Prefix hinzu.
    // Beispiele:
    //   'http://+:8080/'         – alle Interfaces (erfordert Admin/urlacl)
    //   'http://localhost:8080/' – nur loopback (keine erhöhten Rechte)
    //   'https://+:443/myapi/'   – TLS (Zertifikat via netsh vorab binden)
    procedure AddUrlPrefix(const APrefix: string; AContext: HTTP_URL_CONTEXT = 0);
    procedure RemoveUrlPrefix(const APrefix: string);
    procedure ClearUrlPrefixes;

    // Convenience: Fügt 'http://localhost:<Port>/' hinzu
    procedure UseLocalhost;

    // Convenience: Fügt 'http://+:<Port>/' hinzu (erfordert erhöhte Rechte)
    procedure UseAllInterfaces;

    // --- Lifecycle ---

    procedure Start;
    procedure Stop;

    property Active: Boolean read FActive;

    // Direktzugriff auf den internen TDXHttpSysApi-Record (für Power-User)
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
  FUrlPrefixes.Free;
  inherited;
end;

procedure TDXHttpSysServer.CheckNotActive(const AProperty: string);
begin
  if FActive then
    raise EDXHttpSysError.CreateWin32(0,
      Format('Eigenschaft "%s" kann nur vor Start geändert werden', [AProperty]));
end;

procedure TDXHttpSysServer.CheckActive(const AOperation: string);
begin
  if not FActive then
    raise EDXHttpSysError.CreateWin32(0,
      Format('Operation "%s" erfordert einen aktiven Server', [AOperation]));
end;

// --- URL-Management ---

procedure TDXHttpSysServer.AddUrlPrefix(
  const APrefix: string;
  AContext:      HTTP_URL_CONTEXT);
var
  Item: TDXUrlPrefix;
begin
  Item.Prefix  := APrefix;
  Item.Context := AContext;
  FUrlPrefixes.Add(Item);

  // Wenn der Server bereits aktiv ist: sofort registrieren
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
  // Server Session
  TDXHttpSysApi.CheckResult(
    FApi.CreateServerSession(HTTPAPI_VERSION_2, FSessionId, 0),
    'CreateServerSession');

  // URL Group
  TDXHttpSysApi.CheckResult(
    FApi.CreateUrlGroup(FSessionId, FUrlGroupId, 0),
    'CreateUrlGroup');

  // Request Queue
  TDXHttpSysApi.CheckResult(
    FApi.CreateRequestQueue(
      HTTPAPI_VERSION_2,
      nil,     // kein benannter Queue
      nil,     // default Security
      0,
      FReqQueueHandle),
    'CreateRequestQueue');

  // Queue-Länge setzen
  SetQueueLength(FQueueLength);

  // URL Group an Request Queue binden
  FillChar(BindingInfo, SizeOf(BindingInfo), 0);
  BindingInfo.Flags              := 1; // HTTP_PROPERTY_FLAG_PRESENT
  BindingInfo.RequestQueueHandle := FReqQueueHandle;
  TDXHttpSysApi.CheckResult(
    FApi.SetUrlGroupProperty(
      FUrlGroupId,
      HttpServerBindingProperty,
      @BindingInfo,
      SizeOf(BindingInfo)),
    'SetUrlGroupProperty (Binding)');

  // URL-Prefixes registrieren
  for Item in FUrlPrefixes do
    TDXHttpSysApi.CheckResult(
      FApi.AddUrlToUrlGroup(FUrlGroupId, PWideChar(Item.Prefix), Item.Context, 0),
      'AddUrlToUrlGroup: ' + Item.Prefix);
end;

procedure TDXHttpSysServer.TeardownUrlGroup;
var
  Item: TDXUrlPrefix;
begin
  // URL-Prefixes entfernen
  if FUrlGroupId <> 0 then
  begin
    for Item in FUrlPrefixes do
      FApi.RemoveUrlFromUrlGroup(FUrlGroupId, PWideChar(Item.Prefix), 0);

    FApi.CloseUrlGroup(FUrlGroupId);
    FUrlGroupId := 0;
  end;

  // Request Queue schließen
  if FReqQueueHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FReqQueueHandle);
    FReqQueueHandle := INVALID_HANDLE_VALUE;
  end;

  // Server Session schließen
  if FSessionId <> 0 then
  begin
    FApi.CloseServerSession(FSessionId);
    FSessionId := 0;
  end;
end;

procedure TDXHttpSysServer.SetQueueLength(AValue: Cardinal);
begin
  FQueueLength := AValue;
  if FActive and (FUrlGroupId <> 0) then
    FApi.SetUrlGroupProperty(
      FUrlGroupId,
      HttpServerQueueLengthProperty,
      @FQueueLength,
      SizeOf(FQueueLength));
end;

// --- Lifecycle ---

procedure TDXHttpSysServer.Start;
begin
  if FActive then
    Exit;

  if not Assigned(FHandler) then
    raise EDXHttpSysError.CreateWin32(0,
      'Handler muss vor Start gesetzt werden');

  if FUrlPrefixes.Count = 0 then
    raise EDXHttpSysError.CreateWin32(0,
      'Mindestens ein URL-Prefix muss via AddUrlPrefix registriert werden');

  // API laden
  if not FApi.Load then
    raise EDXHttpSysError.CreateWin32(GetLastError,
      'httpapi.dll konnte nicht geladen werden');

  // Initialisieren
  TDXHttpSysApi.CheckResult(
    FApi.Initialize(HTTPAPI_VERSION_2, HTTP_INITIALIZE_SERVER, nil),
    'HttpInitialize');

  try
    SetupUrlGroup;

    // Worker-Pool starten
    FWorkerPool := TDXHttpSysWorkerPool.Create(
      FApi, FReqQueueHandle, FThreadCount, FHandler);
    FWorkerPool.OnError := FOnError;
    FWorkerPool.Start;

    FActive := True;
  except
    TeardownUrlGroup;
    FApi.Terminate(HTTP_INITIALIZE_SERVER, nil);
    FApi.Unload;
    raise;
  end;
end;

procedure TDXHttpSysServer.Stop;
begin
  if not FActive then
    Exit;

  FActive := False;

  // Worker-Pool stoppen (Receiver-Thread wartet auf ReceiveHttpRequest)
  // CloseHandle auf den Queue weckt den blockierenden Aufruf auf
  if Assigned(FWorkerPool) then
  begin
    // Queue schließen weckt Receiver-Thread auf
    if FReqQueueHandle <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(FReqQueueHandle);
      FReqQueueHandle := INVALID_HANDLE_VALUE;
    end;

    FWorkerPool.Stop;
    FreeAndNil(FWorkerPool);
  end;

  TeardownUrlGroup;

  FApi.Terminate(HTTP_INITIALIZE_SERVER, nil);
  FApi.Unload;
end;

function TDXHttpSysServer.GetServerImplementation: TObject;
begin
  Result := Self;
end;

{$ENDIF MSWINDOWS}

end.
