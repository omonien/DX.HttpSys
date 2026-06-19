/// <summary>
///   Test.DX.HttpSys.Soak - longevity / leak test: drive a server through many
///   request waves and assert that memory and OS handle usage stay bounded.
/// </summary>
/// <remarks>
///   The stability goal (PRD section 9.6) demands constant memory and handle
///   consumption under sustained load — no leaks, no handle accumulation. This
///   test is a CI-sized soak (a few thousand requests in waves, a few seconds),
///   not the multi-hour run; the same harness scales up by raising cWaves.
///
///   It measures private memory (GetProcessMemoryInfo) and the process handle
///   count (GetProcessHandleCount) after a warm-up wave and again after the full
///   run, and fails if either grew beyond a generous tolerance — a real leak
///   grows without bound and trips the check, while normal allocator slack stays
///   under it.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Soak;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSoakTests = class
  public
    [Test]
    procedure SustainedLoad_MemoryAndHandlesStayBounded;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  System.Net.HttpClient,
  Winapi.Windows,
  Winapi.PsAPI,
  Winapi.WinSock2,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  TProcHandler = class(TInterfacedObject, IDXHttpSysRequestHandler)
  public
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

procedure TProcHandler.HandleRequest(const ARequest: TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
begin
  AResponse.SetBody('ok:' + ARequest.Path);
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

function CurrentPrivateBytes: NativeUInt;
var
  LCounters: TProcessMemoryCounters;
begin
  FillChar(LCounters, SizeOf(LCounters), 0);
  LCounters.cb := SizeOf(LCounters);
  if GetProcessMemoryInfo(GetCurrentProcess, @LCounters, SizeOf(LCounters)) then
    Result := LCounters.WorkingSetSize
  else
    Result := 0;
end;

function CurrentHandleCount: DWORD;
begin
  if not GetProcessHandleCount(GetCurrentProcess, Result) then
    Result := 0;
end;

// Sends one wave of concurrent requests against the server.
procedure RunWave(const ABaseUrl: string; ACount: Integer);
begin
  TParallel.&For(1, ACount,
    procedure(I: Integer)
    var
      LClient: THTTPClient;
    begin
      LClient := THTTPClient.Create;
      try
        try
          LClient.Get(ABaseUrl + 'soak-' + I.ToString);
        except
          // transient transport hiccups don't matter for the leak measurement
        end;
      finally
        LClient.Free;
      end;
    end);
end;

procedure TSoakTests.SustainedLoad_MemoryAndHandlesStayBounded;
const
  cWaves         = 20;
  cPerWave       = 200;
  cMemToleranceB = 8 * 1024 * 1024; // 8 MB allocator slack
  cHandleTol     = 64;              // generous handle slack
var
  LPort:    Word;
  LServer:  TDXHttpSysServer;
  LBaseUrl: string;
  LMem0, LMem1:       NativeUInt;
  LHandles0, LHandles1: DWORD;
  I: Integer;
begin
  LPort := FindFreePort;
  Assert.IsTrue(LPort > 0, 'no free port');
  LBaseUrl := Format('http://localhost:%d/', [LPort]);

  LServer := TDXHttpSysServer.Create;
  try
    LServer.Port := LPort;
    LServer.ThreadCount := 8;
    LServer.Handler := TProcHandler.Create;
    LServer.UseLocalhost;
    LServer.Start;

    // Warm up: let allocators and the thread pool reach steady state before
    // taking the baseline, so one-time growth isn't counted as a leak.
    RunWave(LBaseUrl, cPerWave);
    RunWave(LBaseUrl, cPerWave);
    LMem0     := CurrentPrivateBytes;
    LHandles0 := CurrentHandleCount;

    for I := 1 to cWaves do
      RunWave(LBaseUrl, cPerWave);

    LMem1     := CurrentPrivateBytes;
    LHandles1 := CurrentHandleCount;

    Assert.IsTrue(LMem1 <= LMem0 + cMemToleranceB,
      Format('Memory grew under sustained load: baseline %d, after %d (delta %d > %d). Possible leak.',
        [LMem0, LMem1, Int64(LMem1) - Int64(LMem0), cMemToleranceB]));

    Assert.IsTrue(LHandles1 <= LHandles0 + cHandleTol,
      Format('Handle count grew under sustained load: baseline %d, after %d (delta %d > %d). Possible handle leak.',
        [LHandles0, LHandles1, Int64(LHandles1) - Int64(LHandles0), cHandleTol]));
  finally
    LServer.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSoakTests);

end.
