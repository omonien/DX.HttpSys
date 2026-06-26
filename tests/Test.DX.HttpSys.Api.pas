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

    [Test]
    procedure InitializeV2_BeforeLoad_RaisesDeterministically;

    // Regression: C int-sized enums passed by value to httpapi.dll must be 4
    // bytes, or the call fails on Win64 with ERROR_INVALID_PARAMETER (the upper
    // bytes of the argument register are garbage). See docs/DECISIONS.md A-18.
    [Test]
    procedure ApiEnums_AreFourBytes;

    // Regression: a queue created with HTTPAPI_VERSION_2 makes HttpSendHttpResponse
    // read a full HTTP_RESPONSE_V2. HTTP_RESPONSE must therefore alias V2, not V1,
    // so the buffer covers ResponseInfoCount/pResponseInfo. With V1 the kernel read
    // those 16 trailing bytes from uninitialised stack — fine on Win32 (happened to
    // be zero), connection-reset on Win64. See docs/DECISIONS.md A-19.
    [Test]
    procedure HttpResponse_IsV2Sized;
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

procedure TApiSmokeTests.InitializeV2_BeforeLoad_RaisesDeterministically;
var
  LApi: TDXHttpSysApi;
begin
  // Calling an API method before Load must fail with a clear exception,
  // not an access violation on a nil function pointer.
  LApi := TDXHttpSysApi.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        LApi.InitializeV2(HTTP_INITIALIZE_SERVER);
      end,
      EDXHttpSysError,
      'InitializeV2 before Load must raise EDXHttpSysError');
  finally
    LApi.Free;
  end;
end;

procedure TApiSmokeTests.ApiEnums_AreFourBytes;
begin
  // These mirror C int-sized enums; {$MINENUMSIZE 4} in DX.HttpSys.Api.Types
  // guarantees the 4-byte layout the API ABI expects.
  Assert.AreEqual(4, SizeOf(HTTP_SERVER_PROPERTY), 'HTTP_SERVER_PROPERTY');
  Assert.AreEqual(4, SizeOf(HTTP_VERB), 'HTTP_VERB');
  Assert.AreEqual(4, SizeOf(HTTP_HEADER_ID), 'HTTP_HEADER_ID');
  Assert.AreEqual(4, SizeOf(HTTP_DATA_CHUNK_TYPE), 'HTTP_DATA_CHUNK_TYPE');
end;

procedure TApiSmokeTests.HttpResponse_IsV2Sized;
begin
  // HTTP_RESPONSE must be the V2 layout (V1 + ResponseInfoCount + pResponseInfo).
  // The two trailing fields add 16 bytes on Win64 (USHORT + 6 pad + 8-byte ptr).
  // If this regresses to V1, HttpSendHttpResponse reads past the buffer on Win64
  // and the connection is reset (12030) on every response.
  Assert.AreEqual(SizeOf(HTTP_RESPONSE_V2), SizeOf(HTTP_RESPONSE),
    'HTTP_RESPONSE must alias HTTP_RESPONSE_V2, not V1');
  Assert.IsTrue(SizeOf(HTTP_RESPONSE) > SizeOf(HTTP_RESPONSE_V1),
    'HTTP_RESPONSE (V2) must be larger than V1');
end;

initialization
  TDUnitX.RegisterTestFixture(TApiSmokeTests);

end.
