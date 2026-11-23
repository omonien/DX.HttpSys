/// <summary>
///   Bench.Endpoints - the framework-neutral endpoint logic shared by every
///   M0 benchmark server.
/// </summary>
/// <remarks>
///   Every candidate maps its native request onto <c>BenchDispatch</c> and
///   writes the returned status, content type and body back through its own
///   API. That keeps the work per request identical across candidates; only the
///   transport and framework overhead differ.
///
///   Endpoints:
///     GET  /plaintext  "Hello, World!" as text/plain (13 bytes)
///     GET  /json       {"message":"Hello, World!"}, serialized per request with System.JSON
///     GET  /bytes/64k  static 64 KiB buffer, application/octet-stream
///     GET  /bytes/1m   static 1 MiB buffer, application/octet-stream
///     POST /echo       the caller reads the full body; the answer is its length as text
///
///   Delphi 11.3 compatible: no multiline strings, no conditional expressions,
///   no NameOf, no inline assembler.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Bench.Endpoints;

interface

uses
  System.SysUtils;

type
  TBenchRoute = (brNotFound, brMethodNotAllowed, brPlaintext, brJson,
    brBytes64k, brBytes1m, brEcho);

  /// <summary>Result of one dispatched request.</summary>
  TBenchResponse = record
    Status: Integer;
    ContentType: string;
    Body: TBytes;
  end;

const
  cBenchPlaintext = 'Hello, World!';
  cBenchContentTypeText = 'text/plain; charset=utf-8';
  cBenchContentTypeJson = 'application/json';
  cBenchContentTypeBinary = 'application/octet-stream';
  cBenchBytes64kSize = 64 * 1024;
  cBenchBytes1mSize = 1024 * 1024;

/// <summary>Maps method and path (without query string) onto a route.</summary>
function BenchRoute(const AMethod, APath: string): TBenchRoute;

/// <summary>
///   Builds the response for a route. <c>ABodyLength</c> is the number of body
///   bytes the caller has read completely (only used by /echo).
/// </summary>
function BenchDispatch(ARoute: TBenchRoute; ABodyLength: Int64): TBenchResponse; overload;

/// <summary>Convenience: BenchRoute plus BenchDispatch.</summary>
function BenchDispatch(const AMethod, APath: string; ABodyLength: Int64): TBenchResponse; overload;

/// <summary>Static, shared response bodies (read only, never modify).</summary>
function BenchPlaintextBytes: TBytes;
function BenchBytes64k: TBytes;
function BenchBytes1m: TBytes;

/// <summary>Serializes {"message":"Hello, World!"} with System.JSON.</summary>
function BenchJsonText: string;

/// <summary>Strips a query string from a URL or path.</summary>
function BenchStripQuery(const AUrl: string): string;

implementation

uses
  System.JSON;

var
  GPlaintext: TBytes;
  GBytes64k: TBytes;
  GBytes1m: TBytes;

procedure FillPattern(var ABuffer: TBytes; ASize: Integer);
var
  I: Integer;
begin
  SetLength(ABuffer, ASize);
  for I := 0 to ASize - 1 do
    ABuffer[I] := Byte(Ord('a') + (I mod 26));
end;

function BenchPlaintextBytes: TBytes;
begin
  Result := GPlaintext;
end;

function BenchBytes64k: TBytes;
begin
  Result := GBytes64k;
end;

function BenchBytes1m: TBytes;
begin
  Result := GBytes1m;
end;

function BenchJsonText: string;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('message', cBenchPlaintext);
    Result := LObj.ToJSON;
  finally
    LObj.Free;
  end;
end;

function BenchStripQuery(const AUrl: string): string;
var
  P: Integer;
begin
  P := Pos('?', AUrl);
  if P > 0 then
    Result := Copy(AUrl, 1, P - 1)
  else
    Result := AUrl;
end;

function BenchRoute(const AMethod, APath: string): TBenchRoute;
var
  LIsGet: Boolean;
begin
  LIsGet := SameText(AMethod, 'GET');
  if APath = '/plaintext' then
  begin
    if LIsGet then Result := brPlaintext else Result := brMethodNotAllowed;
  end
  else if APath = '/json' then
  begin
    if LIsGet then Result := brJson else Result := brMethodNotAllowed;
  end
  else if APath = '/bytes/64k' then
  begin
    if LIsGet then Result := brBytes64k else Result := brMethodNotAllowed;
  end
  else if APath = '/bytes/1m' then
  begin
    if LIsGet then Result := brBytes1m else Result := brMethodNotAllowed;
  end
  else if APath = '/echo' then
  begin
    if SameText(AMethod, 'POST') then Result := brEcho else Result := brMethodNotAllowed;
  end
  else
    Result := brNotFound;
end;

function BenchDispatch(ARoute: TBenchRoute; ABodyLength: Int64): TBenchResponse;
begin
  Result.Status := 200;
  case ARoute of
    brPlaintext:
      begin
        Result.ContentType := cBenchContentTypeText;
        Result.Body := GPlaintext;
      end;
    brJson:
      begin
        Result.ContentType := cBenchContentTypeJson;
        Result.Body := TEncoding.UTF8.GetBytes(BenchJsonText);
      end;
    brBytes64k:
      begin
        Result.ContentType := cBenchContentTypeBinary;
        Result.Body := GBytes64k;
      end;
    brBytes1m:
      begin
        Result.ContentType := cBenchContentTypeBinary;
        Result.Body := GBytes1m;
      end;
    brEcho:
      begin
        Result.ContentType := cBenchContentTypeText;
        Result.Body := TEncoding.UTF8.GetBytes(IntToStr(ABodyLength));
      end;
    brMethodNotAllowed:
      begin
        Result.Status := 405;
        Result.ContentType := cBenchContentTypeText;
        Result.Body := TEncoding.UTF8.GetBytes('Method Not Allowed');
      end;
  else
    Result.Status := 404;
    Result.ContentType := cBenchContentTypeText;
    Result.Body := TEncoding.UTF8.GetBytes('Not Found');
  end;
end;

function BenchDispatch(const AMethod, APath: string; ABodyLength: Int64): TBenchResponse;
begin
  Result := BenchDispatch(BenchRoute(AMethod, APath), ABodyLength);
end;

initialization
  GPlaintext := TEncoding.UTF8.GetBytes(cBenchPlaintext);
  FillPattern(GBytes64k, cBenchBytes64kSize);
  FillPattern(GBytes1m, cBenchBytes1mSize);

end.
