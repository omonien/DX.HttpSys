/// <summary>
///   Test.DX.HttpSys.Url - unit tests for the AddUrlPrefix-only bind API:
///   BuildPrefix string assembly, AddUrlPrefix shape validation, and the
///   actionable access-denied message.
/// </summary>
/// <remarks>
///   These exercise the breaking Core URL API (docs/DECISIONS.md A-20). They are
///   pure string/validation tests and do not bind a real port, so they run
///   without elevated rights.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-26</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Url;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TUrlApiTests = class
  public
    // --- BuildPrefix: scheme ---
    [Test]
    procedure BuildPrefix_Http_EmitsHttpScheme;
    [Test]
    procedure BuildPrefix_Https_EmitsHttpsScheme;

    // --- BuildPrefix: host translation ---
    [Test]
    [TestCase('empty',     ',+')]
    [TestCase('wildcard',  '0.0.0.0,+')]
    [TestCase('localhost', 'localhost,localhost')]
    [TestCase('loopback',  '127.0.0.1,localhost')]
    [TestCase('explicit',  '10.0.0.5,10.0.0.5')]
    procedure BuildPrefix_TranslatesHost(const AHost, AExpectedHost: string);

    // --- BuildPrefix: path normalisation ---
    [Test]
    [TestCase('leading-slash',  '/rest,http://localhost:80/rest/')]
    [TestCase('no-slash',       'rest,http://localhost:80/rest/')]
    [TestCase('trailing-slash', 'rest/,http://localhost:80/rest/')]
    [TestCase('empty-path',     ',http://localhost:80/')]
    [TestCase('root-slash',     '/,http://localhost:80/')]
    procedure BuildPrefix_NormalisesPath(const APath, AExpected: string);

    // --- AddUrlPrefix validation (at call time, not at Start) ---
    [Test]
    procedure AddUrlPrefix_NoScheme_Raises;
    [Test]
    procedure AddUrlPrefix_NoTrailingSlash_Raises;
    [Test]
    procedure AddUrlPrefix_ValidPrefix_DoesNotRaise;

    // --- Actionable access-denied message ---
    [Test]
    procedure AccessDeniedMessage_ContainsNetshPrefixAndAdminHint;
  end;

implementation

uses
  System.SysUtils,
  Winapi.Windows,
  DX.HttpSys.Api,
  DX.HttpSys.Server;

procedure TUrlApiTests.BuildPrefix_Http_EmitsHttpScheme;
begin
  Assert.AreEqual('http://localhost:80/rest/',
    TDXHttpSysServer.BuildPrefix(TDXScheme.Http, 'localhost', 80, '/rest'));
end;

procedure TUrlApiTests.BuildPrefix_Https_EmitsHttpsScheme;
begin
  Assert.AreEqual('https://+:1223/api/',
    TDXHttpSysServer.BuildPrefix(TDXScheme.Https, '+', 1223, '/api'));
end;

procedure TUrlApiTests.BuildPrefix_TranslatesHost(const AHost, AExpectedHost: string);
begin
  Assert.AreEqual(Format('http://%s:80/x/', [AExpectedHost]),
    TDXHttpSysServer.BuildPrefix(TDXScheme.Http, AHost, 80, '/x'));
end;

procedure TUrlApiTests.BuildPrefix_NormalisesPath(const APath, AExpected: string);
begin
  Assert.AreEqual(AExpected,
    TDXHttpSysServer.BuildPrefix(TDXScheme.Http, 'localhost', 80, APath));
end;

procedure TUrlApiTests.AddUrlPrefix_NoScheme_Raises;
var
  LServer: TDXHttpSysServer;
begin
  LServer := TDXHttpSysServer.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        LServer.AddUrlPrefix('localhost:80/x/');
      end,
      EDXHttpSysError,
      'A prefix without http:// or https:// must raise at call time');
  finally
    LServer.Free;
  end;
end;

procedure TUrlApiTests.AddUrlPrefix_NoTrailingSlash_Raises;
var
  LServer: TDXHttpSysServer;
begin
  LServer := TDXHttpSysServer.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        LServer.AddUrlPrefix('http://localhost:80/x');
      end,
      EDXHttpSysError,
      'A prefix without a trailing slash must raise at call time');
  finally
    LServer.Free;
  end;
end;

procedure TUrlApiTests.AddUrlPrefix_ValidPrefix_DoesNotRaise;
var
  LServer: TDXHttpSysServer;
begin
  LServer := TDXHttpSysServer.Create;
  try
    LServer.AddUrlPrefix('http://localhost:80/x/');
    Assert.Pass('A complete, well-formed prefix must be accepted');
  finally
    LServer.Free;
  end;
end;

procedure TUrlApiTests.AccessDeniedMessage_ContainsNetshPrefixAndAdminHint;
const
  cPrefix = 'http://+:80/horse/';
var
  LMessage: string;
begin
  LMessage := TDXHttpSysServer.FormatAccessDeniedMessage(cPrefix, ERROR_ACCESS_DENIED);
  Assert.Contains(LMessage, 'netsh http add urlacl', False,
    'message must name the netsh reservation command');
  Assert.Contains(LMessage, cPrefix, False,
    'message must name the exact prefix');
  Assert.Contains(LMessage, 'Administrator', False,
    'message must include an Administrator hint');
end;

initialization
  TDUnitX.RegisterTestFixture(TUrlApiTests);

end.
