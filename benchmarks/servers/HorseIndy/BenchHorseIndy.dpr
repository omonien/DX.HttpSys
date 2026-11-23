/// <summary>
///   BenchHorseIndy - M0 candidate "Horse 3.3.16 over Indy" (default console provider).
/// </summary>
/// <remarks>
///   --profile default: Horse 3.3.16 unchanged (it switches Indy KeepAlive on by
///   itself; ListenQueue 15 and WebBroker MaxConnections 32 stay Indy defaults).
///   --profile tuned:   KeepConnectionAlive True, ListenQueue 1024, MaxConnections 4096.
///   Build without any HORSE_PROVIDER_* define.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchHorseIndy;

{$APPTYPE CONSOLE}

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
    if LOptions.IsTuned then
    begin
      THorse.KeepConnectionAlive := True;
      THorse.ListenQueue := 1024;
      THorse.MaxConnections := 4096;
    end;
    BenchStartWatchdog(LOptions);
    THorse.Listen(LOptions.Port, LOptions.SocketHost,
      procedure
      begin
        BenchReady('horse33-indy-' + LOptions.Profile, LOptions);
      end);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
