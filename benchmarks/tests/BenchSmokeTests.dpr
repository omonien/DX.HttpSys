/// <summary>
///   BenchSmokeTests - DUnitX console runner for the M0 benchmark smoke tests.
/// </summary>
/// <remarks>
///   Covers the shared endpoint logic (Bench.Endpoints) and an in-process HTTP
///   round trip against the DX.HttpSys handler. The other candidates are smoke
///   tested as running processes by scripts/Smoke-Servers.ps1.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchSmokeTests;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  DX.HttpSys.Api.Types in '..\..\src\Core\DX.HttpSys.Api.Types.pas',
  DX.HttpSys.Api in '..\..\src\Core\DX.HttpSys.Api.pas',
  DX.HttpSys.Request in '..\..\src\Core\DX.HttpSys.Request.pas',
  DX.HttpSys.Response in '..\..\src\Core\DX.HttpSys.Response.pas',
  DX.HttpSys.ThreadPool in '..\..\src\Core\DX.HttpSys.ThreadPool.pas',
  DX.HttpSys.Server in '..\..\src\Core\DX.HttpSys.Server.pas',
  Bench.Endpoints in '..\servers\Common\Bench.Endpoints.pas',
  Bench.DXHttpSysHandler in '..\servers\Common\Bench.DXHttpSysHandler.pas',
  Test.Bench.Endpoints in 'Test.Bench.Endpoints.pas',
  Test.Bench.DXHttpSys in 'Test.Bench.DXHttpSys.pas';

var
  LRunner: ITestRunner;
  LResults: IRunResults;
  LLogger: ITestLogger;
  LNUnitLogger: ITestLogger;

begin
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;
    LRunner := TDUnitX.CreateRunner;
    LRunner.UseRTTI := True;
    LLogger := TDUnitXConsoleLogger.Create(True);
    LRunner.AddLogger(LLogger);
    LNUnitLogger := TDUnitXXmlNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    LRunner.AddLogger(LNUnitLogger);
    LResults := LRunner.Execute;
    if not LResults.AllPassed then
      System.ExitCode := EXIT_ERRORS;
    {$IFNDEF CI}
    if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then
    begin
      System.Write('Done... Press <Enter> key to quit.');
      System.Readln;
    end;
    {$ENDIF}
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := EXIT_ERRORS;
    end;
  end;
end.
