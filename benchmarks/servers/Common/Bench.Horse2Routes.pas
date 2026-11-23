/// <summary>
///   Bench.Horse2Routes - registers the M0 benchmark endpoints with Horse 2.0.14 (HashLoad original, generic provider classes).
/// </summary>
/// <remarks>
///   Text endpoints use the idiomatic Res.Send(string) path that Horse users write.
///   Horse 2 has no Send(TBytes); binary bodies go through RawWebResponse.ContentStream,
///   which both the Indy bridge and the DX.HttpSys WebBroker adapter send.
///   The endpoint semantics come from Bench.Endpoints.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Bench.Horse2Routes;

interface

/// <summary>Registers GET /plaintext, /json, /bytes/64k, /bytes/1m and POST /echo.</summary>
procedure RegisterBenchRoutes;

implementation

uses
  System.SysUtils,
  System.Classes,
  Horse,
  Bench.Endpoints;

procedure SendBinary(ARes: THorseResponse; const ABytes: TBytes);
begin
  ARes.Status(200);
  ARes.RawWebResponse.ContentType := cBenchContentTypeBinary;
  // TBytesStream references the static array; the web response frees the stream.
  ARes.RawWebResponse.ContentStream := TBytesStream.Create(ABytes);
end;

procedure RegisterBenchRoutes;
begin
  THorse.Get('/plaintext',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.ContentType(cBenchContentTypeText).Send(cBenchPlaintext);
    end);

  THorse.Get('/json',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.ContentType(cBenchContentTypeJson).Send(BenchJsonText);
    end);

  THorse.Get('/bytes/64k',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      SendBinary(ARes, BenchBytes64k);
    end);

  THorse.Get('/bytes/1m',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      SendBinary(ARes, BenchBytes1m);
    end);

  THorse.Post('/echo',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    var
      LBody: TBytes;
    begin
      // Read the complete entity as raw bytes (no string decoding).
      LBody := AReq.RawWebRequest.RawContent;
      ARes.ContentType(cBenchContentTypeText).Send(IntToStr(Length(LBody)));
    end);
end;

end.
