/// <summary>
///   Test.Bench.DXHttpSys - in-process HTTP round trip against the DX.HttpSys
///   benchmark handler on http://localhost:18091/ (no URL ACL needed).
/// </summary>
/// <remarks>
///   Uses THTTPClient with ProtocolVersion HTTP_1_1 and checks status, body and
///   the negotiated protocol of every M0 endpoint.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Test.Bench.DXHttpSys;

interface

uses
  DUnitX.TestFramework,
  System.Net.HttpClient,
  DX.HttpSys.Server;

type
  [TestFixture]
  TBenchDXHttpSysTests = class
  private
    FServer: TDXHttpSysServer;
    FClient: THTTPClient;
    function Url(const APath: string): string;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TearDownFixture]
    procedure TearDownFixture;
    [Test]
    procedure Plaintext;
    [Test]
    procedure Json;
    [Test]
    procedure Bytes64k;
    [Test]
    procedure Bytes1m;
    [Test]
    procedure Echo16k;
    [Test]
    procedure Echo1m;
    [Test]
    procedure NotFound;
    [Test]
    procedure KeepAliveSequence;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.URLClient,
  Bench.DXHttpSysHandler;

const
  cPort = 18091;

function TBenchDXHttpSysTests.Url(const APath: string): string;
begin
  Result := Format('http://localhost:%d%s', [cPort, APath]);
end;

procedure TBenchDXHttpSysTests.SetupFixture;
begin
  FServer := TDXHttpSysServer.Create;
  FServer.Handler := TBenchDXHttpSysHandler.Create;
  FServer.AddUrlPrefix(TDXHttpSysServer.BuildPrefix(TDXScheme.Http, 'localhost', cPort, ''));
  FServer.Start;
  FClient := THTTPClient.Create;
  FClient.ProtocolVersion := THTTPProtocolVersion.HTTP_1_1;
end;

procedure TBenchDXHttpSysTests.TearDownFixture;
begin
  FClient.Free;
  if FServer <> nil then
    FServer.Stop;
  FServer.Free;
end;

procedure TBenchDXHttpSysTests.Plaintext;
var
  R: IHTTPResponse;
begin
  R := FClient.Get(Url('/plaintext'));
  Assert.AreEqual(200, R.StatusCode);
  Assert.AreEqual('Hello, World!', R.ContentAsString(TEncoding.UTF8));
  Assert.IsTrue(R.MimeType.StartsWith('text/plain'), R.MimeType);
  Assert.IsTrue(R.Version = THTTPProtocolVersion.HTTP_1_1, 'expected HTTP/1.1');
end;

procedure TBenchDXHttpSysTests.Json;
var
  R: IHTTPResponse;
begin
  R := FClient.Get(Url('/json'));
  Assert.AreEqual(200, R.StatusCode);
  Assert.AreEqual('{"message":"Hello, World!"}', R.ContentAsString(TEncoding.UTF8));
end;

procedure TBenchDXHttpSysTests.Bytes64k;
var
  R: IHTTPResponse;
begin
  R := FClient.Get(Url('/bytes/64k'));
  Assert.AreEqual(200, R.StatusCode);
  Assert.AreEqual(65536, Integer(R.ContentStream.Size));
end;

procedure TBenchDXHttpSysTests.Bytes1m;
var
  R: IHTTPResponse;
begin
  R := FClient.Get(Url('/bytes/1m'));
  Assert.AreEqual(200, R.StatusCode);
  Assert.AreEqual(1048576, Integer(R.ContentStream.Size));
end;

procedure PostEcho(AClient: THTTPClient; const AUrl: string; ASize: Integer);
var
  LBody: TBytesStream;
  LBytes: TBytes;
  R: IHTTPResponse;
begin
  SetLength(LBytes, ASize);
  FillChar(LBytes[0], ASize, Ord('x'));
  LBody := TBytesStream.Create(LBytes);
  try
    R := AClient.Post(AUrl, LBody, nil,
      [TNetHeader.Create('Content-Type', 'application/octet-stream')]);
    Assert.AreEqual(200, R.StatusCode);
    Assert.AreEqual(IntToStr(ASize), R.ContentAsString(TEncoding.UTF8));
  finally
    LBody.Free;
  end;
end;

procedure TBenchDXHttpSysTests.Echo16k;
begin
  PostEcho(FClient, Url('/echo'), 16384);
end;

procedure TBenchDXHttpSysTests.Echo1m;
begin
  PostEcho(FClient, Url('/echo'), 1048576);
end;

procedure TBenchDXHttpSysTests.NotFound;
begin
  Assert.AreEqual(404, FClient.Get(Url('/nope')).StatusCode);
end;

procedure TBenchDXHttpSysTests.KeepAliveSequence;
var
  I: Integer;
begin
  for I := 1 to 200 do
    Assert.AreEqual(200, FClient.Get(Url('/plaintext')).StatusCode);
end;

initialization
  TDUnitX.RegisterTestFixture(TBenchDXHttpSysTests);

end.
