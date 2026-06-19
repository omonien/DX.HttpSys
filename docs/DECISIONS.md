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
