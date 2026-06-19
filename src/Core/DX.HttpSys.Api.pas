/// <summary>
///   DX.HttpSys.Api — runtime loader and function record for httpapi.dll v2.0.
/// </summary>
/// <remarks>
///   All functions are resolved via GetProcAddress; there is no hard import link.
///   The unit compiles on non-Windows platforms, where the function pointers are
///   nil. EDXHttpSysNotSupported is raised on Load when running on non-Windows.
///
///   Usage:
///     if not TDXHttpSysApi.Instance.Load then
///       raise EDXHttpSysError.Create('httpapi.dll could not be loaded');
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.Api;

interface

uses
  System.SysUtils
  {$IFDEF MSWINDOWS}
  , Winapi.Windows
  , DX.HttpSys.Api.Types
  {$ENDIF};

type
  EDXHttpSysError = class(Exception)
  private
    FErrorCode: Cardinal;
  public
    constructor CreateWin32(AErrorCode: Cardinal; const AContext: string);
    property ErrorCode: Cardinal read FErrorCode;
  end;

  EDXHttpSysNotSupported = class(EDXHttpSysError);

{$IFDEF MSWINDOWS}

  // ---------------------------------------------------------------------------
  // Function signatures
  // ---------------------------------------------------------------------------

  TFnHttpInitialize = function(
    Version: THTTP_VERSION;
    Flags:   ULONG;
    pReserved: Pointer): ULONG; stdcall;

  TFnHttpTerminate = function(
    Flags:     ULONG;
    pReserved: Pointer): ULONG; stdcall;

  TFnHttpCreateServerSession = function(
    Version:          THTTP_VERSION;
    out pServerSessionId: HTTP_SERVER_SESSION_ID;
    Reserved:         ULONG): ULONG; stdcall;

  TFnHttpCloseServerSession = function(
    ServerSessionId: HTTP_SERVER_SESSION_ID): ULONG; stdcall;

  TFnHttpCreateUrlGroup = function(
    ServerSessionId: HTTP_SERVER_SESSION_ID;
    out pUrlGroupId: HTTP_URL_GROUP_ID;
    Reserved:        ULONG): ULONG; stdcall;

  TFnHttpCloseUrlGroup = function(
    UrlGroupId: HTTP_URL_GROUP_ID): ULONG; stdcall;

  TFnHttpAddUrlToUrlGroup = function(
    UrlGroupId:         HTTP_URL_GROUP_ID;
    pFullyQualifiedUrl: PCWSTR;
    UrlContext:         HTTP_URL_CONTEXT;
    Reserved:           ULONG): ULONG; stdcall;

  TFnHttpRemoveUrlFromUrlGroup = function(
    UrlGroupId:         HTTP_URL_GROUP_ID;
    pFullyQualifiedUrl: PCWSTR;
    Flags:              ULONG): ULONG; stdcall;

  TFnHttpCreateRequestQueue = function(
    Version:               THTTP_VERSION;
    pName:                 PCWSTR;
    pSecurityAttributes:   Pointer;
    Flags:                 ULONG;
    out pReqQueueHandle:   THandle): ULONG; stdcall;

  TFnHttpCloseRequestQueue = function(
    ReqQueueHandle: THandle): ULONG; stdcall;

  TFnHttpSetUrlGroupProperty = function(
    UrlGroupId:          HTTP_URL_GROUP_ID;
    Property_:           HTTP_SERVER_PROPERTY;
    pPropertyInfo:       Pointer;
    PropertyInfoLength:  ULONG): ULONG; stdcall;

  TFnHttpReceiveHttpRequest = function(
    ReqQueueHandle:      THandle;
    RequestId:           HTTP_REQUEST_ID;
    Flags:               ULONG;
    pRequestBuffer:      PHTTP_REQUEST;
    RequestBufferLength: ULONG;
    pBytesReceived:      PULONG;
    pOverlapped:         POverlapped): ULONG; stdcall;

  TFnHttpReceiveRequestEntityBody = function(
    ReqQueueHandle:   THandle;
    RequestId:        HTTP_REQUEST_ID;
    Flags:            ULONG;
    pEntityBuffer:    Pointer;
    EntityBufferLength: ULONG;
    pBytesReceived:   PULONG;
    pOverlapped:      POverlapped): ULONG; stdcall;

  TFnHttpSendHttpResponse = function(
    ReqQueueHandle: THandle;
    RequestId:      HTTP_REQUEST_ID;
    Flags:          ULONG;
    pResponse:      PHTTP_RESPONSE;
    pCachePolicy:   Pointer;
    pBytesSent:     PULONG;
    pReserved1:     Pointer;
    Reserved2:      ULONG;
    pOverlapped:    POverlapped;
    pLogData:       Pointer): ULONG; stdcall;

  // ---------------------------------------------------------------------------
  // Main structure: TDXHttpSysApi
  // ---------------------------------------------------------------------------

  TDXHttpSysApi = record
  private
    FLibHandle: THandle;
    FLoaded:    Boolean;

    function GetProc(const AName: string): Pointer;
  public
    // Lifecycle
    Initialize:               TFnHttpInitialize;
    Terminate:                TFnHttpTerminate;

    // V2: Server Session
    CreateServerSession:      TFnHttpCreateServerSession;
    CloseServerSession:       TFnHttpCloseServerSession;

    // V2: URL Groups
    CreateUrlGroup:           TFnHttpCreateUrlGroup;
    CloseUrlGroup:            TFnHttpCloseUrlGroup;
    AddUrlToUrlGroup:         TFnHttpAddUrlToUrlGroup;
    RemoveUrlFromUrlGroup:    TFnHttpRemoveUrlFromUrlGroup;

    // Request Queue
    CreateRequestQueue:       TFnHttpCreateRequestQueue;
    CloseRequestQueue:        TFnHttpCloseRequestQueue;
    SetUrlGroupProperty:      TFnHttpSetUrlGroupProperty;

    // I/O
    ReceiveHttpRequest:       TFnHttpReceiveHttpRequest;
    ReceiveRequestEntityBody: TFnHttpReceiveRequestEntityBody;
    SendHttpResponse:         TFnHttpSendHttpResponse;

    // Loads httpapi.dll and all function pointers.
    // Returns False when the DLL cannot be found.
    function  Load: Boolean;

    // Unloads the DLL. Must be called after HttpTerminate.
    procedure Unload;

    property Loaded: Boolean read FLoaded;

    // Raises EDXHttpSysError when AResult <> ERROR_SUCCESS.
    // AContext is embedded into the exception message.
    class procedure CheckResult(AResult: ULONG; const AContext: string); static;

    // Returns the Win32 error text for a result code.
    class function  ResultToString(AResult: ULONG): string; static;
  end;

{$ENDIF MSWINDOWS}

implementation

// -----------------------------------------------------------------------------
// EDXHttpSysError
// -----------------------------------------------------------------------------

constructor EDXHttpSysError.CreateWin32(AErrorCode: Cardinal; const AContext: string);
begin
  FErrorCode := AErrorCode;
  {$IFDEF MSWINDOWS}
  inherited CreateFmt('[DX.HttpSys] %s – Win32 Error %d: %s',
    [AContext, AErrorCode, SysErrorMessage(AErrorCode)]);
  {$ELSE}
  inherited CreateFmt('[DX.HttpSys] %s – Error %d', [AContext, AErrorCode]);
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}

// -----------------------------------------------------------------------------
// TDXHttpSysApi
// -----------------------------------------------------------------------------

function TDXHttpSysApi.GetProc(const AName: string): Pointer;
begin
  Result := GetProcAddress(FLibHandle, PChar(AName));
  // Missing optional functions yield nil; critical ones are checked in Load.
end;

function TDXHttpSysApi.Load: Boolean;
begin
  Result := False;
  if FLoaded then
    Exit(True);

  FLibHandle := LoadLibrary('httpapi.dll');
  if FLibHandle = 0 then
    Exit(False);

  // Lifecycle
  @Initialize               := GetProc('HttpInitialize');
  @Terminate                := GetProc('HttpTerminate');

  // V2 session / URL group
  @CreateServerSession      := GetProc('HttpCreateServerSession');
  @CloseServerSession       := GetProc('HttpCloseServerSession');
  @CreateUrlGroup           := GetProc('HttpCreateUrlGroup');
  @CloseUrlGroup            := GetProc('HttpCloseUrlGroup');
  @AddUrlToUrlGroup         := GetProc('HttpAddUrlToUrlGroup');
  @RemoveUrlFromUrlGroup    := GetProc('HttpRemoveUrlFromUrlGroup');

  // Request Queue
  @CreateRequestQueue       := GetProc('HttpCreateRequestQueue');
  @CloseRequestQueue        := GetProc('HttpCloseRequestQueue');
  @SetUrlGroupProperty      := GetProc('HttpSetUrlGroupProperty');

  // I/O
  @ReceiveHttpRequest       := GetProc('HttpReceiveHttpRequest');
  @ReceiveRequestEntityBody := GetProc('HttpReceiveRequestEntityBody');
  @SendHttpResponse         := GetProc('HttpSendHttpResponse');

  // Check critical functions
  if not Assigned(Initialize)
    or not Assigned(CreateServerSession)
    or not Assigned(CreateUrlGroup)
    or not Assigned(CreateRequestQueue)
    or not Assigned(ReceiveHttpRequest)
    or not Assigned(SendHttpResponse) then
  begin
    FreeLibrary(FLibHandle);
    FLibHandle := 0;
    Exit(False);
  end;

  FLoaded := True;
  Result  := True;
end;

procedure TDXHttpSysApi.Unload;
begin
  if FLibHandle <> 0 then
  begin
    FreeLibrary(FLibHandle);
    FLibHandle := 0;
    FLoaded    := False;
  end;
end;

class procedure TDXHttpSysApi.CheckResult(AResult: ULONG; const AContext: string);
begin
  if AResult <> ERROR_SUCCESS then
    raise EDXHttpSysError.CreateWin32(AResult, AContext);
end;

class function TDXHttpSysApi.ResultToString(AResult: ULONG): string;
begin
  Result := SysErrorMessage(AResult);
end;

{$ENDIF MSWINDOWS}

end.
