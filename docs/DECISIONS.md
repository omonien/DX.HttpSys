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

<!-- New architecture decisions are appended below. -->
