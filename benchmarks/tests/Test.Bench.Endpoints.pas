/// <summary>
///   Test.Bench.Endpoints - unit tests for the framework-neutral endpoint logic.
/// </summary>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Test.Bench.Endpoints;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TBenchEndpointsTests = class
  public
    [Test]
    procedure RoutesMapMethodAndPath;
    [Test]
    procedure PlaintextIs13Bytes;
    [Test]
    procedure JsonHasMessage;
    [Test]
    procedure BytesHaveExactSizes;
    [Test]
    procedure EchoAnswersLength;
    [Test]
    procedure UnknownPathIs404;
    [Test]
    procedure StripQueryRemovesQueryString;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  Bench.Endpoints;

procedure TBenchEndpointsTests.RoutesMapMethodAndPath;
begin
  Assert.IsTrue(BenchRoute('GET', '/plaintext') = brPlaintext);
  Assert.IsTrue(BenchRoute('GET', '/json') = brJson);
  Assert.IsTrue(BenchRoute('GET', '/bytes/64k') = brBytes64k);
  Assert.IsTrue(BenchRoute('GET', '/bytes/1m') = brBytes1m);
  Assert.IsTrue(BenchRoute('POST', '/echo') = brEcho);
  Assert.IsTrue(BenchRoute('POST', '/plaintext') = brMethodNotAllowed);
  Assert.IsTrue(BenchRoute('GET', '/echo') = brMethodNotAllowed);
end;

procedure TBenchEndpointsTests.PlaintextIs13Bytes;
var
  R: TBenchResponse;
begin
  R := BenchDispatch('GET', '/plaintext', 0);
  Assert.AreEqual(200, R.Status);
  Assert.AreEqual(13, Length(R.Body));
  Assert.AreEqual(cBenchPlaintext, TEncoding.UTF8.GetString(R.Body));
  Assert.AreEqual(cBenchContentTypeText, R.ContentType);
end;

procedure TBenchEndpointsTests.JsonHasMessage;
var
  R: TBenchResponse;
  LValue: TJSONValue;
begin
  R := BenchDispatch('GET', '/json', 0);
  Assert.AreEqual(200, R.Status);
  Assert.AreEqual(cBenchContentTypeJson, R.ContentType);
  Assert.AreEqual(27, Length(R.Body));
  LValue := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(R.Body));
  try
    Assert.IsNotNull(LValue);
    Assert.AreEqual(cBenchPlaintext, (LValue as TJSONObject).GetValue<string>('message'));
  finally
    LValue.Free;
  end;
end;

procedure TBenchEndpointsTests.BytesHaveExactSizes;
var
  R: TBenchResponse;
begin
  R := BenchDispatch('GET', '/bytes/64k', 0);
  Assert.AreEqual(65536, Length(R.Body));
  Assert.AreEqual(cBenchContentTypeBinary, R.ContentType);
  Assert.AreEqual(Ord('a'), Integer(R.Body[0]));
  R := BenchDispatch('GET', '/bytes/1m', 0);
  Assert.AreEqual(1048576, Length(R.Body));
  Assert.AreEqual(Ord('a') + (1048575 mod 26), Integer(R.Body[1048575]));
end;

procedure TBenchEndpointsTests.EchoAnswersLength;
var
  R: TBenchResponse;
begin
  R := BenchDispatch('POST', '/echo', 16384);
  Assert.AreEqual(200, R.Status);
  Assert.AreEqual('16384', TEncoding.UTF8.GetString(R.Body));
end;

procedure TBenchEndpointsTests.UnknownPathIs404;
begin
  Assert.AreEqual(404, BenchDispatch('GET', '/nope', 0).Status);
  Assert.AreEqual(405, BenchDispatch('DELETE', '/plaintext', 0).Status);
end;

procedure TBenchEndpointsTests.StripQueryRemovesQueryString;
begin
  Assert.AreEqual('/plaintext', BenchStripQuery('/plaintext?a=1'));
  Assert.AreEqual('/json', BenchStripQuery('/json'));
end;

initialization
  TDUnitX.RegisterTestFixture(TBenchEndpointsTests);

end.
