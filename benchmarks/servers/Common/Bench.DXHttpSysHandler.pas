/// <summary>
///   Bench.DXHttpSysHandler - request handler that serves the M0 endpoints
///   directly on the DX.HttpSys core (no framework).
/// </summary>
/// <remarks>
///   Shared by the BenchDXHttpSysPlain server and the DUnitX smoke tests.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Bench.DXHttpSysHandler;

interface

uses
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool;

type
  TBenchDXHttpSysHandler = class(TInterfacedObject, IDXHttpSysRequestHandler)
  public
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Bench.Endpoints;

procedure TBenchDXHttpSysHandler.HandleRequest(const ARequest: TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
var
  LRoute: TBenchRoute;
  LBodyLength: Int64;
  LBody: TStream;
  LResponse: TBenchResponse;
begin
  LRoute := BenchRoute(ARequest.Method, ARequest.Path);
  LBodyLength := 0;
  if LRoute = brEcho then
  begin
    // Body loads the complete entity from http.sys on first access.
    LBody := ARequest.Body;
    if LBody <> nil then
      LBodyLength := LBody.Size;
  end;
  LResponse := BenchDispatch(LRoute, LBodyLength);
  AResponse.StatusCode := LResponse.Status;
  AResponse.Headers['content-type'] := LResponse.ContentType;
  if Length(LResponse.Body) > 0 then
    AResponse.Body.WriteBuffer(LResponse.Body[0], Length(LResponse.Body));
end;

end.
