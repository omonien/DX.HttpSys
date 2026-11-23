/// <summary>
///   BenchHorseDXHttpSys - M0 candidate "Horse 2.0.14 over DX.HttpSys"
///   (THorseProviderHttpSys from src/Adapters/DX.HttpSys.Horse.pas).
/// </summary>
/// <remarks>
///   Today the only working way to run Horse on DX.HttpSys; repeat with Horse 3.3
///   once M8 ports the adapter. DX.HttpSys defaults: ThreadCount 2 x CPU.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchHorseDXHttpSys;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Horse,
  DX.HttpSys.Api.Types in '..\..\..\src\Core\DX.HttpSys.Api.Types.pas',
  DX.HttpSys.Api in '..\..\..\src\Core\DX.HttpSys.Api.pas',
  DX.HttpSys.Request in '..\..\..\src\Core\DX.HttpSys.Request.pas',
  DX.HttpSys.Response in '..\..\..\src\Core\DX.HttpSys.Response.pas',
  DX.HttpSys.ThreadPool in '..\..\..\src\Core\DX.HttpSys.ThreadPool.pas',
  DX.HttpSys.Server in '..\..\..\src\Core\DX.HttpSys.Server.pas',
  DX.HttpSys.WebBroker in '..\..\..\src\Adapters\DX.HttpSys.WebBroker.pas',
  DX.HttpSys.Horse in '..\..\..\src\Adapters\DX.HttpSys.Horse.pas',
  Bench.Endpoints in '..\Common\Bench.Endpoints.pas',
  Bench.Cli in '..\Common\Bench.Cli.pas',
  Bench.Horse2Routes in '..\Common\Bench.Horse2Routes.pas';

var
  LOptions: TBenchOptions;
begin
  try
    LOptions := BenchParseOptions;
    RegisterBenchRoutes;
    BenchStartWatchdog(LOptions);
    THorseProviderHttpSys<THorse>.BasePath := '';
    // Listen(ACallback) falls back to the default port and host and ignores the
    // Port and Host properties (adapter finding for M8), so pass both explicitly.
    THorseProviderHttpSys<THorse>.Listen(LOptions.Port, LOptions.HttpSysHost,
      procedure(AHorse: THorse)
      begin
        BenchReady('horse2-dxhttpsys', LOptions);
      end);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
