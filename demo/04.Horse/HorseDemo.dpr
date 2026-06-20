/// <summary>
///   HorseDemo - a Horse application served over the kernel HTTP.sys listener.
/// </summary>
/// <remarks>
///   IMPORTANT — not built in this repository. Horse is an external dependency
///   that is intentionally not vendored here. Build it via the optional
///   integration harness (tests-integration/), which downloads Horse, or put
///   Horse on your own library path.
///
///   Targets Horse v2.x. The only DX.HttpSys-specific lines are
///   `uses DX.HttpSys.Horse` plus starting the server through
///   `THorseProviderHttpSys<THorse>.Listen` instead of Horse's default Indy
///   provider; routing is ordinary Horse.
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
  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.Send('pong');
    end);

  THorse.Get('/hello',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    var
      LName: string;
    begin
      if not AReq.Query.TryGetValue('name', LName) then
        LName := 'world';
      ARes.Send('Hello, ' + LName + '!');
    end);

  Writeln('Horse on HTTP.sys, listening on http://localhost:9000/ — Ctrl+C to stop.');
  THorseProviderHttpSys<THorse>.Listen(9000, 'localhost');
end.
