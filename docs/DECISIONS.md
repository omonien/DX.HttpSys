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

## Phase status

- **Phase 1 (PR #1, merged):** Windows-only Core compiles clean (Win32+Win64), API smoke
  tests green (6/6, 0 leaks). Self-review + both GitHub bots (Augment, Copilot) addressed
  over four rounds.
- **Phase 2 (PR #2):** Server serves requests end-to-end. Response header transmission,
  Server header pass-through, QueueLength via HttpSetRequestQueueProperty (A-3 resolved),
  E2E integration tests (12/12, 0 leaks), and a live-verified standalone demo.

<!-- New architecture decisions are appended below. -->
