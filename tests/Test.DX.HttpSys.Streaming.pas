/// <summary>
///   Test.DX.HttpSys.Streaming - integration tests for the chunked streaming
///   API (BeginStream/SendChunk/EndStream/Cancelled) of TDXHttpSysResponse.
/// </summary>
/// <remarks>
///   Same end-to-end approach as Test.DX.HttpSys.Server: each test starts a
///   real TDXHttpSysServer on a free localhost port and drives it with
///   THTTPClient (which transparently consumes chunked transfer encoding). The
///   client only receives a complete response once the stream is terminated, so
///   a successful GET doubles as the assertion that EndStream - or the worker's
///   stream finalization - actually completed the response instead of leaving
///   the client hanging.
///
///   State observed inside the handler is echoed back through the response body
///   so every assertion runs on the client thread without shared state (except
///   the cancellation test, which needs an event plus a stopwatch by nature).
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-08-18</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Streaming;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStreamingIntegrationTests = class
  public
    // Happy path: chunks arrive concatenated and the response completes.
    [Test]
    procedure Stream_DeliversChunksAndCompletes;

    // The state machine as observed inside the handler (echoed via chunks).
    [Test]
    procedure Stream_StateTransitions;

    // Regression (review): a handler that raises after BeginStream used to
    // leave the chunked response unterminated - the client hung until socket
    // timeout. The worker now completes the stream.
    [Test]
    procedure HandlerRaisesMidStream_WorkerCompletesStream;

    // Regression (review): same class of bug for a handler that returns
    // without calling EndStream.
    [Test]
    procedure HandlerForgetsEndStream_WorkerCompletesStream;

    // Misuse guards raise the library exception type (EDXHttpSysError), not
    // EOSError/EInvalidOperation as before the review.
    [Test]
    procedure SendChunkWithoutBeginStream_RaisesDXError;

    [Test]
    procedure BeginStreamWithContentLength_RaisesDXError;

    [Test]
    procedure BeginStreamWithNonEmptyBody_RaisesDXError;

    [Test]
    procedure SecondBeginStream_RaisesDXError;

    // EndStream is a safe no-op outside the streaming state.
    [Test]
    procedure EndStreamWithoutBeginStream_IsNoOp;

    // Empty chunks are accepted and report the stream as still alive.
    [Test]
    procedure SendChunkEmptyData_ReturnsTrue;

    // Regression (review): Server.Stop used to wait out the full duration of
    // running streams. With cooperative cancellation (Response.Cancelled) it
    // returns promptly.
    [Test]
    procedure StopDuringStream_ReturnsPromptly;

    // The disconnect contract: a client that aborts mid-stream must surface as
    // SendChunk = False in the handler and must NOT be reported as a server
    // error (regression: ERROR_CONNECTION_ABORTED/RESET were misclassified as
    // genuine failures, producing spurious worker error reports).
    [Test]
    procedure ClientDisconnectMidStream_EndsCleanly;

    // HTTP/1.1 on the wire: "Transfer-Encoding: chunked" and the exact chunk
    // framing, unchanged by the protocol-dependent framing (regression guard).
    // The handler echoes the detected protocol version.
    [Test]
    procedure Http11RawWire_ChunkFramingUnchanged;

    // HTTP/1.0 on the wire: no Transfer-Encoding (RFC 9112 §6.1), the data goes
    // out unframed and the server closes the connection to end the body.
    [Test]
    procedure Http10RawWire_NoChunkedCoding_ClosesConnection;
  end;

  // The protocol-dependent framing decisions as pure functions. HTTP/2 needs a
  // TLS listener (HTTP.sys negotiates it via ALPN only), i.e. an elevated
  // certificate binding, so its wire behaviour is covered by
  // tests-integration/Http2StreamingCheck.ps1; these tests pin the decisions.
  [TestFixture]
  TStreamFramingTests = class
  public
    // Flags win over the request-line version (HTTP2 = $4, HTTP3 = $8).
    [Test]
    [TestCase('HTTP/1.1', '0,1,1,1,1')]
    [TestCase('HTTP/1.0', '0,1,0,1,0')]
    [TestCase('HTTP/2 flag', '4,1,1,2,0')]
    [TestCase('HTTP/2 flag, version 2.0', '4,2,0,2,0')]
    [TestCase('HTTP/3 flag', '8,1,1,3,0')]
    [TestCase('Other flags only', '3,1,1,1,1')]
    [TestCase('HTTP/2 flag with other flags', '7,0,0,2,0')]
    procedure ResolveProtocolVersion(AFlags, ARawMajor, ARawMinor,
      AExpectedMajor, AExpectedMinor: Integer);

    [Test]
    [TestCase('HTTP/1.1', '1,1,Chunked')]
    [TestCase('HTTP/1.2 (future 1.x)', '1,2,Chunked')]
    [TestCase('HTTP/1.0', '1,0,CloseDelimited')]
    [TestCase('HTTP/0.9', '0,9,CloseDelimited')]
    [TestCase('HTTP/2', '2,0,ProtocolFrames')]
    [TestCase('HTTP/3', '3,0,ProtocolFrames')]
    procedure GetStreamFraming(AMajor, AMinor: Integer; const AExpected: string);

    [Test]
    [TestCase('HTTP/1.1 transfer-encoding', 'transfer-encoding,1,1,True')]
    [TestCase('HTTP/1.1 connection', 'Connection,1,1,True')]
    [TestCase('HTTP/1.1 keep-alive', 'keep-alive,1,1,True')]
    [TestCase('HTTP/1.1 upgrade', 'upgrade,1,1,True')]
    [TestCase('HTTP/2 transfer-encoding', 'transfer-encoding,2,0,False')]
    [TestCase('HTTP/2 Transfer-Encoding', 'Transfer-Encoding,2,0,False')]
    [TestCase('HTTP/2 connection', 'connection,2,0,False')]
    [TestCase('HTTP/2 keep-alive', 'Keep-Alive,2,0,False')]
    [TestCase('HTTP/2 proxy-connection', 'proxy-connection,2,0,False')]
    [TestCase('HTTP/2 upgrade', 'upgrade,2,0,False')]
    [TestCase('HTTP/3 transfer-encoding', 'transfer-encoding,3,0,False')]
    [TestCase('HTTP/2 content-type', 'content-type,2,0,True')]
    [TestCase('HTTP/2 cache-control', 'cache-control,2,0,True')]
    [TestCase('HTTP/2 server', 'server,2,0,True')]
    [TestCase('HTTP/1.0 transfer-encoding', 'transfer-encoding,1,0,False')]
    [TestCase('HTTP/1.0 connection', 'connection,1,0,True')]
    [TestCase('HTTP/1.0 content-type', 'content-type,1,0,True')]
    procedure IsHeaderAllowed(const AName: string; AMajor, AMinor: Integer;
      AExpected: Boolean);
  end;

  // The send sequence a response hands to HTTP.sys per protocol version, with
  // the two send functions of TDXHttpSysApi replaced by recording fakes. This
  // runs the HTTP/2 paths (which need an elevated TLS binding on the wire)
  // without elevation.
  [TestFixture]
  TStreamSendSequenceTests = class
  private
    FApi: TObject; // TDXHttpSysApi with fake send functions
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // HTTP/2: no Transfer-Encoding, no connection-specific headers, unframed
    // DATA, an empty final send without MORE_DATA.
    [Test]
    procedure Http2_Stream_UnframedDataAndEmptyFinalSend;

    // HTTP/3 takes the same path as HTTP/2.
    [Test]
    procedure Http3_Stream_UnframedDataAndEmptyFinalSend;

    // HTTP/1.1: exactly the sequence before the protocol-dependent framing.
    [Test]
    procedure Http11_Stream_ChunkFramingUnchanged;

    // HTTP/1.0: no Transfer-Encoding, DISCONNECT on the header send and on the
    // final send, unframed data.
    [Test]
    procedure Http10_Stream_CloseDelimited;

    // HTTP/2 single-shot Send: connection-specific headers are dropped too.
    [Test]
    procedure Http2_Send_DropsConnectionSpecificHeaders;

    // A failed BeginStream leaves no "Transfer-Encoding: chunked" behind for the
    // error response the worker sends next (it has a Content-Length body).
    [Test]
    procedure FailedBeginStream_ErrorResponseHasNoTransferEncoding;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Net.HttpClient,
  System.Rtti,
  Winapi.WinSock2,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  // A small handler driven by a closure, so each test can define its behaviour
  // inline without a dedicated class (same pattern as Test.DX.HttpSys.Server).
  TProcHandler = class(TInterfacedObject, IDXHttpSysRequestHandler)
  private
    FProc: TProc<TDXHttpSysRequest, TDXHttpSysResponse>;
  public
    constructor Create(const AProc: TProc<TDXHttpSysRequest, TDXHttpSysResponse>);
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

constructor TProcHandler.Create(
  const AProc: TProc<TDXHttpSysRequest, TDXHttpSysResponse>);
begin
  inherited Create;
  FProc := AProc;
end;

procedure TProcHandler.HandleRequest(const ARequest: TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
begin
  FProc(ARequest, AResponse);
end;

type
  // Collects OnError reports (thread-safe) so tests can assert that no error -
  // or exactly the expected one - was reported by the worker. Without this, an
  // assertion failing INSIDE a handler would be swallowed by the worker's
  // exception guard and the test could pass silently.
  TErrorCollector = class
  private
    FLock:  TCriticalSection;
    FItems: TStringList;
    function GetText: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Report(const AException: Exception; const AContext: string);
    property Text: string read GetText;
  end;

constructor TErrorCollector.Create;
begin
  inherited Create;
  FLock  := TCriticalSection.Create;
  FItems := TStringList.Create;
end;

destructor TErrorCollector.Destroy;
begin
  FreeAndNil(FItems);
  FreeAndNil(FLock);
  inherited;
end;

procedure TErrorCollector.Report(const AException: Exception;
  const AContext: string);
begin
  FLock.Enter;
  try
    FItems.Add(Format('[%s] %s: %s',
      [AContext, AException.ClassName, AException.Message]));
  finally
    FLock.Leave;
  end;
end;

function TErrorCollector.GetText: string;
begin
  FLock.Enter;
  try
    Result := FItems.Text.Trim;
  finally
    FLock.Leave;
  end;
end;

// Picks a free TCP port by binding to port 0 and reading back the assignment.
// Another process could still take the port between the probe and the HTTP.sys
// bind, so these tests must run sequentially (DUnitX does) — same caveat as
// Test.DX.HttpSys.Server.
function FindFreePort: Word;
var
  LData: TWSAData;
  LSock: TSocket;
  LAddr: TSockAddrIn;
  LLen:  Integer;
begin
  Result := 0;
  if WSAStartup($0202, LData) <> 0 then
    Exit;
  try
    LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if LSock = INVALID_SOCKET then
      Exit;
    try
      FillChar(LAddr, SizeOf(LAddr), 0);
      LAddr.sin_family := AF_INET;
      LAddr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);
      LAddr.sin_port := 0;
      if bind(LSock, TSockAddr(LAddr), SizeOf(LAddr)) = 0 then
      begin
        LLen := SizeOf(LAddr);
        if getsockname(LSock, TSockAddr(LAddr), LLen) = 0 then
          Result := ntohs(LAddr.sin_port);
      end;
    finally
      closesocket(LSock);
    end;
  finally
    WSACleanup;
  end;
end;

// Builds and starts a server on localhost:APort with the given handler. The
// optional error sink must be wired BEFORE Start (the pool copies it there).
function StartServer(APort: Word;
  const AHandler: IDXHttpSysRequestHandler;
  const AOnError: TOnHttpSysError = nil): TDXHttpSysServer;
begin
  Result := TDXHttpSysServer.Create;
  try
    Result.Handler := AHandler;
    Result.OnError := AOnError;
    Result.AddUrlPrefix(Format('http://localhost:%d/', [APort]));
    Result.Start;
  except
    Result.Free;
    raise;
  end;
end;

function BaseUrl(APort: Word): string;
begin
  Result := Format('http://localhost:%d/', [APort]);
end;

// GET with a bounded response timeout: a regression that leaves a stream
// unterminated must fail the test quickly, not hang the run.
type
  // Plain value copy of the interesting response parts, so no IHTTPResponse
  // outlives its owning THTTPClient.
  TGetResult = record
    StatusCode: Integer;
    MimeType:   string;
    Content:    string;
  end;

function BoundedGet(const AUrl: string): TGetResult;
var
  LClient:   THTTPClient;
  LHttpResp: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.ConnectionTimeout := 5000;
    LClient.ResponseTimeout   := 5000;
    LHttpResp := LClient.Get(AUrl);
    Result.StatusCode := LHttpResp.StatusCode;
    Result.MimeType   := LHttpResp.MimeType;
    Result.Content    := LHttpResp.ContentAsString(TEncoding.UTF8);
    LHttpResp := nil; // release before the client goes away
  finally
    LClient.Free;
  end;
end;

function Utf8Chunk(const AText: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(AText);
end;

// Opens a raw socket to the streaming endpoint, reads until the stream started
// (headers + first chunk), then aborts the connection with a hard close (RST).
// The server side must then observe SendChunk = False — not a server error.
procedure AbortSseConnection(APort: Word);
var
  LData:    TWSAData;
  LSock:    TSocket;
  LAddr:    TSockAddrIn;
  LLinger:  TLinger;
  LTimeout: Integer;
  LRequest: string;
  LBytes:   TBytes;
  LBuffer:  array[0..1023] of Byte;
  LLen:     Integer;
begin
  Assert.IsTrue(WSAStartup($0202, LData) = 0, 'WSAStartup failed');
  try
    LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    Assert.IsTrue(LSock <> INVALID_SOCKET, 'socket failed');
    try
      LTimeout := 5000;
      setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO, @LTimeout, SizeOf(LTimeout));

      FillChar(LAddr, SizeOf(LAddr), 0);
      LAddr.sin_family      := AF_INET;
      LAddr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);
      LAddr.sin_port        := htons(APort);
      Assert.IsTrue(connect(LSock, TSockAddr(LAddr), SizeOf(LAddr)) = 0,
        'connect failed');

      LRequest := 'GET / HTTP/1.1'#13#10 +
        'Host: localhost:' + IntToStr(APort) + #13#10 +
        'Connection: keep-alive'#13#10#13#10;
      LBytes := TEncoding.UTF8.GetBytes(LRequest);
      Assert.IsTrue(send(LSock, LBytes[0], Length(LBytes), 0) > 0,
        'send failed');

      // Wait until the stream actually started, then abort with RST so the
      // server observes a hard disconnect (not a graceful close).
      LLen := recv(LSock, LBuffer[0], SizeOf(LBuffer), 0);
      Assert.IsTrue(LLen > 0, 'no data received from the stream');

      LLinger.l_onoff  := 1;
      LLinger.l_linger := 0;
      setsockopt(LSock, SOL_SOCKET, SO_LINGER, @LLinger, SizeOf(LLinger));
    finally
      closesocket(LSock);
    end;
  finally
    WSACleanup;
  end;
end;

// Sends a raw request over a fresh socket and reads the whole reply until the
// server closes the connection. AClosedByServer is False when the read ended
// by the receive timeout (or an error) instead — the server never closed it.
// Every byte becomes one Char of the same ordinal, so framing is visible.
function RawExchange(APort: Word; const ARequest: string;
  out AClosedByServer: Boolean): string;
var
  LData:    TWSAData;
  LSock:    TSocket;
  LAddr:    TSockAddrIn;
  LTimeout: Integer;
  LBytes:   TBytes;
  LBuffer:  array[0..4095] of Byte;
  LLen:     Integer;
  LReply:   TBytesStream;
  I:        Integer;
begin
  AClosedByServer := False;
  Result := '';
  Assert.IsTrue(WSAStartup($0202, LData) = 0, 'WSAStartup failed');
  try
    LSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    Assert.IsTrue(LSock <> INVALID_SOCKET, 'socket failed');
    LReply := TBytesStream.Create;
    try
      LTimeout := 5000;
      setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO, @LTimeout, SizeOf(LTimeout));

      FillChar(LAddr, SizeOf(LAddr), 0);
      LAddr.sin_family      := AF_INET;
      LAddr.sin_addr.S_addr := htonl(INADDR_LOOPBACK);
      LAddr.sin_port        := htons(APort);
      Assert.IsTrue(connect(LSock, TSockAddr(LAddr), SizeOf(LAddr)) = 0,
        'connect failed');

      LBytes := TEncoding.ASCII.GetBytes(ARequest);
      Assert.IsTrue(send(LSock, LBytes[0], Length(LBytes), 0) = Length(LBytes),
        'send failed');

      repeat
        LLen := recv(LSock, LBuffer[0], SizeOf(LBuffer), 0);
        if LLen > 0 then
          LReply.WriteBuffer(LBuffer[0], LLen);
      until LLen <= 0;
      AClosedByServer := LLen = 0; // 0 = orderly close; SOCKET_ERROR = timeout
      SetLength(Result, LReply.Size);
      for I := 0 to LReply.Size - 1 do
        Result[I + 1] := Char(LReply.Bytes[I]);
    finally
      LReply.Free;
      closesocket(LSock);
    end;
  finally
    WSACleanup;
  end;
end;

// Splits a raw HTTP reply at the blank line into header block and body.
procedure SplitReply(const AReply: string; out AHead, ABody: string);
var
  LPos: Integer;
begin
  LPos := Pos(#13#10#13#10, AReply);
  Assert.IsTrue(LPos > 0, 'no header terminator in the reply: ' + AReply);
  AHead := Copy(AReply, 1, LPos + 1);
  ABody := Copy(AReply, LPos + 4, MaxInt);
end;

// A streaming handler that echoes the detected protocol version as its first
// chunk, then a second chunk, then ends the stream.
function VersionEchoHandler: IDXHttpSysRequestHandler;
begin
  Result := TProcHandler.Create(
    procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
    begin
      AResp.Headers['content-type'] := 'text/plain';
      AResp.BeginStream;
      AResp.SendChunk(Utf8Chunk(Format('%d.%d|',
        [AReq.ProtocolVersion.MajorVersion, AReq.ProtocolVersion.MinorVersion])));
      AResp.SendChunk(Utf8Chunk('tail'));
      AResp.EndStream;
    end);
end;

// -----------------------------------------------------------------------------
// TStreamingIntegrationTests
// -----------------------------------------------------------------------------

procedure TStreamingIntegrationTests.Stream_DeliversChunksAndCompletes;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
  LErrors: TErrorCollector;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'could not find a free port');

  LErrors := TErrorCollector.Create;
  try
    LServer := StartServer(LPort,
      TProcHandler.Create(
        procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
        begin
          AResp.Headers['content-type'] := 'text/event-stream';
          AResp.BeginStream;
          Assert.IsTrue(AResp.SendChunk(Utf8Chunk('one|')), 'chunk 1');
          Assert.IsTrue(AResp.SendChunk(Utf8Chunk('two|')), 'chunk 2');
          Assert.IsTrue(AResp.SendChunk(Utf8Chunk('three')), 'chunk 3');
          AResp.EndStream;
        end),
      LErrors.Report);
    try
      LResp := BoundedGet(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.Contains(LResp.MimeType, 'text/event-stream', True, 'content-type');
      Assert.AreEqual('one|two|three', LResp.Content, 'body');
    finally
      LServer.Free; // joins the workers - late error reports land before this returns
    end;
    Assert.AreEqual('', LErrors.Text, 'no worker-side errors');
  finally
    LErrors.Free;
  end;
end;

procedure TStreamingIntegrationTests.Stream_StateTransitions;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
  LErrors: TErrorCollector;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LErrors := TErrorCollector.Create;
  try
    LServer := StartServer(LPort,
      TProcHandler.Create(
        procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
        var
          LBefore, LDuring: string;
        begin
          LBefore := Format('before:streaming=%s,sent=%s|',
            [BoolToStr(AResp.Streaming, True), BoolToStr(AResp.Sent, True)]);
          AResp.BeginStream;
          LDuring := Format('during:streaming=%s,sent=%s',
            [BoolToStr(AResp.Streaming, True), BoolToStr(AResp.Sent, True)]);
          AResp.SendChunk(Utf8Chunk(LBefore));
          AResp.SendChunk(Utf8Chunk(LDuring));
          AResp.EndStream;
          // After EndStream the response is complete. A failure here raises on
          // the worker thread and surfaces through the error collector below.
          Assert.IsFalse(AResp.Streaming, 'streaming after EndStream');
          Assert.IsTrue(AResp.Sent, 'sent after EndStream');
        end),
      LErrors.Report);
    try
      LResp := BoundedGet(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode);
      Assert.AreEqual(
        'before:streaming=False,sent=False|during:streaming=True,sent=False',
        LResp.Content, 'state transitions');
    finally
      LServer.Free; // joins the workers - late error reports land before this returns
    end;
    Assert.AreEqual('', LErrors.Text, 'no worker-side errors');
  finally
    LErrors.Free;
  end;
end;

procedure TStreamingIntegrationTests.HandlerRaisesMidStream_WorkerCompletesStream;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
  LErrors: TErrorCollector;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LErrors := TErrorCollector.Create;
  try
    LServer := StartServer(LPort,
      TProcHandler.Create(
        procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
        begin
          AResp.BeginStream;
          AResp.SendChunk(Utf8Chunk('partial'));
          raise Exception.Create('boom mid-stream');
        end),
      LErrors.Report);
    try
      // The worker must terminate the chunked response despite the exception:
      // the client gets a COMPLETE (albeit truncated-in-content) 200 response
      // instead of hanging until socket timeout.
      LResp := BoundedGet(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode, 'headers went out before the exception');
      Assert.AreEqual('partial', LResp.Content, 'body');
    finally
      LServer.Free; // joins the workers - late error reports land before this returns
    end;
    // ... and the original handler exception is still reported.
    Assert.Contains(LErrors.Text, 'boom mid-stream', 'handler error reported');
  finally
    LErrors.Free;
  end;
end;

procedure TStreamingIntegrationTests.HandlerForgetsEndStream_WorkerCompletesStream;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
  LErrors: TErrorCollector;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LErrors := TErrorCollector.Create;
  try
    LServer := StartServer(LPort,
      TProcHandler.Create(
        procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
        begin
          AResp.BeginStream;
          AResp.SendChunk(Utf8Chunk('no-endstream'));
          // Handler returns without EndStream - the worker completes the stream.
        end),
      LErrors.Report);
    try
      LResp := BoundedGet(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode);
      Assert.AreEqual('no-endstream', LResp.Content, 'body');
    finally
      LServer.Free; // joins the workers - late error reports land before this returns
    end;
    Assert.AreEqual('', LErrors.Text, 'silent completion, no error report');
  finally
    LErrors.Free;
  end;
end;

procedure TStreamingIntegrationTests.SendChunkWithoutBeginStream_RaisesDXError;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LOutcome: string;
      begin
        // Echo the guard behaviour back in the body so the assertion runs on
        // the client thread.
        try
          AResp.SendChunk(Utf8Chunk('x'));
          LOutcome := 'no-raise';
        except
          on EDXHttpSysError do
            LOutcome := 'raised:EDXHttpSysError';
          on E: Exception do
            LOutcome := 'raised:' + E.ClassName;
        end;
        AResp.SetBody(LOutcome);
      end));
  try
    LResp := BoundedGet(BaseUrl(LPort));
    Assert.AreEqual('raised:EDXHttpSysError',
      LResp.Content, 'guard exception type');
  finally
    LServer.Free;
  end;
end;

procedure TStreamingIntegrationTests.BeginStreamWithContentLength_RaisesDXError;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LOutcome: string;
      begin
        // The outcome bodies are exactly 24 bytes, so the pre-set
        // Content-Length stays correct for the ordinary Send afterwards.
        AResp.Headers['content-length'] := '24';
        try
          AResp.BeginStream;
          LOutcome := 'no-raise................';
        except
          on EDXHttpSysError do
            LOutcome := 'raised:EDXHttpSysError..';
          on E: Exception do
            LOutcome := ('raised:' + E.ClassName + StringOfChar('.', 24)).Substring(0, 24);
        end;
        AResp.SetBody(LOutcome);
      end));
  try
    LResp := BoundedGet(BaseUrl(LPort));
    Assert.AreEqual('raised:EDXHttpSysError..',
      LResp.Content, 'guard exception type');
  finally
    LServer.Free;
  end;
end;

procedure TStreamingIntegrationTests.BeginStreamWithNonEmptyBody_RaisesDXError;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LOutcome: string;
      begin
        AResp.SetBody('buffered body');
        try
          AResp.BeginStream;
          LOutcome := 'no-raise';
        except
          on EDXHttpSysError do
            LOutcome := 'raised:EDXHttpSysError';
          on E: Exception do
            LOutcome := 'raised:' + E.ClassName;
        end;
        AResp.Body.Clear;
        AResp.SetBody(LOutcome);
      end));
  try
    LResp := BoundedGet(BaseUrl(LPort));
    Assert.AreEqual('raised:EDXHttpSysError',
      LResp.Content, 'guard exception type');
  finally
    LServer.Free;
  end;
end;

procedure TStreamingIntegrationTests.SecondBeginStream_RaisesDXError;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LOutcome: string;
      begin
        AResp.BeginStream;
        try
          AResp.BeginStream;
          LOutcome := 'no-raise';
        except
          on EDXHttpSysError do
            LOutcome := 'raised:EDXHttpSysError';
          on E: Exception do
            LOutcome := 'raised:' + E.ClassName;
        end;
        AResp.SendChunk(Utf8Chunk(LOutcome));
        AResp.EndStream;
      end));
  try
    LResp := BoundedGet(BaseUrl(LPort));
    Assert.AreEqual(200, LResp.StatusCode);
    Assert.AreEqual('raised:EDXHttpSysError',
      LResp.Content, 'guard exception type');
  finally
    LServer.Free;
  end;
end;

procedure TStreamingIntegrationTests.EndStreamWithoutBeginStream_IsNoOp;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      begin
        AResp.EndStream; // must be a silent no-op before any stream
        AResp.SetBody('still fine');
      end));
  try
    LResp := BoundedGet(BaseUrl(LPort));
    Assert.AreEqual(200, LResp.StatusCode);
    Assert.AreEqual('still fine', LResp.Content);
  finally
    LServer.Free;
  end;
end;

procedure TStreamingIntegrationTests.SendChunkEmptyData_ReturnsTrue;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LResp:   TGetResult;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LEmptyOk: Boolean;
      begin
        AResp.BeginStream;
        LEmptyOk := AResp.SendChunk(nil);
        AResp.SendChunk(Utf8Chunk('empty-ok=' + BoolToStr(LEmptyOk, True)));
        AResp.EndStream;
      end));
  try
    LResp := BoundedGet(BaseUrl(LPort));
    Assert.AreEqual(200, LResp.StatusCode);
    Assert.AreEqual('empty-ok=True', LResp.Content);
  finally
    LServer.Free;
  end;
end;

procedure TStreamingIntegrationTests.StopDuringStream_ReturnsPromptly;
const
  // The handler would stream for ~30 s if cancellation did not interrupt it.
  cLoopIterations   = 300;
  cStopBudgetMs     = 5000;
var
  LPort:      Word;
  LServer:    TDXHttpSysServer;
  LStarted:   TSimpleEvent;
  LClientRun: TThread;
  LWatch:     TStopwatch;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LStarted := TSimpleEvent.Create;
  try
    LServer := StartServer(LPort,
      TProcHandler.Create(
        procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
        begin
          AResp.BeginStream;
          LStarted.SetEvent;
          for var I := 1 to cLoopIterations do
          begin
            if not AResp.SendChunk(Utf8Chunk('tick')) then
              Exit; // disconnect or shutdown
            for var J := 1 to 10 do
            begin
              Sleep(10);
              if AResp.Cancelled then
                Exit; // cooperative cancellation - the worker ends the stream
            end;
          end;
        end));
    try
      // Drive the stream from a background client; its response will die with
      // the server, which is expected here.
      LClientRun := TThread.CreateAnonymousThread(
        procedure
        begin
          try
            BoundedGet(BaseUrl(LPort));
          except
            // Expected: the server goes away mid-stream.
          end;
        end);
      LClientRun.FreeOnTerminate := False;
      LClientRun.Start;
      try
        Assert.IsTrue(LStarted.WaitFor(cStopBudgetMs) = TWaitResult.wrSignaled,
          'stream did not start');

        LWatch := TStopwatch.StartNew;
        LServer.Stop;
        LWatch.Stop;

        Assert.IsTrue(LWatch.ElapsedMilliseconds < cStopBudgetMs,
          Format('Stop took %d ms - cancellation did not interrupt the stream',
            [LWatch.ElapsedMilliseconds]));
      finally
        // Bound the join: the client may only finish once the server closed
        // the queue; if it does not within the budget, the test must not hang.
        var LClientWatch := TStopwatch.StartNew;
        while (not LClientRun.Finished)
          and (LClientWatch.ElapsedMilliseconds < cStopBudgetMs) do
          Sleep(10);
        Assert.IsTrue(LClientRun.Finished, 'client did not end after server stop');
        LClientRun.Free;
      end;
    finally
      LServer.Free;
    end;
  finally
    LStarted.Free;
  end;
end;

procedure TStreamingIntegrationTests.ClientDisconnectMidStream_EndsCleanly;
const
  cBudgetMs = 5000;
var
  LPort:           Word;
  LServer:         TDXHttpSysServer;
  LErrors:         TErrorCollector;
  LStarted:        TSimpleEvent;
  LDisconnectSeen: TSimpleEvent;
  LHandlerDone:    TSimpleEvent;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LErrors := TErrorCollector.Create;
  LStarted := TSimpleEvent.Create;
  LDisconnectSeen := TSimpleEvent.Create;
  LHandlerDone := TSimpleEvent.Create;
  try
    LServer := StartServer(LPort,
      TProcHandler.Create(
        procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
        begin
          try
            AResp.BeginStream;
            AResp.SendChunk(Utf8Chunk('first'));
            LStarted.SetEvent;
            while AResp.SendChunk(Utf8Chunk('keepalive')) do
            begin
              if AResp.Cancelled then
                Break;
              Sleep(10);
            end;
            if not AResp.Cancelled then
              LDisconnectSeen.SetEvent; // SendChunk ended by disconnect, not shutdown
          finally
            AResp.EndStream; // no-op after a disconnect
            LHandlerDone.SetEvent;
          end;
        end), LErrors.Report);
    try
      // AbortSseConnection issues the GET that makes the handler run, reads the
      // start of the stream, then aborts with RST — only after that can the
      // handler-side events be awaited.
      AbortSseConnection(LPort);
      Assert.IsTrue(LStarted.WaitFor(cBudgetMs) = TWaitResult.wrSignaled,
        'stream did not start');
      Assert.IsTrue(LDisconnectSeen.WaitFor(cBudgetMs) = TWaitResult.wrSignaled,
        'handler did not observe the client disconnect');
      Assert.IsTrue(LHandlerDone.WaitFor(cBudgetMs) = TWaitResult.wrSignaled,
        'handler did not finish after the disconnect');
      Assert.AreEqual('', LErrors.Text,
        'a client disconnect must not be reported as a server error');
    finally
      LServer.Free;
    end;
  finally
    LHandlerDone.Free;
    LDisconnectSeen.Free;
    LStarted.Free;
    LErrors.Free;
  end;
end;

procedure TStreamingIntegrationTests.Http11RawWire_ChunkFramingUnchanged;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LErrors: TErrorCollector;
  LReply, LHead, LBody: string;
  LClosed: Boolean;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LErrors := TErrorCollector.Create;
  try
    LServer := StartServer(LPort, VersionEchoHandler, LErrors.Report);
    try
      // Connection: close lets the read end at the server's close; the chunked
      // body itself is complete before that (terminal chunk asserted below).
      LReply := RawExchange(LPort, 'GET / HTTP/1.1'#13#10 +
        'Host: localhost:' + IntToStr(LPort) + #13#10 +
        'Connection: close'#13#10#13#10, LClosed);
    finally
      LServer.Free;
    end;
    Assert.IsTrue(LClosed, 'server did not close the connection: ' + LReply);
    SplitReply(LReply, LHead, LBody);
    Assert.StartsWith('HTTP/1.1 200', LHead, 'status line');
    Assert.Contains(LHead, #13#10'Transfer-Encoding: chunked'#13#10, True,
      'chunked announced');
    Assert.AreEqual('4'#13#10'1.1|'#13#10 + '4'#13#10'tail'#13#10 +
      '0'#13#10#13#10, LBody, 'chunk framing on the wire');
    Assert.AreEqual('', LErrors.Text, 'no worker-side errors');
  finally
    LErrors.Free;
  end;
end;

procedure TStreamingIntegrationTests.Http10RawWire_NoChunkedCoding_ClosesConnection;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LErrors: TErrorCollector;
  LReply, LHead, LBody: string;
  LClosed: Boolean;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LErrors := TErrorCollector.Create;
  try
    LServer := StartServer(LPort, VersionEchoHandler, LErrors.Report);
    try
      // Keep-Alive asked for on purpose: the unframed body can only end with
      // the connection, so the server must close it regardless.
      LReply := RawExchange(LPort, 'GET / HTTP/1.0'#13#10 +
        'Host: localhost:' + IntToStr(LPort) + #13#10 +
        'Connection: keep-alive'#13#10#13#10, LClosed);
    finally
      LServer.Free;
    end;
    Assert.IsTrue(LClosed,
      'server did not close the connection (HTTP/1.0 client would hang): ' + LReply);
    SplitReply(LReply, LHead, LBody);
    Assert.Contains(LHead, ' 200 ', 'status line');
    Assert.DoesNotContain(LHead, 'Transfer-Encoding', True,
      'no chunked coding for an HTTP/1.0 client');
    Assert.DoesNotContain(LHead, 'keep-alive', True,
      'a close-delimited body must not announce keep-alive: ' + LHead);
    Assert.AreEqual('1.0|tail', LBody, 'unframed body');
    Assert.AreEqual('', LErrors.Text, 'no worker-side errors');
  finally
    LErrors.Free;
  end;
end;

// -----------------------------------------------------------------------------
// TStreamFramingTests
// -----------------------------------------------------------------------------

function MakeVersion(AMajor, AMinor: Integer): THTTP_VERSION;
begin
  Result.MajorVersion := AMajor;
  Result.MinorVersion := AMinor;
end;

procedure TStreamFramingTests.ResolveProtocolVersion(AFlags, ARawMajor,
  ARawMinor, AExpectedMajor, AExpectedMinor: Integer);
var
  LVersion: THTTP_VERSION;
begin
  LVersion := TDXHttpSysRequest.ResolveProtocolVersion(AFlags,
    MakeVersion(ARawMajor, ARawMinor));
  Assert.AreEqual(AExpectedMajor, Integer(LVersion.MajorVersion), 'major');
  Assert.AreEqual(AExpectedMinor, Integer(LVersion.MinorVersion), 'minor');
end;

procedure TStreamFramingTests.GetStreamFraming(AMajor, AMinor: Integer;
  const AExpected: string);
var
  LFraming: TDXHttpSysStreamFraming;
begin
  LFraming := TDXHttpSysResponse.GetStreamFraming(MakeVersion(AMajor, AMinor));
  Assert.AreEqual(AExpected,
    TRttiEnumerationType.GetName<TDXHttpSysStreamFraming>(LFraming));
end;

procedure TStreamFramingTests.IsHeaderAllowed(const AName: string; AMajor,
  AMinor: Integer; AExpected: Boolean);
begin
  Assert.AreEqual(AExpected,
    TDXHttpSysResponse.IsHeaderAllowed(AName, MakeVersion(AMajor, AMinor)));
end;

// -----------------------------------------------------------------------------
// TStreamSendSequenceTests — recording fakes for the two HTTP.sys send calls
// -----------------------------------------------------------------------------

var
  // One line per send call (tests run sequentially, on the test thread).
  GSendLog: TStringList;
  // Result code of the next HttpSendHttpResponse call (then reset to success).
  GNextHeaderResult: ULONG;

// Renders a byte buffer with CR/LF made visible, so the framing reads in a log.
function VisibleBytes(AData: PByte; ALength: ULONG): string;
var
  I: ULONG;
begin
  Result := '';
  if ALength = 0 then
    Exit;
  for I := 0 to ALength - 1 do
    case AData[I] of
      13: Result := Result + '\r';
      10: Result := Result + '\n';
    else
      Result := Result + Char(AData[I]);
    end;
end;

function ChunksText(ACount: USHORT; AChunks: PHTTP_DATA_CHUNK): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Integer(ACount) - 1 do
  begin
    Result := Result + VisibleBytes(AChunks^.FromMemory.pBuffer,
      AChunks^.FromMemory.BufferLength);
    Inc(AChunks);
  end;
end;

function BufferText(ABuffer: PAnsiChar; ALength: USHORT): string;
var
  LText: AnsiString;
begin
  Result := '';
  if (ABuffer = nil) or (ALength = 0) then
    Exit;
  SetString(LText, ABuffer, ALength);
  Result := string(LText);
end;

function KnownHeaderText(const AResponse: HTTP_RESPONSE; AId: HTTP_HEADER_ID): string;
begin
  Result := BufferText(AResponse.Headers.KnownHeaders[Ord(AId)].pRawValue,
    AResponse.Headers.KnownHeaders[Ord(AId)].RawValueLength);
end;

function FakeSendHttpResponse(ReqQueueHandle: THandle; RequestId: HTTP_REQUEST_ID;
  Flags: ULONG; pResponse: PHTTP_RESPONSE; pCachePolicy: Pointer;
  pBytesSent: PULONG; pReserved1: Pointer; Reserved2: ULONG;
  pOverlapped: POverlapped; pLogData: Pointer): ULONG; stdcall;
var
  LUnknown: string;
  LHeader:  PHTTP_UNKNOWN_HEADER;
  I:        Integer;
begin
  LUnknown := '';
  LHeader  := pResponse^.Headers.pUnknownHeaders;
  for I := 0 to Integer(pResponse^.Headers.UnknownHeaderCount) - 1 do
  begin
    LUnknown := LUnknown + BufferText(LHeader^.pName, LHeader^.NameLength) + ';';
    Inc(LHeader);
  end;
  GSendLog.Add(Format('H flags=%d te=%s connection=%s keep-alive=%s upgrade=%s ' +
    'content-length=%s unknown=%s body=%s', [Flags,
    KnownHeaderText(pResponse^, HttpHeaderTransferEncoding),
    KnownHeaderText(pResponse^, HttpHeaderConnection),
    KnownHeaderText(pResponse^, HttpHeaderKeepAlive),
    KnownHeaderText(pResponse^, HttpHeaderUpgrade),
    KnownHeaderText(pResponse^, HttpHeaderContentLength),
    LUnknown,
    ChunksText(pResponse^.EntityChunkCount, pResponse^.pEntityChunks)]));
  Result := GNextHeaderResult;
  GNextHeaderResult := ERROR_SUCCESS;
end;

function FakeSendResponseEntityBody(ReqQueueHandle: THandle;
  RequestId: HTTP_REQUEST_ID; Flags: ULONG; EntityChunkCount: USHORT;
  pEntityChunks: PHTTP_DATA_CHUNK; pBytesSent: PULONG; pReserved1: Pointer;
  Reserved2: ULONG; pOverlapped: POverlapped; pLogData: Pointer): ULONG; stdcall;
begin
  GSendLog.Add(Format('B flags=%d chunks=%d data=%s',
    [Flags, EntityChunkCount, ChunksText(EntityChunkCount, pEntityChunks)]));
  Result := ERROR_SUCCESS;
end;

// Runs a typical SSE stream (two events) on a response of the given version and
// returns the recorded send log.
function RecordStream(AApi: TDXHttpSysApi; AMajor, AMinor: Integer): string;
var
  LResponse: TDXHttpSysResponse;
begin
  GSendLog.Clear;
  LResponse := TDXHttpSysResponse.Create(AApi, 1, 1, MakeVersion(AMajor, AMinor));
  try
    LResponse.Headers['content-type']  := 'text/event-stream';
    LResponse.Headers['connection']    := 'keep-alive'; // a typical SSE handler habit
    LResponse.Headers['x-accel-buffering'] := 'no';
    LResponse.BeginStream;
    LResponse.SendChunk(Utf8Chunk('data: a'#10#10));
    LResponse.SendChunk(Utf8Chunk('data: bc'#10#10));
    LResponse.EndStream;
    Assert.IsTrue(LResponse.Sent, 'response complete after EndStream');
  finally
    LResponse.Free;
  end;
  Result := GSendLog.Text.Trim;
end;

procedure TStreamSendSequenceTests.Setup;
var
  LApi: TDXHttpSysApi;
begin
  GSendLog := TStringList.Create;
  GNextHeaderResult := ERROR_SUCCESS;
  LApi := TDXHttpSysApi.Create; // never loaded: only the two fakes are wired
  LApi.SendHttpResponse       := FakeSendHttpResponse;
  LApi.SendResponseEntityBody := FakeSendResponseEntityBody;
  FApi := LApi;
end;

procedure TStreamSendSequenceTests.TearDown;
begin
  FreeAndNil(FApi);
  FreeAndNil(GSendLog);
end;

procedure TStreamSendSequenceTests.Http2_Stream_UnframedDataAndEmptyFinalSend;
begin
  Assert.AreEqual(
    'H flags=2 te= connection= keep-alive= upgrade= content-length= unknown=x-accel-buffering; body='#13#10 +
    'B flags=2 chunks=1 data=data: a\n\n'#13#10 +
    'B flags=2 chunks=1 data=data: bc\n\n'#13#10 +
    'B flags=0 chunks=0 data=',
    RecordStream(TDXHttpSysApi(FApi), 2, 0));
end;

procedure TStreamSendSequenceTests.Http3_Stream_UnframedDataAndEmptyFinalSend;
begin
  Assert.AreEqual(RecordStream(TDXHttpSysApi(FApi), 2, 0),
    RecordStream(TDXHttpSysApi(FApi), 3, 0));
end;

procedure TStreamSendSequenceTests.Http11_Stream_ChunkFramingUnchanged;
begin
  Assert.AreEqual(
    'H flags=2 te=chunked connection=keep-alive keep-alive= upgrade= content-length= unknown=x-accel-buffering; body='#13#10 +
    'B flags=2 chunks=1 data=9\r\ndata: a\n\n\r\n'#13#10 +
    'B flags=2 chunks=1 data=A\r\ndata: bc\n\n\r\n'#13#10 +
    'B flags=0 chunks=1 data=0\r\n\r\n',
    RecordStream(TDXHttpSysApi(FApi), 1, 1));
end;

procedure TStreamSendSequenceTests.Http10_Stream_CloseDelimited;
begin
  Assert.AreEqual(
    'H flags=3 te= connection=keep-alive keep-alive= upgrade= content-length= unknown=x-accel-buffering; body='#13#10 +
    'B flags=2 chunks=1 data=data: a\n\n'#13#10 +
    'B flags=2 chunks=1 data=data: bc\n\n'#13#10 +
    'B flags=1 chunks=0 data=',
    RecordStream(TDXHttpSysApi(FApi), 1, 0));
end;

procedure TStreamSendSequenceTests.Http2_Send_DropsConnectionSpecificHeaders;
var
  LResponse: TDXHttpSysResponse;
begin
  GSendLog.Clear;
  LResponse := TDXHttpSysResponse.Create(TDXHttpSysApi(FApi), 1, 1, MakeVersion(2, 0));
  try
    LResponse.Headers['connection']        := 'close';
    LResponse.Headers['keep-alive']        := 'timeout=5';
    LResponse.Headers['upgrade']           := 'websocket';
    LResponse.Headers['proxy-connection']  := 'keep-alive';
    LResponse.Headers['transfer-encoding'] := 'chunked';
    LResponse.SetBody('ok');
    LResponse.Send;
  finally
    LResponse.Free;
  end;
  Assert.AreEqual(
    'H flags=0 te= connection= keep-alive= upgrade= content-length=2 unknown= body=ok',
    GSendLog.Text.Trim);
end;

procedure TStreamSendSequenceTests.FailedBeginStream_ErrorResponseHasNoTransferEncoding;
var
  LResponse: TDXHttpSysResponse;
begin
  GSendLog.Clear;
  GNextHeaderResult := ERROR_INVALID_PARAMETER; // the BeginStream header send fails
  LResponse := TDXHttpSysResponse.Create(TDXHttpSysApi(FApi), 1, 1, MakeVersion(1, 1));
  try
    Assert.WillRaise(
      procedure
      begin
        LResponse.BeginStream;
      end, EDXHttpSysError);
    Assert.IsFalse(LResponse.Streaming, 'failed BeginStream stays NotSent');
    LResponse.SendError(500); // what the worker does next
    Assert.IsTrue(LResponse.Sent);
  finally
    LResponse.Free;
  end;
  Assert.AreEqual(2, GSendLog.Count, GSendLog.Text);
  Assert.StartsWith('H flags=2 te=chunked ', GSendLog[0], 'the failed stream header send');
  Assert.StartsWith('H flags=0 te= ', GSendLog[1],
    'the 500 must not announce chunked coding: ' + GSendLog[1]);
end;

initialization
  TDUnitX.RegisterTestFixture(TStreamingIntegrationTests);
  TDUnitX.RegisterTestFixture(TStreamFramingTests);
  TDUnitX.RegisterTestFixture(TStreamSendSequenceTests);

end.
