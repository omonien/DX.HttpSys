/// <summary>
///   DX.HttpSys.Request — abstraction of an incoming HTTP.sys request.
/// </summary>
/// <remarks>
///   TDXHttpSysRequest wraps a PHTTP_REQUEST and exposes type-safe,
///   Delphi-friendly properties.
///
///   Important:
///     - Always use CookedUrl, never pRawUrl (the latter is only for
///       logging/statistics).
///     - The body is loaded lazily via HttpReceiveRequestEntityBody.
///     - Instances are NOT thread-safe; use them only within their owning
///       worker thread.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.Request;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.WinSock2,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api;

type
  // ---------------------------------------------------------------------------
  // TDXHttpHeaders – simple name/value list for request and response headers
  // ---------------------------------------------------------------------------

  TDXHttpHeaders = class
  private
    FItems: TDictionary<string, string>;
  public
    constructor Create;
    destructor  Destroy; override;

    procedure   SetHeader(const AName, AValue: string);
    function    GetHeader(const AName: string): string;
    function    HasHeader(const AName: string): Boolean;
    procedure   Clear;

    // Iteration
    procedure   EnumHeaders(AProc: TProc<string, string>);

    property Values[const AName: string]: string
      read GetHeader write SetHeader; default;
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysRequest
  // ---------------------------------------------------------------------------

  TDXHttpSysRequest = class
  private
    FApi:           TDXHttpSysApi;       // Reference, not owned
    FQueueHandle:   THandle;
    FRawRequest:    PHTTP_REQUEST;       // Points into the recv buffer (not owned)
    FHeaders:       TDXHttpHeaders;
    FBody:          TStream;
    FBodyLoaded:    Boolean;
    FMethod:        string;
    FUrl:           string;
    FPath:          string;
    FQueryString:   string;
    FHost:          string;
    FRemoteIP:      string;
    FRequestId:     HTTP_REQUEST_ID;
    FUrlContext:    HTTP_URL_CONTEXT;
    FContentLength: Int64;

    procedure ParseFromRaw;
    procedure ParseKnownHeaders;
    function  LoadBody: TStream;
    function  SockAddrToIP(ASockAddr: PSOCKADDR): string;
  public
    // Creates an instance from a raw HTTP_REQUEST buffer.
    // The buffer must remain valid for the entire lifetime of the instance.
    constructor Create(
      const AApi:         TDXHttpSysApi;
      AQueueHandle:       THandle;
      ARawRequest:        PHTTP_REQUEST);
    destructor  Destroy; override;

    // HTTP verb (GET, POST, PUT, DELETE, ...)
    property Method:        string          read FMethod;

    // Full URL from CookedUrl.pFullUrl (e.g. "http://server:8080/api/test?x=1")
    property Url:           string          read FUrl;

    // Path from CookedUrl.pAbsPath (e.g. "/api/test")
    property Path:          string          read FPath;

    // Query string from CookedUrl.pQueryString (e.g. "x=1", WITHOUT leading '?')
    property QueryString:   string          read FQueryString;

    // Host from CookedUrl.pHost (e.g. "server:8080")
    property Host:          string          read FHost;

    // All request headers
    property Headers:       TDXHttpHeaders  read FHeaders;

    // Body as a stream – loaded lazily on first access
    property Body:          TStream         read LoadBody;

    // Content-Length header value (-1 if not set)
    property ContentLength: Int64           read FContentLength;

    // Remote IP of the client as a string (IPv4 or IPv6)
    property RemoteIP:      string          read FRemoteIP;

    // Internal request identifier – required by TDXHttpSysResponse
    property RequestId:     HTTP_REQUEST_ID read FRequestId;

    // Routing context from the UrlGroup setup (0 if not set)
    property UrlContext:    HTTP_URL_CONTEXT read FUrlContext;
  end;

implementation

uses
  System.StrUtils;

// -----------------------------------------------------------------------------
// TDXHttpHeaders
// -----------------------------------------------------------------------------

constructor TDXHttpHeaders.Create;
begin
  inherited;
  FItems := TDictionary<string, string>.Create;
end;

destructor TDXHttpHeaders.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TDXHttpHeaders.SetHeader(const AName, AValue: string);
begin
  FItems.AddOrSetValue(AName.ToLower, AValue);
end;

function TDXHttpHeaders.GetHeader(const AName: string): string;
begin
  if not FItems.TryGetValue(AName.ToLower, Result) then
    Result := '';
end;

function TDXHttpHeaders.HasHeader(const AName: string): Boolean;
begin
  Result := FItems.ContainsKey(AName.ToLower);
end;

procedure TDXHttpHeaders.Clear;
begin
  FItems.Clear;
end;

procedure TDXHttpHeaders.EnumHeaders(AProc: TProc<string, string>);
var
  Pair: TPair<string, string>;
begin
  for Pair in FItems do
    AProc(Pair.Key, Pair.Value);
end;

// -----------------------------------------------------------------------------
// TDXHttpSysRequest
// -----------------------------------------------------------------------------

constructor TDXHttpSysRequest.Create(
  const AApi:     TDXHttpSysApi;
  AQueueHandle:   THandle;
  ARawRequest:    PHTTP_REQUEST);
begin
  inherited Create;
  FApi          := AApi;
  FQueueHandle  := AQueueHandle;
  FRawRequest   := ARawRequest;
  FHeaders      := TDXHttpHeaders.Create;
  FContentLength := -1;

  ParseFromRaw;
end;

destructor TDXHttpSysRequest.Destroy;
begin
  FreeAndNil(FHeaders);
  FreeAndNil(FBody);
  inherited;
end;

procedure TDXHttpSysRequest.ParseFromRaw;
var
  R: PHTTP_REQUEST;
begin
  R := FRawRequest;

  FRequestId  := R^.RequestId;
  FUrlContext := R^.UrlContext;

  // HTTP verb
  if R^.Verb in [Low(HTTP_VERB)..High(HTTP_VERB)] then
  begin
    if R^.Verb = HttpVerbUnknown then
      FMethod := string(AnsiString(R^.pUnknownVerb))
    else
      FMethod := HTTP_VERB_STRINGS[R^.Verb];
  end
  else
    FMethod := '';

  // URL parts – ALWAYS use CookedUrl
  if R^.CookedUrl.pFullUrl <> nil then
    FUrl := string(R^.CookedUrl.pFullUrl);
  if R^.CookedUrl.pAbsPath <> nil then
    FPath := string(R^.CookedUrl.pAbsPath);
  if R^.CookedUrl.pQueryString <> nil then
  begin
    FQueryString := string(R^.CookedUrl.pQueryString);
    // Strip leading '?'
    if FQueryString.StartsWith('?') then
      FQueryString := FQueryString.Substring(1);
  end;
  if R^.CookedUrl.pHost <> nil then
    FHost := string(R^.CookedUrl.pHost);

  // Remote IP
  if R^.Address.pRemoteAddress <> nil then
    FRemoteIP := SockAddrToIP(R^.Address.pRemoteAddress);

  ParseKnownHeaders;
end;

procedure TDXHttpSysRequest.ParseKnownHeaders;

  procedure AddKnown(AIndex: Integer; const AName: string);
  var
    H: HTTP_KNOWN_HEADER;
  begin
    H := FRawRequest^.Headers.KnownHeaders[AIndex];
    if (H.RawValueLength > 0) and (H.pRawValue <> nil) then
      FHeaders.SetHeader(AName, string(AnsiString(H.pRawValue)));
  end;

var
  I: Integer;
  UH: PHTTP_UNKNOWN_HEADER;
begin
  // Known headers
  AddKnown(Ord(HttpHeaderCacheControl),       'cache-control');
  AddKnown(Ord(HttpHeaderConnection),         'connection');
  AddKnown(Ord(HttpHeaderContentLength),      'content-length');
  AddKnown(Ord(HttpHeaderContentType),        'content-type');
  AddKnown(Ord(HttpHeaderHost),               'host');
  AddKnown(Ord(HttpHeaderUserAgent),          'user-agent');
  AddKnown(Ord(HttpHeaderAccept),             'accept');
  AddKnown(Ord(HttpHeaderAcceptEncoding),     'accept-encoding');
  AddKnown(Ord(HttpHeaderAcceptLanguage),     'accept-language');
  AddKnown(Ord(HttpHeaderAuthorization),      'authorization');
  AddKnown(Ord(HttpHeaderCookie),             'cookie');
  AddKnown(Ord(HttpHeaderReferer),            'referer');
  // ... add more as needed

  // Parse Content-Length as Int64
  if FHeaders.HasHeader('content-length') then
    FContentLength := StrToInt64Def(FHeaders['content-length'], -1);

  // Unknown headers
  if (FRawRequest^.Headers.UnknownHeaderCount > 0)
    and (FRawRequest^.Headers.pUnknownHeaders <> nil) then
  begin
    UH := FRawRequest^.Headers.pUnknownHeaders;
    for I := 0 to FRawRequest^.Headers.UnknownHeaderCount - 1 do
    begin
      if (UH^.NameLength > 0) and (UH^.pName <> nil)
        and (UH^.RawValueLength > 0) and (UH^.pRawValue <> nil) then
      begin
        FHeaders.SetHeader(
          string(AnsiString(UH^.pName)),
          string(AnsiString(UH^.pRawValue)));
      end;
      Inc(UH);
    end;
  end;
end;

function TDXHttpSysRequest.LoadBody: TStream;
const
  CHUNK_SIZE = 64 * 1024; // 64 KB per chunk
var
  Buffer:       array of Byte;
  BytesRead:    ULONG;
  Result_:      ULONG;
  MemStream:    TMemoryStream;
  I:            Integer;
  Chunk:        PHTTP_DATA_CHUNK;
  MoreExists:   Boolean;
begin
  if FBodyLoaded then
    Exit(FBody);

  if FContentLength = 0 then
  begin
    FBodyLoaded := True;
    Exit(nil); // no body — Body returns nil by convention
  end;

  MemStream := TMemoryStream.Create;
  try
    // 1) HttpReceiveHttpRequest was called with COPY_BODY, so any body that fit
    //    in the request buffer is already present as inline entity chunks. Read
    //    those first — they will NOT be returned again by ReceiveRequestEntityBody.
    if (FRawRequest^.EntityChunkCount > 0) and (FRawRequest^.pEntityChunks <> nil) then
    begin
      Chunk := FRawRequest^.pEntityChunks;
      for I := 0 to FRawRequest^.EntityChunkCount - 1 do
      begin
        if (Chunk^.DataChunkType = HttpDataChunkFromMemory) and
           (Chunk^.FromMemory.pBuffer <> nil) and
           (Chunk^.FromMemory.BufferLength > 0) then
          MemStream.Write(PByte(Chunk^.FromMemory.pBuffer)^, Chunk^.FromMemory.BufferLength);
        Inc(Chunk);
      end;
    end;

    // 2) If the body did not fully fit, pull the remainder from the kernel.
    MoreExists :=
      (FRawRequest^.Flags and HTTP_REQUEST_FLAG_MORE_ENTITY_BODY_EXISTS) <> 0;
    if MoreExists then
    begin
      SetLength(Buffer, CHUNK_SIZE);
      repeat
        BytesRead := 0;
        Result_ := FApi.ReceiveRequestEntityBody(
          FQueueHandle,
          FRequestId,
          0,
          @Buffer[0],
          CHUNK_SIZE,
          @BytesRead,
          nil);

        if (Result_ = ERROR_SUCCESS) and (BytesRead > 0) then
          MemStream.Write(Buffer[0], BytesRead)
        else if Result_ = ERROR_HANDLE_EOF then
          Break
        else if Result_ <> ERROR_SUCCESS then
          TDXHttpSysApi.CheckResult(Result_, 'ReceiveRequestEntityBody');
      until (Result_ = ERROR_HANDLE_EOF) or (BytesRead = 0);
    end;
  except
    MemStream.Free;
    raise;
  end;

  MemStream.Position := 0;
  FBody := MemStream;
  // Set only after a successful read: HTTP.sys delivers the body once, but a
  // failure mid-read should surface (and not be cached as an empty body).
  FBodyLoaded := True;
  Result := FBody;
end;

function TDXHttpSysRequest.SockAddrToIP(ASockAddr: PSOCKADDR): string;
type
  // Minimal sockaddr_in6 — only the address field is needed for formatting.
  // Winapi.WinSock2 does not declare this, and we avoid pulling in extra units.
  TSockAddrIn6Min = record
    sin6_family:   USHORT;
    sin6_port:     USHORT;
    sin6_flowinfo: ULONG;
    sin6_addr:     array[0..15] of Byte;
    sin6_scope_id: ULONG;
  end;
  PSockAddrIn6Min = ^TSockAddrIn6Min;
const
  cMaxIpLen = 46; // enough for the longest IPv6 textual form
var
  SA4:  PSockAddrIn absolute ASockAddr;
  SA6:  PSockAddrIn6Min absolute ASockAddr;
  LBuf: array[0..cMaxIpLen - 1] of AnsiChar;
begin
  Result := '';
  if ASockAddr = nil then
    Exit;

  // inet_ntop formats both IPv4 and IPv6 correctly (including loopback ::1).
  case ASockAddr^.sa_family of
    AF_INET:
      if inet_ntop(AF_INET, @SA4^.sin_addr, @LBuf[0], Length(LBuf)) <> nil then
        Result := string(AnsiString(PAnsiChar(@LBuf[0])));
    AF_INET6:
      if inet_ntop(AF_INET6, @SA6^.sin6_addr, @LBuf[0], Length(LBuf)) <> nil then
        Result := string(AnsiString(PAnsiChar(@LBuf[0])));
  end;
end;

end.
