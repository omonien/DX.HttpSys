/// <summary>
///   HorseDemo - a Horse application served over the kernel HTTP.sys listener.
/// </summary>
/// <remarks>
///   IMPORTANT — not built in this repository. Horse is an external dependency
///   that is intentionally not vendored here. Build it via the optional
///   integration harness (tests-integration/), which downloads Horse, or put
///   Horse on your own library path.
///
///   Binds under /horse/ on the shared port 80, so it runs simultaneously with
///   the Standalone (/standalone), WiRL (/rest) and WebBroker (/webbroker) demos.
///   Horse has no base-path concept, so the path lives in two matching spots the
///   user controls: the provider's BasePath (drives the HTTP.sys prefix) and the
///   routes registered under that same prefix.
///
///   Targets Horse v2.x. The only DX.HttpSys-specific lines are
///   `uses DX.HttpSys.Horse` plus starting the server through
///   `THorseProviderHttpSys<THorse>` instead of Horse's default Indy provider;
///   routing is ordinary Horse.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-20</created>
/// <license>MIT</license>
program HorseDemo;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Horse,
  // Serve Horse over kernel HTTP.sys by starting this provider:
  DX.HttpSys.Horse in '..\..\src\Adapters\DX.HttpSys.Horse.pas';

begin
  THorse.Get('/horse/ping',                         // routes under the shared prefix
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.Send('pong');
    end);

  THorse.Get('/horse/hello',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    var
      LName: string;
    begin
      if not AReq.Query.TryGetValue('name', LName) then
        LName := 'world';
      ARes.Send('Hello, ' + LName + '!');
    end);

  THorseProviderHttpSys<THorse>.Port     := 80;       // shared port
  THorseProviderHttpSys<THorse>.Host     := 'localhost';
  THorseProviderHttpSys<THorse>.BasePath := 'horse';  // → http://localhost:80/horse/
  Writeln('Horse on HTTP.sys: http://localhost:80/horse/ping — Ctrl+C to stop.');
  THorseProviderHttpSys<THorse>.Listen;
end.
