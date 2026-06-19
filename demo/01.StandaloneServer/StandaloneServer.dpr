/// <summary>
///   StandaloneServer - the smallest possible DX.HttpSys server.
/// </summary>
/// <remarks>
///   Starts a kernel-mode HTTP.sys listener on http://localhost:8080/ and answers
///   every request with a short text body. No framework, just the Core.
///
///   localhost binding needs no elevated rights. To listen on all interfaces
///   (http://+:8080/) either run elevated or pre-register a URL ACL:
///     netsh http add urlacl url=http://+:8080/ user=DOMAIN\User
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
program StandaloneServer;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DX.HttpSys.Api.Types in '..\..\src\Core\DX.HttpSys.Api.Types.pas',
  DX.HttpSys.Api in '..\..\src\Core\DX.HttpSys.Api.pas',
  DX.HttpSys.Request in '..\..\src\Core\DX.HttpSys.Request.pas',
  DX.HttpSys.Response in '..\..\src\Core\DX.HttpSys.Response.pas',
  DX.HttpSys.ThreadPool in '..\..\src\Core\DX.HttpSys.ThreadPool.pas',
  DX.HttpSys.Server in '..\..\src\Core\DX.HttpSys.Server.pas';

type
  /// <summary>Answers every request with a small greeting.</summary>
  THelloHandler = class(TInterfacedObject, IDXHttpSysRequestHandler)
  public
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

procedure THelloHandler.HandleRequest(const ARequest: TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
begin
  AResponse.SetBody(Format(
    'Hello from DX.HttpSys!'#10 +
    '%s %s'#10 +
    'from %s'#10,
    [ARequest.Method, ARequest.Path, ARequest.RemoteIP]));
end;

const
  cPort = 8080;

var
  LServer: TDXHttpSysServer;
begin
  try
    LServer := TDXHttpSysServer.Create;
    try
      LServer.Port := cPort;
      LServer.Handler := THelloHandler.Create;
      LServer.UseLocalhost;
      LServer.Start;

      Writeln(Format('DX.HttpSys standalone server listening on http://localhost:%d/',
        [cPort]));
      Writeln('Try:  curl http://localhost:' + IntToStr(cPort) + '/');
      Writeln('Press <Enter> to stop.');
      Readln;

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
