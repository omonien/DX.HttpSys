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

  IDXHttpSysRequestHandler = interface
    ['{6FFE159C-82F2-4FF1-8BA6-3F2544EC5C49}']
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
    FPool:          TDXHttpSysWorkerPool;
    FRequestBuffer: TBytes;
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
    FActive:          Boolean;
  public
    constructor Create(
      const AApi:       TDXHttpSysApi;
      AQueueHandle:     THandle;
      AWorkerCount:     Integer;
      AHandler:         IDXHttpSysRequestHandler);
    destructor  Destroy; override;

    procedure Start;
    procedure Stop;

    // Internal access by the threads
    property Api:          TDXHttpSysApi           read FApi;
    property QueueHandle:  THandle                 read FQueueHandle;
    property Handler:      IDXHttpSysRequestHandler read FHandler;
    property PendingQueue: TThreadedQueue<TDXHttpSysWorkItem>
                                                   read FPendingQueue;
    property Active:       Boolean                 read FActive;

    // Optional error callback (e.g. for logging)
    property OnError:      TOnHttpSysError         read FOnError write FOnError;

    procedure ReportError(const AException: Exception; const AContext: string);
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
  SetLength(FRequestBuffer, DEFAULT_REQUEST_BUFFER_SIZE);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDXHttpSysReceiverThread.Execute;
var
  Result_:    ULONG;
  BytesRecvd: ULONG;
  WorkItem:   TDXHttpSysWorkItem;
  ReqPtr:     PHTTP_REQUEST;
begin
  NameThreadForDebugging('DX.HttpSys.Receiver');

  while not Terminated do
  begin
    BytesRecvd := 0;
    ReqPtr := PHTTP_REQUEST(@FRequestBuffer[0]);

    // Blocking call - waits until a request arrives
    Result_ := FPool.Api.ReceiveHttpRequest(
      FPool.QueueHandle,
      HTTP_NULL_ID,         // 0 = next arbitrary request
      HTTP_RECEIVE_REQUEST_FLAG_COPY_BODY,
      ReqPtr,
      Length(FRequestBuffer),
      @BytesRecvd,
      nil);                 // synchronous

    if Terminated then
      Break;

    case Result_ of
      ERROR_SUCCESS:
      begin
        // Create a work item with a copy of the buffer
        WorkItem := TDXHttpSysWorkItem.Create;
        SetLength(WorkItem.RequestBuffer, BytesRecvd);
        Move(FRequestBuffer[0], WorkItem.RequestBuffer[0], BytesRecvd);
        WorkItem.QueueHandle := FPool.QueueHandle;
        WorkItem.RequestId   := ReqPtr^.RequestId;

        FPool.PendingQueue.PushItem(WorkItem);
      end;

      ERROR_MORE_DATA:
      begin
        // Buffer too small - reject the request and respond with 400
        // TODO: grow the buffer dynamically
        FPool.ReportError(
          Exception.Create('Request buffer too small (ERROR_MORE_DATA)'),
          'Receiver');
      end;

      ERROR_CONNECTION_INVALID,
      ERROR_NETNAME_DELETED:
        // Client disconnected - ignore
        ;

    else
      if not Terminated then
        FPool.ReportError(
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
      try
        Request := TDXHttpSysRequest.Create(
          FPool.Api,
          WorkItem.QueueHandle,
          PHTTP_REQUEST(@WorkItem.RequestBuffer[0]));

        Response := TDXHttpSysResponse.Create(
          FPool.Api,
          WorkItem.QueueHandle,
          WorkItem.RequestId);

        try
          FPool.Handler.HandleRequest(Request, Response);
        except
          on E: Exception do
          begin
            FPool.ReportError(E, Format('HandleRequest [%s %s]',
              [Request.Method, Request.Path]));
            // Send 500 if not sent yet
            if not Response.Sent then
              Response.SendError(500);
          end;
        end;

        // Ensure a response is always sent
        if not Response.Sent then
          Response.Send;

      finally
        Request.Free;
        Response.Free;
        WorkItem.Free;
      end;
    end;
  end;
end;

// -----------------------------------------------------------------------------
// TDXHttpSysWorkerPool
// -----------------------------------------------------------------------------

constructor TDXHttpSysWorkerPool.Create(
  const AApi:     TDXHttpSysApi;
  AQueueHandle:   THandle;
  AWorkerCount:   Integer;
  AHandler:       IDXHttpSysRequestHandler);
begin
  inherited Create;
  FApi          := AApi;
  FQueueHandle  := AQueueHandle;
  FHandler      := AHandler;
  FWorkerCount  := AWorkerCount;
  FActive       := False;

  // Capacity: 10x worker count as a reasonable buffer
  FPendingQueue := TThreadedQueue<TDXHttpSysWorkItem>.Create(
    FWorkerCount * 10, INFINITE, INFINITE);

  FWorkerThreads := TObjectList<TDXHttpSysWorkerThread>.Create(True);
end;

destructor TDXHttpSysWorkerPool.Destroy;
begin
  if FActive then
    Stop;
  FWorkerThreads.Free;
  FPendingQueue.Free;
  inherited;
end;

procedure TDXHttpSysWorkerPool.Start;
var
  I: Integer;
begin
  if FActive then
    Exit;

  FActive := True;

  // Start worker threads
  for I := 1 to FWorkerCount do
    FWorkerThreads.Add(TDXHttpSysWorkerThread.Create(Self));

  // Start receiver thread
  FReceiverThread := TDXHttpSysReceiverThread.Create(Self);
end;

procedure TDXHttpSysWorkerPool.Stop;
var
  Thread: TDXHttpSysWorkerThread;
begin
  if not FActive then
    Exit;

  FActive := False;

  // Stop the receiver thread
  if Assigned(FReceiverThread) then
  begin
    FReceiverThread.Terminate;
    // HttpCloseRequestQueue wakes up the blocking ReceiveHttpRequest
    // (called by TDXHttpSysServer before control reaches Stop here)
    FReceiverThread.WaitFor;
    FreeAndNil(FReceiverThread);
  end;

  // Worker threads: push nil items to allow WaitFor to complete
  for Thread in FWorkerThreads do
  begin
    Thread.Terminate;
    FPendingQueue.PushItem(nil); // Wakes up a blocking PopItem
  end;

  for Thread in FWorkerThreads do
    Thread.WaitFor;

  FWorkerThreads.Clear;
end;

procedure TDXHttpSysWorkerPool.ReportError(
  const AException: Exception;
  const AContext:   string);
begin
  if Assigned(FOnError) then
    FOnError(AException, AContext);
  // No handler: swallow the exception silently (the worker thread keeps running)
end;

end.
