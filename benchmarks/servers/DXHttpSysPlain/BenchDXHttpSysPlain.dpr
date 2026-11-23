/// <summary>
///   BenchDXHttpSysPlain - M0 candidate "DX.HttpSys pur": TDXHttpSysServer with a
///   direct handler, no framework.
/// </summary>
/// <remarks>
///   ThreadCount 2 x CPU (DX.HttpSys default, or --threads N), QueueLength 1000.
///   --host localhost registers http://localhost:PORT/ (no URL ACL needed),
///   --host all registers http://+:PORT/ (needs a URL ACL or elevation).
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchDXHttpSysPlain;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DX.HttpSys.Api.Types in '..\..\..\src\Core\DX.HttpSys.Api.Types.pas',
  DX.HttpSys.Api in '..\..\..\src\Core\DX.HttpSys.Api.pas',
  DX.HttpSys.Request in '..\..\..\src\Core\DX.HttpSys.Request.pas',
  DX.HttpSys.Response in '..\..\..\src\Core\DX.HttpSys.Response.pas',
  DX.HttpSys.ThreadPool in '..\..\..\src\Core\DX.HttpSys.ThreadPool.pas',
  DX.HttpSys.Server in '..\..\..\src\Core\DX.HttpSys.Server.pas',
  Bench.Endpoints in '..\Common\Bench.Endpoints.pas',
  Bench.Cli in '..\Common\Bench.Cli.pas',
  Bench.DXHttpSysHandler in '..\Common\Bench.DXHttpSysHandler.pas';

var
  LOptions: TBenchOptions;
  LServer: TDXHttpSysServer;
begin
  try
    LOptions := BenchParseOptions;
    LServer := TDXHttpSysServer.Create;
    try
      LServer.Handler := TBenchDXHttpSysHandler.Create;
      LServer.QueueLength := 1000;
      if LOptions.Threads > 0 then
        LServer.ThreadCount := LOptions.Threads;
      LServer.AddUrlPrefix(TDXHttpSysServer.BuildPrefix(TDXScheme.Http,
        LOptions.HttpSysHost, Word(LOptions.Port), ''));
      LServer.Start;
      BenchReady('dxhttpsys-plain', LOptions);
      BenchWait(LOptions);
      LServer.Stop;
    finally
      LServer.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
