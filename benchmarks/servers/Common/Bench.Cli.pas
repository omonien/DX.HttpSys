/// <summary>
///   Bench.Cli - command line options and lifetime helpers shared by the M0
///   benchmark servers.
/// </summary>
/// <remarks>
///   Options (all optional):
///     --port N          listening port, default 8080
///     --host H          localhost (default), all, or an explicit address.
///                       "all" means every interface: 0.0.0.0 for socket servers,
///                       the "+" wildcard for http.sys (needs a URL ACL).
///     --profile P       default or tuned (only Horse over Indy uses it)
///     --seconds N       stop the process after N seconds (runner scripts always
///                       pass it; 0 means wait for Enter on the console)
///     --threads N       worker threads where the candidate supports it, 0 = its default
///
///   Every server prints one line "READY <candidate> pid=<pid> port=<port>" once
///   it accepts requests; the runner scripts wait for that line or for the
///   health check on /plaintext.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Bench.Cli;

interface

type
  TBenchOptions = record
    Port: Integer;
    Host: string;
    Profile: string;
    Seconds: Integer;
    Threads: Integer;
    function IsTuned: Boolean;
    function IsAllInterfaces: Boolean;
    /// <summary>Address for socket based servers (Indy, mORMot).</summary>
    function SocketHost: string;
    /// <summary>Host part of an http.sys URL prefix.</summary>
    function HttpSysHost: string;
  end;

/// <summary>Parses ParamStr into the options record.</summary>
function BenchParseOptions: TBenchOptions;

/// <summary>Prints the READY line and flushes stdout.</summary>
procedure BenchReady(const ACandidate: string; const AOptions: TBenchOptions);

/// <summary>
///   Starts a background thread that terminates the process after
///   AOptions.Seconds seconds (no-op when Seconds is 0). Used by servers whose
///   Listen call blocks (Horse).
/// </summary>
procedure BenchStartWatchdog(const AOptions: TBenchOptions);

/// <summary>
///   Blocks the main thread: sleeps AOptions.Seconds seconds, or waits for Enter
///   when Seconds is 0.
/// </summary>
procedure BenchWait(const AOptions: TBenchOptions);

/// <summary>Writes a log line with a UTC timestamp to stdout.</summary>
procedure BenchLog(const AText: string);

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  System.SysUtils,
  System.Classes,
  System.DateUtils;

function TBenchOptions.IsTuned: Boolean;
begin
  Result := SameText(Profile, 'tuned');
end;

function TBenchOptions.IsAllInterfaces: Boolean;
begin
  Result := SameText(Host, 'all') or (Host = '+') or (Host = '0.0.0.0') or (Host = '*');
end;

function TBenchOptions.SocketHost: string;
begin
  if IsAllInterfaces then
    Result := '0.0.0.0'
  else if SameText(Host, 'localhost') then
    Result := '127.0.0.1'
  else
    Result := Host;
end;

function TBenchOptions.HttpSysHost: string;
begin
  if IsAllInterfaces then
    Result := '+'
  else
    Result := Host;
end;

function BenchParseOptions: TBenchOptions;
var
  I: Integer;
  LName, LValue: string;
begin
  Result.Port := 8080;
  Result.Host := 'localhost';
  Result.Profile := 'default';
  Result.Seconds := 0;
  Result.Threads := 0;
  I := 1;
  while I <= ParamCount do
  begin
    LName := LowerCase(ParamStr(I));
    if I < ParamCount then
      LValue := ParamStr(I + 1)
    else
      LValue := '';
    if LName = '--port' then
    begin
      Result.Port := StrToInt(LValue);
      Inc(I);
    end
    else if LName = '--host' then
    begin
      Result.Host := LValue;
      Inc(I);
    end
    else if LName = '--profile' then
    begin
      Result.Profile := LowerCase(LValue);
      Inc(I);
    end
    else if LName = '--seconds' then
    begin
      Result.Seconds := StrToInt(LValue);
      Inc(I);
    end
    else if LName = '--threads' then
    begin
      Result.Threads := StrToInt(LValue);
      Inc(I);
    end
    else
      raise Exception.CreateFmt('Unknown option: %s', [ParamStr(I)]);
    Inc(I);
  end;
  if (Result.Profile <> 'default') and (Result.Profile <> 'tuned') then
    raise Exception.CreateFmt('Unknown profile: %s (default or tuned)', [Result.Profile]);
end;

procedure BenchLog(const AText: string);
begin
  Writeln(FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', TTimeZone.Local.ToUniversalTime(Now)), ' ', AText);
  Flush(Output);
end;

procedure BenchReady(const ACandidate: string; const AOptions: TBenchOptions);
begin
  Writeln(Format('READY %s pid=%d port=%d host=%s profile=%s',
    [ACandidate, {$IFDEF MSWINDOWS}GetCurrentProcessId{$ELSE}0{$ENDIF},
     AOptions.Port, AOptions.Host, AOptions.Profile]));
  Flush(Output);
end;

procedure TerminateNow;
begin
  BenchLog('watchdog: time is up, terminating');
{$IFDEF MSWINDOWS}
  // Hard exit: framework threads (Indy, http.sys workers) must not block the
  // end of a benchmark run.
  Winapi.Windows.ExitProcess(0);
{$ELSE}
  Halt(0);
{$ENDIF}
end;

procedure BenchStartWatchdog(const AOptions: TBenchOptions);
var
  LSeconds: Integer;
  LThread: TThread;
begin
  if AOptions.Seconds <= 0 then
    Exit;
  LSeconds := AOptions.Seconds;
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(LSeconds * 1000);
      TerminateNow;
    end);
  LThread.FreeOnTerminate := True;
  LThread.Start;
end;

procedure BenchWait(const AOptions: TBenchOptions);
begin
  if AOptions.Seconds > 0 then
    Sleep(AOptions.Seconds * 1000)
  else
  begin
    Writeln('Press <Enter> to stop.');
    Readln;
  end;
end;

end.
