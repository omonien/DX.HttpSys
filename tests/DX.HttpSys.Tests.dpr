/// <summary>
///   DX.HttpSys.Tests — DUnitX console test runner for DX.HttpSys.
/// </summary>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
program DX.HttpSys.Tests;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  Test.DX.HttpSys.Api in 'Test.DX.HttpSys.Api.pas',
  Test.DX.HttpSys.Url in 'Test.DX.HttpSys.Url.pas',
  Test.DX.HttpSys.Server in 'Test.DX.HttpSys.Server.pas',
  Test.DX.HttpSys.Stress in 'Test.DX.HttpSys.Stress.pas',
  Test.DX.HttpSys.WebBroker in 'Test.DX.HttpSys.WebBroker.pas',
  Test.DX.HttpSys.Soak in 'Test.DX.HttpSys.Soak.pas';

var
  LRunner: ITestRunner;
  LResults: IRunResults;
  LLogger: ITestLogger;
  LNUnitLogger: ITestLogger;

begin
  // Surface any leaked object at shutdown (PRD section 9.6 leak gate).
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
