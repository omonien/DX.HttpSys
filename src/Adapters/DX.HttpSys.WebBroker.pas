/// <summary>
///   DX.HttpSys.WebBroker — WebBroker adapter exposing DX.HttpSys requests through the standard WebBroker dispatcher.
/// </summary>
/// <remarks>
///   Implements IDXHttpSysRequestHandler and forwards requests via the standard WebBroker dispatcher
///   (WebReq.DispatchAction). It creates TDXHttpSysWebRequest / TDXHttpSysWebResponse as subclasses of the
///   abstract WebBroker base classes TWebRequest / TWebResponse.
///
///   Usage:
///   <code>
///     var
///       Server:     TDXHttpSysServer;
///       Dispatcher: TWebBrokerHttpSysDispatcher;
///
///     Dispatcher := TWebBrokerHttpSysDispatcher.Create;
///     Server     := TDXHttpSysServer.Create;
///     Server.Handler := Dispatcher;
///     Server.AddUrlPrefix('http://localhost:8080/');
///     Server.Start;
///   </code>
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.WebBroker;

interface

uses
  System.SysUtils,
  System.Classes,
  // WebBroker
  Web.WebReq,
  Web.HTTPApp,
  // DX.HttpSys Core
  DX.HttpSys.Api.Types,
  DX.HttpSys.Request,
  DX.HttpSys.Response,
  DX.HttpSys.ThreadPool,
  DX.HttpSys.Server;

type
  // ---------------------------------------------------------------------------
  // TDXHttpSysWebRequest
  // Subclass of TWebRequest – delegates to TDXHttpSysRequest
  // ---------------------------------------------------------------------------

  TDXHttpSysWebRequest = class(TWebRequest)
  private
    FDXRequest: TDXHttpSysRequest;  // Reference, not owned
  protected
    // Implement the abstract getters from TWebRequest
    function GetStringVariable(Index: Integer): string; override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    function GetIntegerVariable(Index: Integer): Integer; override;
    function GetRawContent: TBytes; override;
  public
    constructor Create(ADXRequest: TDXHttpSysRequest);

    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer;
      const ReasonString, Headers: string): Boolean; override;
  end;

  // ---------------------------------------------------------------------------
  // TDXHttpSysWebResponse
  // Subclass of TWebResponse – delegates to TDXHttpSysResponse
  // ---------------------------------------------------------------------------

  TDXHttpSysWebResponse = class(TWebResponse)
  private
    FDXResponse: TDXHttpSysResponse;  // Reference, not owned
  protected
    function GetContent: string; override;
    procedure SetContent(const AValue: string); override;
    function GetStatusCode: Integer; override;
    procedure SetStatusCode(AValue: Integer); override;
    function GetLogMessage: string; override;
    procedure SetLogMessage(const AValue: string); override;
    function GetReasonString: string; override;
    procedure SetReasonString(const AValue: string); override;
    procedure SetContentType(const AValue: string); override;
  public
    constructor Create(
      ARequest:    TWebRequest;
      ADXResponse: TDXHttpSysResponse);

    procedure SendResponse; override;
    procedure SendStream(AStream: TStream); override;
    function  Sent: Boolean; override;
  end;

  // ---------------------------------------------------------------------------
  // TWebBrokerHttpSysDispatcher
  // Implements IDXHttpSysRequestHandler – connects DX.HttpSys with WebBroker
  // ---------------------------------------------------------------------------

  TWebBrokerHttpSysDispatcher = class(TInterfacedObject, IDXHttpSysRequestHandler)
  public
    { IDXHttpSysRequestHandler }
    procedure HandleRequest(
      const ARequest:  TDXHttpSysRequest;
      const AResponse: TDXHttpSysResponse);
  end;

implementation

// -----------------------------------------------------------------------------
// TDXHttpSysWebRequest
// -----------------------------------------------------------------------------

constructor TDXHttpSysWebRequest.Create(ADXRequest: TDXHttpSysRequest);
begin
  inherited Create;
  FDXRequest := ADXRequest;
end;

function TDXHttpSysWebRequest.GetStringVariable(Index: Integer): string;
begin
  // Index mapping per TWebRequest convention (see Web.HTTPApp.pas)
  // Full implementation in Milestone 5
  case Index of
    0:  Result := FDXRequest.Method;
    1:  Result := FDXRequest.Url;
    2:  Result := FDXRequest.Path;
    3:  Result := FDXRequest.QueryString;
    4:  Result := FDXRequest.RemoteIP;
    5:  Result := FDXRequest.Headers['content-type'];
    6:  Result := FDXRequest.Headers['content-length'];
    7:  Result := FDXRequest.Headers['accept'];
    8:  Result := FDXRequest.Headers['authorization'];
    9:  Result := FDXRequest.Headers['host'];
    10: Result := FDXRequest.Headers['user-agent'];
  else
    Result := '';
  end;
end;

function TDXHttpSysWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  // TODO: header date parsing (If-Modified-Since etc.)
  Result := 0;
end;

function TDXHttpSysWebRequest.GetIntegerVariable(Index: Integer): Integer;
begin
  case Index of
    0: Result := FDXRequest.ContentLength;
  else
    Result := 0;
  end;
end;

function TDXHttpSysWebRequest.GetRawContent: TBytes;
var
  BodyStream: TStream;
begin
  BodyStream := FDXRequest.Body;
  if Assigned(BodyStream) and (BodyStream.Size > 0) then
  begin
    SetLength(Result, BodyStream.Size);
    BodyStream.Position := 0;
    BodyStream.Read(Result[0], BodyStream.Size);
  end
  else
    Result := [];
end;

function TDXHttpSysWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  BodyStream: TStream;
begin
  BodyStream := FDXRequest.Body;
  if Assigned(BodyStream) then
    Result := BodyStream.Read(Buffer, Count)
  else
    Result := 0;
end;

function TDXHttpSysWebRequest.ReadString(Count: Integer): string;
var
  Bytes: TBytes;
  Len:   Integer;
begin
  SetLength(Bytes, Count);
  Len := ReadClient(Bytes[0], Count);
  SetLength(Bytes, Len);
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function TDXHttpSysWebRequest.TranslateURI(const URI: string): string;
begin
  Result := URI; // No translation required
end;

function TDXHttpSysWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  Result := 0; // Do not write via the request
end;

function TDXHttpSysWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := False;
end;

function TDXHttpSysWebRequest.WriteHeaders(
  StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := False;
end;

// -----------------------------------------------------------------------------
// TDXHttpSysWebResponse
// -----------------------------------------------------------------------------

constructor TDXHttpSysWebResponse.Create(
  ARequest:    TWebRequest;
  ADXResponse: TDXHttpSysResponse);
begin
  inherited Create(ARequest);
  FDXResponse := ADXResponse;
end;

function TDXHttpSysWebResponse.GetContent: string;
begin
  FDXResponse.Body.Position := 0;
  Result := TEncoding.UTF8.GetString(
    TBytesStream(FDXResponse.Body).Bytes, 0, FDXResponse.Body.Size);
end;

procedure TDXHttpSysWebResponse.SetContent(const AValue: string);
begin
  FDXResponse.SetBody(AValue);
end;

function TDXHttpSysWebResponse.GetStatusCode: Integer;
begin
  Result := FDXResponse.StatusCode;
end;

procedure TDXHttpSysWebResponse.SetStatusCode(AValue: Integer);
begin
  FDXResponse.StatusCode := AValue;
end;

function TDXHttpSysWebResponse.GetLogMessage: string;
begin
  Result := '';
end;

procedure TDXHttpSysWebResponse.SetLogMessage(const AValue: string);
begin
  // Logging hook – TODO
end;

function TDXHttpSysWebResponse.GetReasonString: string;
begin
  Result := FDXResponse.ReasonPhrase;
end;

procedure TDXHttpSysWebResponse.SetReasonString(const AValue: string);
begin
  FDXResponse.ReasonPhrase := AValue;
end;

procedure TDXHttpSysWebResponse.SetContentType(const AValue: string);
begin
  FDXResponse.Headers['content-type'] := AValue;
end;

procedure TDXHttpSysWebResponse.SendResponse;
begin
  if not FDXResponse.Sent then
    FDXResponse.Send;
end;

procedure TDXHttpSysWebResponse.SendStream(AStream: TStream);
begin
  FDXResponse.Body.CopyFrom(AStream, 0);
  SendResponse;
end;

function TDXHttpSysWebResponse.Sent: Boolean;
begin
  Result := FDXResponse.Sent;
end;

// -----------------------------------------------------------------------------
// TWebBrokerHttpSysDispatcher
// -----------------------------------------------------------------------------

procedure TWebBrokerHttpSysDispatcher.HandleRequest(
  const ARequest:  TDXHttpSysRequest;
  const AResponse: TDXHttpSysResponse);
var
  WebReq:  TDXHttpSysWebRequest;
  WebResp: TDXHttpSysWebResponse;
begin
  WebReq  := nil;
  WebResp := nil;
  try
    WebReq  := TDXHttpSysWebRequest.Create(ARequest);
    WebResp := TDXHttpSysWebResponse.Create(WebReq, AResponse);

    // Standard WebBroker dispatch
    if not WebReq.DispatchRequest(WebResp) then
      AResponse.SendError(404, 'Not Found');
  finally
    WebReq.Free;
    WebResp.Free;
  end;
end;

end.
