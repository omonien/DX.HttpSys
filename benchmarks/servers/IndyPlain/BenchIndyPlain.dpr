/// <summary>
///   BenchIndyPlain - M0 candidate "Indy pur": TIdHTTPServer with OnCommandGet.
/// </summary>
/// <remarks>
///   Configuration as documented in benchmarks/README.md: KeepAlive on,
///   ListenQueue 1024, Nagle off, MaxConnections 0 (unlimited), Indy default
///   thread per connection scheduler. Indy ships with Delphi, no third party code.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
program BenchIndyPlain;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  IdContext,
  IdSocketHandle,
  IdCustomHTTPServer,
  IdHTTPServer,
  Bench.Endpoints in '..\Common\Bench.Endpoints.pas',
  Bench.Cli in '..\Common\Bench.Cli.pas';

type
  TIndyBench = class
  public
    procedure CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  end;

procedure TIndyBench.CommandGet(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  LBodyLength: Int64;
  LResponse: TBenchResponse;
begin
  // Indy has already read the complete entity into PostStream.
  LBodyLength := 0;
  if ARequestInfo.PostStream <> nil then
    LBodyLength := ARequestInfo.PostStream.Size;
  LResponse := BenchDispatch(ARequestInfo.Command, ARequestInfo.Document, LBodyLength);
  AResponseInfo.ResponseNo := LResponse.Status;
  AResponseInfo.ContentType := LResponse.ContentType;
  AResponseInfo.ContentLength := Length(LResponse.Body);
  // TBytesStream keeps a reference to the (static) array, no copy.
  AResponseInfo.ContentStream := TBytesStream.Create(LResponse.Body);
  AResponseInfo.FreeContentStream := True;
end;

var
  LOptions: TBenchOptions;
  LServer: TIdHTTPServer;
  LBench: TIndyBench;
  LBinding: TIdSocketHandle;
begin
  try
    LOptions := BenchParseOptions;
    LBench := TIndyBench.Create;
    LServer := TIdHTTPServer.Create(nil);
    try
      LServer.OnCommandGet := LBench.CommandGet;
      LServer.KeepAlive := True;
      LServer.ListenQueue := 1024;
      LServer.UseNagle := False;
      LServer.MaxConnections := 0;
      LServer.Bindings.Clear;
      LBinding := LServer.Bindings.Add;
      LBinding.IP := LOptions.SocketHost;
      LBinding.Port := LOptions.Port;
      LServer.Active := True;
      BenchReady('indy-plain', LOptions);
      BenchWait(LOptions);
      LServer.Active := False;
    finally
      LServer.Free;
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
