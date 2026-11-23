/// <summary>
///   BenchHorseHttpSys33 - M0 candidate "Horse 3.3.16 with its own HttpSys provider".
/// </summary>
/// <remarks>
///   Build with the define HORSE_PROVIDER_HTTPSYS (Horse.pas then selects
///   Horse.Provider.HttpSys). Provider defaults, no tuning.
///   --host localhost registers http://localhost:PORT/ (no URL ACL needed),
///   --host all registers http://+:PORT/ (needs a URL ACL or elevation).
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchHorseHttpSys33;

{$APPTYPE CONSOLE}

{$IFNDEF HORSE_PROVIDER_HTTPSYS}
  {$MESSAGE FATAL 'Build BenchHorseHttpSys33 with the define HORSE_PROVIDER_HTTPSYS.'}
{$ENDIF}

uses
  System.SysUtils,
  Horse,
  Bench.Endpoints in '..\Common\Bench.Endpoints.pas',
  Bench.Cli in '..\Common\Bench.Cli.pas',
  Bench.Horse3Routes in '..\Common\Bench.Horse3Routes.pas';

var
  LOptions: TBenchOptions;
begin
  try
    LOptions := BenchParseOptions;
    RegisterBenchRoutes;
    BenchStartWatchdog(LOptions);
    THorse.Listen(LOptions.Port, LOptions.HttpSysHost,
      procedure
      begin
        BenchReady('horse33-httpsys', LOptions);
      end);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
