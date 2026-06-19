/// <summary>
///   DX.HttpSys.Response — abstraction of an outgoing HTTP.sys response.
/// </summary>
/// <remarks>
///   TDXHttpSysResponse wraps HttpSendHttpResponse and provides a
///   Delphi-friendly API.
///
///   Important:
///     - Send() may only be called once.
///     - After Send(), no further property changes are possible.
///     - Instances are NOT thread-safe; use them only on the owning worker thread.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
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
    FApi:          TDXHttpSysApi;    // Reference, not owned
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

    // HTTP status code (default: 200)
    property StatusCode:    Word   read FStatusCode  write SetStatusCode;

    // Reason phrase (default: derived from StatusCode)
    property ReasonPhrase:  string
      read (string(FReasonPhrase))
      write SetReasonPhrase;

    // Response headers
    property Headers:       TDXHttpHeaders read FHeaders;

    // Body stream – can be filled directly
    property Body:          TMemoryStream  read FBody;

    // Convenience: set body from string + Content-Type header
    procedure SetBody(
      const AText:        string;
      const AContentType: string = 'text/plain; charset=utf-8');

    // Convenience: set body from JSON string
    procedure SetJsonBody(const AJson: string);

    // Sends the response via HttpSendHttpResponse.
    // May only be called once; afterwards Sent = True.
    procedure Send;

    // Sends a simple error response (no body required)
    procedure SendError(AStatusCode: Word; const AReason: string = '');

    // True after a successful Send()
    property Sent: Boolean read FSent;
  end;

implementation

// -----------------------------------------------------------------------------
// Standard reason phrases per RFC 9110
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
    raise EDXHttpSysError.CreateWin32(0, 'Response has already been sent (Send may only be called once)');
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

  // TODO: populate known response headers
  // (HttpHeaderContentType, HttpHeaderServer, etc.)
  // Milestone 2: implement full header transmission

  // Body chunk
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

  // Prepare body data
  BodyLength := FBody.Size;
  if BodyLength > 0 then
  begin
    FBody.Position := 0;
    BodyData := FBody.Memory;

    // Set Content-Length if not explicitly provided
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
