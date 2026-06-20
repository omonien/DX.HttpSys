/// <summary>
///   Test.DX.HttpSys.WiRL - end-to-end test of the WiRL adapter: a real WiRL
///   REST resource served over the kernel HTTP.sys engine.
/// </summary>
/// <remarks>
///   This test requires WiRL, which is NOT part of DX.HttpSys. It only builds
///   inside the optional integration-test project (tests-integration/) after
///   FetchThirdParty.ps1 has downloaded WiRL into build/thirdparty/. See
///   tests-integration/README.md.
///
///   It binds to http://localhost:PORT/ (no elevated rights) and drives the
///   server with an HTTP client, proving: HTTP.sys -> DX.HttpSys.WiRL adapter ->
///   WiRL listener -> resource -> response.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-20</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.WiRL;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TWiRLAdapterTests = class
  public
    [Test]
    procedure GetResource_ReturnsBody;

    [Test]
    procedure EchoResource_ReturnsQueryEcho;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  Winapi.WinSock2,
  WiRL.Core.Engine,
  WiRL.Core.Application,
  WiRL.http.Server,
  WiRL.Core.Registry,
  WiRL.Core.Attributes,
  WiRL.http.Accept.MediaType,
  WiRL.Core.MessageBody.Default,   // registers the default message-body writers
  DX.HttpSys.WiRL;   // registers the 'HttpSys' WiRL engine

type
  [Path('hello')]
  THelloResource = class
  public
    [GET, Produces(TMediaType.TEXT_PLAIN)]
    function World: string;

    [GET, Path('echo'), Produces(TMediaType.TEXT_PLAIN)]
    function Echo([QueryParam('msg')] const AMsg: string): string;
  end;

function THelloResource.World: string;
begin
  Result := 'hello from wirl over httpsys';
end;

function THelloResource.Echo(const AMsg: string): string;
begin
  Result := 'echo:' + AMsg;
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

function StartWiRLServer(APort: Word): TWiRLServer;
begin
  Result := TWiRLServer.Create(nil);
  try
    Result.Port := APort;
    // ServerVendor selects the registered server engine; DX.HttpSys.WiRL
    // registers itself as 'HttpSys'.
    Result.ServerVendor := 'HttpSys';
    Result
      .AddEngine<TWiRLEngine>('/rest')
        .SetEngineName('DX.HttpSys WiRL integration test')
      .AddApplication('/app')
        .SetResources('*');
    Result.Active := True;
  except
    Result.Free;
    raise;
  end;
end;

function BaseUrl(APort: Word): string;
begin
  Result := Format('http://localhost:%d/rest/app/hello', [APort]);
end;

procedure TWiRLAdapterTests.GetResource_ReturnsBody;
var
  LPort:   Word;
  LServer: TWiRLServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LServer := StartWiRLServer(LPort);
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort));
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('hello from wirl over httpsys',
        LResp.ContentAsString(TEncoding.UTF8), 'body');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TWiRLAdapterTests.EchoResource_ReturnsQueryEcho;
var
  LPort:   Word;
  LServer: TWiRLServer;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LServer := StartWiRLServer(LPort);
  try
    LClient := THTTPClient.Create;
    try
      LResp := LClient.Get(BaseUrl(LPort) + '/echo?msg=ping');
      Assert.AreEqual(200, LResp.StatusCode, 'status');
      Assert.AreEqual('echo:ping',
        LResp.ContentAsString(TEncoding.UTF8), 'query echo');
    finally
      LClient.Free;
    end;
  finally
    LServer.Free;
  end;
end;

initialization
  // WiRL resources must be registered before they can be selected by name.
  TWiRLResourceRegistry.Instance.RegisterResource<THelloResource>;
  TDUnitX.RegisterTestFixture(TWiRLAdapterTests);

end.
