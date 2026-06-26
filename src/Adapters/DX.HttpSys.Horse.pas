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
    class var FPort:     Integer;  // Horse provider API contract (Listen takes Integer)
    class var FHost:     string;
    class var FScheme:   TDXScheme;
    class var FBasePath: string;
    class var FRunning:  Boolean;
    class var FEvent:    TEvent;
    class var FServer:   TDXHttpSysServer;  // the single HTTP.sys listener

    class function GetDefaultEvent: TEvent;
    class function GetDefaultPort: Integer; static;
    class function GetDefaultHost: string; static;
    class function GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;
    class function GetHost: string; static;
    class procedure SetHost(const AValue: string); static;
    class function GetScheme: TDXScheme; static;
    class procedure SetScheme(const AValue: TDXScheme); static;
    class function GetBasePath: string; static;
    class procedure SetBasePath(const AValue: string); static;

    class procedure InternalListen; virtual;
    class procedure InternalStopListen; virtual;
  public
    class property Host: string  read GetHost write SetHost;
    class property Port: Integer read GetPort write SetPort;

    // The URL scheme (default Http) and the HTTP.sys path segment. Horse has no
    // base-path concept, so BasePath drives the prefix and the user registers
    // routes under that same segment (e.g. BasePath='horse' + Get('/horse/...')).
    // Set both before Listen. https additionally needs an sslcert (netsh).
    class property Scheme:   TDXScheme read GetScheme   write SetScheme;
    class property BasePath: string    read GetBasePath write SetBasePath;

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

class function THorseProviderHttpSys<T>.GetScheme: TDXScheme;
begin
  Result := FScheme;
end;

class procedure THorseProviderHttpSys<T>.SetScheme(const AValue: TDXScheme);
begin
  FScheme := AValue;
end;

class function THorseProviderHttpSys<T>.GetBasePath: string;
begin
  Result := FBasePath;
end;

class procedure THorseProviderHttpSys<T>.SetBasePath(const AValue: string);
begin
  FBasePath := AValue.Trim;
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
  // Default to loopback (admin-free), matching the WiRL adapter and the spec's
  // "Host default localhost". Horse's own GetDefaultHost is '0.0.0.0', which
  // BuildPrefix maps to the '+' wildcard (needs urlacl/admin) — not the
  // admin-free default the README advertises. Set Host explicitly for '+'/an IP.
  if FHost.IsEmpty then
    FHost := 'localhost';

  if FServer <> nil then
    raise Exception.Create('Horse (HTTP.sys) is already listening');

  // Route every WebBroker request into Horse's web module (the THorseCore
  // singleton that THorse.Get/Use populate).
  WebRequestHandler.WebModuleClass := WebModuleClass;

  FServer := TDXHttpSysServer.Create;
  try
    FServer.Handler := TWebBrokerHttpSysDispatcher.Create;
    // Build the prefix through the shared Core formatter (host/scheme logic lives
    // in exactly one place, shared with WiRL): loopback needs no urlacl, the
    // wildcard ('+') does. BasePath is the path segment routes are registered under.
    // FPort is Integer (Horse API contract) but a port is a Word; the cast is
    // explicit so the narrowing is intentional, not a silent implicit conversion.
    FServer.AddUrlPrefix(
      TDXHttpSysServer.BuildPrefix(FScheme, FHost, Word(FPort), FBasePath));
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
