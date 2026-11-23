/// <summary>
///   BenchMormot2Async - M0 reference "mORMot 2 async" (THttpAsyncServer, IOCP based
///   on Windows), mORMot 2.4-stable.
/// </summary>
/// <remarks>
///   Only used as a yardstick in benchmarks/. No DX.Http core unit references
///   mORMot. Defaults: thread pool 32 (or --threads N), keep alive 30 s, no
///   server options. Routing compares RawUtf8 directly (mORMot style); the
///   response bodies and the System.JSON serialization come from Bench.Endpoints.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchMormot2Async;

{$APPTYPE CONSOLE}

{$I mormot.defines.inc}

uses
  {$I mormot.uses.inc}
  System.SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.net.http,
  mormot.net.server,
  mormot.net.async,
  Bench.Endpoints in '..\Common\Bench.Endpoints.pas',
  Bench.Cli in '..\Common\Bench.Cli.pas';

type
  TMormotBench = class
  private
    FPlaintext: RawByteString;
    FBytes64k: RawByteString;
    FBytes1m: RawByteString;
  public
    constructor Create;
    function DoRequest(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function BytesToRaw(const ABytes: TBytes): RawByteString;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], PAnsiChar(Result)^, Length(ABytes));
end;

constructor TMormotBench.Create;
begin
  inherited Create;
  FPlaintext := BytesToRaw(BenchPlaintextBytes);
  FBytes64k := BytesToRaw(BenchBytes64k);
  FBytes1m := BytesToRaw(BenchBytes1m);
end;

function TMormotBench.DoRequest(Ctxt: THttpServerRequestAbstract): cardinal;
var
  LPath: RawUtf8;
  LIsGet: Boolean;
  P: Integer;
begin
  LPath := Ctxt.Url;
  P := Pos('?', LPath);
  if P > 0 then
    LPath := Copy(LPath, 1, P - 1);
  LIsGet := Ctxt.Method = 'GET';
  Result := HTTP_SUCCESS;
  if LIsGet and (LPath = '/plaintext') then
  begin
    Ctxt.OutContent := FPlaintext;
    Ctxt.OutContentType := TEXT_CONTENT_TYPE;
  end
  else if LIsGet and (LPath = '/json') then
  begin
    Ctxt.OutContent := StringToUtf8(BenchJsonText);
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
  end
  else if LIsGet and (LPath = '/bytes/64k') then
  begin
    Ctxt.OutContent := FBytes64k;
    Ctxt.OutContentType := BINARY_CONTENT_TYPE;
  end
  else if LIsGet and (LPath = '/bytes/1m') then
  begin
    Ctxt.OutContent := FBytes1m;
    Ctxt.OutContentType := BINARY_CONTENT_TYPE;
  end
  else if (Ctxt.Method = 'POST') and (LPath = '/echo') then
  begin
    // mORMot has read the complete body into InContent before calling us.
    Ctxt.OutContent := StringToUtf8(IntToStr(Length(Ctxt.InContent)));
    Ctxt.OutContentType := TEXT_CONTENT_TYPE;
  end
  else
  begin
    Ctxt.OutContent := 'Not Found';
    Ctxt.OutContentType := TEXT_CONTENT_TYPE;
    Result := HTTP_NOTFOUND;
  end;
end;

var
  LOptions: TBenchOptions;
  LBench: TMormotBench;
  LServer: THttpAsyncServer;
  LPort: RawUtf8;
  LThreads: Integer;
begin
  try
    LOptions := BenchParseOptions;
    if LOptions.IsAllInterfaces then
      LPort := StringToUtf8(IntToStr(LOptions.Port))
    else
      LPort := StringToUtf8(LOptions.SocketHost + ':' + IntToStr(LOptions.Port));
    LThreads := 32;
    if LOptions.Threads > 0 then
      LThreads := LOptions.Threads;
    LBench := TMormotBench.Create;
    try
      LServer := THttpAsyncServer.Create(LPort, nil, nil, 'bench', LThreads, 30000, []);
      try
        LServer.OnRequest := LBench.DoRequest;
        LServer.WaitStarted;
        BenchReady('mormot2-async', LOptions);
        BenchWait(LOptions);
      finally
        LServer.Free;
      end;
    finally
      LBench.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
