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
| 1.5 | Test health / deterministic self-test | DONE | `70f1b4e` | build OK · 263/0 ×2 · 1067/0/0 ×2 | `Sources/Jarvis/Core/SelfTest.swift` (median-of-5 halt latency). Emergency-stop halt latency reads **0.00 ms**; **no flake was observed before** the median-of-5 change; the **50 ms bound is unchanged**. |
| 2.1 | Local vs Groq benchmark (executor R1) | DONE | `177d14a` | build OK · 270/0 · self-test 1067/0/0 · no `@State` | `Sources/Jarvis/Core/LocalVsGroqBenchmark.swift`, `Tests/JarvisTests/LocalVsGroqBenchmarkScoringTests.swift`, `build/local-vs-groq-benchmark.{md,raw.txt}` |
| 2.1b | Groq provider fixes (executor R2) | DONE | `571c6a6` | build OK · 277/0 · self-test 1067/0/0 · no `@State` | `Sources/Jarvis/Brain/Providers/GroqProvider.swift` (real SSE, bounded `/models` verify, injectable session/key), `HealthService.report(verifyExternalModels:)`, `ZiaProviderModel.groqModelNote`, `Tests/JarvisTests/GroqProviderTests.swift` |
| 2.1c | Keychain bounds (executor R3) | DONE | `5cb04a1` | build OK · 282/0 · self-test 1067/0/0 · no `@State` | `Sources/Jarvis/Core/KeychainManager.swift` (bounded fail-closed reads, injectable backend), `Tests/JarvisTests/KeychainBoundsTests.swift` |
| 2.1d | Loose ends (executor R4) | DONE | `0826c67` | build OK · 282/0 · self-test 1067/0/0 · no `@State` | `docs/OWNER_CHECKLIST.md` (new); tool count reconciled; hazard/screenshot/host notes recorded below |

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
| OC-1 | Microphone permission is **Not Determined**; captured samples are **exact-zero** | macOS has not granted mic access to the invoking process. Owner must grant it; live mic/voice checks are hardware-only. |
| OC-2 | Accessibility, Screen Recording, Automation TCC grants; Safari **Allow JavaScript from Apple Events** | Needed for computer control, screenshots, browser automation. Unattended runs cannot verify these. |
| OC-3 | Live on-screen UI, release signing/notarization | Requires the owner at the Mac. |
| — | Full checklist: `docs/OWNER_CHECKLIST.md` (details completed in Phase 9). | |

## Operational hazard discovered (Phase 1.4)

A stale `Jarvis --audit` process (58 minutes old) plus two orphaned `mlx_worker.py`
processes were left over from an earlier session. While they lived, **every** new
`Jarvis --self-test` run deadlocked inside `Security`/`securityd` during
`GroqProvider.isAvailable → KeychainManager.getAPIKey → SecItemCopyMatching`
(main thread pumping the runloop in `ZiaSubsystemSelfTests.wait`). Killing the
stale processes restored the self-test (now 1067/0/0 in ~101s). Mitigation:
before running gates, clear stale `Jarvis`/`mlx_worker.py` processes.

**Hardened in R3 (executor, commit `5cb04a1`):** the keychain read path is now
bounded — every read runs off the caller's thread and waits at most **2 s**,
then fails closed to "no key". A wedged `securityd` can no longer freeze a
health check or the self-test. Verified by `KeychainBoundsTests` (a 3 s backend
returns `nil` in < 2 s) and by a full self-test that still passes 1067/0/0.

## Baseline deltas vs the stated verified state

- `--self-test` now reports **1067 passed / 0 failed / 0 skipped**; the handoff
  stated "1066 passed / 1 skipped (screenshot, needs Screen Recording)". The
  screenshot self-test now *runs and passes*, consistent with Screen Recording
  being granted to the invoking terminal. No code change involved.
  **Host dependency:** the screenshot test passes because the *host app running
  it* (the invoking terminal) has Screen Recording granted — this is not proof
  that the packaged `build/Jarvis.app` is granted. Owner must grant it
  separately (`docs/OWNER_CHECKLIST.md` §4).
- **Tool count reconciled.** The production registry (`registerBuiltins()`)
  registers **42 distinct tool names**. `CAPABILITY_AUDIT.md`'s 42 is correct.
  The self-test prints **43** because it registers its own test-only probe
  (`SelfTestVerificationOutcomeTool`, `SelfTest.swift:8`) during the run; the
  extra entry is not a production tool. True production number: **42**.
- **Local model availability is layered, by design.** `MLXProvider.isAvailable`
  checks only that *any* model is cached (pure and synchronous: no MainActor hop,
  so it is safe while the main runloop is pumped). The **slot-specific** model is
  resolved in `ensureLoaded` (which may await `Config`) and is reported by
  `HealthService`'s `local-models` component as the effective reflex/normal model.
  Documented at `Sources/Jarvis/Brain/Providers/MLXProvider.swift` (`isAvailable`).
