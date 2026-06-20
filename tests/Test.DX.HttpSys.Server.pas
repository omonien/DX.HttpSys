/// <summary>
///   Test.DX.HttpSys.Server - end-to-end integration tests that start a real
///   TDXHttpSysServer on localhost and drive it with an HTTP client.
/// </summary>
/// <remarks>
///   These prove the full request lifecycle: HTTP.sys receive -> worker thread ->
///   IDXHttpSysRequestHandler -> response send -> client. They bind to
///   http://localhost:PORT/ which needs no elevated rights (PRD section 9.3).
///
///   A free TCP port is picked per run to avoid clashes with anything already
///   listening. Each test starts and stops its own server.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Server;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TServerIntegrationTests = class
  public
    [Test]
    procedure Get_ReturnsHandlerBody;

    [Test]
    procedure Get_AppliesServerHeaderAndContentType;

    [Test]
    procedure Get_HandlerStatusCodeIsPropagated;

    [Test]
    procedure Post_BodyIsReceivedByHandler;

    [Test]
    procedure UnhandledExceptionInHandler_Yields500;

    // Regression: CookedUrl.pAbsPath is not null-terminated at the path end, so
    // a naive string() cast leaked the query string into Path. With a query
    // present, Path must stop at the '?' and QueryString must hold the rest.
    [Test]
    procedure RequestWithQuery_SplitsPathAndQuery;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
  Winapi.WinSock2,
  Winapi.Windows,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  // A small handler driven by a closure, so each test can define its behaviour
  // inline without a dedicated class.
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

// Picks a free TCP port by binding to port 0 and reading back the assignment.
// There is a small race window between closing this probe socket and HTTP.sys
// binding the same port, so these tests must run sequentially (DUnitX does).
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

// Builds and starts a server on localhost:APort with the given handler.
function StartServer(APort: Word;
  const AHandler: IDXHttpSysRequestHandler): TDXHttpSysServer;
begin
  Result := TDXHttpSysServer.Create;
  try
    Result.Port := APort;
    Result.Handler := AHandler;
    Result.UseLocalhost;
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

procedure TServerIntegrationTests.Get_ReturnsHandlerBody;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'could not find a free port');

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      begin
        AResp.SetBody('Hello, HTTP.sys!');
      end));
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('Hello, HTTP.sys!', LResp.ContentAsString(TEncoding.UTF8), 'body');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TServerIntegrationTests.Get_AppliesServerHeaderAndContentType;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      begin
        AResp.SetBody('{"ok":true}', 'application/json; charset=utf-8');
      end));
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode);
      Assert.Contains(LResp.MimeType, 'application/json', True, 'content-type');
      // The default Server header (DX.HttpSys/1.0) is applied by the worker.
      Assert.Contains(LResp.HeaderValue['Server'], 'DX.HttpSys', 'server header');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TServerIntegrationTests.Get_HandlerStatusCodeIsPropagated;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      begin
        AResp.StatusCode := 404;
        AResp.SetBody('nope');
      end));
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort));
      Assert.AreEqual(404, LResp.StatusCode);
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TServerIntegrationTests.Post_BodyIsReceivedByHandler;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LBody:   TStringStream;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LReader: TStreamReader;
        LText:   string;
      begin
        LText := '';
        if Assigned(AReq.Body) then
        begin
          AReq.Body.Position := 0;
          LReader := TStreamReader.Create(AReq.Body, TEncoding.UTF8);
          try
            LText := LReader.ReadToEnd;
          finally
            LReader.Free;
          end;
        end;
        AResp.SetBody('echo:' + LText);
      end));
  try
    LClient := THTTPClient.Create;
    LBody := TStringStream.Create('ping', TEncoding.UTF8);
    try
      LResp := LClient.Post(BaseUrl(LPort), LBody);
      Assert.AreEqual(200, LResp.StatusCode);
      Assert.AreEqual('echo:ping', LResp.ContentAsString(TEncoding.UTF8));
    finally
      LBody.Free;
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TServerIntegrationTests.UnhandledExceptionInHandler_Yields500;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      begin
        raise Exception.Create('boom');
      end));
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort));
      Assert.AreEqual(500, LResp.StatusCode, 'unhandled handler exception must yield 500');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TServerIntegrationTests.RequestWithQuery_SplitsPathAndQuery;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'could not find a free port');

  LServer := StartServer(LPort,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      begin
        // Echo the parsed values back in the body so the assertion runs on the
        // client thread with no cross-thread shared state.
        AResp.SetBody(AReq.Path + '|' + AReq.QueryString);
      end));
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(Format('http://localhost:%d/echo?msg=ping&x=1', [LPort]));
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      // Path must exclude the query string; QueryString must hold it.
      Assert.AreEqual('/echo|msg=ping&x=1',
        LResp.ContentAsString(TEncoding.UTF8), 'path|query');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TServerIntegrationTests);

end.
