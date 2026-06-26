/// <summary>
///   DX.HttpSys.Api.Types — Pascal type definitions for the Windows HTTP Server API v2.0.
/// </summary>
/// <remarks>
///   Contains all HTTP_* records, enums and constants required for httpapi.dll v2.0.
///   No logic, no dependencies other than Windows.
///
///   Sources:
///     - Windows SDK: http_def.h, http.h
///     - MSDN: HTTP Server API Version 2.0
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>2026-06-19</created>
/// <license>MIT</license>
unit DX.HttpSys.Api.Types;

interface

// The Windows HTTP Server API uses C int-sized (4-byte) enums. Delphi's default
// is 1-byte; passing a 1-byte enum BY VALUE to httpapi.dll leaves the upper bytes
// of the argument register uninitialised on Win64, so the API reads a garbage
// property value and fails with ERROR_INVALID_PARAMETER (e.g.
// HttpSetRequestQueueProperty with HttpServerQueueLengthProperty). Forcing 4-byte
// enums unit-wide matches the C ABI and fixes Win64. See docs/DECISIONS.md (A-18).
{$MINENUMSIZE 4}

uses
  Winapi.Windows,
  Winapi.WinSock2;

// -----------------------------------------------------------------------------
// HTTP API Version
// -----------------------------------------------------------------------------

type
  // SDK string-pointer aliases not present in Winapi.Windows.
  PCWSTR = PWideChar;  // LPCWSTR — wide, const, null-terminated
  PCSTR  = PAnsiChar;  // LPCSTR  — narrow, const, null-terminated

  THTTP_VERSION = record
    MajorVersion: USHORT;
    MinorVersion: USHORT;
  end;
  PHTTP_VERSION = ^THTTP_VERSION;

const
  HTTPAPI_VERSION_1: THTTP_VERSION = (MajorVersion: 1; MinorVersion: 0);
  HTTPAPI_VERSION_2: THTTP_VERSION = (MajorVersion: 2; MinorVersion: 0);

  HTTP_INITIALIZE_SERVER = $00000001;
  HTTP_INITIALIZE_CONFIG = $00000002;

  HTTP_CREATE_REQUEST_QUEUE_FLAG_OPEN_EXISTING = $00000001;
  HTTP_CREATE_REQUEST_QUEUE_FLAG_CONTROLLER    = $00000002;

  HTTP_RECEIVE_REQUEST_FLAG_COPY_BODY  = $00000001;
  HTTP_RECEIVE_REQUEST_FLAG_FLUSH_BODY = $00000002;

  // HTTP_REQUEST.Flags bits
  HTTP_REQUEST_FLAG_MORE_ENTITY_BODY_EXISTS = $00000001;

  HTTP_SEND_RESPONSE_FLAG_DISCONNECT   = $00000001;
  HTTP_SEND_RESPONSE_FLAG_MORE_DATA    = $00000002;
  HTTP_SEND_RESPONSE_FLAG_RAW_HEADER   = $00000004;

// -----------------------------------------------------------------------------
// Handle types
// -----------------------------------------------------------------------------

type
  HTTP_SERVER_SESSION_ID = UInt64;
  PHTTP_SERVER_SESSION_ID = ^HTTP_SERVER_SESSION_ID;

  HTTP_URL_GROUP_ID = UInt64;
  PHTTP_URL_GROUP_ID = ^HTTP_URL_GROUP_ID;

  HTTP_REQUEST_ID = UInt64;
  PHTTP_REQUEST_ID = ^HTTP_REQUEST_ID;

  HTTP_URL_CONTEXT = UInt64;

  HTTP_OPAQUE_ID = UInt64;

const
  // Sentinel "no specific request" id for HttpReceiveHttpRequest (HTTP_NULL_ID).
  HTTP_NULL_ID: HTTP_REQUEST_ID = 0;

  // HTTP_PROPERTY_FLAGS.Present bit — marks an SDK property struct as "set".
  HTTP_PROPERTY_FLAG_PRESENT = $00000001;

// -----------------------------------------------------------------------------
// HTTP_SERVER_PROPERTY – property enums for SetUrlGroupProperty etc.
// -----------------------------------------------------------------------------

type
  // HTTP_SERVER_PROPERTY — order and values per the Windows SDK (http.h).
  // These ordinals are passed verbatim to HttpSetUrlGroupProperty etc., so the
  // enumeration MUST mirror the SDK exactly; do not reorder.
  HTTP_SERVER_PROPERTY = (
    HttpServerAuthenticationProperty         = 0,
    HttpServerLoggingProperty                = 1,
    HttpServerQosProperty                    = 2,
    HttpServerTimeoutsProperty               = 3,
    HttpServerQueueLengthProperty            = 4,
    HttpServerStateProperty                  = 5,
    HttpServer503VerbosityProperty           = 6,
    HttpServerBindingProperty                = 7,
    HttpServerExtendedAuthenticationProperty = 8,
    HttpServerListenEndpointProperty         = 9,
    HttpServerChannelBindProperty            = 10,
    HttpServerProtectionLevelProperty        = 11,
    HttpServerDelegationProperty             = 12
  );

// Used with HttpServerBindingProperty to bind a URL group to a request queue.
type
  HTTP_BINDING_INFO = record
    Flags:                  ULONG;
    RequestQueueHandle:     THandle;
  end;
  PHTTP_BINDING_INFO = ^HTTP_BINDING_INFO;

// -----------------------------------------------------------------------------
// HTTP_VERB – known HTTP verbs as an enum
// -----------------------------------------------------------------------------

type
  HTTP_VERB = (
    HttpVerbUnparsed     = 0,
    HttpVerbUnknown      = 1,
    HttpVerbInvalid      = 2,
    HttpVerbOPTIONS      = 3,
    HttpVerbGET          = 4,
    HttpVerbHEAD         = 5,
    HttpVerbPOST         = 6,
    HttpVerbPUT          = 7,
    HttpVerbDELETE       = 8,
    HttpVerbTRACE        = 9,
    HttpVerbCONNECT      = 10,
    HttpVerbTRACK        = 11,
    HttpVerbMOVE         = 12,
    HttpVerbCOPY         = 13,
    HttpVerbPROPFIND     = 14,
    HttpVerbPROPPATCH    = 15,
    HttpVerbMKCOL        = 16,
    HttpVerbLOCK         = 17,
    HttpVerbUNLOCK       = 18,
    HttpVerbSEARCH       = 19,
    HttpVerbMaximum      = 20
  );

const
  HTTP_VERB_STRINGS: array[HTTP_VERB] of string = (
    '', '', '', 'OPTIONS', 'GET', 'HEAD', 'POST', 'PUT', 'DELETE',
    'TRACE', 'CONNECT', 'TRACK', 'MOVE', 'COPY', 'PROPFIND', 'PROPPATCH',
    'MKCOL', 'LOCK', 'UNLOCK', 'SEARCH', ''
  );

// -----------------------------------------------------------------------------
// HTTP_HEADER_ID – known request/response headers as an enum
// -----------------------------------------------------------------------------

type
  HTTP_HEADER_ID = (
    HttpHeaderCacheControl          = 0,
    HttpHeaderConnection            = 1,
    HttpHeaderDate                  = 2,
    HttpHeaderKeepAlive             = 3,
    HttpHeaderPragma                = 4,
    HttpHeaderTrailer               = 5,
    HttpHeaderTransferEncoding      = 6,
    HttpHeaderUpgrade               = 7,
    HttpHeaderVia                   = 8,
    HttpHeaderWarning               = 9,
    HttpHeaderAllow                 = 10,
    HttpHeaderContentLength         = 11,
    HttpHeaderContentType           = 12,
    HttpHeaderContentEncoding       = 13,
    HttpHeaderContentLanguage       = 14,
    HttpHeaderContentLocation       = 15,
    HttpHeaderContentMd5            = 16,
    HttpHeaderContentRange          = 17,
    HttpHeaderExpires               = 18,
    HttpHeaderLastModified          = 19,
    // Request-only
    HttpHeaderAccept                = 20,
    HttpHeaderAcceptCharset         = 21,
    HttpHeaderAcceptEncoding        = 22,
    HttpHeaderAcceptLanguage        = 23,
    HttpHeaderAuthorization         = 24,
    HttpHeaderCookie                = 25,
    HttpHeaderExpect                = 26,
    HttpHeaderFrom                  = 27,
    HttpHeaderHost                  = 28,
    HttpHeaderIfMatch               = 29,
    HttpHeaderIfModifiedSince       = 30,
    HttpHeaderIfNoneMatch           = 31,
    HttpHeaderIfRange               = 32,
    HttpHeaderIfUnmodifiedSince     = 33,
    HttpHeaderMaxForwards           = 34,
    HttpHeaderProxyAuthorization    = 35,
    HttpHeaderReferer               = 36,
    HttpHeaderRange                 = 37,
    HttpHeaderTe                    = 38,
    HttpHeaderTranslate             = 39,
    HttpHeaderUserAgent             = 40,
    HttpHeaderRequestMaximum        = 41,
    // Response-only
    HttpHeaderAcceptRanges          = 20,
    HttpHeaderAge                   = 21,
    HttpHeaderEtag                  = 22,
    HttpHeaderLocation              = 23,
    HttpHeaderProxyAuthenticate     = 24,
    HttpHeaderRetryAfter            = 25,
    HttpHeaderServer                = 26,
    HttpHeaderSetCookie             = 27,
    HttpHeaderVary                  = 28,
    HttpHeaderWwwAuthenticate       = 29,
    HttpHeaderResponseMaximum       = 30,
    HttpHeaderMaximum               = 41
  );

// -----------------------------------------------------------------------------
// HTTP_KNOWN_HEADER / HTTP_UNKNOWN_HEADER
// -----------------------------------------------------------------------------

type
  HTTP_KNOWN_HEADER = record
    RawValueLength: USHORT;
    pRawValue:      PAnsiChar;
  end;
  PHTTP_KNOWN_HEADER = ^HTTP_KNOWN_HEADER;

  HTTP_UNKNOWN_HEADER = record
    NameLength:     USHORT;
    RawValueLength: USHORT;
    pName:          PAnsiChar;
    pRawValue:      PAnsiChar;
  end;
  PHTTP_UNKNOWN_HEADER = ^HTTP_UNKNOWN_HEADER;

// -----------------------------------------------------------------------------
// HTTP_REQUEST_HEADERS / HTTP_RESPONSE_HEADERS
// -----------------------------------------------------------------------------

const
  HTTP_MAX_SERVER_QUEUE_LENGTH = $7FFFFFFF;

type
  // 41 known request headers (HttpHeaderRequestMaximum = 41)
  THTTPKnownRequestHeaders = array[0..40] of HTTP_KNOWN_HEADER;
  // 30 known response headers (HttpHeaderResponseMaximum = 30)
  THTTPKnownResponseHeaders = array[0..29] of HTTP_KNOWN_HEADER;

  HTTP_REQUEST_HEADERS = record
    UnknownHeaderCount: USHORT;
    pUnknownHeaders:    PHTTP_UNKNOWN_HEADER;
    TrailerCount:       USHORT;
    pTrailers:          PHTTP_UNKNOWN_HEADER;
    KnownHeaders:       THTTPKnownRequestHeaders;
  end;
  PHTTP_REQUEST_HEADERS = ^HTTP_REQUEST_HEADERS;

  HTTP_RESPONSE_HEADERS = record
    UnknownHeaderCount: USHORT;
    pUnknownHeaders:    PHTTP_UNKNOWN_HEADER;
    TrailerCount:       USHORT;
    pTrailers:          PHTTP_UNKNOWN_HEADER;
    KnownHeaders:       THTTPKnownResponseHeaders;
  end;
  PHTTP_RESPONSE_HEADERS = ^HTTP_RESPONSE_HEADERS;

// -----------------------------------------------------------------------------
// HTTP_COOKED_URL – pre-parsed URL (always prefer over RawUrl)
// -----------------------------------------------------------------------------

type
  HTTP_COOKED_URL = record
    FullUrlLength:    USHORT;    // bytes (not characters)
    HostLength:       USHORT;
    AbsPathLength:    USHORT;
    QueryStringLength:USHORT;
    pFullUrl:         PWideChar; // e.g. L"http://server:80/path?query"
    pHost:            PWideChar;
    pAbsPath:         PWideChar;
    pQueryString:     PWideChar; // including leading '?', or nil
  end;
  PHTTP_COOKED_URL = ^HTTP_COOKED_URL;

// -----------------------------------------------------------------------------
// HTTP_TRANSPORT_ADDRESS – remote address of the client
// -----------------------------------------------------------------------------

type
  HTTP_TRANSPORT_ADDRESS = record
    pRemoteAddress: PSOCKADDR;
    pLocalAddress:  PSOCKADDR;
  end;
  PHTTP_TRANSPORT_ADDRESS = ^HTTP_TRANSPORT_ADDRESS;

// -----------------------------------------------------------------------------
// HTTP_DATA_CHUNK – body payload (inline, FileHandle, etc.)
// -----------------------------------------------------------------------------

type
  HTTP_DATA_CHUNK_TYPE = (
    HttpDataChunkFromMemory         = 0,
    HttpDataChunkFromFileHandle     = 1,
    HttpDataChunkFromFragmentCache  = 2,
    HttpDataChunkFromFragmentCacheEx= 3,
    HttpDataChunkMaximum            = 4
  );

  THTTPDataChunkFromMemory = record
    pBuffer:     Pointer;
    BufferLength: ULONG;
  end;

  THTTPDataChunkFromFileHandle = record
    ByteRange:   record
      StartingOffset: ULARGE_INTEGER;
      Length:         ULARGE_INTEGER;
    end;
    FileHandle:  THandle;
  end;

  HTTP_DATA_CHUNK = record
    DataChunkType: HTTP_DATA_CHUNK_TYPE;
    case Integer of
      0: (FromMemory:     THTTPDataChunkFromMemory);
      1: (FromFileHandle: THTTPDataChunkFromFileHandle);
  end;
  PHTTP_DATA_CHUNK = ^HTTP_DATA_CHUNK;

// -----------------------------------------------------------------------------
// HTTP_REQUEST_V2 (simplified; flags, ssl-info etc. treated as reserved)
// -----------------------------------------------------------------------------

type
  HTTP_REQUEST_V1 = record
    Flags:              ULONG;
    ConnectionId:       HTTP_OPAQUE_ID;
    RequestId:          HTTP_REQUEST_ID;
    UrlContext:         HTTP_URL_CONTEXT;
    Version:            THTTP_VERSION;
    Verb:               HTTP_VERB;
    UnknownVerbLength:  USHORT;
    RawUrlLength:       USHORT;
    pUnknownVerb:       PAnsiChar;
    pRawUrl:            PAnsiChar;   // do NOT use for routing – logging only!
    CookedUrl:          HTTP_COOKED_URL;
    Address:            HTTP_TRANSPORT_ADDRESS;
    Headers:            HTTP_REQUEST_HEADERS;
    BytesReceived:      ULONGLONG;
    EntityChunkCount:   USHORT;
    pEntityChunks:      PHTTP_DATA_CHUNK;
    RawConnectionId:    HTTP_OPAQUE_ID;
    // SSL info, request info etc. follow in V2 – treated as padding here
  end;
  PHTTP_REQUEST_V1 = ^HTTP_REQUEST_V1;

  // In practice always read as V1; V2 fields via pointer arithmetic
  HTTP_REQUEST  = HTTP_REQUEST_V1;
  PHTTP_REQUEST = ^HTTP_REQUEST;

// -----------------------------------------------------------------------------
// HTTP_RESPONSE_V2
// -----------------------------------------------------------------------------

type
  HTTP_RESPONSE_V1 = record
    Flags:          ULONG;
    Version:        THTTP_VERSION;
    StatusCode:     USHORT;
    ReasonLength:   USHORT;
    pReason:        PAnsiChar;
    Headers:        HTTP_RESPONSE_HEADERS;
    EntityChunkCount: USHORT;
    pEntityChunks:  PHTTP_DATA_CHUNK;
  end;
  PHTTP_RESPONSE_V1 = ^HTTP_RESPONSE_V1;

  // HTTP_RESPONSE_INFO_TYPE / HTTP_RESPONSE_INFO – the V2 trailer payload.
  // We never populate response-info, but the V2 fields MUST exist (and be zeroed)
  // because a queue created with HTTPAPI_VERSION_2 makes HttpSendHttpResponse read
  // a full HTTP_RESPONSE_V2; see HTTP_RESPONSE below.
  HTTP_RESPONSE_INFO_TYPE = (
    HttpResponseInfoTypeMultipleKnownHeaders = 0,
    HttpResponseInfoTypeAuthentication       = 1,
    HttpResponseInfoTypeQosProperty          = 2,
    HttpResponseInfoTypeChannelBind          = 3
  );

  HTTP_RESPONSE_INFO = record
    Type_:  HTTP_RESPONSE_INFO_TYPE;
    Length: ULONG;
    pInfo:  Pointer;
  end;
  PHTTP_RESPONSE_INFO = ^HTTP_RESPONSE_INFO;

  // HTTP_RESPONSE_V2 = HTTP_RESPONSE_V1 + { ResponseInfoCount, pResponseInfo }.
  // The V1 fields are declared inline (not via an embedded V1) so all existing
  // field accesses (RawResp.StatusCode, .Headers, …) stay unchanged. The two
  // trailing fields make SizeOf match what the kernel reads (568 bytes on Win64),
  // so the whole struct is zero-initialised and HttpSendHttpResponse no longer
  // reads ResponseInfoCount/pResponseInfo out of uninitialised stack memory.
  HTTP_RESPONSE_V2 = record
    Flags:             ULONG;
    Version:           THTTP_VERSION;
    StatusCode:        USHORT;
    ReasonLength:      USHORT;
    pReason:           PAnsiChar;
    Headers:           HTTP_RESPONSE_HEADERS;
    EntityChunkCount:  USHORT;
    pEntityChunks:     PHTTP_DATA_CHUNK;
    ResponseInfoCount: USHORT;
    pResponseInfo:     PHTTP_RESPONSE_INFO;
  end;
  PHTTP_RESPONSE_V2 = ^HTTP_RESPONSE_V2;

  // The request queue is created with HTTPAPI_VERSION_2, so responses are sent
  // as V2. Aliasing HTTP_RESPONSE to V2 (not V1) is the Win64 correctness fix:
  // on Win32 the missing 16 trailing bytes happened to be zero on the stack, on
  // Win64 they were garbage → ERROR_INVALID_PARAMETER (87) → connection reset.
  HTTP_RESPONSE  = HTTP_RESPONSE_V2;
  PHTTP_RESPONSE = ^HTTP_RESPONSE;

implementation

end.
