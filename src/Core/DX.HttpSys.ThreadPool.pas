/// <summary>
///   DX.HttpSys.ThreadPool — receiver thread plus worker thread pool for TDXHttpSysServer.
/// </summary>
/// <remarks>
///   Architecture:
///     1 TDXHttpSysReceiverThread  - blocking HttpReceiveHttpRequest loop;
///                                   posts work items into TDXHttpSysPendingQueue
///     N TDXHttpSysWorkerThread    - take work items from the queue, create
///                                   request/response objects and invoke
///                                   IDXHttpSysRequestHandler.HandleRequest
///
///   Error handling:
///     Unhandled exceptions in worker threads -> 500 response + OnError callback
///     A crashed worker thread is restarted automatically
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.ThreadPool;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request,
  DX.HttpSys.Response;

const
  // Buffer size for HttpReceiveHttpRequest
  // 16 KB also covers authentication headers
  DEFAULT_REQUEST_BUFFER_SIZE = 16 * 1024;

type
  // ---------------------------------------------------------------------------
  // IDXHttpSysRequestHandler - the only interface that adapters must implement
  // ---------------------------------------------------------------------------

  /// <summary>
  ///   The single interface a consumer (or framework adapter) implements to
  ///   handle requests. The server invokes <c>HandleRequest</c> on a worker
  ///   thread for each incoming request.
  /// </summary>
  /// <remarks>
  ///   The request and response are valid only for the duration of the call and
  ///   are not thread-safe. Calling <c>AResponse.Send</c> is optional: if the
  ///   handler returns without having sent, the worker sends the response for it.
  ///   Likewise, a streaming response the handler began but did not end is
  ///   completed by the worker. An unhandled exception is turned into a 500
  ///   response (or, mid-stream, into stream completion) and reported via the
  ///   server's OnError callback; the worker keeps running. Long-running
  ///   handlers should poll <c>AResponse.Cancelled</c> and return promptly when
  ///   it turns True (server shutdown) — note that each handler occupies one
  ///   pooled worker thread for its full duration.
  /// </remarks>
  IDXHttpSysRequestHandler = interface
    ['{6FFE159C-82F2-4FF1-8BA6-3F2544EC5C49}']
    /// <summary>Handle one request and fill in the response.</summary>
    /// <param name="ARequest">The incoming request (read-only).</param>
    /// <param name="AResponse">
    ///   The response to populate. Set status/headers/body; you may call Send
    ///   explicitly, but if you don't, the server sends it after you return.
    /// </param>
    procedure HandleRequest(
      const ARequest:  TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysWorkItem - data container for the worker queue
  // ---------------------------------------------------------------------------

  TDXHttpSysWorkItem = class
  public
    RequestBuffer: TBytes;    // Copy of the raw HTTP_REQUEST buffer
    QueueHandle:   THandle;
    RequestId:     HTTP_REQUEST_ID;
    destructor Destroy; override;
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysWorkerThread
  // ---------------------------------------------------------------------------

  TDXHttpSysWorkerPool = class; // Forward

  TDXHttpSysWorkerThread = class(TThread)
  private
    FPool:    TDXHttpSysWorkerPool;
    // Injected into each response as OnQueryCancelled so handlers can observe
    // shutdown (Response.Cancelled) without depending on this unit.
    function QueryCancelled: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TDXHttpSysWorkerPool);
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysReceiverThread
  // ---------------------------------------------------------------------------

  TDXHttpSysReceiverThread = class(TThread)
  private
    FPool: TDXHttpSysWorkerPool;
    // Sends a minimal status-only response and disconnects, removing a request
    // we cannot service (e.g. oversized headers) from the kernel queue.
    procedure RejectRequest(ARequestId: HTTP_REQUEST_ID;
      AStatus: USHORT; const AReason: AnsiString);
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TDXHttpSysWorkerPool);
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysWorkerPool - coordinates receiver + worker threads
  // ---------------------------------------------------------------------------

  TOnHttpSysError = procedure(const AException: Exception; const AContext: string) of object;

  TDXHttpSysWorkerPool = class
  private
    FApi:             TDXHttpSysApi;
    FQueueHandle:     THandle;
    FHandler:         IDXHttpSysRequestHandler;
    FWorkerCount:     Integer;
    FPendingQueue:    TThreadedQueue<TDXHttpSysWorkItem>;
    FReceiverThread:  TDXHttpSysReceiverThread;
    FWorkerThreads:   TObjectList<TDXHttpSysWorkerThread>;
    FOnError:         TOnHttpSysError;
    FServerHeader:    string;
    FActive:          Boolean;
    FShuttingDown:    Boolean;

    // Frees any work items still queued (so their buffers don't leak on Stop).
    procedure DrainPendingQueue;
  public
    constructor Create(
      const AApi:        TDXHttpSysApi;
      AQueueHandle:      THandle;
      AWorkerCount:      Integer;
      AHandler:          IDXHttpSysRequestHandler;
      const AServerHeader: string);
    destructor  Destroy; override;

    procedure Start;
    procedure Stop;

    // Flags the pool as shutting down WITHOUT waiting for the threads. Streaming
    // and other long-running handlers observe this via Response.Cancelled and
    // unwind promptly. Called by TDXHttpSysServer.Stop before the request queue
    // handle is closed; Stop sets it as well (idempotent).
    procedure SignalShutdown;

    // True once shutdown has been signalled (see SignalShutdown).
    property ShuttingDown: Boolean read FShuttingDown;

    // Internal access by the threads
    property Api:          TDXHttpSysApi           read FApi;
    property QueueHandle:  THandle                 read FQueueHandle;
    property Handler:      IDXHttpSysRequestHandler read FHandler;
    property PendingQueue: TThreadedQueue<TDXHttpSysWorkItem>
                                                   read FPendingQueue;
    property Active:       Boolean                 read FActive;

    // Default Server header applied to each response before the handler runs
    // (the handler may override it). Empty means "do not set one". Fixed at
    // construction, so workers read it without synchronisation.
    property ServerHeader: string read FServerHeader;

    // Optional error callback (e.g. for logging)
    property OnError:      TOnHttpSysError         read FOnError write FOnError;

    // Reports a caught exception (the caller's except block still owns it).
    procedure ReportError(const AException: Exception; const AContext: string);
    // Reports a freshly created exception and FREES it (caller transfers
    // ownership). Use when raising an ad-hoc error to the OnError callback.
    procedure ReportErrorOwned(AException: Exception; const AContext: string);
  end;

implementation

// -----------------------------------------------------------------------------
// TDXHttpSysWorkItem
// -----------------------------------------------------------------------------

destructor TDXHttpSysWorkItem.Destroy;
begin
  // RequestBuffer is released automatically by TBytes
  inherited;
end;

// -----------------------------------------------------------------------------
// TDXHttpSysReceiverThread
// -----------------------------------------------------------------------------

constructor TDXHttpSysReceiverThread.Create(APool: TDXHttpSysWorkerPool);
begin
  FPool := APool;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDXHttpSysReceiverThread.RejectRequest(ARequestId: HTTP_REQUEST_ID;
  AStatus: USHORT; const AReason: AnsiString);
var
  Resp:      HTTP_RESPONSE;
  BytesSent: ULONG;
begin
  FillChar(Resp, SizeOf(Resp), 0);
  Resp.Version      := HTTPAPI_VERSION_2;
  Resp.StatusCode   := AStatus;
  Resp.pReason      := PAnsiChar(AReason);
  Resp.ReasonLength := Length(AReason);
  BytesSent := 0;
  // Best-effort: ignore the result (the client may already be gone).
  FPool.Api.SendHttpResponse(
    FPool.QueueHandle, ARequestId,
    HTTP_SEND_RESPONSE_FLAG_DISCONNECT,
    @Resp, nil, @BytesSent, nil, 0, nil, nil);
end;

procedure TDXHttpSysReceiverThread.Execute;
const
  // Upper bound for the request header buffer; a request whose headers exceed
  // this is rejected rather than allowed to exhaust memory.
  cMaxRequestBufferSize = 1024 * 1024; // 1 MB
var
  Result_:    ULONG;
  BytesRecvd: ULONG;
  WorkItem:   TDXHttpSysWorkItem;
  Buffer:     TBytes;
  ReqPtr:     PHTTP_REQUEST;
  LRequestId: HTTP_REQUEST_ID;
begin
  NameThreadForDebugging('DX.HttpSys.Receiver');

  while not Terminated do
  begin
    // CRITICAL: each request gets its OWN buffer that HTTP.sys writes into and
    // that is then handed to the work item by reference (no Move). HTTP_REQUEST
    // holds absolute pointers (CookedUrl, headers, entity) into this buffer, so
    // copying the bytes elsewhere would leave those pointers dangling into a
    // reused buffer — which crosses requests under load. Ownership of Buffer
    // transfers to the work item; we allocate a fresh one each iteration.
    BytesRecvd := 0;
    SetLength(Buffer, DEFAULT_REQUEST_BUFFER_SIZE);
    ReqPtr := PHTTP_REQUEST(@Buffer[0]);
    LRequestId := HTTP_NULL_ID; // 0 = next arbitrary request

    Result_ := FPool.Api.ReceiveHttpRequest(
      FPool.QueueHandle,
      LRequestId,
      HTTP_RECEIVE_REQUEST_FLAG_COPY_BODY,
      ReqPtr,
      Length(Buffer),
      @BytesRecvd,
      nil);                 // synchronous

    while (Result_ = ERROR_MORE_DATA) and not Terminated do
    begin
      // BytesRecvd holds the required size. Grow (bounded) and retry the same
      // request id, which ReceiveHttpRequest wrote into our buffer.
      LRequestId := ReqPtr^.RequestId;
      if (BytesRecvd = 0) or (BytesRecvd > cMaxRequestBufferSize) then
      begin
        FPool.ReportErrorOwned(
          EDXHttpSysError.CreateWin32(Result_,
            Format('Request headers exceed %d bytes', [cMaxRequestBufferSize])),
          'Receiver');
        // Reject and disconnect so HTTP.sys removes the request from the queue.
        // Leaving it pending would have it re-delivered on the next receive,
        // spinning forever and blocking later requests (a DoS vector).
        RejectRequest(LRequestId, 431, 'Request Header Fields Too Large');
        Result_ := ERROR_MORE_DATA; // signal "handled, skip" below
        Break;
      end;

      SetLength(Buffer, BytesRecvd);
      ReqPtr := PHTTP_REQUEST(@Buffer[0]);
      Result_ := FPool.Api.ReceiveHttpRequest(
        FPool.QueueHandle,
        LRequestId,
        HTTP_RECEIVE_REQUEST_FLAG_COPY_BODY,
        ReqPtr,
        Length(Buffer),
        @BytesRecvd,
        nil);
    end;

    if Terminated then
      Break;

    case Result_ of
      ERROR_SUCCESS:
      begin
        // Hand the buffer to the work item by reference — no copy, so the
        // HTTP_REQUEST internal pointers stay valid for the worker.
        WorkItem := TDXHttpSysWorkItem.Create;
        WorkItem.RequestBuffer := Buffer;   // ownership transfer (shared ref)
        Buffer := nil;                      // receiver drops its reference
        WorkItem.QueueHandle := FPool.QueueHandle;
        WorkItem.RequestId   := ReqPtr^.RequestId;

        FPool.PendingQueue.PushItem(WorkItem);
      end;

      ERROR_MORE_DATA:
        // Oversized request already reported above; skip it.
        ;

      ERROR_CONNECTION_INVALID,
      ERROR_NETNAME_DELETED:
        // Client disconnected - ignore
        ;

      ERROR_INVALID_HANDLE,
      ERROR_OPERATION_ABORTED:
        // The queue handle was closed (shutdown). Stop the loop instead of
        // spinning on a dead handle while Terminate is still propagating.
        Break;

    else
      if not Terminated then
        FPool.ReportErrorOwned(
          EDXHttpSysError.CreateWin32(Result_, 'ReceiveHttpRequest'),
          'Receiver');
    end;
  end;
end;

// -----------------------------------------------------------------------------
// TDXHttpSysWorkerThread
// -----------------------------------------------------------------------------

constructor TDXHttpSysWorkerThread.Create(APool: TDXHttpSysWorkerPool);
begin
  FPool := APool;
  FreeOnTerminate := False;
  inherited Create(False);
end;

function TDXHttpSysWorkerThread.QueryCancelled: Boolean;
begin
  Result := Terminated or FPool.ShuttingDown;
end;

procedure TDXHttpSysWorkerThread.Execute;
var
  WorkItem:  TDXHttpSysWorkItem;
  QueueRes:  TWaitResult;
  Request:   TDXHttpSysRequest;
  Response:  TDXHttpSysResponse;
begin
  NameThreadForDebugging('DX.HttpSys.Worker');

  while not Terminated do
  begin
    QueueRes := FPool.PendingQueue.PopItem(WorkItem);

    if QueueRes = wrSignaled then
    begin
      if WorkItem = nil then
        Continue;

      Request  := nil;
      Response := nil;
      // Outer guard: no failure here (even creating the request/response, or a
      // failing Send) may ever escape and kill the worker thread. A worker that
      // never dies removes the need to restart one.
      try
        try
          Request := TDXHttpSysRequest.Create(
            FPool.Api,
            WorkItem.QueueHandle,
            PHTTP_REQUEST(@WorkItem.RequestBuffer[0]));

          Response := TDXHttpSysResponse.Create(
            FPool.Api,
            WorkItem.QueueHandle,
            WorkItem.RequestId);

          // Wire up cooperative cancellation (Response.Cancelled).
          Response.OnQueryCancelled := QueryCancelled;

          // Apply the configured Server header as a default the handler may override.
          if FPool.ServerHeader <> '' then
            Response.Headers['server'] := FPool.ServerHeader;

          try
            FPool.Handler.HandleRequest(Request, Response);
          except
            on E: Exception do
            begin
              FPool.ReportError(E, Format('HandleRequest [%s %s]',
                [Request.Method, Request.Path]));
              // Best effort: still answer the request (500) or, if the handler
              // failed mid-stream, terminate the chunked response so the client
              // is not left waiting for chunks that will never come. Either may
              // hit a dead client; that must not mask the original error.
              try
                if Response.Streaming then
                  Response.EndStream
                else if not Response.Sent then
                  Response.SendError(500);
              except
                on ECleanup: Exception do
                  FPool.ReportError(ECleanup, 'HandleRequest cleanup');
              end;
            end;
          end;

          // Ensure a response is always sent, and a stream the handler began
          // but did not end is always completed.
          if Response.Streaming then
            Response.EndStream
          else if not Response.Sent then
            Response.Send;
        finally
          Request.Free;
          Response.Free;
          WorkItem.Free;
        end;
      except
        on E: Exception do
          // Anything that slipped past the inner handling (e.g. a failed Send to
          // an aborted client). Log and keep the worker alive for the next item.
          FPool.ReportError(E, 'Worker');
      end;
    end;
  end;
end;

// -----------------------------------------------------------------------------
// TDXHttpSysWorkerPool
// -----------------------------------------------------------------------------

constructor TDXHttpSysWorkerPool.Create(
  const AApi:        TDXHttpSysApi;
  AQueueHandle:      THandle;
  AWorkerCount:      Integer;
  AHandler:          IDXHttpSysRequestHandler;
  const AServerHeader: string);
begin
  inherited Create;
  FApi          := AApi;
  FQueueHandle  := AQueueHandle;
  FHandler      := AHandler;
  FWorkerCount  := AWorkerCount;
  FServerHeader := AServerHeader;
  FActive       := False;

  // Capacity: 10x worker count. PopItem uses a finite (100 ms) timeout so a
  // worker wakes periodically to observe Terminated, instead of relying on nil
  // wake-up items — pushing those could block on a full queue during shutdown
  // and deadlock. Push timeout stays INFINITE (the receiver applies backpressure).
  FPendingQueue := TThreadedQueue<TDXHttpSysWorkItem>.Create(
    FWorkerCount * 10, INFINITE, 100);

  FWorkerThreads := TObjectList<TDXHttpSysWorkerThread>.Create(True);
end;

destructor TDXHttpSysWorkerPool.Destroy;
begin
  if FActive then
    Stop;
  FreeAndNil(FWorkerThreads);
  FreeAndNil(FPendingQueue);
  inherited;
end;

procedure TDXHttpSysWorkerPool.Start;
var
  I: Integer;
begin
  if FActive then
    Exit;

  FActive       := True;
  FShuttingDown := False;

  // Start worker threads
  for I := 1 to FWorkerCount do
    FWorkerThreads.Add(TDXHttpSysWorkerThread.Create(Self));

  // Start receiver thread
  FReceiverThread := TDXHttpSysReceiverThread.Create(Self);
end;

procedure TDXHttpSysWorkerPool.SignalShutdown;
begin
  // No synchronisation needed: a plain Boolean written once and polled by the
  // workers (via Response.Cancelled). Stale reads only delay the observation
  // by one poll interval.
  FShuttingDown := True;
end;

procedure TDXHttpSysWorkerPool.Stop;
var
  Thread: TDXHttpSysWorkerThread;
begin
  if not FActive then
    Exit;

  // Let long-running handlers (streams) observe the shutdown first, so the
  // WaitFor below does not have to sit out their full duration.
  SignalShutdown;

  FActive := False;

  // Stop the receiver thread. CloseHandle on the queue (done by the server
  // before calling here) wakes its blocking ReceiveHttpRequest.
  if Assigned(FReceiverThread) then
  begin
    FReceiverThread.Terminate;
    FReceiverThread.WaitFor;
    FreeAndNil(FReceiverThread);
  end;

  // Worker threads: just signal termination. Each worker's PopItem has a finite
  // timeout, so it observes Terminated within ~100 ms — no nil wake-up items
  // (which could block on a full queue and deadlock under load).
  for Thread in FWorkerThreads do
    Thread.Terminate;

  for Thread in FWorkerThreads do
    Thread.WaitFor;

  FWorkerThreads.Clear;

  // Drain and free any work items the workers did not get to (their buffers
  // would otherwise leak when the queue is freed).
  DrainPendingQueue;
end;

procedure TDXHttpSysWorkerPool.DrainPendingQueue;
var
  LItem: TDXHttpSysWorkItem;
begin
  // PopItem returns wrTimeout once the queue is empty (finite pop timeout).
  while FPendingQueue.PopItem(LItem) = wrSignaled do
    LItem.Free;
end;

procedure TDXHttpSysWorkerPool.ReportError(
  const AException: Exception;
  const AContext:   string);
begin
  if Assigned(FOnError) then
    FOnError(AException, AContext);
  // The caller's except block owns AException; nothing to free here. With no
  // handler the error is swallowed and the worker thread keeps running.
end;

procedure TDXHttpSysWorkerPool.ReportErrorOwned(
  AException: Exception;
  const AContext: string);
begin
  try
    ReportError(AException, AContext);
  finally
    AException.Free; // we own this freshly created exception
  end;
end;

end.
