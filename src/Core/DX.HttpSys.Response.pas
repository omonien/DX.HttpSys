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

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request;

type
  /// <summary>
  ///   The outgoing HTTP response. Set <c>StatusCode</c>, headers and body (via
  ///   <c>SetBody</c>/<c>SetJsonBody</c> or by writing to <c>Body</c>), then call
  ///   <c>Send</c>. <c>Send</c> may be called only once.
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
    FSent:         Boolean;

    // Buffers that must outlive the HttpSendHttpResponse call: the response
    // struct holds raw pointers into these, so they are instance fields kept
    // alive until Send returns.
    FHeaderValues:   array of AnsiString;       // backing storage for header values
    FHeaderNames:    array of AnsiString;       // backing storage for unknown header names
    FUnknownHeaders: array of HTTP_UNKNOWN_HEADER;

    procedure SetStatusCode(AValue: Word);
    function  GetReasonPhrase: string;
    procedure SetReasonPhrase(const AValue: string);
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
    FillChar(AChunk, SizeOf(AChunk), 0);
    AChunk.DataChunkType            := HttpDataChunkFromMemory;
    AChunk.FromMemory.pBuffer       := ABodyData;
    AChunk.FromMemory.BufferLength  := ABodyLength;
    ARawResp.EntityChunkCount := 1;
    ARawResp.pEntityChunks    := @AChunk;
  end;
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

end.
