/// <summary>
///   DX.HttpSys.IntegrationTests — DUnitX runner for the OPTIONAL third-party
///   adapter integration tests (WiRL today; more wrappers later).
/// </summary>
/// <remarks>
///   This project depends on third-party libraries that are NOT part of
///   DX.HttpSys and are NOT vendored. Build it with
///   build-scripts/BuildIntegrationTests.ps1, which first downloads the required
///   sources via FetchThirdParty.ps1. See tests-integration/README.md.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-20</created>
/// <license>MIT</license>
program DX.HttpSys.IntegrationTests;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  Test.DX.HttpSys.WiRL in 'Test.DX.HttpSys.WiRL.pas';

var
  LRunner:  ITestRunner;
  LResults: IRunResults;
  LLogger:  ITestLogger;
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
