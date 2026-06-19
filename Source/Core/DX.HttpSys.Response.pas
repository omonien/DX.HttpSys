// =============================================================================
// DX.HttpSys.Response.pas
// Abstraktion eines ausgehenden HTTP.sys-Response
//
// TDXHttpSysResponse kapselt HttpSendHttpResponse und stellt eine
// Delphi-freundliche API bereit.
//
// WICHTIG:
//   - Send() darf nur einmal aufgerufen werden
//   - Nach Send() sind keine Property-Änderungen mehr möglich
//   - Instanzen sind NICHT thread-safe; nur im zugehörigen Worker-Thread nutzen
//
// (c) Developer Experts LLC – MIT License
// =============================================================================

unit DX.HttpSys.Response;

{$IFDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request;

type
  // ---------------------------------------------------------------------------
  // TDXHttpSysResponse
  // ---------------------------------------------------------------------------

  TDXHttpSysResponse = class
  private
    FApi:          TDXHttpSysApi;    // Referenz, kein Besitz
    FQueueHandle:  THandle;
    FRequestId:    HTTP_REQUEST_ID;
    FStatusCode:   Word;
    FReasonPhrase: AnsiString;
    FHeaders:      TDXHttpHeaders;
    FBody:         TMemoryStream;
    FSent:         Boolean;

    procedure SetStatusCode(AValue: Word);
    procedure SetReasonPhrase(const AValue: string);
    procedure CheckNotSent;
    function  BuildHttpResponse(
      ABodyData:   Pointer;
      ABodyLength: ULONG;
      out ARawResp: HTTP_RESPONSE;
      out AChunk:   HTTP_DATA_CHUNK): Boolean;
  public
    constructor Create(
      const AApi:        TDXHttpSysApi;
      AQueueHandle:      THandle;
      ARequestId:        HTTP_REQUEST_ID);
    destructor  Destroy; override;

    // HTTP-Statuscode (Default: 200)
    property StatusCode:    Word   read FStatusCode  write SetStatusCode;

    // Reason-Phrase (Default: wird aus StatusCode abgeleitet)
    property ReasonPhrase:  string
      read (string(FReasonPhrase))
      write SetReasonPhrase;

    // Response-Header
    property Headers:       TDXHttpHeaders read FHeaders;

    // Body-Stream – direkt befüllbar
    property Body:          TMemoryStream  read FBody;

    // Convenience: Body aus String setzen + Content-Type-Header
    procedure SetBody(
      const AText:        string;
      const AContentType: string = 'text/plain; charset=utf-8');

    // Convenience: Body aus JSON-String setzen
    procedure SetJsonBody(const AJson: string);

    // Sendet den Response über HttpSendHttpResponse.
    // Darf nur einmal aufgerufen werden; danach ist Sent = True.
    procedure Send;

    // Sendet einen einfachen Fehler-Response (kein Body erforderlich)
    procedure SendError(AStatusCode: Word; const AReason: string = '');

    // True nach erfolgreichem Send()
    property Sent: Boolean read FSent;
  end;

implementation

// -----------------------------------------------------------------------------
// Standard-Reason-Phrases nach RFC 9110
// -----------------------------------------------------------------------------

function DefaultReasonPhrase(AStatusCode: Word): AnsiString;
begin
  case AStatusCode of
    100: Result := 'Continue';
    101: Result := 'Switching Protocols';
    200: Result := 'OK';
    201: Result := 'Created';
    202: Result := 'Accepted';
    204: Result := 'No Content';
    206: Result := 'Partial Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    415: Result := 'Unsupported Media Type';
    422: Result := 'Unprocessable Content';
    429: Result := 'Too Many Requests';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
  else
    Result := 'Unknown';
  end;
end;

// -----------------------------------------------------------------------------
// TDXHttpSysResponse
// -----------------------------------------------------------------------------

constructor TDXHttpSysResponse.Create(
  const AApi:     TDXHttpSysApi;
  AQueueHandle:   THandle;
  ARequestId:     HTTP_REQUEST_ID);
begin
  inherited Create;
  FApi          := AApi;
  FQueueHandle  := AQueueHandle;
  FRequestId    := ARequestId;
  FStatusCode   := 200;
  FReasonPhrase := DefaultReasonPhrase(200);
  FHeaders      := TDXHttpHeaders.Create;
  FBody         := TMemoryStream.Create;
  FSent         := False;
end;

destructor TDXHttpSysResponse.Destroy;
begin
  FHeaders.Free;
  FBody.Free;
  inherited;
end;

procedure TDXHttpSysResponse.SetStatusCode(AValue: Word);
begin
  CheckNotSent;
  FStatusCode   := AValue;
  FReasonPhrase := DefaultReasonPhrase(AValue);
end;

procedure TDXHttpSysResponse.SetReasonPhrase(const AValue: string);
begin
  CheckNotSent;
  FReasonPhrase := AnsiString(AValue);
end;

procedure TDXHttpSysResponse.CheckNotSent;
begin
  if FSent then
    raise EDXHttpSysError.CreateWin32(0, 'Response wurde bereits gesendet (Send darf nur einmal aufgerufen werden)');
end;

procedure TDXHttpSysResponse.SetBody(const AText, AContentType: string);
var
  Bytes: TBytes;
begin
  CheckNotSent;
  Bytes := TEncoding.UTF8.GetBytes(AText);
  FBody.Clear;
  FBody.Write(Bytes[0], Length(Bytes));
  FHeaders['content-type'] := AContentType;
end;

procedure TDXHttpSysResponse.SetJsonBody(const AJson: string);
begin
  SetBody(AJson, 'application/json; charset=utf-8');
end;

function TDXHttpSysResponse.BuildHttpResponse(
  ABodyData:   Pointer;
  ABodyLength: ULONG;
  out ARawResp: HTTP_RESPONSE;
  out AChunk:   HTTP_DATA_CHUNK): Boolean;
begin
  FillChar(ARawResp, SizeOf(ARawResp), 0);
  ARawResp.StatusCode   := FStatusCode;
  ARawResp.pReason      := PAnsiChar(FReasonPhrase);
  ARawResp.ReasonLength := Length(FReasonPhrase);
  ARawResp.Version      := HTTPAPI_VERSION_2;

  // TODO: Known Response Headers befüllen
  // (HttpHeaderContentType, HttpHeaderServer, etc.)
  // Milestone 2: vollständige Header-Übertragung implementieren

  // Body-Chunk
  if (ABodyData <> nil) and (ABodyLength > 0) then
  begin
    FillChar(AChunk, SizeOf(AChunk), 0);
    AChunk.DataChunkType            := HttpDataChunkFromMemory;
    AChunk.FromMemory.pBuffer       := ABodyData;
    AChunk.FromMemory.BufferLength  := ABodyLength;
    ARawResp.EntityChunkCount := 1;
    ARawResp.pEntityChunks    := @AChunk;
  end;

  Result := True;
end;

procedure TDXHttpSysResponse.Send;
var
  RawResp:    HTTP_RESPONSE;
  Chunk:      HTTP_DATA_CHUNK;
  BodyData:   Pointer;
  BodyLength: ULONG;
  BytesSent:  ULONG;
  Result_:    ULONG;
begin
  CheckNotSent;
  FSent := True;

  // Body-Daten vorbereiten
  BodyLength := FBody.Size;
  if BodyLength > 0 then
  begin
    FBody.Position := 0;
    BodyData := FBody.Memory;

    // Content-Length setzen falls nicht explizit gesetzt
    if not FHeaders.HasHeader('content-length') then
      FHeaders['content-length'] := IntToStr(BodyLength);
  end
  else
    BodyData := nil;

  BuildHttpResponse(BodyData, BodyLength, RawResp, Chunk);

  BytesSent := 0;
  Result_ := FApi.SendHttpResponse(
    FQueueHandle,
    FRequestId,
    0,           // Flags
    @RawResp,
    nil,         // pCachePolicy
    @BytesSent,
    nil,         // pReserved1
    0,           // Reserved2
    nil,         // pOverlapped (synchron)
    nil);        // pLogData

  TDXHttpSysApi.CheckResult(Result_, 'HttpSendHttpResponse');
end;

procedure TDXHttpSysResponse.SendError(AStatusCode: Word; const AReason: string);
begin
  CheckNotSent;
  StatusCode := AStatusCode;
  if AReason <> '' then
    ReasonPhrase := AReason;
  Send;
end;

{$ENDIF MSWINDOWS}

end.
