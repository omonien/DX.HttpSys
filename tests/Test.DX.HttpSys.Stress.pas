/// <summary>
///   Test.DX.HttpSys.Stress - concurrency / load tests that hammer a real
///   TDXHttpSysServer with many simultaneous requests.
/// </summary>
/// <remarks>
///   The core stability goal (PRD section 9.6): under saturation the server must
///   not lose, mix up, or corrupt responses, and must stay leak-free.
///
///   Each request carries a unique id in its path; the handler echoes that id
///   back. The test asserts every response matches its own request, which is the
///   strongest check that requests are not crossed between worker threads.
///
///   These are sized for CI (a "shortened" stress run per PRD section 9.6): a few
///   hundred requests across many concurrent clients. A longer soak run lives in
///   Phase 6.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Stress;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStressTests = class
  public
    [Test]
    procedure ManyConcurrentRequests_EachResponseMatchesItsRequest;

    [Test]
    procedure ConcurrentPosts_BodiesAreNotCrossed;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Threading,
  System.Net.HttpClient,
  Winapi.WinSock2,
  Winapi.Windows,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
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

function StartServer(APort: Word; AThreadCount: Integer;
  const AHandler: IDXHttpSysRequestHandler): TDXHttpSysServer;
begin
  Result := TDXHttpSysServer.Create;
  try
    Result.Port := APort;
    Result.ThreadCount := AThreadCount;
    Result.Handler := AHandler;
    Result.UseLocalhost;
    Result.Start;
  except
    Result.Free;
    raise;
  end;
end;

procedure TStressTests.ManyConcurrentRequests_EachResponseMatchesItsRequest;
const
  cRequests = 500;
var
  LPort:     Word;
  LServer:   TDXHttpSysServer;
  LBaseUrl:  string;
  LFailures: Integer;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LBaseUrl := Format('http://localhost:%d/', [LPort]);

  // Handler echoes the last path segment (the request's unique id) as the body.
  LServer := StartServer(LPort, 8,
    TProcHandler.Create(
      procedure(AReq: TDXHttpSysRequest; AResp: TDXHttpSysResponse)
      var
        LId: string;
        P:   Integer;
      begin
        LId := AReq.Path;
        P := LId.LastIndexOf('/');
        if P >= 0 then
          LId := LId.Substring(P + 1);
        AResp.SetBody(LId);
      end));
  try
    LFailures := 0;
    TParallel.&For(1, cRequests,
      procedure(I: Integer)
      var
        LClient: THTTPClient;
        LResp:   IHTTPResponse;
        LExpect: string;
      begin
        LExpect := 'req-' + I.ToString;
        LClient := THTTPClient.Create;
        try
          LResp := LClient.Get(LBaseUrl + LExpect);
          if (LResp.StatusCode <> 200) or
             (LResp.ContentAsString(TEncoding.UTF8) <> LExpect) then
            TInterlocked.Increment(LFailures);
        finally
          LClient.Free;
        end;
      end);

    Assert.AreEqual(0, LFailures,
      Format('%d of %d concurrent responses did not match their request',
        [LFailures, cRequests]));
  finally
    LServer.Free;
  end;
end;

procedure TStressTests.ConcurrentPosts_BodiesAreNotCrossed;
const
  cRequests = 300;
var
  LPort:     Word;
  LServer:   TDXHttpSysServer;
  LBaseUrl:  string;
  LFailures: Integer;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LBaseUrl := Format('http://localhost:%d/', [LPort]);

  // Handler echoes the POST body, so a crossed body shows up as a mismatch.
  LServer := StartServer(LPort, 8,
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
        AResp.SetBody(LText);
      end));
  try
    LFailures := 0;
    TParallel.&For(1, cRequests,
      procedure(I: Integer)
      var
        LClient: THTTPClient;
        LResp:   IHTTPResponse;
        LBody:   TStringStream;
        LExpect: string;
      begin
        LExpect := 'payload-' + I.ToString;
        LClient := THTTPClient.Create;
        LBody := TStringStream.Create(LExpect, TEncoding.UTF8);
        try
          LResp := LClient.Post(LBaseUrl, LBody);
          if (LResp.StatusCode <> 200) or
             (LResp.ContentAsString(TEncoding.UTF8) <> LExpect) then
            TInterlocked.Increment(LFailures);
        finally
          LBody.Free;
          LClient.Free;
        end;
      end);

    Assert.AreEqual(0, LFailures,
      Format('%d of %d concurrent POST bodies were crossed or lost',
        [LFailures, cRequests]));
  finally
    LServer.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TStressTests);

end.
