# ZiA — Completion Ledger

> Contract: **Frozen Architecture & Implementation Contract v1.0** (9 frozen
> principles + Principle 10 "Self-Modification Never Equals Self-Validation").
> Executor: Mac-side lead engineer. Reviewer: Claude (no repo access; this ledger
> and the written reports are the only evidence).
>
> **Gates** (run after every task):
> ```bash
> swift build 2>&1 | tail -5
> swift test --skip ZiaVoicePipelineBenchmarkTests --skip VoiceTurnLifecycleRegressionTests 2>&1 | tail -5
> swift run Jarvis --self-test 2>&1 | tail -8
> grep -rn "@State\b" Sources/Jarvis/UI      # must show only comments
> git status --short
> ```

Baseline at ledger creation (`77a5799`):
`swift build` → Build complete · `swift test` → **254 tests / 38 suites, 0 failures** ·
`--self-test` → **1067 passed / 0 failed / 0 skipped** · `@State` grep → comments only.

## Task rows

| ID | Task | Status | Commit | Gates | Evidence |
|---|---|---|---|---|---|
| 0.1 | Orient & baseline | DONE | — | build OK · 254/0 · 1067/0/0 · no `@State` | baseline tail captured this session (see summary) |
| 0.2 | Capability audit of ToolRegistry | DONE | `12c4298` | build OK · 254/0 · 1067/0/0 | `docs/CAPABILITY_AUDIT.md` |
| 1.1 | Docs truth refresh | DONE | `229d149` | build OK · 254/0 · 1067/0/0 · no `@State` | `PROJECT_CONTEXT.md`, `ZIA_ARCHITECTURE.md` |
| 1.2 | Repo hygiene classification | DONE | `4f979f2` | build OK · 254/0 · 1067/0/0 | `docs/REPO_HYGIENE.md`, `.gitignore` |
| 1.3 | Stale branch diff (read-only) | DONE | `2bc8cf4` | build OK · 254/0 · 1067/0/0 | `docs/STALE_BRANCHES.md` |
| 1.4 | Model config truth (cached-only models, no download) | DONE | `242413d` | build OK · 263/0 · 1067/0/0 · no `@State` | `Sources/Jarvis/Brain/LocalModelCatalog.swift`, `Tests/JarvisTests/LocalModelCatalogTests.swift` |
| 1.5 | Test health / deterministic self-test | DONE | _(this commit)_ | build OK · 263/0 ×2 · 1067/0/0 ×2 | `Sources/Jarvis/Core/SelfTest.swift` (median-of-5 halt latency) |

## APPROVAL QUEUE (owner-only destructive/licence-sensitive actions)

| ID | Action | Why | Status |
|---|---|---|---|
| AQ-1 | `git rm --cached swiftly.pkg` (then consider history rewrite) | 10.9 MB installer binary tracked in git | PENDING OWNER |
| AQ-2 | `git rm --cached output.txt forbidden.txt "..."` | tool/test residue tracked at repo root | PENDING OWNER |
| AQ-3 | `git rm --cached PolicyEvaluator.swift` | orphan, unreferenced, fails-open policy engine at repo root | PENDING OWNER |
| AQ-4 | remove/relocate `.continuerules` from tracking | AI-agent prompt file that self-grants destructive authority | PENDING OWNER |
| AQ-5 | stale branch delete: `freebuff/verification-subsystem`, `gemini/milestone4-verification` | superseded (see Phase 1.3) | PENDING OWNER |

## OWNER-ONLY (needs Jayanth's hands at the Mac)

| ID | Item | Why |
|---|---|---|
| — | (populated in Phase 9) | |

## Operational hazard discovered (Phase 1.4)

A stale `Jarvis --audit` process (58 minutes old) plus two orphaned `mlx_worker.py`
processes were left over from an earlier session. While they lived, **every** new
`Jarvis --self-test` run deadlocked inside `Security`/`securityd` during
`GroqProvider.isAvailable → KeychainManager.getAPIKey → SecItemCopyMatching`
(main thread pumping the runloop in `ZiaSubsystemSelfTests.wait`). Killing the
stale processes restored the self-test (now 1067/0/0 in ~101s). Mitigation:
before running gates, clear stale `Jarvis`/`mlx_worker.py` processes.

## Baseline deltas vs the stated verified state

- `--self-test` now reports **1067 passed / 0 failed / 0 skipped**; the handoff
  stated "1066 passed / 1 skipped (screenshot, needs Screen Recording)". The
  screenshot self-test now *runs and passes*, consistent with Screen Recording
  being granted to the invoking terminal. No code change involved.
