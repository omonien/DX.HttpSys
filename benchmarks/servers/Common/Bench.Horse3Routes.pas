/// <summary>
///   Bench.Horse3Routes - registers the M0 benchmark endpoints with Horse 3.3.16.
/// </summary>
/// <remarks>
///   Text endpoints use the idiomatic Res.Send(string) path that Horse users write.
///   Binary bodies use Horse 3 Send(TBytes).
///   The endpoint semantics come from Bench.Endpoints.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-11-23</created>
/// <license>MIT</license>
unit Bench.Horse3Routes;

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
  ARes.ContentType(cBenchContentTypeBinary).Send(ABytes);
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
