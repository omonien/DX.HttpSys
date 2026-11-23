/// <summary>
///   BenchHorseIndy2 - M0 candidate "Horse 2.0.14 over Indy" (default console provider).
/// </summary>
/// <remarks>
///   --profile default: Horse 2.0.14 unchanged: Indy KeepAlive off, ListenQueue 15,
///   WebBroker MaxConnections 32. This is most likely the setup of the GHttps comparison.
///   --profile tuned:   ListenQueue 1024, MaxConnections 4096 and Indy KeepAlive on.
///
///   Horse 2.0.14 has no public switch for KeepAlive; the bridge instance is a
///   private class var. The tuned profile therefore switches KeepAlive on through
///   the Indy server that owns the current connection (TIdServerContext.Server),
///   once, in a middleware. Indy reads KeepAlive per request, so every request
///   after the first one (that is: after the warmup) keeps its connection.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchHorseIndy2;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Web.HTTPApp,
  IdContext,
  IdCustomTCPServer,
  IdCustomHTTPServer,
  IdHTTPWebBrokerBridge,
  Horse,
  Bench.Endpoints in '..\Common\Bench.Endpoints.pas',
  Bench.Cli in '..\Common\Bench.Cli.pas',
  Bench.Horse2Routes in '..\Common\Bench.Horse2Routes.pas';

type
  /// <summary>Access class for the protected context field of the Indy WebBroker request.</summary>
  TIdHTTPAppRequestAccess = class(TIdHTTPAppRequest);

var
  GKeepAliveApplied: Boolean = False;

procedure ApplyIndyKeepAlive(ARequest: TWebRequest);
var
  LContext: TIdContext;
begin
  if GKeepAliveApplied or not (ARequest is TIdHTTPAppRequest) then
    Exit;
  LContext := TIdHTTPAppRequestAccess(ARequest).FThread;
  if (LContext is TIdServerContext) and
     (TIdServerContext(LContext).Server is TIdCustomHTTPServer) then
  begin
    TIdCustomHTTPServer(TIdServerContext(LContext).Server).KeepAlive := True;
    GKeepAliveApplied := True;
  end;
end;

var
  LOptions: TBenchOptions;
begin
  try
    LOptions := BenchParseOptions;
    if LOptions.IsTuned then
    begin
      THorse.ListenQueue := 1024;
      THorse.MaxConnections := 4096;
      THorse.Use(
        procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
        begin
          ApplyIndyKeepAlive(AReq.RawWebRequest);
          ANext();
        end);
    end;
    RegisterBenchRoutes;
    BenchStartWatchdog(LOptions);
    THorse.Listen(LOptions.Port, LOptions.SocketHost,
      procedure(AHorse: THorse)
      begin
        BenchReady('horse2-indy-' + LOptions.Profile, LOptions);
      end);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
