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
| C5 | Measure, don't guess (Zia) | DONE | this commit | build OK · 322/0 · self-test 1067/0/0 · `--chatgpt-bench` ran (capped) | `Jarvis --chatgpt-bench` (`ChatGPTBrainBenchmark`): ≤ 6 synthetic prompts per transport, engine route first, UI route only when health is READY and ChatGPT is not frontmost, whole run capped at 5 min with spacing, records success/first-chunk/total/transport, writes `build/chatgpt-brain-benchmark.md` (numbers first, recommendation separate) + `build/chatgpt-brain-benchmark.raw.txt`. `ChatGPTDesktopProvider.currentLatencyMs` is now the **rolling measured median** (`ChatGPTBrainLatency`), replacing the hard-coded 1200 ms. This run: no Agent Bridge key in the Keychain → 0 prompts sent (honest evidence; routing unchanged). Tests `ChatGPTBrainBenchmarkTests` (5). |
| C4 | Routing + user-visible provenance (Zia) | DONE | this commit | build OK · 317/0 · self-test 1067/0/0 · no `@State` | `ChatGPTBrainPolicy` + `HybridRoutingPolicy` feature flag (default ON, effective gate is the opt-in). Rules enforced in order: never scheduled/background, only user-present, never sensitive/highly-sensitive, never the extraction prompt, only deep reasoning, never past the daily cap, never quarantined, never while unavailable. `RoutingDecision` now records `availability` + `fallbackReason`; `ProviderManager` skips the deep tier with a logged reason and sets `ChatGPTBrainProvenance`; `DirectComposer` supplies a user-present context; the overlay shows “Answered by ChatGPT · engine/ui”. Tests `ChatGPTBrainPolicyTests` (15). Circuit breaker reuses existing quarantine (3 consecutive failures → 60 s); daily cap enforced by the policy and shown in Settings. |
| C3 | ChatGPT brain provider + settings (Zia) | DONE | this commit | build OK · 302/0 · self-test 1067/0/0 · no `@State` | Gate order before anything is sent: **opt-in (default OFF)** → Agent Bridge key → **DataClassifier** (sensitive/highly-sensitive fails closed to local) → **ContextSanitizer**. Deadlines: first token 15 s, total 60 s, then fall through with a reason. Availability uses the N1 tri-state (health + key + opt-in); the bridge's chosen transport is captured (`lastTransport`) as provenance. `ChatGPTBrain.swift` holds the off-main-readable flag + daily counter (soft cap 50). Settings card: switch, exact-reason status line, transport in use, requests-today. Tests `ChatGPTBrainSettingsTests` (7) + updated `ChatGPTBrainKeyTests` (4). |
| C2 | Headless engine as default transport (bridge) | DONE | bridge `dc2654b` | bridge `npm test` 354/346p/8s/0f | `/api/chatgpt/complete` accepts `transport` `auto`/`engine`/`ui` (default `auto`; engine when installed+healthy else UI) and always reports the answering transport. `chatgpt-local-engine.js`: new stateless `answer()` + hardened `executeTurn` — fresh EMPTY temp cwd, `--sandbox read-only`, `--ephemeral`, first-token + total timeouts, whole-process-group kill, buffered JSONL (malformed tolerated), text assembled from all `agent_message` events, usage reported. Tests `tests/chatgpt-local-engine.test.js` (9: success/malformed/crash/never-ends/no-output/cancel/concurrency/transport-resolution) using a fake codex executable. |
| C1 | ChatGPT endpoint security (bridge + Zia) | DONE | bridge `5a752db` · Zia this commit | bridge `npm test` 345/337p/8s/0f · Zia build OK · 295/0 · self-test 1067/0/0 · no `@State` | **Bridge:** `guardChatGPTRequest` on every `/api/chatgpt/*` route — loopback clients only, any browser `Origin` rejected (CSRF), loopback `Host` validated (DNS rebinding), and a **mandatory constant-time** control-plane key that fails closed (503) when unset; `tests/chatgpt-endpoint-security.test.js` (9). **Zia:** `KeychainManager.APIService.agentBridge` (`jarvis.agentbridge.api_key`), provider sends `x-api-key` and fails closed with the exact reason when absent; `Tests/JarvisTests/ChatGPTBrainKeyTests.swift` (4). Note: the bridge commit also lands the previously-uncommitted background-GPT endpoint worker it depends on (owner authorized continuing on top). |
| N1 | Verified provider availability (prerequisite) | DONE | this commit | build OK · 291/0 · self-test 1067/0/0 · no `@State` | `Sources/Jarvis/Brain/ProviderAvailability.swift` (tri-state `available`/`unverified`/`unavailable(reason)`, ~10-min cache, 5 s probe bound); every provider overrides `verifiedAvailability(probe:)` — key-only providers report `.unverified`, never `.available`; `ProviderManager.healthSnapshot` exposes `availability`/`isVerified`/`verifiedCount` (legacy `isAvailable` = "usable", documented); UI shows an **Unverified** state. Tests: `Tests/JarvisTests/ProviderAvailabilityTests.swift` (9). One environmental flake on the first self-test run (check 21.12 hashes the production `conversations.sqlite`); clean **1067/0/0** on re-run — N1 touches no conversation storage. |
| C0 | ChatGPT-brain recon (read-only) | DONE | this commit | build OK · 282/0 · bridge `npm test` 336/328p/8s/0f | `docs/CHATGPT_BRAIN.md` §1–2. Verified: endpoint is **unauthenticated by default** (`isAuthorized` returns true when no key; `REQUIRE_API_KEY` default false), wildcard CORS + no Origin/Host check; engine adapter spawns codex with **no cwd / no sandbox / `env: process.env`** and kills only the direct child; provider is first in every chain with no opt-in. `codex-cli 0.160.0`, logged in via ChatGPT. |

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
