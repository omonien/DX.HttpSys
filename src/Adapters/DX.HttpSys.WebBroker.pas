/// <summary>
///   DX.HttpSys.WebBroker — WebBroker transport that runs the standard WebBroker
///   dispatcher (WebModules) on top of the kernel HTTP.sys engine.
/// </summary>
/// <remarks>
///   TDXHttpSysWebRequest / TDXHttpSysWebResponse are concrete TWebRequest /
///   TWebResponse subclasses that delegate to a TDXHttpSysRequest /
///   TDXHttpSysResponse pair. TWebBrokerHttpSysDispatcher implements
///   IDXHttpSysRequestHandler and feeds each request through
///   WebRequestHandler.HandleRequest — exactly the entry point the Indy and
///   ISAPI bridges use.
///
///   Usage:
///   <code>
///     Server := TDXHttpSysServer.Create;
///     Server.Handler := TWebBrokerHttpSysDispatcher.Create;
///     Server.AddUrlPrefix('http://localhost:8080/');
///     Server.Start;
///   </code>
///
///   The application must register a WebModule (the usual Web.WebReq /
///   Web.WebBroker setup) so WebRequestHandler has something to dispatch to.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.WebBroker;

interface

uses
  System.SysUtils,
  System.Classes,
  Web.WebReq,
  Web.HTTPApp,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  // ---------------------------------------------------------------------------
  // TDXHttpSysWebRequest — concrete TWebRequest over a TDXHttpSysRequest
  // ---------------------------------------------------------------------------

  TDXHttpSysWebRequest = class(TWebRequest)
  private
    FDXRequest: TDXHttpSysRequest;  // reference, not owned
  protected
    function GetStringVariable(Index: Integer): string; override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    function GetRawContent: TBytes; override;
  public
    constructor Create(ADXRequest: TDXHttpSysRequest);

    function GetFieldByName(const Name: string): string; override;
    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer;
      const ReasonString, Headers: string): Boolean; override;
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysWebResponse — concrete TWebResponse over a TDXHttpSysResponse
  // ---------------------------------------------------------------------------

  TDXHttpSysWebResponse = class(TWebResponse)
  private
    FDXResponse: TDXHttpSysResponse;  // reference, not owned
    FStatusCode: Integer;
    FReason:     string;
    FContentStr: string;
    FLogMessage: string;
    FSent:       Boolean;
  protected
    function  GetStringVariable(Index: Integer): string; override;
    procedure SetStringVariable(Index: Integer; const Value: string); override;
    function  GetDateVariable(Index: Integer): TDateTime; override;
    procedure SetDateVariable(Index: Integer; const Value: TDateTime); override;
    function  GetIntegerVariable(Index: Integer): Int64; override;
    procedure SetIntegerVariable(Index: Integer; Value: Int64); override;
    function  GetContent: string; override;
    procedure SetContent(const Value: string); override;
    function  GetStatusCode: Integer; override;
    procedure SetStatusCode(Value: Integer); override;
    function  GetLogMessage: string; override;
    procedure SetLogMessage(const Value: string); override;
  public
    constructor Create(AHTTPRequest: TWebRequest; ADXResponse: TDXHttpSysResponse);

    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;
    procedure SendStream(AStream: TStream); override;
    function  Sent: Boolean; override;
  end;

  // ---------------------------------------------------------------------------
  // TWebBrokerHttpSysDispatcher — IDXHttpSysRequestHandler -> WebBroker pipeline
  // ---------------------------------------------------------------------------

  TWebBrokerHttpSysDispatcher = class(TInterfacedObject, IDXHttpSysRequestHandler)
  public
    procedure HandleRequest(const ARequest: TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

implementation

// TWebRequest string-variable indices (Web.HTTPApp): 0 Method, 2 URL, 3 Query,
// 4 PathInfo, 8 Accept, 10 Host, 12 Referer, 13 UserAgent, 15 ContentType,
// 21 RemoteAddr, 23 ScriptName, 27 Cookie, 28 Authorization.
// Integer indices: 16 ContentLength, 24 ServerPort.

// -----------------------------------------------------------------------------
// TDXHttpSysWebRequest
// -----------------------------------------------------------------------------

constructor TDXHttpSysWebRequest.Create(ADXRequest: TDXHttpSysRequest);
begin
  FDXRequest := ADXRequest;
  inherited Create;
end;

function TDXHttpSysWebRequest.GetStringVariable(Index: Integer): string;
begin
  case Index of
    0:  Result := FDXRequest.Method;
    1:  Result := 'HTTP/1.1';
    2:  Result := FDXRequest.Url;
    3:  Result := FDXRequest.QueryString;
    4:  Result := FDXRequest.Path;
    8:  Result := FDXRequest.Headers['accept'];
    10: Result := FDXRequest.Host;
    12: Result := FDXRequest.Headers['referer'];
    13: Result := FDXRequest.Headers['user-agent'];
    14: Result := FDXRequest.Headers['content-encoding'];
    15: Result := FDXRequest.Headers['content-type'];
    17: Result := FDXRequest.Headers['content-version'];
    21: Result := FDXRequest.RemoteIP;
    22: Result := FDXRequest.RemoteIP;
    23: Result := FDXRequest.Path;
    26: Result := FDXRequest.Headers['connection'];
    27: Result := FDXRequest.Headers['cookie'];
    28: Result := FDXRequest.Headers['authorization'];
  else
    Result := '';
  end;
end;

function TDXHttpSysWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  // Date headers (Date / If-Modified-Since / Expires) are not parsed yet.
  Result := -1;
end;

function TDXHttpSysWebRequest.GetIntegerVariable(Index: Integer): Int64;
begin
  case Index of
    16: Result := FDXRequest.ContentLength; // ContentLength
    // 24 = ServerPort is not exposed by TDXHttpSysRequest (HTTP.sys doesn't
    // surface it in the parsed request); WebModules rarely need it. -1 = unknown.
  else
    Result := -1;
  end;
end;

function TDXHttpSysWebRequest.GetRawContent: TBytes;
var
  LBody:  TStream;
  LSaved: Int64;
begin
  LBody := FDXRequest.Body;
  if Assigned(LBody) and (LBody.Size > 0) then
  begin
    // Restore the stream position so a later ReadClient/ReadString still works.
    LSaved := LBody.Position;
    try
      SetLength(Result, LBody.Size);
      LBody.Position := 0;
      LBody.ReadBuffer(Result[0], LBody.Size);
    finally
      LBody.Position := LSaved;
    end;
  end
  else
    Result := nil;
end;

function TDXHttpSysWebRequest.GetFieldByName(const Name: string): string;
begin
  Result := FDXRequest.Headers[Name];
end;

function TDXHttpSysWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  LBody: TStream;
begin
  LBody := FDXRequest.Body;
  if Assigned(LBody) then
    Result := LBody.Read(Buffer, Count)
  else
    Result := 0;
end;

function TDXHttpSysWebRequest.ReadString(Count: Integer): string;
var
  LBytes: TBytes;
  LRead:  Integer;
begin
  SetLength(LBytes, Count);
  if Length(LBytes) = 0 then
    Exit('');
  LRead := ReadClient(LBytes[0], Count);
  SetLength(LBytes, LRead);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function TDXHttpSysWebRequest.TranslateURI(const URI: string): string;
begin
  Result := URI; // no virtual-directory translation for a standalone server
end;

function TDXHttpSysWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  Result := 0; // the request never writes to the client
end;

function TDXHttpSysWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := False;
end;

function TDXHttpSysWebRequest.WriteHeaders(StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := False; // headers are written by the response side
end;

// -----------------------------------------------------------------------------
// TDXHttpSysWebResponse
// -----------------------------------------------------------------------------

constructor TDXHttpSysWebResponse.Create(AHTTPRequest: TWebRequest;
  ADXResponse: TDXHttpSysResponse);
begin
  inherited Create(AHTTPRequest);
  FDXResponse := ADXResponse;
  FStatusCode := 200;
  FSent := False;
end;

// String-variable indices for TWebResponse: 1 ReasonString, 2 Server,
// 7 ContentEncoding, 8 ContentType, 6 Location.
function TDXHttpSysWebResponse.GetStringVariable(Index: Integer): string;
begin
  case Index of
    1: Result := FReason;
    2: Result := FDXResponse.Headers['server'];
    6: Result := FDXResponse.Headers['location'];
    7: Result := FDXResponse.Headers['content-encoding'];
    8: Result := FDXResponse.Headers['content-type'];
  else
    Result := '';
  end;
end;

procedure TDXHttpSysWebResponse.SetStringVariable(Index: Integer;
  const Value: string);
begin
  case Index of
    1: FReason := Value;
    2: FDXResponse.Headers['server'] := Value;
    6: FDXResponse.Headers['location'] := Value;
    7: FDXResponse.Headers['content-encoding'] := Value;
    8: FDXResponse.Headers['content-type'] := Value;
  end;
end;

function TDXHttpSysWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := -1;
end;

procedure TDXHttpSysWebResponse.SetDateVariable(Index: Integer;
  const Value: TDateTime);
begin
  // Date response headers are left to HTTP.sys (it sets Date automatically).
end;

function TDXHttpSysWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  case Index of
    0: Result := StrToInt64Def(FDXResponse.Headers['content-length'], -1);
  else
    Result := -1;
  end;
end;

procedure TDXHttpSysWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
  case Index of
    0: if Value >= 0 then
         FDXResponse.Headers['content-length'] := IntToStr(Value);
  end;
end;

function TDXHttpSysWebResponse.GetContent: string;
begin
  Result := FContentStr;
end;

procedure TDXHttpSysWebResponse.SetContent(const Value: string);
begin
  FContentStr := Value;
end;

function TDXHttpSysWebResponse.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

procedure TDXHttpSysWebResponse.SetStatusCode(Value: Integer);
begin
  FStatusCode := Value;
end;

function TDXHttpSysWebResponse.GetLogMessage: string;
begin
  Result := FLogMessage;
end;

procedure TDXHttpSysWebResponse.SetLogMessage(const Value: string);
begin
  FLogMessage := Value;
end;

procedure TDXHttpSysWebResponse.SendResponse;
var
  LContentType: string;
begin
  if FSent then
    Exit;
  FSent := True;

  FDXResponse.StatusCode := FStatusCode;
  if FReason <> '' then
    FDXResponse.ReasonPhrase := FReason;

  // Carry the dispatcher-set content type through, defaulting sensibly.
  LContentType := ContentType;
  if LContentType = '' then
    LContentType := 'text/html; charset=utf-8';

  if ContentStream <> nil then
  begin
    FDXResponse.Body.Clear; // don't append to anything already written
    ContentStream.Position := 0;
    FDXResponse.Body.CopyFrom(ContentStream, 0);
    FDXResponse.Headers['content-type'] := LContentType;
  end
  else
    FDXResponse.SetBody(FContentStr, LContentType);

  FDXResponse.Send;
end;

procedure TDXHttpSysWebResponse.SendRedirect(const URI: string);
begin
  if FSent then
    Exit;
  FStatusCode := 302;
  FReason := 'Moved Temporarily';
  FDXResponse.Headers['location'] := URI;
  FContentStr := '';
  SendResponse;
end;

procedure TDXHttpSysWebResponse.SendStream(AStream: TStream);
begin
  SetContentStream(AStream);
  SendResponse;
end;

function TDXHttpSysWebResponse.Sent: Boolean;
begin
  Result := FSent or FDXResponse.Sent;
end;

// -----------------------------------------------------------------------------
// TWebBrokerHttpSysDispatcher
// -----------------------------------------------------------------------------

type
  // TWebRequestHandler.HandleRequest is protected; expose it through a
  // descendant, the same technique the Indy/ISAPI WebBroker bridges use.
  TDXWebRequestHandlerAccess = class(TWebRequestHandler)
  public
    function DispatchToModules(ARequest: TWebRequest;
      AResponse: TWebResponse): Boolean;
  end;

function TDXWebRequestHandlerAccess.DispatchToModules(
  ARequest: TWebRequest; AResponse: TWebResponse): Boolean;
begin
  Result := HandleRequest(ARequest, AResponse);
end;

procedure TWebBrokerHttpSysDispatcher.HandleRequest(
  const ARequest: TDXHttpSysRequest; const AResponse: TDXHttpSysResponse);
var
  LWebReq:  TDXHttpSysWebRequest;
  LWebResp: TDXHttpSysWebResponse;
begin
  // No WebModule registered (the app forgot to set WebRequestHandlerProc) —
  // return a clear 500 instead of dereferencing a nil handler in the worker.
  if WebRequestHandler = nil then
  begin
    if not AResponse.Sent then
      AResponse.SendError(500, 'No WebBroker request handler registered');
    Exit;
  end;

  LWebReq  := nil;
  LWebResp := nil;
  try
    LWebReq  := TDXHttpSysWebRequest.Create(ARequest);
    LWebResp := TDXHttpSysWebResponse.Create(LWebReq, AResponse);

    // The standard WebBroker entry point — dispatches to the registered
    // WebModule. Returns False when nothing handled the request.
    if not TDXWebRequestHandlerAccess(WebRequestHandler).DispatchToModules(LWebReq, LWebResp) then
    begin
      if not AResponse.Sent then
        AResponse.SendError(404, 'Not Found');
    end
    else if not LWebResp.Sent then
      LWebResp.SendResponse;
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

end.
