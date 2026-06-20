/// <summary>
///   Test.DX.HttpSys.Horse - end-to-end test of the Horse provider: real Horse
///   routes served over the kernel HTTP.sys engine.
/// </summary>
/// <remarks>
///   This test requires Horse, which is NOT part of DX.HttpSys. It only builds
///   inside the optional integration-test project (tests-integration/) after
///   FetchThirdParty.ps1 has downloaded Horse into build/thirdparty/. See
///   tests-integration/README.md.
///
///   It binds to http://localhost:PORT/ (no elevated rights) and drives the
///   server with an HTTP client, proving: HTTP.sys -> DX.HttpSys.Horse provider
///   -> WebBroker -> Horse routing -> response.
///
///   Horse's provider Listen blocks in a console host, so the server runs on a
///   background thread; the test polls IsRunning, issues a request, then calls
///   StopListen to release the thread.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-20</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Horse;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  THorseAdapterTests = class
  public
    [Test]
    procedure GetRoute_ReturnsBody;

    [Test]
    procedure GetRoute_EchoesQueryParam;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  Winapi.WinSock2,
  Horse,
  DX.HttpSys.Horse;

type
  // Runs the (blocking, console) provider Listen on its own thread.
  THorseListenThread = class(TThread)
  private
    FPort: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Integer);
  end;

constructor THorseListenThread.Create(APort: Integer);
begin
  FPort := APort;
  inherited Create(False);
end;

procedure THorseListenThread.Execute;
begin
  THorseProviderHttpSys<THorse>.Listen(FPort, 'localhost');
end;

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

var
  GRoutesDefined: Boolean = False;

// Defines the routes once on the THorseCore singleton; idempotent across tests.
procedure EnsureRoutes;
begin
  if GRoutesDefined then
    Exit;
  GRoutesDefined := True;
  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.Send('pong from horse over httpsys');
    end);
  THorse.Get('/echo',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    var
      LMsg: string;
    begin
      if not AReq.Query.TryGetValue('msg', LMsg) then
        LMsg := '';
      ARes.Send('echo:' + LMsg);
    end);
end;

// Starts the provider on a background thread and waits until it is listening.
function StartHorse(APort: Word): THorseListenThread;
var
  LWaited: Integer;
begin
  EnsureRoutes;
  Result := THorseListenThread.Create(APort);
  LWaited := 0;
  while (not THorseProviderHttpSys<THorse>.IsRunning) and (LWaited < 5000) do
  begin
    Sleep(25);
    Inc(LWaited, 25);
  end;
  Assert.IsTrue(THorseProviderHttpSys<THorse>.IsRunning, 'server did not start');
end;

procedure StopHorse(AThread: THorseListenThread);
begin
  THorseProviderHttpSys<THorse>.StopListen;
  AThread.WaitFor;
  AThread.Free;
end;

procedure THorseAdapterTests.GetRoute_ReturnsBody;
var
  LPort:   Word;
  LThread: THorseListenThread;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LThread := StartHorse(LPort);
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(Format('http://localhost:%d/ping', [LPort]));
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('pong from horse over httpsys',
        LResp.ContentAsString(TEncoding.UTF8), 'body');
    finally
      LClient.Free;
    end;
  finally
    StopHorse(LThread);
  end;
end;

procedure THorseAdapterTests.GetRoute_EchoesQueryParam;
var
  LPort:   Word;
  LThread: THorseListenThread;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LThread := StartHorse(LPort);
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(Format('http://localhost:%d/echo?msg=ping', [LPort]));
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('echo:ping',
        LResp.ContentAsString(TEncoding.UTF8), 'query echo');
    finally
      LClient.Free;
    end;
  finally
    StopHorse(LThread);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(THorseAdapterTests);

end.
