/// <summary>
///   SseDemo - server-sent events over DX.HttpSys chunked streaming.
/// </summary>
/// <remarks>
///   Demonstrates the streaming API (BeginStream/SendChunk/EndStream): every
///   GET /sse connection receives ten events, one per second. Test with:
///     curl -N http://localhost:8123/sse
///   HTTP.sys uses chunked transfer encoding because the response carries no
///   Content-Length and is sent with HTTP_SEND_RESPONSE_FLAG_MORE_DATA.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-08-18</created>
/// <license>MIT</license>
program SseDemo;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DX.HttpSys.Api.Types,
  DX.HttpSys.Api,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  /// <summary>Serves /sse as a text/event-stream.</summary>
  TSseHandler = class(TInterfacedObject, IDXHttpSysRequestHandler)
  public
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

procedure TSseHandler.HandleRequest(const ARequest: TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
var
  LData: TBytes;
begin
  if ARequest.Path <> '/sse' then
  begin
    AResponse.SetBody('Try:  curl -N http://localhost:8123/sse');
    AResponse.Send;
    Exit;
  end;

  AResponse.Headers['content-type']  := 'text/event-stream';
  AResponse.Headers['cache-control'] := 'no-cache';
  AResponse.BeginStream;

  for var i := 1 to 10 do
  begin
    LData := TEncoding.UTF8.GetBytes('data: tick ' + IntToStr(i) + #10#10);
    if not AResponse.SendChunk(LData) then
      Exit; // client disconnected — the stream is over
    Sleep(1000);
  end;

  LData := TEncoding.UTF8.GetBytes('event: done'#10'data: stream finished'#10#10);
  AResponse.SendChunk(LData);
  AResponse.EndStream;
end;

const
  cPrefix = 'http://localhost:8123/';

var
  LServer: TDXHttpSysServer;
begin
  try
    LServer := TDXHttpSysServer.Create;
    try
      LServer.Handler := TSseHandler.Create;
      LServer.AddUrlPrefix(cPrefix);
      LServer.Start;

      Writeln('DX.HttpSys SSE demo listening on ' + cPrefix);
      Writeln('Try:  curl -N ' + cPrefix + 'sse');
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
