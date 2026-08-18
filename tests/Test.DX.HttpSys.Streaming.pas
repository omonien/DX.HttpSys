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
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Net.HttpClient,
  Winapi.WinSock2,
  Winapi.Windows,
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
        LClientRun.WaitFor;
        LClientRun.Free;
      end;
    finally
      LServer.Free;
    end;
  finally
    LStarted.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TStreamingIntegrationTests);

end.
