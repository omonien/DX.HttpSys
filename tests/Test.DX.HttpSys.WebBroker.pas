/// <summary>
///   Test.DX.HttpSys.WebBroker - end-to-end test that runs a real WebBroker
///   WebModule over the HTTP.sys engine via TWebBrokerHttpSysDispatcher.
/// </summary>
/// <remarks>
///   Registers a minimal TWebModule with one action, points the WebBroker
///   request handler at it, serves it through TDXHttpSysServer on localhost, and
///   drives it with an HTTP client. Proves the full path:
///   HTTP.sys -> dispatcher -> WebBroker WebModule -> response.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.WebBroker;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TWebBrokerAdapterTests = class
  public
    [Test]
    procedure WebModuleAction_HandlesGet;

    [Test]
    procedure WebModuleAction_EchoesPostBody;

    [Test]
    procedure UnmatchedPath_Yields404;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  Winapi.WinSock2,
  Web.HTTPApp,
  Web.WebReq,
  Web.WebBroker,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server,
  DX.HttpSys.WebBroker;

type
  // A minimal WebModule with two actions: a "/hello" GET and a "/echo" POST.
  TTestWebModule = class(TWebModule)
  private
    procedure HelloAction(Sender: TObject; Request: TWebRequest;
      Response: TWebResponse; var Handled: Boolean);
    procedure EchoAction(Sender: TObject; Request: TWebRequest;
      Response: TWebResponse; var Handled: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
  end;

constructor TTestWebModule.Create(AOwner: TComponent);
var
  LHello, LEcho: TWebActionItem;
begin
  inherited Create(AOwner);

  LHello := Actions.Add;
  LHello.Name := 'Hello';
  LHello.PathInfo := '/hello';
  LHello.MethodType := mtGet;
  LHello.OnAction := HelloAction;

  LEcho := Actions.Add;
  LEcho.Name := 'Echo';
  LEcho.PathInfo := '/echo';
  LEcho.MethodType := mtPost;
  LEcho.OnAction := EchoAction;
end;

procedure TTestWebModule.HelloAction(Sender: TObject; Request: TWebRequest;
  Response: TWebResponse; var Handled: Boolean);
begin
  Response.ContentType := 'text/plain; charset=utf-8';
  Response.Content := 'hello from webbroker';
  Handled := True;
end;

procedure TTestWebModule.EchoAction(Sender: TObject; Request: TWebRequest;
  Response: TWebResponse; var Handled: Boolean);
begin
  Response.ContentType := 'text/plain; charset=utf-8';
  Response.Content := 'echo:' + Request.Content;
  Handled := True;
end;

var
  GHandler: TWebRequestHandler = nil;

// WebBroker calls this to obtain the request handler that owns the module class.
function TestWebRequestHandler: TWebRequestHandler;
begin
  Result := GHandler;
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

// Sets up the WebBroker handler with the test module, starts a server, and
// returns it. The caller must call TearDown after.
function StartWebBrokerServer(APort: Word): TDXHttpSysServer;
begin
  // Register the test module class and a handler factory.
  if GHandler = nil then
  begin
    GHandler := TWebRequestHandler.Create(nil);
    GHandler.WebModuleClass := TTestWebModule;
    Web.WebReq.WebRequestHandlerProc := TestWebRequestHandler;
  end;

  Result := TDXHttpSysServer.Create;
  try
    Result.Port := APort;
    Result.Handler := TWebBrokerHttpSysDispatcher.Create;
    Result.UseLocalhost;
    Result.Start;
  except
    Result.Free;
    raise;
  end;
end;

procedure TearDownWebBroker;
begin
  Web.WebReq.WebRequestHandlerProc := nil;
  FreeAndNil(GHandler);
end;

function BaseUrl(APort: Word): string;
begin
  Result := Format('http://localhost:%d', [APort]);
end;

procedure TWebBrokerAdapterTests.WebModuleAction_HandlesGet;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);
  LServer := StartWebBrokerServer(LPort);
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort) + '/hello');
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('hello from webbroker',
        LResp.ContentAsString(TEncoding.UTF8), 'body');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
    TearDownWebBroker;
  end;
end;

procedure TWebBrokerAdapterTests.WebModuleAction_EchoesPostBody;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LBody:   TStringStream;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);
  LServer := StartWebBrokerServer(LPort);
  try
    LClient := THTTPClient.Create;
    LBody := TStringStream.Create('ping', TEncoding.UTF8);
    try
      LResp := LClient.Post(BaseUrl(LPort) + '/echo', LBody);
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('echo:ping',
        LResp.ContentAsString(TEncoding.UTF8), 'echoed body');
    finally
      LBody.Free;
      LClient.Free;
    end;
  finally
    LServer.Free;
    TearDownWebBroker;
  end;
end;

procedure TWebBrokerAdapterTests.UnmatchedPath_Yields404;
var
  LPort:   Word;
  LServer: TDXHttpSysServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0);
  LServer := StartWebBrokerServer(LPort);
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort) + '/nothing-here');
      Assert.AreEqual(404, LResp.StatusCode, 'unmatched path should be 404');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
    TearDownWebBroker;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TWebBrokerAdapterTests);

end.
