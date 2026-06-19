/// <summary>
///   WebBrokerDemo - a WebBroker WebModule served over kernel HTTP.sys.
/// </summary>
/// <remarks>
///   Shows how an existing WebBroker application moves to HTTP.sys: define a
///   WebModule with actions as usual, then host it with
///   TWebBrokerHttpSysDispatcher instead of the Indy/ISAPI bridge.
///
///   Routes:
///     GET /            -> greeting
///     GET /time        -> current server time
///
///   localhost needs no elevated rights. For http://+:PORT/ use netsh or run
///   elevated (see README).
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
program WebBrokerDemo;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  Web.WebReq,
  Web.WebBroker,
  DX.HttpSys.Request in '..\..\src\Core\DX.HttpSys.Request.pas',
  DX.HttpSys.Response in '..\..\src\Core\DX.HttpSys.Response.pas',
  DX.HttpSys.Api.Types in '..\..\src\Core\DX.HttpSys.Api.Types.pas',
  DX.HttpSys.Api in '..\..\src\Core\DX.HttpSys.Api.pas',
  DX.HttpSys.ThreadPool in '..\..\src\Core\DX.HttpSys.ThreadPool.pas',
  DX.HttpSys.Server in '..\..\src\Core\DX.HttpSys.Server.pas',
  DX.HttpSys.WebBroker in '..\..\src\Adapters\DX.HttpSys.WebBroker.pas';

type
  TDemoWebModule = class(TWebModule)
  private
    procedure RootAction(Sender: TObject; Request: TWebRequest;
      Response: TWebResponse; var Handled: Boolean);
    procedure TimeAction(Sender: TObject; Request: TWebRequest;
      Response: TWebResponse; var Handled: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
  end;

constructor TDemoWebModule.Create(AOwner: TComponent);
var
  LRoot, LTime: TWebActionItem;
begin
  inherited Create(AOwner);

  LRoot := Actions.Add;
  LRoot.Name := 'Root';
  LRoot.PathInfo := '/';
  LRoot.Default := True;
  LRoot.OnAction := RootAction;

  LTime := Actions.Add;
  LTime.Name := 'Time';
  LTime.PathInfo := '/time';
  LTime.OnAction := TimeAction;
end;

procedure TDemoWebModule.RootAction(Sender: TObject; Request: TWebRequest;
  Response: TWebResponse; var Handled: Boolean);
begin
  Response.ContentType := 'text/plain; charset=utf-8';
  Response.Content :=
    'WebBroker over DX.HttpSys'#10 +
    'Try GET /time'#10;
  Handled := True;
end;

procedure TDemoWebModule.TimeAction(Sender: TObject; Request: TWebRequest;
  Response: TWebResponse; var Handled: Boolean);
begin
  Response.ContentType := 'text/plain; charset=utf-8';
  Response.Content := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  Handled := True;
end;

var
  GHandler: TWebRequestHandler = nil;

function DemoHandler: TWebRequestHandler;
begin
  Result := GHandler;
end;

const
  cPort = 8080;

var
  LServer: TDXHttpSysServer;
begin
  try
    GHandler := TWebRequestHandler.Create(nil);
    GHandler.WebModuleClass := TDemoWebModule;
    Web.WebReq.WebRequestHandlerProc := DemoHandler;

    LServer := TDXHttpSysServer.Create;
    try
      LServer.Port := cPort;
      LServer.Handler := TWebBrokerHttpSysDispatcher.Create;
      LServer.UseLocalhost;
      LServer.Start;

      Writeln(Format('WebBroker demo on http://localhost:%d/', [cPort]));
      Writeln('Try:  curl http://localhost:' + IntToStr(cPort) + '/time');
      Writeln('Press <Enter> to stop.');
      Readln;

      LServer.Stop;
    finally
      LServer.Free;
    end;

    Web.WebReq.WebRequestHandlerProc := nil;
    FreeAndNil(GHandler);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
