/// <summary>
///   DX.HttpSys.Horse — a Horse server provider backed by the kernel HTTP.sys
///   listener.
/// </summary>
/// <remarks>
///   Horse dispatches every request through WebBroker (THorseWebModule over
///   TWebRequest/TWebResponse), so this provider is a thin wrapper around the
///   already-verified TWebBrokerHttpSysDispatcher: it points
///   WebRequestHandler.WebModuleClass at Horse's WebModule and runs a
///   TDXHttpSysServer with that dispatcher. No request/response bridge of its
///   own is needed — Horse reuses the WebBroker layer DX.HttpSys already serves.
///
///   Usage — define routes on THorse as usual, start the server through this
///   provider instead of Horse's default Indy provider:
///
///     uses Horse, DX.HttpSys.Horse;
///     ...
///     THorse.Get('/ping',
///       procedure(AReq: THorseRequest; ARes: THorseResponse)
///       begin
///         ARes.Send('pong');
///       end);
///     THorseProviderHttpSys&lt;THorse&gt;.Listen(9000);
///
///   Routes registered via THorse and this provider share the same THorseCore
///   singleton, so the routes defined above are served by HTTP.sys here.
///
///   Horse is an external dependency that is intentionally NOT vendored, so this
///   unit only compiles where Horse is on the library path. It is exercised by
///   the optional integration tests under tests-integration/. See
///   docs/DECISIONS.md (A-10, A-15).
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-20</created>
/// <license>MIT</license>
unit DX.HttpSys.Horse;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  Horse.Provider.Abstract,
  Horse.Constants,
  DX.HttpSys.Server;

type
  // ---------------------------------------------------------------------------
  // THorseProviderHttpSys — a Horse provider that listens via HTTP.sys
  // ---------------------------------------------------------------------------

  THorseProviderHttpSys<T: class> = class(THorseProviderAbstract<T>)
  private
    class var FPort:    Integer;
    class var FHost:    string;
    class var FRunning: Boolean;
    class var FEvent:   TEvent;
    class var FServer:  TDXHttpSysServer;  // the single HTTP.sys listener

    class function GetDefaultEvent: TEvent;
    class function GetDefaultPort: Integer; static;
    class function GetDefaultHost: string; static;
    class function GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;
    class function GetHost: string; static;
    class procedure SetHost(const AValue: string); static;

    class procedure InternalListen; virtual;
    class procedure InternalStopListen; virtual;
  public
    class property Host: string  read GetHost write SetHost;
    class property Port: Integer read GetPort write SetPort;

    class procedure Listen; overload; override;
    class procedure StopListen; override;

    class procedure Listen(APort: Integer; const AHost: string = '0.0.0.0';
      const ACallbackListen: TProc<T> = nil;
      const ACallbackStopListen: TProc<T> = nil); reintroduce; overload; static;
    class procedure Listen(APort: Integer; const ACallbackListen: TProc<T>;
      const ACallbackStopListen: TProc<T> = nil); reintroduce; overload; static;
    class procedure Listen(const AHost: string;
      const ACallbackListen: TProc<T> = nil;
      const ACallbackStopListen: TProc<T> = nil); reintroduce; overload; static;
    class procedure Listen(const ACallbackListen: TProc<T>;
      const ACallbackStopListen: TProc<T> = nil); reintroduce; overload; static;

    class function IsRunning: Boolean;
    class destructor UnInitialize;
  end;

implementation

uses
  Web.WebReq,
  Horse.WebModule,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.WebBroker;

// -----------------------------------------------------------------------------
// THorseProviderHttpSys<T> — accessors
// -----------------------------------------------------------------------------

class function THorseProviderHttpSys<T>.GetDefaultEvent: TEvent;
begin
  if FEvent = nil then
    FEvent := TEvent.Create;
  Result := FEvent;
end;

class function THorseProviderHttpSys<T>.GetDefaultPort: Integer;
begin
  Result := DEFAULT_PORT;
end;

class function THorseProviderHttpSys<T>.GetDefaultHost: string;
begin
  Result := DEFAULT_HOST;
end;

class function THorseProviderHttpSys<T>.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderHttpSys<T>.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

class function THorseProviderHttpSys<T>.GetHost: string;
begin
  Result := FHost;
end;

class procedure THorseProviderHttpSys<T>.SetHost(const AValue: string);
begin
  FHost := AValue.Trim;
end;

class function THorseProviderHttpSys<T>.IsRunning: Boolean;
begin
  Result := FRunning;
end;

// -----------------------------------------------------------------------------
// THorseProviderHttpSys<T> — lifecycle
// -----------------------------------------------------------------------------

class procedure THorseProviderHttpSys<T>.InternalListen;
begin
  inherited;
  if FPort <= 0 then
    FPort := GetDefaultPort;
  if FHost.IsEmpty then
    FHost := GetDefaultHost;

  if FServer <> nil then
    raise Exception.Create('Horse (HTTP.sys) is already listening');

  // Route every WebBroker request into Horse's web module (the THorseCore
  // singleton that THorse.Get/Use populate).
  WebRequestHandler.WebModuleClass := WebModuleClass;

  FServer := TDXHttpSysServer.Create;
  try
    FServer.Handler := TWebBrokerHttpSysDispatcher.Create;
    // A loopback host needs no URL ACL; any other host binds the wildcard
    // ("http://+:port/"), which requires elevated rights / a urlacl reservation.
    if SameText(FHost, 'localhost') or SameText(FHost, '127.0.0.1') then
      FServer.AddUrlPrefix(Format('http://localhost:%d/', [FPort]))
    else if SameText(FHost, GetDefaultHost) then
      FServer.AddUrlPrefix(Format('http://+:%d/', [FPort]))
    else
      FServer.AddUrlPrefix(Format('http://%s:%d/', [FHost, FPort]));
    FServer.Start;
  except
    FreeAndNil(FServer);
    raise;
  end;

  FRunning := True;
  DoOnListen;

  // A console host blocks here until StopListen signals the event, mirroring
  // Horse's Indy console provider. Reset first so a signal left over from a
  // previous Listen/Stop cycle doesn't make WaitFor return immediately (the
  // event is manual-reset).
  if IsConsole then
  begin
    GetDefaultEvent.ResetEvent;
    while FRunning do
      GetDefaultEvent.WaitFor(INFINITE);
  end;
end;

class procedure THorseProviderHttpSys<T>.InternalStopListen;
begin
  if FServer = nil then
    raise Exception.Create('Horse (HTTP.sys) is not listening');
  // Clear FRunning first so the console WaitFor loop exits on wake-up.
  FRunning := False;
  FServer.Stop;
  FreeAndNil(FServer);
  DoOnStopListen;
  if FEvent <> nil then
    FEvent.SetEvent;
end;

class procedure THorseProviderHttpSys<T>.Listen;
begin
  InternalListen;
end;

class procedure THorseProviderHttpSys<T>.StopListen;
begin
  InternalStopListen;
end;

class procedure THorseProviderHttpSys<T>.Listen(APort: Integer;
  const AHost: string; const ACallbackListen, ACallbackStopListen: TProc<T>);
begin
  SetPort(APort);
  SetHost(AHost);
  if Assigned(ACallbackListen) then
    SetOnListen(ACallbackListen);
  if Assigned(ACallbackStopListen) then
    SetOnStopListen(ACallbackStopListen);
  InternalListen;
end;

class procedure THorseProviderHttpSys<T>.Listen(APort: Integer;
  const ACallbackListen, ACallbackStopListen: TProc<T>);
begin
  Listen(APort, GetDefaultHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderHttpSys<T>.Listen(const AHost: string;
  const ACallbackListen, ACallbackStopListen: TProc<T>);
begin
  Listen(GetDefaultPort, AHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderHttpSys<T>.Listen(
  const ACallbackListen, ACallbackStopListen: TProc<T>);
begin
  Listen(GetDefaultPort, GetDefaultHost, ACallbackListen, ACallbackStopListen);
end;

class destructor THorseProviderHttpSys<T>.UnInitialize;
begin
  FreeAndNil(FServer);
  FreeAndNil(FEvent);
end;

end.
