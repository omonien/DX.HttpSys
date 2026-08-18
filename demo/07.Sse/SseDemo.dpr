/// <summary>
///   SseDemo - server-sent events over DX.HttpSys chunked streaming.
/// </summary>
/// <remarks>
///   Demonstrates the streaming API (BeginStream/SendChunk/EndStream): every
///   GET /sse/ connection receives ten events, one per second. Test with:
///     curl -N http://localhost:80/sse/
///   HTTP.sys uses chunked transfer encoding because the response carries no
///   Content-Length and is sent with HTTP_SEND_RESPONSE_FLAG_MORE_DATA.
///
///   It binds under a distinct path prefix on the shared port 80, so it can run
///   simultaneously with the Standalone (/standalone), WiRL (/rest), WebBroker
///   (/webbroker) and Horse (/horse) demos - HTTP.sys routes by longest-prefix
///   match across processes.
///
///   Note that a streaming handler occupies one pooled worker thread for the
///   whole stream duration; the handler polls AResponse.Cancelled between
///   events so server shutdown ends the stream promptly.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-08-18</created>
/// <license>MIT</license>
program SseDemo;

{$APPTYPE CONSOLE}

{$R *.res}

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
  if ARequest.Path <> '/sse/' then
  begin
    AResponse.SetBody('Try:  curl -N http://localhost:80/sse/');
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
      Exit; // client disconnected or server stopping — the stream is over

    // Wait one second between events, but stay responsive to server shutdown:
    // poll Cancelled instead of a single blind Sleep(1000).
    for var j := 1 to 10 do
    begin
      Sleep(100);
      if AResponse.Cancelled then
        Exit; // the worker completes the stream
    end;
  end;

  LData := TEncoding.UTF8.GetBytes('event: done'#10'data: stream finished'#10#10);
  AResponse.SendChunk(LData); // if this reports the stream as over, ...
  AResponse.EndStream;        // ... EndStream is a safe no-op
end;

const
  cPrefix = 'http://localhost:80/sse/';

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
      Writeln('Try:  curl -N ' + cPrefix);
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
