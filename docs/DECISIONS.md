# Architecture & Process Decisions — DX.HttpSys

This log records the important decisions taken while developing DX.HttpSys from the
PRD (`docs/PRD.md`). It exists so a reviewer can reconstruct *why* the code looks the
way it does without re-deriving it. Newest entries first within each section.

The PRD itself is the source of truth for **what** is built; this file captures the
**how** and **why** of decisions that the PRD left open or that emerged during work.

---

## Process

### P-1 — Phased delivery with one branch + PR per phase
The work follows the PRD's milestone roadmap (§10), grouped into phases. Each phase is
developed on its own branch (`phase/NN-<slug>`), pushed, and opened as a PR.

**Review during the author's absence:** A human review is not available while the work
runs autonomously. As agreed with the user, each PR is gated by:
1. A self-review via the agent-based `/code-review`, with findings addressed before merge.
2. The repository's automated GitHub review bot; its comments are awaited and addressed.

Only after both are green is the phase merged and the next phase started.

### P-3 — Review cadence per phase
To keep the review loop productive (PR #1 took two bot rounds for 11 findings):
1. Run a focused agent **self-review before pushing**, so the obvious issues are
   fixed before the bots see them.
2. The GitHub bots (Augment, Copilot) review automatically on push. Wait for **one**
   bot round, fold in the valid findings, and reply on the PR mapping each finding to
   its resolution.
3. Only run a second bot round when round 1 surfaced substantive new issues.
4. Merge when the build is clean (Win32+Win64), tests pass with no leaks, and findings
   are addressed.

Findings are judged on technical merit, not accepted blindly — a couple were
documentation/contract mismatches, one was a real use-after-free on the partial-startup
path, several were genuine lifecycle/leak issues.

**Bot availability:** From PR #2 onward, Augment is out of credits and no longer reviews.
The available automated reviewer is **GitHub Copilot** (plus the agent self-review). The
cadence is unchanged; there is simply one bot instead of two.

### P-2 — GitHub repository
The PRD (§11, Q2) targets `omonien/DX.HttpSys`. The repo is created **private** initially
(reversible: can be made public later) so that the work can be reviewed before publication.
`gh` is authenticated as `omonien`.

---

## Architecture

### A-1 — Remove `{$IFDEF MSWINDOWS}` guards (YAGNI, Windows-only)
**Decision:** The cross-platform compile guards present in the scaffolding are removed.

**Why:** HTTP.sys is a Windows kernel facility (`httpapi.dll`). The library is, by its very
nature, Windows-only. The scaffolding carried `{$IFDEF MSWINDOWS}` wrappers and a
`EDXHttpSysNotSupported` "compiles-but-raises-on-non-Windows" story (PRD §9.1). Per the
user's explicit instruction and YAGNI, we drop this now. The units simply *are* Windows code.

**Consequence / how to apply:** If genuine multi-platform support is ever needed, it will be
(re)introduced deliberately at that point — not carried speculatively. `EDXHttpSysNotSupported`
is kept as an exception type for genuine runtime "feature not available on this Windows"
situations, but is no longer tied to the platform-compile story.

### A-2 — `TDXHttpSysApi` is a class, not a record
**Decision:** The API loader/dispatch table `TDXHttpSysApi` is a **class** (was a `record`
in the scaffolding).

**Why (root-caused, not guessed):** As a record with no managed fields, a local
`TDXHttpSysApi` variable is **not** zero-initialised by Delphi. `Load` begins with
`if FLoaded then Exit(True)` — with an uninitialised `FLoaded` holding garbage (≠ 0),
`Load` returned `True` immediately **without loading httpapi.dll or resolving any function
pointer**. Every pointer stayed garbage, so the first real API call
(`HttpInitialize`) jumped to a junk address and corrupted the stack/heap. The failure was
nondeterministic: a standalone program happened to get a zeroed stack and "worked", while
the DUnitX runner (methods invoked via RTTI, garbage on the stack) crashed with
`EAccessViolation` / `EInvalidPointer`. This was proven by reducing to a minimal program
and observing that `LApi := Default(TDXHttpSysApi)` before `Load` made the crash vanish.

A class instance is always zero-initialised on `Create`, which removes the entire failure
mode at the source instead of relying on every caller remembering to pre-zero the record.
It also gives the loader a natural lifecycle: `Unload` runs in the destructor.

**How to apply:** Consumers (Server, Request, Response, ThreadPool) hold the API as an
**object reference**, so they all share the one loaded function table — which is what we
want. Never reintroduce a record here, and never rely on implicit zero-init of a record
that has a "already done" early-exit flag.

### A-3 — QueueLength is request-queue state, deferred to Phase 2
**Decision:** `QueueLength` is stored as configuration in Phase 1 but **not** applied
to HTTP.sys yet.

**Why:** `HttpServerQueueLengthProperty` is a property of the **request queue**, set via
`HttpSetRequestQueueProperty(FReqQueueHandle, ...)` — not a URL-group property. The
scaffolding applied it through `SetUrlGroupProperty`, which silently no-ops. Rather than
keep a fake apply, Phase 1 stores the value and the real call is wired together with the
rest of the server runtime in Phase 2 (which also needs `HttpSetRequestQueueProperty`
added to the loader). Flagged by both review bots on PR #1.

**How to apply:** In Phase 2, add `HttpSetRequestQueueProperty` to `TDXHttpSysApi`, apply
`FQueueLength` to the queue handle right after `CreateRequestQueue` in `SetupUrlGroup`
with `CheckResult`, and allow a live update from the setter when active.

### A-4 — Response header transmission strategy
**Decision:** Header values handed to `HttpSendHttpResponse` are backed by **instance
fields** (`FHeaderValues`, `FHeaderNames`, `FUnknownHeaders`). Within a single `Send`, each
array is sized **once** (in `BuildHeaders`, before the fill loop) and the raw `PAnsiChar`
pointers are taken **after** that `SetLength`; the arrays are never resized again until the
Send completes.

**Why:** HTTP.sys reads the `HTTP_RESPONSE` struct (and the raw pointers inside it) during
the synchronous `HttpSendHttpResponse` call. If the backing strings were locals, or were
reallocated after a pointer was taken, the kernel would read freed/moved memory. Sizing
each array exactly once per response and never trimming it keeps every pointer stable until
Send returns. The unknown-header array is sized to the worst case (all headers unknown) on
purpose — a later trim would reallocate and invalidate `pUnknownHeaders`. (A `Send` runs
once per response object, so "once per Send" and "once per instance" coincide in practice.)

### A-5 — Each request owns its receive buffer (no copy) — fixes cross-talk under load
**Decision:** The receiver thread allocates a **fresh buffer per request**, lets HTTP.sys
write the `HTTP_REQUEST` directly into it, and transfers **ownership** of that buffer to
the work item by reference (`WorkItem.RequestBuffer := Buffer; Buffer := nil`). It does
**not** `Move` the bytes into a separate buffer.

**Why (found by the stress harness, root-caused):** `HTTP_REQUEST` contains **absolute
pointers** into the receive buffer — `CookedUrl.pFullUrl` / `pAbsPath` / `pQueryString`,
the known/unknown header `pRawValue`s, the entity chunks. The original code received into a
single shared `FRequestBuffer` and `Move`d the bytes into a per-work-item buffer. The bytes
were copied, but those internal pointers still referenced the **shared** `FRequestBuffer`.
By the time a worker parsed the request, the receiver had already overwritten
`FRequestBuffer` with a **later** request — so `/req-6` returned the body for `/req-3`.

Single-request tests never caught this (the buffer wasn't reused before parsing). The
concurrency harness exposed it immediately: 42/500 GET and 161/300 POST responses were
crossed. The fix removes the copy entirely: the buffer HTTP.sys wrote into is the exact
buffer the worker reads from, and it lives (owned by the work item) until the worker is
done. `TBytes` reference semantics make the ownership transfer a single assignment.

**How to apply:** Never copy an `HTTP_REQUEST` to a different address and then read its
internal pointers — they do not survive the move. Keep the buffer that HTTP.sys filled
alive for as long as anything reads the parsed request, and never reuse it for another
receive until then. This is the single most important correctness invariant in the engine.

### A-6 — Body loading must read inline entity chunks first (COPY_BODY)
**Decision:** `TDXHttpSysRequest.LoadBody` reads the request's **inline entity chunks**
(`pEntityChunks`) first, and only calls `HttpReceiveRequestEntityBody` for the remainder
when `HTTP_REQUEST_FLAG_MORE_ENTITY_BODY_EXISTS` is set.

**Why (found by the POST stress harness):** `HttpReceiveHttpRequest` is called with
`HTTP_RECEIVE_REQUEST_FLAG_COPY_BODY`, so a body that fits in the request buffer is
delivered **inline** as entity chunks and is **not** returned again by
`HttpReceiveRequestEntityBody` (which then reports `ERROR_HANDLE_EOF`). The original
`LoadBody` ignored the inline chunks and only called `ReceiveRequestEntityBody`, so for any
request whose body was copied inline it returned an **empty** body. Single POST tests passed
by luck (timing sometimes left the body for a separate receive); under load the body was
reliably inline, so 174/300 POST bodies came back empty.

**How to apply:** With `COPY_BODY`, always consume `pEntityChunks` before falling back to
`ReceiveRequestEntityBody`. The fallback is only for bodies too large to copy inline.

### A-7 — Worker shutdown polls for termination; no nil wake-up items
**Decision:** Worker threads pop from the pending queue with a **finite (100 ms) timeout**
and observe `Terminated` on each tick. `Stop` simply terminates the workers, waits, then
drains and frees any leftover work items.

**Why (found by the stress harness):** The original `Stop` pushed one nil "wake-up" item
per worker into the bounded queue. Under load the queue is full, and once a worker is
terminated it leaves its loop without draining further — so the nil pushes blocked forever
on the full queue and `Stop` deadlocked. Running the two stress tests back to back hung
reliably. Timeout-based polling removes the need for wake-up items entirely; the queue
drain reclaims work-item buffers that would otherwise leak.

The receiver also breaks its loop on `ERROR_INVALID_HANDLE` / `ERROR_OPERATION_ABORTED`
(the queue handle being closed during shutdown) instead of spinning on a dead handle.

### A-8 — Oversized requests are rejected (431 + disconnect); buffer growth is defensive
**Decision:** When a request's headers do not fit even after growing the receive buffer to
its 1 MB cap, the receiver sends a **431 (Request Header Fields Too Large) with
`HTTP_SEND_RESPONSE_FLAG_DISCONNECT`** and moves on.

**Why (flagged by Copilot on PR #3):** An `ERROR_MORE_DATA` request stays **pending** in the
kernel queue until it is either fully received or answered. If we just skipped it, the very
next `HttpReceiveHttpRequest` would return the same oversized request again — a tight loop
that spins the CPU, spams logs, and blocks every later request (a DoS vector). Sending a
response (with disconnect) removes it from the queue.

**Note on HTTP.sys's own limit:** In practice HTTP.sys enforces its own default ~16 KB total
request-header limit and answers 400 itself **before** the request ever reaches our receiver,
so the `ERROR_MORE_DATA` growth path is only exercised when that kernel limit is raised via
the registry (`MaxRequestBytes`/`MaxFieldLength`). The growth + reject logic is therefore a
correct defensive measure rather than a hot path, and is not unit-tested (it would require
changing machine-wide HTTP.sys registry settings).

### A-9 — WebBroker adapter dispatches via a TWebRequestHandler descendant
**Decision:** `TWebBrokerHttpSysDispatcher` feeds requests into WebBroker through
`TWebRequestHandler.HandleRequest`, reached via a small descendant
(`TDXWebRequestHandlerAccess`) that re-exposes the **protected** `HandleRequest`. The
application registers its WebModule by setting `WebRequestHandlerProc`.

**Why:** `TWebRequestHandler.HandleRequest` is protected with no public interface; the same
"descendant exposes protected method" technique is exactly what Embarcadero's own Indy and
ISAPI WebBroker bridges use. There is no separate `WebBroker` runtime package in this Delphi
install, so the `Web.HTTPApp` / `Web.WebReq` units link statically into the adapter BPL
(`{$WARN IMPLICIT_IMPORT OFF}` silences the expected notice).

**Known limitation:** `TWebRequest.ServerPort` returns -1 — HTTP.sys does not surface the
port in the parsed request and `TDXHttpSysRequest` doesn't carry it. WebModules essentially
never need it; revisit only if a real use appears (YAGNI).

### A-11 — Soak test measures memory + handles against a warmed-up baseline
**Decision:** The longevity test (`Test.DX.HttpSys.Soak`) runs warm-up waves first, takes a
memory and handle-count baseline, then runs many more waves and asserts both stayed within a
generous tolerance (8 MB working set, 64 handles).

**Why:** PRD §9.6 requires proof of constant memory and handle usage under sustained load.
The baseline is taken **after** warm-up so one-time allocator/thread-pool growth isn't
mistaken for a leak; a real leak grows without bound and trips the tolerance, while normal
allocator slack stays under it. The size is CI-friendly (waves × per-wave ≈ 4000 requests,
a few seconds); the same harness scales to a multi-hour run by raising `cWaves`.

### A-12 — CI targets a self-hosted Windows runner with Delphi
**Decision:** The GitHub Actions workflow (`.github/workflows/build-and-test.yml`) runs on a
**self-hosted** runner labelled `[self-hosted, windows, delphi]`, not a GitHub-hosted runner.

**Why:** Delphi is commercial and is not available on GitHub-hosted runners, so a real
compile+test gate (PRD §9.6) can only run where Delphi is installed. The workflow builds the
Core (Win32+Win64) and WebBroker package, builds the DUnitX runner, and runs the full suite,
failing the job on any test failure or leak. The HTTP.sys integration/stress/soak tests bind
to `localhost`, so the runner needs no admin rights or URL ACL. The WiRL adapter is excluded
(A-10).

### A-10 — WiRL is a consumer dependency, fetched on demand; two adapters by API era
**Decision:** WiRL (and any future wrapped framework) is **never vendored or submoduled**.
Its source is fetched on demand by `build-scripts/FetchThirdParty.ps1` (driven by
`thirdparty.manifest.json`) into the git-ignored `build/thirdparty/`, and only the **optional**
integration tests in `tests-integration/` build against it. A plain clone of DX.HttpSys pulls
nothing extra.

Because WiRL's `IWiRLListener` signature changed across versions, there are **two adapters**:
- `DX.HttpSys.WiRL` — the WiRL **4.x release** API: two-arg `HandleRequest(request, response)`,
  `WiRL.Core.Engine`. **Verified** against WiRL v4.6.0 by the integration harness (2/2, 0 leaks).
- `DX.HttpSys.WiRL.REST` — the WiRL **master** API: three-arg `HandleRequest(context, request,
  response)`, `WiRL.Engine.REST`. Same structure against the newer signature; best-effort
  until pinned and run against a master snapshot.

A consumer uses exactly one, matching their WiRL version, and selects the engine with
`TWiRLServer.ServerVendor := 'HttpSys'`.

**How to apply (adding a wrapper or a transitive dep):** append an entry to the manifest
(name, repo, ref, sourcePaths) and a `Test.*.pas` fixture — no submodule, no change to the
standard build. WiRL's own transitive deps (delphi-jose-jwt, delphi-neon) are manifest entries.

### A-13 — ReportError must not leak freshly-created exceptions
**Decision:** `TDXHttpSysWorkerPool` has two error-reporting entry points: `ReportError` (the
caller's `except` block still owns the exception) and `ReportErrorOwned` (the caller hands over
a freshly-created exception, which the pool frees).

**Why (found by the WiRL integration soak):** the receiver thread reported ad-hoc errors by
passing `EDXHttpSysError.CreateWin32(...)` straight to `ReportError`, which — with no `OnError`
handler — swallowed the exception **without freeing it**. Under repeated server start/stop
(three WiRL tests back to back) a shutdown-race error leaked an `EDXHttpSysError`. This is a
real Core bug, not WiRL-specific; the integration harness simply surfaced it. The fix splits
ownership explicitly so a swallowed error is always freed.

### A-14 — WiRL response owns its content stream
**Decision:** `TWiRLHttpResponseHttpSys` owns its content stream and frees it in the destructor;
`SetContentStream` takes over (and frees the previous) so ownership stays with the response.

**Why:** WiRL writes the response body into the response's `ContentStream` and does **not** free
it (the Indy adapter hands ownership to Indy via `FreeContentStream := True`). The original
"WiRL owns it" assumption leaked the stream WiRL set. Verified leak-free by the integration tests.

### A-15 — Horse adapter is a thin provider over the WebBroker dispatcher
**Decision:** The Horse adapter (`DX.HttpSys.Horse`) is a `THorseProviderHttpSys<T>`
deriving from `THorseProviderAbstract<T>`. Horse dispatches every request through
WebBroker (`THorseWebModule` over `TWebRequest`/`TWebResponse`), so the provider does
not bridge requests itself: `InternalListen` sets
`WebRequestHandler.WebModuleClass := WebModuleClass` and runs a `TDXHttpSysServer`
whose handler is the **already-verified** `TWebBrokerHttpSysDispatcher`. Routes
registered via `THorse.Get/Use` and this provider share the same `THorseCore`
singleton, so a user keeps writing normal Horse code and only swaps the `Listen` call.

Horse is fetched on demand like WiRL (A-10): manifest entry pinned to **v2.0.14**,
plus a `tests-integration/` fixture — no submodule. The manifest entry carries an
`excludeFiles` list dropping Horse's bundled `Web.WebConst.pas` (an FPC compat shim
that, on the Delphi search path, shadows the RTL unit and breaks resolution of the
RTL `Web.*` units). `FetchThirdParty.ps1` honours `excludeFiles` on every run.

**Why a provider, not an engine:** Horse has no runtime server-registration hook
(the active server is chosen at compile time by `{$IFDEF}` in `Horse.pas`). The
clean external integration point is therefore a provider class the user calls
directly, not an injection into `THorse`.

### A-16 — Cooked URL pointers must be sliced by length, not cast as strings
**Decision:** `TDXHttpSysRequest.ParseFromRaw` slices `pAbsPath`, `pHost` and
`pQueryString` from `HTTP_COOKED_URL` with `SetString` using the matching
`*Length` field (bytes ÷ `SizeOf(WideChar)`), not `string(PWideChar)`.

**Why (found by the Horse integration test):** these three pointers index into the
same buffer as `pFullUrl` and are **not** individually null-terminated — `pAbsPath`
runs straight into `"?query"`. The old `string(pAbsPath)` cast read to the next `#0`
and so leaked the query string into `Path`. WebBroker (and thus Horse) routes on
`PathInfo` = `Path`, so `GET /echo?x=1` became the un-routable token `echo?x=1`
→ 404. WiRL masked it (it parses query separately and matched anyway); Horse, which
routes purely on the path tokens, exposed it. This is a Core bug affecting every
consumer; a regression test (`RequestWithQuery_SplitsPathAndQuery`) now guards it
in the standard suite.

The same non-null-terminated hazard applies to the ANSI buffer pointers
(`pUnknownVerb`, known/unknown header `pName`/`pRawValue`); those are now sliced
through a shared `AnsiStringFromBuffer(ptr, length)` helper rather than cast as
null-terminated strings, closing the whole class rather than just the path case.

### A-19 — `HTTP_RESPONSE` must alias the V2 layout, not V1 (Win64 send fix)
**Decision:** `HTTP_RESPONSE` aliases `HTTP_RESPONSE_V2` (V1 fields inline + `ResponseInfoCount` /
`pResponseInfo`), not `HTTP_RESPONSE_V1`. The two send sites (`TDXHttpSysResponse.Send` via
`BuildHttpResponse`, and `TDXHttpSysReceiverThread.RejectRequest`) keep their existing
`FillChar(.., SizeOf(..), 0)` — sizing the alias to V2 makes that zero the full 568 bytes.

**Why (found locally; Win32 passed, Win64 reset every response):** the request queue is created
with `HTTPAPI_VERSION_2` (A-3/Phase 2), so `HttpSendHttpResponse` reads the response buffer as a
full `HTTP_RESPONSE_V2`. The struct was only declared as V1 (552 bytes on Win64), so the kernel
read the 16 trailing V2 bytes (`ResponseInfoCount` + `pResponseInfo`) out of **uninitialised
stack**: a non-zero count with a garbage pointer → `HttpSendHttpResponse` returns
`ERROR_INVALID_PARAMETER` (87) → HTTP.sys resets the connection → the client sees WinHTTP `12030`.
On Win32 those bytes happened to be zero on the stack, so it silently worked; on Win64 they were
garbage. The whole integration/stress/soak suite failed on Win64 (every real HTTP round-trip) while
the pure unit tests passed — confirmed by a minimal in-process server+client repro that passed on
Win32 and reset on Win64, then passed on Win64 once the buffer was V2-sized and zeroed. This is a
**second, independent** Win64 defect from A-18: A-18 fixed server *start* (`HttpSetRequestQueueProperty`),
A-19 fixes response *send*.

**How to apply:** When a struct is passed to a `*_VERSION_2` API, model the **full V2 layout** even
if the V2-only fields are never populated — they must exist and be zeroed so the kernel does not read
past the buffer. Never alias an `HTTP_RESPONSE`/`HTTP_REQUEST` to V1 when the queue is V2. Guarded by
`HttpResponse_IsV2Sized` in the standard suite. (This is the response-side twin of A-2's "always
zero-initialise what the kernel reads".)

### A-20 — `AddUrlPrefix(complete-URL)` is the single bind mechanism; `Port` / `UseLocalhost` / `UseAllInterfaces` removed (breaking)
**Decision:** The Core configures where the server binds in exactly one explicit way:
`AddUrlPrefix(const APrefix: string)`, taking a **complete** URL (e.g.
`'http://localhost:80/standalone/'`, `'https://+:1223/api/'`). The vague `Port` property and the
`UseLocalhost` / `UseAllInterfaces` convenience methods are **removed** from `TDXHttpSysServer`.
`AddUrlPrefix` now validates the prefix shape at call time — it must start with `http://` / `https://`
and end with `/` (HTTP.sys requires the trailing slash) — raising `EDXHttpSysError` immediately
instead of a cryptic Win32 error at `Start`.

Adapters assemble their own complete URL from three building blocks and pass the finished string to
`AddUrlPrefix`. The host/scheme→string translation is shared (DRY) via one Core formatter,
`TDXHttpSysServer.BuildPrefix(AScheme, AHost, APort, APath)` — it only formats the string;
`AddUrlPrefix` stays the only binder. The three building blocks an adapter owns:
- **Scheme** — the scoped enum `TDXScheme = (Http, Https)`, declared in the Core so adapters and
  consumers share one type (default `Http`).
- **Host** — a string (default `localhost`); `0.0.0.0`/empty → `+` (wildcard), `localhost`/`127.0.0.1`
  → `localhost`, anything else verbatim.
- **Path** — owned by the framework (WiRL engine `BasePath`; Horse provider `BasePath`; the Standalone
  demo sets it directly on HTTP.sys).

This is how a consumer chooses `+` / an IP / `https`: set the adapter's `Host` / `Scheme` before start.
The default (`Http` + `localhost`) keeps the demos admin-free.

**Port sharing (single source of truth):** all four demos bind under a distinct path prefix on the
shared port 80 (`/standalone`, `/rest`, `/webbroker`, `/horse`), so they run simultaneously —
HTTP.sys routes by longest-prefix match across processes. The path is configured in exactly one place
(the framework) and the adapter reads it to build the prefix; no path stripping (HTTP.sys passes the
full path through and the framework routes on it). Only the Standalone demo, which has no framework,
sets the path directly at the HTTP.sys level.

**Actionable bind error:** when `AddUrlToUrlGroup` fails with `ERROR_ACCESS_DENIED` (5), the Core
(`SetupUrlGroup`) raises an error naming the exact prefix and the one-time
`netsh http add urlacl url=… user=DOMAIN\User` reservation to run as Administrator. Other error codes
keep the generic message (no netsh noise). Central in the Core, so every adapter and consumer benefits
without duplication. The message is formatted by the `FormatAccessDeniedMessage` seam so the test
asserts the shape without an actual privileged-port bind.

**Why:** `Port` was a second source of truth — consulted only by the convenience methods and silently
ignored when `AddUrlPrefix` was called directly (a real trap); `UseLocalhost` / `UseAllInterfaces` hid
the host translation, the scheme, the port and the trailing `/`. One explicit, validated mechanism with
a shared formatter removes the magic while keeping the host/scheme logic in one place.

**How to apply:** Configure binds via `AddUrlPrefix` with a complete URL; build that URL from parts with
`BuildPrefix`. Guarded by the `Test.DX.HttpSys.Url` fixture (`BuildPrefix` scheme/host/path,
`AddUrlPrefix` validation, the access-denied message). Deferred (YAGNI): a generic per-framework
`BasePath` abstraction; netsh guidance for non-access-denied errors; `+:80` in the demos.

<!-- New architecture decisions are appended below. -->

---

## Phase status

Single source of truth for where each phase stands. (One section — earlier per-phase
status blocks were consolidated here.)

- **Phase 1 (PR #1, merged):** Windows-only Core, builds clean Win32+Win64, API smoke tests
  (6/6, 0 leaks). Four bot-review rounds.
- **Phase 2 (PR #2, merged):** Server end-to-end — header transmission, Server header,
  QueueLength (A-3), E2E tests, standalone demo verified live.
- **Phase 3 (PR #3, merged):** Threading hardened under load. The stress harness found three
  real bugs single-request tests missed — cross-talk (A-5), empty bodies (A-6), shutdown
  deadlock (A-7); all fixed. Oversized-request reject (A-8). IPv6 RemoteIP. 14/14, 0 leaks.
- **Phase 4 (PR #4, merged):** WebBroker adapter (A-9) — `TWebRequest`/`TWebResponse` over the
  Core, real WebModule E2E tests, demo 03 verified live. 17/17, 0 leaks.
- **Phase 5 (PR #5, DRAFT — not merged):** WiRL adapter (A-10), best-effort, not built here;
  removed from the build group; awaiting verification with WiRL installed.
- **Phase 6 (PR #6):** Soak/longevity test (A-11) — bounded working set + handles under
  sustained load. 18/18, 0 leaks.
- **Phase 7 (PR #7):** Packaging + CI + docs — self-hosted CI workflow (A-12), README updated
  (status, roadmap, WebBroker/WiRL quick-starts), XML doc comments on the public types, and
  the project group builds clean as one unit (Core + WebBroker + Tests + demos). WiRL removed
  from the group so the group is buildable without WiRL.
