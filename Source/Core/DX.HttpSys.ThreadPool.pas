// =============================================================================
// DX.HttpSys.ThreadPool.pas
// Receiver-Thread + Worker-Thread-Pool für TDXHttpSysServer
//
// Architektur:
//   1 TDXHttpSysReceiverThread  – blockierender HttpReceiveHttpRequest-Loop
//                                 postet Work-Items in TDXHttpSysPendingQueue
//   N TDXHttpSysWorkerThread    – nehmen Work-Items aus der Queue,
//                                 erzeugen Request/Response-Objekte und rufen
//                                 IDXHttpSysRequestHandler.HandleRequest auf
//
// Fehlerbehandlung:
//   Unbehandelte Exceptions in Worker-Threads → 500-Response + OnError-Callback
//   Abgestürzter Worker-Thread → wird automatisch neu gestartet
//
// (c) Developer Experts LLC – MIT License
// =============================================================================

unit DX.HttpSys.ThreadPool;

{$IFDEF MSWINDOWS}

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
  // Puffergröße für HttpReceiveHttpRequest
  // 16 KB deckt auch Authentication-Headers ab
  DEFAULT_REQUEST_BUFFER_SIZE = 16 * 1024;

type
  // ---------------------------------------------------------------------------
  // IDXHttpSysRequestHandler – das einzige Interface, das Adapter implementieren
  // ---------------------------------------------------------------------------

  IDXHttpSysRequestHandler = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}'] // TODO: echte GUID generieren
    procedure HandleRequest(
      const ARequest:  TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysWorkItem – Datencontainer für die Worker-Queue
  // ---------------------------------------------------------------------------

  TDXHttpSysWorkItem = class
  public
    RequestBuffer: TBytes;    // Kopie des rohen HTTP_REQUEST-Puffers
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
  // TDXHttpSysWorkerPool – Koordination Receiver + Worker-Threads
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

    procedure HandleWorkerError(const AException: Exception;
      AWorkItem: TDXHttpSysWorkItem);
  public
    constructor Create(
      const AApi:       TDXHttpSysApi;
      AQueueHandle:     THandle;
      AWorkerCount:     Integer;
      AHandler:         IDXHttpSysRequestHandler);
    destructor  Destroy; override;

    procedure Start;
    procedure Stop;

    // Interner Zugriff durch Threads
    property Api:          TDXHttpSysApi           read FApi;
    property QueueHandle:  THandle                 read FQueueHandle;
    property Handler:      IDXHttpSysRequestHandler read FHandler;
    property PendingQueue: TThreadedQueue<TDXHttpSysWorkItem>
                                                   read FPendingQueue;
    property Active:       Boolean                 read FActive;

    // Optionaler Error-Callback (z.B. für Logging)
    property OnError:      TOnHttpSysError         read FOnError write FOnError;

    procedure ReportError(const AException: Exception; const AContext: string);
  end;

implementation

// -----------------------------------------------------------------------------
// TDXHttpSysWorkItem
// -----------------------------------------------------------------------------

destructor TDXHttpSysWorkItem.Destroy;
begin
  // RequestBuffer wird durch TBytes automatisch freigegeben
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

    // Blockierender Aufruf – wartet bis ein Request eintrifft
    Result_ := FPool.Api.ReceiveHttpRequest(
      FPool.QueueHandle,
      HTTP_NULL_ID,         // 0 = nächsten beliebigen Request
      HTTP_RECEIVE_REQUEST_FLAG_COPY_BODY,
      ReqPtr,
      Length(FRequestBuffer),
      @BytesRecvd,
      nil);                 // synchron

    if Terminated then
      Break;

    case Result_ of
      ERROR_SUCCESS:
      begin
        // Work-Item mit Kopie des Puffers erzeugen
        WorkItem := TDXHttpSysWorkItem.Create;
        SetLength(WorkItem.RequestBuffer, BytesRecvd);
        Move(FRequestBuffer[0], WorkItem.RequestBuffer[0], BytesRecvd);
        WorkItem.QueueHandle := FPool.QueueHandle;
        WorkItem.RequestId   := ReqPtr^.RequestId;

        FPool.PendingQueue.PushItem(WorkItem);
      end;

      ERROR_MORE_DATA:
      begin
        // Puffer zu klein – Request abweisen und mit 400 antworten
        // TODO: Puffer dynamisch vergrößern
        FPool.ReportError(
          Exception.Create('Request-Puffer zu klein (ERROR_MORE_DATA)'),
          'Receiver');
      end;

      ERROR_CONNECTION_INVALID,
      ERROR_NETNAME_DELETED:
        // Client hat die Verbindung getrennt – ignorieren
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
            // 500 senden, falls noch nicht gesendet
            if not Response.Sent then
              Response.SendError(500);
          end;
        end;

        // Sicherstellen dass immer gesendet wurde
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

  // Kapazität: 10× Worker-Count als sinnvoller Puffer
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

  // Worker-Threads starten
  for I := 1 to FWorkerCount do
    FWorkerThreads.Add(TDXHttpSysWorkerThread.Create(Self));

  // Receiver-Thread starten
  FReceiverThread := TDXHttpSysReceiverThread.Create(Self);
end;

procedure TDXHttpSysWorkerPool.Stop;
var
  Thread: TDXHttpSysWorkerThread;
begin
  if not FActive then
    Exit;

  FActive := False;

  // Receiver-Thread beenden
  if Assigned(FReceiverThread) then
  begin
    FReceiverThread.Terminate;
    // HttpCloseRequestQueue weckt den blockierenden ReceiveHttpRequest auf
    // (wird vom TDXHttpSysServer aufgerufen bevor Stop hier landet)
    FReceiverThread.WaitFor;
    FreeAndNil(FReceiverThread);
  end;

  // Worker-Threads: nil-Items pushen um WaitFor zu ermöglichen
  for Thread in FWorkerThreads do
  begin
    Thread.Terminate;
    FPendingQueue.PushItem(nil); // Weckt blockierende PopItem auf
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
  // Wenn kein Handler: Exception still schlucken (Worker-Thread soll weiterlaufen)
end;

{$ENDIF MSWINDOWS}

// Platzhalter für HTTP_NULL_ID – falls nicht in Winapi.Windows definiert
const
  HTTP_NULL_ID: HTTP_REQUEST_ID = 0;

end.
