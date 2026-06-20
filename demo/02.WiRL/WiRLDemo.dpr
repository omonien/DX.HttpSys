/// <summary>
///   WiRLDemo - a WiRL REST resource served over the kernel HTTP.sys listener.
/// </summary>
/// <remarks>
///   IMPORTANT — not built in this repository. WiRL is an external dependency
///   that is intentionally not vendored here. Build it via the optional
///   integration harness (tests-integration/), which downloads WiRL, or put WiRL
///   on your own library path.
///
///   Targets the WiRL 4.x release API. The only DX.HttpSys-specific lines are
///   `uses DX.HttpSys.WiRL` plus `ServerVendor := 'HttpSys'`; everything else is
///   ordinary WiRL.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-20</created>
/// <license>MIT</license>
program WiRLDemo;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  WiRL.Core.Engine,
  WiRL.Core.Application,
  WiRL.http.Server,
  WiRL.Core.Registry,
  WiRL.Core.Attributes,
  WiRL.http.Accept.MediaType,
  WiRL.Core.MessageBody.Default,   // default message-body writers
  // Switch the WiRL engine from Indy to kernel HTTP.sys with this one unit:
  DX.HttpSys.WiRL in '..\..\src\Adapters\DX.HttpSys.WiRL.pas';

type
  [Path('hello')]
  THelloResource = class
  public
    [GET, Produces(TMediaType.TEXT_PLAIN)]
    function World: string;
  end;

function THelloResource.World: string;
begin
  Result := 'Hello from WiRL over DX.HttpSys!';
end;

var
  LServer: TWiRLServer;
begin
  try
    TWiRLResourceRegistry.Instance.RegisterResource<THelloResource>;

    LServer := TWiRLServer.Create(nil);
    try
      LServer.Port := 8080;
      // Select the HTTP.sys engine registered by DX.HttpSys.WiRL.
      LServer.ServerVendor := 'HttpSys';

      LServer
        .AddEngine<TWiRLEngine>('/rest')
          .SetEngineName('DX.HttpSys WiRL Demo')
          .AddApplication('/app')
            .SetResources('*');

      LServer.Active := True;

      Writeln('WiRL over DX.HttpSys on http://localhost:8080/rest/app/hello');
      Writeln('Press <Enter> to stop.');
      Readln;

      LServer.Active := False;
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
