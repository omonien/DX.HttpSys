// =============================================================================
// DX.HttpSys.Request.pas
// Abstraktion eines eingehenden HTTP.sys-Requests
//
// TDXHttpSysRequest kapselt einen PHTTP_REQUEST und stellt typsichere,
// Delphi-freundliche Properties bereit.
//
// WICHTIG:
//   - Immer CookedUrl verwenden, niemals pRawUrl (nur für Logging/Statistik)
//   - Body wird lazy via HttpReceiveRequestEntityBody geladen
//   - Instanzen sind NICHT thread-safe; nur im zugehörigen Worker-Thread nutzen
//
// (c) Developer Experts LLC – MIT License
// =============================================================================

unit DX.HttpSys.Request;

{$IFDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.WinSock,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api;

type
  // ---------------------------------------------------------------------------
  // TDXHttpHeaders – einfache Name/Value-Liste für Request- und Response-Header
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
    FApi:           TDXHttpSysApi;       // Referenz, kein Besitz
    FQueueHandle:   THandle;
    FRawRequest:    PHTTP_REQUEST;       // Zeigt in den Recv-Puffer (kein Besitz)
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
    // Erzeugt eine Instanz aus einem rohen HTTP_REQUEST-Buffer.
    // Der Puffer muss für die gesamte Lebensdauer der Instanz gültig bleiben.
    constructor Create(
      const AApi:         TDXHttpSysApi;
      AQueueHandle:       THandle;
      ARawRequest:        PHTTP_REQUEST);
    destructor  Destroy; override;

    // HTTP-Verb (GET, POST, PUT, DELETE, ...)
    property Method:        string          read FMethod;

    // Vollständige URL aus CookedUrl.pFullUrl (z.B. "http://server:8080/api/test?x=1")
    property Url:           string          read FUrl;

    // Pfad aus CookedUrl.pAbsPath (z.B. "/api/test")
    property Path:          string          read FPath;

    // Query-String aus CookedUrl.pQueryString (z.B. "x=1", OHNE führendes '?')
    property QueryString:   string          read FQueryString;

    // Host aus CookedUrl.pHost (z.B. "server:8080")
    property Host:          string          read FHost;

    // Alle Request-Header
    property Headers:       TDXHttpHeaders  read FHeaders;

    // Body als Stream – wird beim ersten Zugriff lazy geladen
    property Body:          TStream         read LoadBody;

    // Content-Length Header-Wert (-1 wenn nicht gesetzt)
    property ContentLength: Int64           read FContentLength;

    // Remote-IP des Clients als String (IPv4 oder IPv6)
    property RemoteIP:      string          read FRemoteIP;

    // Interner Request-Identifier – wird von TDXHttpSysResponse benötigt
    property RequestId:     HTTP_REQUEST_ID read FRequestId;

    // Routing-Kontext aus dem UrlGroup-Setup (0 wenn nicht gesetzt)
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
  FHeaders.Free;
  FBody.Free;
  inherited;
end;

procedure TDXHttpSysRequest.ParseFromRaw;
var
  R: PHTTP_REQUEST;
begin
  R := FRawRequest;

  FRequestId  := R^.RequestId;
  FUrlContext := R^.UrlContext;

  // HTTP-Verb
  if R^.Verb in [Low(HTTP_VERB)..High(HTTP_VERB)] then
  begin
    if R^.Verb = HttpVerbUnknown then
      FMethod := string(AnsiString(R^.pUnknownVerb))
    else
      FMethod := HTTP_VERB_STRINGS[R^.Verb];
  end
  else
    FMethod := '';

  // URL-Teile – IMMER CookedUrl verwenden
  if R^.CookedUrl.pFullUrl <> nil then
    FUrl := string(R^.CookedUrl.pFullUrl);
  if R^.CookedUrl.pAbsPath <> nil then
    FPath := string(R^.CookedUrl.pAbsPath);
  if R^.CookedUrl.pQueryString <> nil then
  begin
    FQueryString := string(R^.CookedUrl.pQueryString);
    // Führendes '?' entfernen
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
  // Bekannte Header
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
  // ... weitere nach Bedarf ergänzen

  // Content-Length als Int64 parsen
  if FHeaders.HasHeader('content-length') then
    FContentLength := StrToInt64Def(FHeaders['content-length'], -1);

  // Unbekannte Header
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
  CHUNK_SIZE = 64 * 1024; // 64 KB pro Chunk
var
  Buffer:       array of Byte;
  BytesRead:    ULONG;
  Result_:      ULONG;
  MemStream:    TMemoryStream;
begin
  if FBodyLoaded then
    Exit(FBody);

  FBodyLoaded := True;

  if FContentLength = 0 then
    Exit(nil);

  MemStream := TMemoryStream.Create;
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
    begin
      MemStream.Free;
      TDXHttpSysApi.CheckResult(Result_, 'ReceiveRequestEntityBody');
    end;
  until (Result_ = ERROR_HANDLE_EOF) or (BytesRead = 0);

  MemStream.Position := 0;
  FBody := MemStream;
  Result := FBody;
end;

function TDXHttpSysRequest.SockAddrToIP(ASockAddr: PSOCKADDR): string;
var
  SA4: PSockAddrIn absolute ASockAddr;
  // IPv6: PSockAddrIn6 – TODO: Milestone 2
begin
  Result := '';
  if ASockAddr = nil then
    Exit;

  case ASockAddr^.sa_family of
    AF_INET:
      Result := Format('%d.%d.%d.%d', [
        Byte(SA4^.sin_addr.S_un_b.s_b1),
        Byte(SA4^.sin_addr.S_un_b.s_b2),
        Byte(SA4^.sin_addr.S_un_b.s_b3),
        Byte(SA4^.sin_addr.S_un_b.s_b4)]);
    AF_INET6:
      Result := '[IPv6]'; // TODO: Vollständige IPv6-Formatierung
  end;
end;

{$ENDIF MSWINDOWS}

end.
