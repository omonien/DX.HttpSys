/// <summary>
///   Test.DX.HttpSys.Api - smoke tests for the Layer 1 API translation
///   (DX.HttpSys.Api / DX.HttpSys.Api.Types).
/// </summary>
/// <remarks>
///   Verifies that httpapi.dll loads, that the critical function pointers resolve,
///   that HttpInitialize/HttpTerminate succeed, and that the error-translation
///   helpers behave. These are the Milestone 1 acceptance tests (PRD section 10).
///
///   They require a real Windows host with httpapi.dll (always present on Windows).
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit Test.DX.HttpSys.Api;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TApiSmokeTests = class
  public
    [Test]
    procedure Load_Succeeds;

    [Test]
    procedure Load_ResolvesCriticalFunctionPointers;

    [Test]
    procedure Load_IsIdempotent;

    [Test]
    procedure InitializeAndTerminate_Succeed;

    [Test]
    procedure CheckResult_Success_DoesNotRaise;

    [Test]
    procedure CheckResult_Failure_RaisesWithContext;
  end;

implementation

uses
  System.SysUtils,
  Winapi.Windows,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api;

procedure TApiSmokeTests.Load_Succeeds;
var
  LApi: TDXHttpSysApi;
begin
  LApi := TDXHttpSysApi.Create;
  try
    Assert.IsTrue(LApi.Load, 'httpapi.dll must load on Windows');
    Assert.IsTrue(LApi.Loaded, 'Loaded must be True after a successful Load');
  finally
    LApi.Free;
  end;
end;

procedure TApiSmokeTests.Load_ResolvesCriticalFunctionPointers;
var
  LApi: TDXHttpSysApi;
begin
  LApi := TDXHttpSysApi.Create;
  try
    Assert.IsTrue(LApi.Load);
    // Assigned(field) — NOT Assigned(@field): @ on a procedural field yields the
    // field's storage address (always non-nil) and would make the check useless.
    // A function-reference field with parameters is not invoked without arguments,
    // so Assigned(LApi.Initialize) tests the resolved pointer value, as intended.
    Assert.IsTrue(Assigned(LApi.Initialize),          'HttpInitialize');
    Assert.IsTrue(Assigned(LApi.Terminate),           'HttpTerminate');
    Assert.IsTrue(Assigned(LApi.CreateServerSession), 'HttpCreateServerSession');
    Assert.IsTrue(Assigned(LApi.CreateUrlGroup),      'HttpCreateUrlGroup');
    Assert.IsTrue(Assigned(LApi.CreateRequestQueue),  'HttpCreateRequestQueue');
    Assert.IsTrue(Assigned(LApi.ReceiveHttpRequest),  'HttpReceiveHttpRequest');
    Assert.IsTrue(Assigned(LApi.SendHttpResponse),    'HttpSendHttpResponse');
  finally
    LApi.Free;
  end;
end;

procedure TApiSmokeTests.Load_IsIdempotent;
var
  LApi: TDXHttpSysApi;
begin
  LApi := TDXHttpSysApi.Create;
  try
    Assert.IsTrue(LApi.Load, 'first Load');
    Assert.IsTrue(LApi.Load, 'second Load must also report success');
  finally
    LApi.Free;
  end;
end;

procedure TApiSmokeTests.InitializeAndTerminate_Succeed;
var
  LApi: TDXHttpSysApi;
begin
  LApi := TDXHttpSysApi.Create;
  try
    Assert.IsTrue(LApi.Load);
    Assert.AreEqual(Cardinal(ERROR_SUCCESS),
      Cardinal(LApi.InitializeV2(HTTP_INITIALIZE_SERVER)),
      'HttpInitialize(V2, SERVER)');
    Assert.AreEqual(Cardinal(ERROR_SUCCESS),
      Cardinal(LApi.Terminate(HTTP_INITIALIZE_SERVER, nil)),
      'HttpTerminate(SERVER)');
  finally
    LApi.Free;
  end;
end;

procedure TApiSmokeTests.CheckResult_Success_DoesNotRaise;
begin
  TDXHttpSysApi.CheckResult(ERROR_SUCCESS, 'no-op');
  Assert.Pass('ERROR_SUCCESS must not raise');
end;

procedure TApiSmokeTests.CheckResult_Failure_RaisesWithContext;
begin
  Assert.WillRaise(
    procedure
    begin
      TDXHttpSysApi.CheckResult(ERROR_ACCESS_DENIED, 'unit-test-context');
    end,
    EDXHttpSysError,
    'A non-zero result must raise EDXHttpSysError');
end;

initialization
  TDUnitX.RegisterTestFixture(TApiSmokeTests);

end.
