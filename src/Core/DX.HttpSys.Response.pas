/// <summary>
///   DX.HttpSys.Response — abstraction of an outgoing HTTP.sys response.
/// </summary>
/// <remarks>
///   TDXHttpSysResponse wraps HttpSendHttpResponse and provides a
///   Delphi-friendly API.
///
///   Important:
///     - Send() may only be called once.
///     - After Send() (or BeginStream()), no further property changes are possible.
///     - Streaming responses: BeginStream, then SendChunk repeatedly, then
///       EndStream. A stream the handler abandons is completed by the worker.
///     - Instances are NOT thread-safe; use them only on the owning worker thread.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.Response;

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request;

type
{$SCOPEDENUMS ON}
  /// <summary>
  ///   Lifecycle state of a response. <c>NotSent</c> until headers went out,
  ///   <c>Streaming</c> between a successful <c>BeginStream</c> and the end of
  ///   the stream, <c>Sent</c> once the response is complete.
  /// </summary>
  TDXHttpSysResponseState = (NotSent, Streaming, Sent);
{$SCOPEDENUMS OFF}

  /// <summary>
  ///   Queried by <see cref="TDXHttpSysResponse.Cancelled"/>. Injected by the
  ///   worker thread so handlers can observe server shutdown without the
  ///   response depending on the thread-pool unit.
  /// </summary>
  TDXHttpSysQueryCancelled = function: Boolean of object;

  /// <summary>
  ///   The outgoing HTTP response. Set <c>StatusCode</c>, headers and body (via
  ///   <c>SetBody</c>/<c>SetJsonBody</c> or by writing to <c>Body</c>), then call
  ///   <c>Send</c>. <c>Send</c> may be called only once. Alternatively start a
  ///   chunked streaming response with <c>BeginStream</c>/<c>SendChunk</c>/
  ///   <c>EndStream</c> (e.g. for Server-Sent Events).
  /// </summary>
  /// <remarks>Not thread-safe — use only on the owning worker thread.</remarks>
  TDXHttpSysResponse = class
  private
    FApi:          TDXHttpSysApi;    // Reference, not owned
    FQueueHandle:  THandle;
    FRequestId:    HTTP_REQUEST_ID;
    FStatusCode:   Word;
    FReasonPhrase: AnsiString;
    FHeaders:      TDXHttpHeaders;
    FBody:         TMemoryStream;
    FState:        TDXHttpSysResponseState;
    FOnQueryCancelled: TDXHttpSysQueryCancelled;

    // Buffers that must outlive the HttpSendHttpResponse call: the response
    // struct holds raw pointers into these, so they are instance fields kept
    // alive until Send returns.
    FHeaderValues:   array of AnsiString;       // backing storage for header values
    FHeaderNames:    array of AnsiString;       // backing storage for unknown header names
    FUnknownHeaders: array of HTTP_UNKNOWN_HEADER;

    procedure SetStatusCode(AValue: Word);
    function  GetReasonPhrase: string;
    procedure SetReasonPhrase(const AValue: string);
    function  GetSent: Boolean;
    function  GetStreaming: Boolean;
    function  GetCancelled: Boolean;
    procedure CheckNotSent;
    // Maps a header name to its known HTTP.sys response header index, or -1 if
    // the header is not a known response header and must travel as "unknown".
    class function KnownResponseHeaderIndex(const AName: string): Integer; static;
    procedure BuildHeaders(out ARawResp: HTTP_RESPONSE);
    procedure BuildHttpResponse(
      ABodyData:   Pointer;
      ABodyLength: ULONG;
      out ARawResp: HTTP_RESPONSE;
      out AChunk:   HTTP_DATA_CHUNK);
    // Wraps a memory buffer into an HTTP_DATA_CHUNK (the single place that
    // knows the chunk layout — used for the Send body and for SendChunk).
    class function BuildDataChunk(AData: Pointer; ALength: ULONG): HTTP_DATA_CHUNK; static;
    // Shared HttpSendHttpResponse call for Send (AFlags=0, with body) and
    // BeginStream (MORE_DATA, no body). Raises via CheckResult on failure.
    procedure SendHeaders(AFlags: ULONG; ABodyData: Pointer; ABodyLength: ULONG;
      const AContext: string);
    // Shared HttpSendResponseEntityBody call for SendChunk and EndStream.
    // Returns the raw Win32 result; the callers decide how to treat it.
    function SendEntityBody(AFlags: ULONG; AChunkCount: USHORT;
      AChunks: PHTTP_DATA_CHUNK): ULONG;
    // True for result codes that mean "this connection/stream is gone" (client
    // disconnect or queue closed during shutdown) as opposed to a genuine
    // failure of the call itself.
    class function IsStreamOverError(ACode: ULONG): Boolean; static;
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
      read GetReasonPhrase
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

    // True once the response is complete (single-shot Send finished, or a
    // streaming response ended). False while a stream is still in progress.
    property Sent: Boolean read GetSent;

    // The lifecycle state (NotSent / Streaming / Sent).
    property State: TDXHttpSysResponseState read FState;

    // ------------------------------------------------------------------
    // Streaming (chunked transfer encoding, e.g. Server-Sent Events)
    // ------------------------------------------------------------------

    // Starts a streaming response: sends the headers without Content-Length so
    // HTTP.sys uses chunked transfer encoding for HTTP/1.1 clients. Requires an
    // empty Body and no Content-Length header; the caller sets Content-Type
    // etc. via Headers. On success State becomes Streaming; if the underlying
    // send fails, the state stays NotSent (an error response is still possible).
    procedure BeginStream;

    // Sends one chunk of a streaming response. Returns False when the stream is
    // over — the client disconnected or the server is shutting down (see
    // Cancelled); the handler should then simply return. Raises EDXHttpSysError
    // for genuine failures (they never masquerade as a disconnect). Requires
    // BeginStream.
    function SendChunk(const AData: TBytes): Boolean;

    // Completes a streaming response (no more data follows). A no-op unless the
    // response is currently streaming, so it is safe to call unconditionally
    // after a send loop. A client disconnect during this call is treated as a
    // normal end of the stream, not an error.
    procedure EndStream;

    // True while a streaming response is in progress.
    property Streaming: Boolean read GetStreaming;

    // True once the server is shutting down (or this worker is asked to stop).
    // Long-running handlers — streaming or not — should poll this in their
    // loops and return promptly when it turns True. SendChunk checks it and
    // reports the stream as over. Wired up by the worker thread.
    property Cancelled: Boolean read GetCancelled;

    // Injected by the worker thread; see Cancelled.
    property OnQueryCancelled: TDXHttpSysQueryCancelled
      read FOnQueryCancelled write FOnQueryCancelled;
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
  FState        := TDXHttpSysResponseState.NotSent;
end;

destructor TDXHttpSysResponse.Destroy;
begin
  FreeAndNil(FHeaders);
  FreeAndNil(FBody);
  inherited;
end;

procedure TDXHttpSysResponse.SetStatusCode(AValue: Word);
begin
  CheckNotSent;
  FStatusCode   := AValue;
  FReasonPhrase := DefaultReasonPhrase(AValue);
end;

function TDXHttpSysResponse.GetReasonPhrase: string;
begin
  Result := string(FReasonPhrase);
end;

procedure TDXHttpSysResponse.SetReasonPhrase(const AValue: string);
begin
  CheckNotSent;
  FReasonPhrase := AnsiString(AValue);
end;

function TDXHttpSysResponse.GetSent: Boolean;
begin
  Result := FState = TDXHttpSysResponseState.Sent;
end;

function TDXHttpSysResponse.GetStreaming: Boolean;
begin
  Result := FState = TDXHttpSysResponseState.Streaming;
end;

function TDXHttpSysResponse.GetCancelled: Boolean;
begin
  Result := Assigned(FOnQueryCancelled) and FOnQueryCancelled();
end;

procedure TDXHttpSysResponse.CheckNotSent;
begin
  if FState <> TDXHttpSysResponseState.NotSent then
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

class function TDXHttpSysResponse.KnownResponseHeaderIndex(
  const AName: string): Integer;
var
  LName: string;
begin
  // The known response header set (HTTP_HEADER_ID response ordinals 0..29).
  // Names are matched case-insensitively. Anything not here travels as an
  // unknown header, which is perfectly valid for HTTP.sys.
  LName := AName.ToLower;
  if LName = 'cache-control'     then Exit(Ord(HttpHeaderCacheControl));
  if LName = 'connection'        then Exit(Ord(HttpHeaderConnection));
  if LName = 'date'              then Exit(Ord(HttpHeaderDate));
  if LName = 'keep-alive'        then Exit(Ord(HttpHeaderKeepAlive));
  if LName = 'pragma'            then Exit(Ord(HttpHeaderPragma));
  if LName = 'trailer'           then Exit(Ord(HttpHeaderTrailer));
  if LName = 'transfer-encoding' then Exit(Ord(HttpHeaderTransferEncoding));
  if LName = 'upgrade'           then Exit(Ord(HttpHeaderUpgrade));
  if LName = 'via'               then Exit(Ord(HttpHeaderVia));
  if LName = 'warning'           then Exit(Ord(HttpHeaderWarning));
  if LName = 'allow'             then Exit(Ord(HttpHeaderAllow));
  if LName = 'content-length'    then Exit(Ord(HttpHeaderContentLength));
  if LName = 'content-type'      then Exit(Ord(HttpHeaderContentType));
  if LName = 'content-encoding'  then Exit(Ord(HttpHeaderContentEncoding));
  if LName = 'content-language'  then Exit(Ord(HttpHeaderContentLanguage));
  if LName = 'content-location'  then Exit(Ord(HttpHeaderContentLocation));
  if LName = 'content-md5'       then Exit(Ord(HttpHeaderContentMd5));
  if LName = 'content-range'     then Exit(Ord(HttpHeaderContentRange));
  if LName = 'expires'           then Exit(Ord(HttpHeaderExpires));
  if LName = 'last-modified'     then Exit(Ord(HttpHeaderLastModified));
  if LName = 'accept-ranges'     then Exit(Ord(HttpHeaderAcceptRanges));
  if LName = 'age'               then Exit(Ord(HttpHeaderAge));
  if LName = 'etag'              then Exit(Ord(HttpHeaderEtag));
  if LName = 'location'          then Exit(Ord(HttpHeaderLocation));
  if LName = 'proxy-authenticate' then Exit(Ord(HttpHeaderProxyAuthenticate));
  if LName = 'retry-after'       then Exit(Ord(HttpHeaderRetryAfter));
  if LName = 'server'            then Exit(Ord(HttpHeaderServer));
  if LName = 'set-cookie'        then Exit(Ord(HttpHeaderSetCookie));
  if LName = 'vary'              then Exit(Ord(HttpHeaderVary));
  if LName = 'www-authenticate'  then Exit(Ord(HttpHeaderWwwAuthenticate));
  Result := -1;
end;

procedure TDXHttpSysResponse.BuildHeaders(out ARawResp: HTTP_RESPONSE);
var
  LNames:   TArray<string>;
  LValues:  TArray<string>;
  I:        Integer;
  LIndex:   Integer;
  LUnknown: Integer;
begin
  // Collect the headers first (a closure cannot capture the `out` ARawResp),
  // then write them into ARawResp and the backing buffers in a plain loop. The
  // FHeader* fields outlive HttpSendHttpResponse, which holds raw pointers into
  // them.
  SetLength(LNames, 0);
  SetLength(LValues, 0);
  FHeaders.EnumHeaders(
    procedure(AName, AValue: string)
    begin
      SetLength(LNames, Length(LNames) + 1);
      SetLength(LValues, Length(LValues) + 1);
      LNames[High(LNames)]   := AName;
      LValues[High(LValues)] := AValue;
    end);

  SetLength(FHeaderValues, Length(LNames));
  SetLength(FHeaderNames, Length(LNames));
  SetLength(FUnknownHeaders, Length(LNames));
  LUnknown := 0;

  for I := 0 to High(LNames) do
  begin
    FHeaderValues[I] := AnsiString(LValues[I]);
    LIndex := KnownResponseHeaderIndex(LNames[I]);
    if LIndex >= 0 then
    begin
      ARawResp.Headers.KnownHeaders[LIndex].pRawValue :=
        PAnsiChar(FHeaderValues[I]);
      ARawResp.Headers.KnownHeaders[LIndex].RawValueLength :=
        Length(FHeaderValues[I]);
    end
    else
    begin
      FHeaderNames[LUnknown] := AnsiString(LNames[I]);
      FUnknownHeaders[LUnknown].pName          := PAnsiChar(FHeaderNames[LUnknown]);
      FUnknownHeaders[LUnknown].NameLength     := Length(FHeaderNames[LUnknown]);
      FUnknownHeaders[LUnknown].pRawValue      := PAnsiChar(FHeaderValues[I]);
      FUnknownHeaders[LUnknown].RawValueLength := Length(FHeaderValues[I]);
      Inc(LUnknown);
    end;
  end;

  if LUnknown > 0 then
  begin
    ARawResp.Headers.UnknownHeaderCount := LUnknown;
    ARawResp.Headers.pUnknownHeaders    := @FUnknownHeaders[0];
  end;
end;

procedure TDXHttpSysResponse.BuildHttpResponse(
  ABodyData:   Pointer;
  ABodyLength: ULONG;
  out ARawResp: HTTP_RESPONSE;
  out AChunk:   HTTP_DATA_CHUNK);
begin
  FillChar(ARawResp, SizeOf(ARawResp), 0);
  ARawResp.StatusCode   := FStatusCode;
  ARawResp.pReason      := PAnsiChar(FReasonPhrase);
  ARawResp.ReasonLength := Length(FReasonPhrase);
  ARawResp.Version      := HTTPAPI_VERSION_2;

  BuildHeaders(ARawResp);

  // Body chunk
  if (ABodyData <> nil) and (ABodyLength > 0) then
  begin
    AChunk := BuildDataChunk(ABodyData, ABodyLength);
    ARawResp.EntityChunkCount := 1;
    ARawResp.pEntityChunks    := @AChunk;
  end;
end;

class function TDXHttpSysResponse.BuildDataChunk(AData: Pointer;
  ALength: ULONG): HTTP_DATA_CHUNK;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.DataChunkType           := HttpDataChunkFromMemory;
  Result.FromMemory.pBuffer      := AData;
  Result.FromMemory.BufferLength := ALength;
end;

procedure TDXHttpSysResponse.SendHeaders(AFlags: ULONG; ABodyData: Pointer;
  ABodyLength: ULONG; const AContext: string);
var
  LRawResp:   HTTP_RESPONSE;
  LChunk:     HTTP_DATA_CHUNK;
  LBytesSent: ULONG;
  LResult:    ULONG;
begin
  // LChunk is referenced by LRawResp.pEntityChunks (body case only) and must
  // stay alive for the duration of the synchronous call.
  BuildHttpResponse(ABodyData, ABodyLength, LRawResp, LChunk);

  LBytesSent := 0;
  LResult := FApi.SendHttpResponse(
    FQueueHandle,
    FRequestId,
    AFlags,
    @LRawResp,
    nil,           // pCachePolicy
    @LBytesSent,
    nil,           // pReserved1
    0,             // Reserved2
    nil,           // pOverlapped (synchronous)
    nil);          // pLogData

  TDXHttpSysApi.CheckResult(LResult, AContext);
end;

function TDXHttpSysResponse.SendEntityBody(AFlags: ULONG; AChunkCount: USHORT;
  AChunks: PHTTP_DATA_CHUNK): ULONG;
var
  LBytesSent: ULONG;
begin
  LBytesSent := 0;
  Result := FApi.SendResponseEntityBody(
    FQueueHandle,
    FRequestId,
    AFlags,
    AChunkCount,
    AChunks,
    @LBytesSent,
    nil,           // pReserved1
    0,             // Reserved2
    nil,           // pOverlapped (synchronous)
    nil);          // pLogData
end;

class function TDXHttpSysResponse.IsStreamOverError(ACode: ULONG): Boolean;
begin
  // "The connection/stream is gone" — the client disconnected
  // (CONNECTION_INVALID / NETNAME_DELETED) or the request queue was closed or
  // the I/O aborted during server shutdown (INVALID_HANDLE / OPERATION_ABORTED).
  // Everything else is a genuine failure of the call itself.
  Result := (ACode = ERROR_CONNECTION_INVALID)
    or (ACode = ERROR_NETNAME_DELETED)
    or (ACode = ERROR_INVALID_HANDLE)
    or (ACode = ERROR_OPERATION_ABORTED);
end;

procedure TDXHttpSysResponse.Send;
var
  LBodyData:   Pointer;
  LBodyLength: ULONG;
begin
  CheckNotSent;

  // Prepare body data
  LBodyLength := FBody.Size;
  if LBodyLength > 0 then
  begin
    FBody.Position := 0;
    LBodyData := FBody.Memory;

    // Set Content-Length if not explicitly provided
    if not FHeaders.HasHeader('content-length') then
      FHeaders['content-length'] := IntToStr(LBodyLength);
  end
  else
    LBodyData := nil;

  SendHeaders(0, LBodyData, LBodyLength, 'HttpSendHttpResponse');

  // Mark as sent only after the call succeeded: a failed Send leaves the state
  // NotSent, so the worker's error path can still attempt an error response.
  FState := TDXHttpSysResponseState.Sent;
end;

procedure TDXHttpSysResponse.SendError(AStatusCode: Word; const AReason: string);
begin
  CheckNotSent;
  StatusCode := AStatusCode;
  if AReason <> '' then
    ReasonPhrase := AReason;
  Send;
end;

procedure TDXHttpSysResponse.BeginStream;
begin
  CheckNotSent;
  if not Assigned(FApi.SendResponseEntityBody) then
    raise EDXHttpSysError.CreateWin32(0,
      'BeginStream: HttpSendResponseEntityBody is not available (httpapi.dll v2 required)');
  if FHeaders.HasHeader('content-length') then
    raise EDXHttpSysError.CreateWin32(0,
      'BeginStream: a streaming response must not carry a Content-Length header');
  if FBody.Size > 0 then
    raise EDXHttpSysError.CreateWin32(0,
      'BeginStream: the response body must be empty — stream data is sent via SendChunk');

  // No Content-Length + MORE_DATA makes HTTP.sys switch to chunked transfer
  // encoding for HTTP/1.1 clients (SSE needs HTTP/1.1 anyway).
  SendHeaders(HTTP_SEND_RESPONSE_FLAG_MORE_DATA, nil, 0,
    'HttpSendHttpResponse (BeginStream)');

  // Enter the streaming state only after the headers actually went out: a
  // failed BeginStream leaves the state NotSent, so the worker's error path
  // can still send an error response.
  FState := TDXHttpSysResponseState.Streaming;
end;

function TDXHttpSysResponse.SendChunk(const AData: TBytes): Boolean;
var
  LChunk:  HTTP_DATA_CHUNK;
  LResult: ULONG;
begin
  if FState <> TDXHttpSysResponseState.Streaming then
    raise EDXHttpSysError.CreateWin32(0, 'SendChunk requires a prior BeginStream');

  // Cooperative cancellation: the server is shutting down. Report the stream
  // as over so the handler unwinds; the worker then completes the stream.
  if Cancelled then
    Exit(False);

  if Length(AData) = 0 then
    Exit(True);

  LChunk  := BuildDataChunk(@AData[0], Length(AData));
  LResult := SendEntityBody(HTTP_SEND_RESPONSE_FLAG_MORE_DATA, 1, @LChunk);

  if LResult = ERROR_SUCCESS then
    Exit(True);

  if IsStreamOverError(LResult) then
  begin
    // The client is gone (or the queue closed during shutdown) — the normal
    // end of a long-lived stream, not an error.
    FState := TDXHttpSysResponseState.Sent;
    Exit(False);
  end;

  // Anything else is a genuine failure (invalid parameter, resources, ...) and
  // must surface instead of masquerading as a client disconnect. The state
  // stays Streaming; the worker completes the stream best-effort.
  TDXHttpSysApi.CheckResult(LResult, 'HttpSendResponseEntityBody (SendChunk)');
  Result := False; // not reached — CheckResult raised
end;

procedure TDXHttpSysResponse.EndStream;
var
  LResult: ULONG;
begin
  if FState <> TDXHttpSysResponseState.Streaming then
    Exit; // no-op: never started, or the stream already ended (disconnect)

  // Whatever the API says below, the stream is over after this call.
  FState := TDXHttpSysResponseState.Sent;

  LResult := SendEntityBody(0 { no MORE_DATA — completes the response }, 0, nil);

  // A disconnect between the last chunk and EndStream is a normal race for
  // long-lived streams — only genuine failures raise.
  if (LResult <> ERROR_SUCCESS) and not IsStreamOverError(LResult) then
    TDXHttpSysApi.CheckResult(LResult, 'HttpSendResponseEntityBody (EndStream)');
end;

end.
