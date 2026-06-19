/// <summary>
///   WiRLDemo - a WiRL REST resource served over the kernel HTTP.sys listener.
/// </summary>
/// <remarks>
///   IMPORTANT — not built in this repository. WiRL is an external dependency that
///   is intentionally not vendored here. To build and run this demo, put WiRL on
///   the library path and add this project to a local project group. See
///   docs/DECISIONS.md (A-10).
///
///   The only DX.HttpSys-specific line is `uses DX.HttpSys.WiRL` plus selecting
///   the 'HttpSys' engine — everything else is ordinary WiRL.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
program WiRLDemo;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  WiRL.Core.Engine,
  WiRL.Core.Application,
  WiRL.http.Server,
  WiRL.Core.Registry,
  WiRL.Core.Attributes,
  WiRL.http.Accept.MediaType,
  // Switch the WiRL engine from Indy to kernel HTTP.sys with this one unit:
  DX.HttpSys.WiRL in '..\..\src\Adapters\DX.HttpSys.WiRL.pas';

type
  // A trivial REST resource.
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
    THelloResource.ClassName; // keep the resource unit referenced

    LServer := TWiRLServer.Create(nil);
    try
      LServer.ServerPort := 8080;
      // Select the HTTP.sys engine registered by DX.HttpSys.WiRL.
      LServer.ServerEngine := 'HttpSys';

      LServer
        .AddEngine<TWiRLEngine>('/rest')
        .SetEngineName('DX.HttpSys WiRL Demo')
        .AddApplication('/app')
          .SetResources('THelloResource');

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
