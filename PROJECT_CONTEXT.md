# PROJECT_CONTEXT.md — Zia / JARVIS Engineering State & Canonical Handoff

> **Document Status:** CANONICAL REPOSITORY HANDOFF DOCUMENT  
> **Repository Path:** `/Users/jayanthpranaykonada/Zia`  
> **Generation Date:** 2026-09-29 (refreshed 2026-10-07)  
> **Target Audience:** Incoming Autonomous Coding Agents (Claude Opus, Gemini, Codex, Antigravity)  
> **Operational Rule:** **EVIDENCE > MEMORY > ASSUMPTION.** Every claim in this document is labeled with an explicit evidentiary verification status.

---

# CURRENT VERIFIED STATE

> **How to verify (run from the repository root).** Every claim below is
> reproducible with these five gate commands:
> ```bash
> swift build 2>&1 | tail -5
> swift test --skip ZiaVoicePipelineBenchmarkTests --skip VoiceTurnLifecycleRegressionTests 2>&1 | tail -5
> swift run Jarvis --self-test 2>&1 | tail -8
> grep -rn "@State\b" Sources/Jarvis/UI      # must print only documentation comments
> git status --short
> ```
> `swift test` and `swift run Jarvis --self-test` are **both** valid, both
> expected green, and neither substitutes for the other.

- **Date:** 2026-10-07 `[VERIFIED FROM CURRENT SESSION]`
- **Current HEAD Commit:** `77a5799` (`feat: introduce comprehensive design system and UI reference rendering harness`) `[VERIFIED: git rev-parse HEAD]`
- **Active Branch:** `master`, clean, level with `origin/master` `[VERIFIED: git status]`
- **Working Tree State:** Tracked tree is clean. Untracked diagnostic/evidence files preserved under `build/`. `[VERIFIED: git status --short]`

### CURRENT VERIFIED BASELINE
- **Native Swift test suite:** **254 tests / 38 suites, 0 failures** on the current Apple Silicon toolchain. `[VERIFIED BY TEST: swift test]`
- **In-process SelfTest suite:** **1067 passed / 0 failed / 0 skipped**. `[VERIFIED BY RUN: swift run Jarvis --self-test]`
- **Offline Replay Benchmark:** **15/15 passed** (structural repair of malformed shapes + deterministic compilation gates). `[VERIFIED FROM BENCHMARK: Sources/Jarvis/Core/PlannerRoutingBenchmark.swift:102-120]`
- **Live Routing Benchmark Matrix (30 runs across 10 cases + 5 rerun):**
  - Structural conformance: **30/30** (and **35/35** including rerun)
  - Semantic correctness: **30/30** on final run (and **35/35** including rerun)
  - Route classification: `directAnswer` 3/3, `deterministic` 6/6, `planner` 20/21 (rerun: 5/5), `escalation` 1/21 (rerun: 0/5)
  - Argument preservation on rerun: **5/5 byte-exact**
  - *Crucial Finding:* The shell benchmark cases (`ctrl-planner-shell`, `arg-spaces`, `arg-numbers`, `arg-punct`, `arg-unusual`) matched `PlannerExtraction.explicitShellEchoExtraction` and therefore ran via deterministic extraction with **0 model calls**. They must **NOT** be cited as evidence of general 0.5B model extraction capability. `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Agent/PlannerExtraction.swift:151-176, MLXPlanner.swift:562-578]`
- **Physical E2E Tool Verification (`write_file`):**
  - Genuinely exercised the local model extraction path (did NOT match `explicitShellEchoExtraction`).
  - 1 planner generation attempt, `parseFailed = false`, `validatorError = none`, `repair = false`.
  - Exact token `jarvis_e2e_k9w4t21790655668` preserved: `extracted == compiled == executed == preserved`.
  - Deterministic file re-read and byte-exact comparison passed at `build/jarvis-e2e-jarvis_e2e_k9w4t21790655668.txt`. `[VERIFIED BY PHYSICAL E2E: build/e2e-physical.txt, build/jarvis-e2e-jarvis_e2e_k9w4t21790655668.txt]`

### CURRENT PRODUCTION CONFIGURATION
- **Normal Production Model:** `qwen2.5-7b` (configured in `Config.shared.localNormalModel`, fallback default `"qwen2.5-7b"`) `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Core/Config.swift:193]`
- **Reflex Model:** `qwen2.5-3b` (configured in `Config.shared.localReflexModel`, fallback default `"qwen2.5-3b"`) `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Core/Config.swift:188]`
- **Autonomy Level:** `1` (Supervised: read-only and safe mutations authorized; destructive actions require Preview/Commit confirmation) `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Core/Config.swift:35]`
- **Local On-Device Planner Worker:** `mlx-community/Qwen2.5-0.5B-Instruct-4bit` on Apple Metal via persistent Python worker `mlx_worker.py` (used for bounded local planning and structured extraction) `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Brain/Workers/mlx_worker.py:8, MLXProvider.swift:51]`
- **Cloud/External Provider Strategy:**
  - `GroqProvider` is implemented (`https://api.groq.com/openai/v1/chat/completions`) as an optional low-latency external intelligence accelerator. Groq is **NOT** a mandatory dependency, **NOT** the deterministic execution authority, and its finite quota must **NEVER** become a hidden architectural dependency. Local models remain the persistent baseline. `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Brain/Providers/GroqProvider.swift]`
  - `OpenRouterProvider` is implemented (`https://openrouter.ai/api/v1/chat/completions`) and wired to `OpenRouterTierBProvider` for Milestone 3 escalation. `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Brain/Providers/OpenRouterProvider.swift, EscalationPipeline.swift:136-187]`

### CURRENT VERIFICATION & EXECUTION POLICIES
- **Post-Action Verification:** 5-state mechanical verification (`VerificationOutcome`: `.passed`, `.failed`, `.inconclusive`, `.unavailable`, `.notApplicable`). Only `.passed` counts as verified or referenceable. `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Brain/Tools/ToolDefinitions.swift:48-84]`
- **Silent Action Outcome Policy:** `AgentStepOutcomePolicy` accepts empty tool stdout **only** if the tool's deterministic verification outcome is `.passed` (e.g. `echo x > file` writes the file without stdout). Failed execution or failed verification strictly fails closed. `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Agent/AgentLoop.swift:6-12]`

### CURRENT MAJOR MILESTONES (ALL VERIFIED IN ROOT CHECKOUT)
1. **Milestone 1 — Live Desktop Ambient Context Binding:** `$ambient.current_app` captured from `NSWorkspace`, 300s freshness guard, safe-fail on unsupported slots.
2. **Milestone 2 — Deterministic Accessibility Bridge & Fast UI Mode:** `inspect_ui`, `click_element`, `set_text`, destructive keyword screening, sub-50ms AX inspection without vision models.
3. **Milestone 3 — Lossless Escalation Pipeline (Tier A → Tier B):** `EscalationPipeline`, `EscalationContext`, privacy gate (`DataClassifier`), `PlanValidator` post-escalation enforcement, state/reference continuity, emergency-stop integration.
4. **Milestone 4A — High-Reliability Deterministic Verification:** Active-tab observation, DOM snapshots, single-element extraction, link navigation verification, bounded text entry (`fill_browser_text`), exact read-back.
5. **Planner Decomposition & Direct-Answer Routing:** Router layer (L0 deterministic, L1 direct answer), recency safety net, bounded single-action extraction IR (`ExtractedAction`), deterministic compiler (`PlannerExtraction.compile`), byte-exact argument preservation recorder.

### KNOWN UNRESOLVED LIMITATIONS
- 0.5B model extraction is reliable **only on tightly bounded supported shapes**; arbitrary complex goals fall back to the legacy whole-plan generation path. `[VERIFIED FROM CODE/BENCHMARK]`
- Tier-B cloud escalation can occasionally produce unparseable or schema-invalid plans (e.g. `arg-unusual #2` substituted argument and took 53,202ms). `[VERIFIED FROM BENCHMARK: build/routing-benchmark-final.txt:176]`
- Escalation incurs substantial latency compared to local/deterministic paths. `[VERIFIED FROM BENCHMARK]`
- Emergency stop latency tests can be sensitive to host system load (latest test passed at 43.58ms against a 50ms bound). `[VERIFIED FROM SELFTEST]`
- Physical browser DOM automation in Safari requires the user to enable *"Allow JavaScript from Apple Events"* in Safari Developer settings. `[VERIFIED FROM CODE/DOCS]`
- Chrome active-tab automation was unverified on sign-in pages to prevent credential leakage. `[VERIFIED HISTORICAL]`
- Acoustic DSP wake-word engine remains deferred; wake detection relies on streaming `SFSpeechRecognizer` transcript matching. `[VERIFIED FROM CURRENT CODE]`
- `swift test` is currently executable on the installed Swift 6.4 toolchain and is the primary automated suite; `SelfTest` remains the broader in-process integration/physical capability runner. `[VERIFIED BY CURRENT SESSION]`
- Four to five shell benchmark cases in the routing matrix were handled by deterministic `explicitShellEchoExtraction` rather than model generation. `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Agent/PlannerExtraction.swift:151-176]`
- **Voice subsystem is implemented but hardware-unverified.** Mic → STT → agent → TTS code paths and their pure logic are covered by tests; the microphone currently reports exact-zero samples because macOS has not granted Microphone permission to the invoking process. Hardware verification is OWNER-ONLY (`docs/OWNER_CHECKLIST.md`). `[REPORTED, NOT VERIFIED ON HARDWARE]`
- **UI system** (presence HUD, main window, menu bar, 11 settings panes, onboarding, render harness) is documented in `docs/ZIA_UI_SYSTEM.md` and asserted by `ZiaDesignSystemTests`; live on-screen appearance is OWNER-ONLY. `[VERIFIED FROM TESTS + DOCS]`
- **ChatGPT Desktop provider** (`ChatGPTDesktopProvider`) is implemented as a local Agent-Bridge-backed brain using the user's already-authenticated ChatGPT Desktop; it is off unless the bridge is running. `[VERIFIED FROM CURRENT CODE]`

### CURRENT OPEN ENGINEERING QUESTION & PROPOSED NEXT WORK
- **Core Open Architectural Question:** *How should Zia combine deterministic routing, bounded extraction, local models (0.5B/3B/7B), and Groq efficiently while preserving safety, strictly adhering to the 9 Frozen Principles, and minimizing unnecessary model/API usage?*
- **Potential Next Decisions [PROPOSED / PENDING ARCHITECTURAL REVIEW]:**
  1. Systematic local-vs-Groq latency and reliability benchmark.
  2. Bounded extraction grammar expansion beyond single shell/file shapes.
  3. Dynamic routing policy design between local reflex, local planner, and external acceleration.
  *Note: No routing expansion or Groq coupling has been pre-selected; all options remain pending architectural review.*

---

## Table of Contents
1. [Section 1 — Project Identity](#section-1--project-identity)
2. [Section 2 — Frozen Architectural Principles](#section-2--frozen-architectural-principles)
3. [Section 3 — Complete Architecture & Execution Pipeline](#section-3--complete-architecture--execution-pipeline)
4. [Section 4 — Repository Map](#section-4--repository-map)
5. [Section 5 — Model, Intelligence & Provider Strategy](#section-5--model-intelligence--provider-strategy)
6. [Section 6 — Deterministic Mac Control](#section-6--deterministic-mac-control)
7. [Section 7 — Voice Subsystem](#section-7--voice-subsystem)
8. [Section 8 — Task State & Authoritative Lifecycle](#section-8--task-state--authoritative-lifecycle)
9. [Section 9 — Reference Resolution Subsystem](#section-9--reference-resolution-subsystem)
10. [Section 10 — Accessibility Subsystem & Fast UI Mode](#section-10--accessibility-subsystem--fast-ui-mode)
11. [Section 11 — Post-Action Verification & False-Success Defenses](#section-11--post-action-verification--false-success-defenses)
12. [Section 12 — Lossless Escalation Pipeline (Milestone 3)](#section-12--lossless-escalation-pipeline-milestone-3)
13. [Section 13 — Planner Subsystem & Bounded Extraction](#section-13--planner-subsystem--bounded-extraction)
14. [Section 14 — Empirical Experiments Archive (Experiments A & B)](#section-14--empirical-experiments-archive-experiments-a--b)
15. [Section 15 — Performance & Latency Telemetry](#section-15--performance--latency-telemetry)
16. [Section 16 — Testing Infrastructure & Inventories](#section-16--testing-infrastructure--inventories)
17. [Section 17 — Known Limitations & Operational Boundaries](#section-17--known-limitations--operational-boundaries)
18. [Section 18 — Explicitly Deferred Features & Out-of-Scope Items](#section-18--explicitly-deferred-features--out-of-scope-items)
19. [Section 19 — Git History, Key Commits & Branch State](#section-19--git-history-key-commits--branch-state)
20. [Section 20 — Evidence Artifacts & Archives](#section-20--evidence-artifacts--archives)
21. [Section 21 — Current Engineering Roadmap](#section-21--current-engineering-roadmap)
22. [Section 22 — Senior Agent Handoff Rules](#section-22--senior-agent-handoff-rules)
23. [Section 23 — Historical Milestones Archive](#section-23--historical-milestones-archive)

---

## Section 1 — Project Identity

- **Project Name:** Zia (internal codebase identifier: `Jarvis`, module name: `Jarvis`, package name: `zia`) `[VERIFIED FROM CURRENT CODE: Package.swift:5-6]`
- **Repository Path:** `/Users/jayanthpranaykonada/Zia` `[VERIFIED FROM CURRENT CODE]`
- **Mission & Vision:** An always-on, voice-and-text accessible, low-latency, deterministic, highly safe autonomous assistant for macOS. It bridges physical hardware perception (microphone, audio playback, screen capture) with deterministic OS automation and on-device/cloud multi-step agent planning.
- **Current Target Platform:** Apple Silicon macOS (minimum deployment target: macOS Sonoma 14.0, running on macOS 27.x / Darwin arm64) `[VERIFIED FROM CURRENT CODE: Package.swift:8]`
- **Toolchain & Build Environment:**
  - Swift 6.0 Language Mode (`swift-version 6`) with strict concurrency checking `[VERIFIED FROM CURRENT CODE: Package.swift:1]`
  - Host Toolchain: `/Library/Developer/CommandLineTools` (Xcode Command Line Tools only, **Xcode.app is NOT installed** on this host machine) `[VERIFIED BY PHYSICAL TEST: xcode-select -p]`
  - Compiler Flags: `BareSlashRegexLiterals`, `ConciseMagicFile`, `ForwardTrailingClosures`, `ExistentialAny` `[VERIFIED FROM CURRENT CODE: Package.swift:31-34]`
- **Primary Dependencies:**
  - `HotKey` (0.2.1): Global macOS keyboard shortcut registration `[VERIFIED FROM CURRENT CODE: Package.swift:15]`
  - `KeychainAccess` (4.2.2): macOS Keychain wrapper for secure cloud API key storage `[VERIFIED FROM CURRENT CODE: Package.swift:17]`
  - `mlx` / `mlx_lm`: Python virtual environment (`.venv-mlx` with Python 3.12) running a persistent worker process (`mlx_worker.py`) for on-device Apple Metal neural network inference `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Brain/Workers/mlx_worker.py]`
- **Build System:** Swift Package Manager (SPM). Build invocation: `swift build` or `./Scripts/build-app.sh debug|release`.
- **Test Strategy:** Native in-process `SelfTest` remains the broad integration runner, while `swift test` now executes the Swift Testing/XCTest suite on the current toolchain. Both are used; neither is treated as evidence for capabilities that were not physically exercised. `[VERIFIED BY CURRENT SESSION]`

---

## Section 2 — Frozen Architectural Principles

These 9 operational principles are frozen and must never be violated in any implementation:

1. **Intelligence Never Equals Authority** `[VERIFIED FROM CURRENT CODE: PermissionGate.swift, CommandSandbox.swift, PlanValidator.swift]`
   - A model (whether 0.5B local or 400B cloud) is an untrusted text-generator. It proposes steps or plans; it NEVER has direct execution authority.
   - Authority resides exclusively in deterministic gatekeepers: `CommandSandbox`, `PermissionGate`, and `DestructiveActionManager`.
2. **Fail Open to Intelligence, Not Authority** `[VERIFIED FROM CURRENT CODE: PermissionGate.swift:53-56]`
   - If an LLM fails, crashes, hallucinates, or returns invalid syntax, the system safely degrades or asks the user.
   - If a permission check or sandbox validation is ambiguous, it MUST FAIL CLOSED. It never defaults to permitting an action.
3. **State Over Transcript** `[VERIFIED FROM CURRENT CODE: TaskStateMachine.swift:153-166, ReferenceResolver.swift:42-66]`
   - The ground truth of any task is its explicit typed state machine (`TaskState`, `TaskStep.verification`, `currentStepIndex`, `StepResolutionRecord`), never an LLM's conversational chat history or narrative claims.
4. **Cheapest Sufficient Intelligence** `[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift, IntentClassifier.swift, DirectAnswerRouter.swift]`
   - Hierarchy: 0 model calls (deterministic matchers) > local small reflex model (3B) > local planner (0.5B/3B/7B) > cloud provider (Groq/Claude/OpenAI).
   - If a request can be executed deterministically via regex/intent matching (e.g. "what time is it", "open Safari", "set volume to 40"), it routes with 0 model calls and < 1ms latency.
5. **Lossless Escalation** `[VERIFIED FROM CURRENT CODE: EscalationPipeline.swift, ProviderManager.swift, AgentLoop.swift]`
   - When a lower-tier model or local recovery fails, the complete context, previous error traces, completed steps, verified outputs, and exact validator rejections are preserved losslessly as structured input to the next escalation tier.
6. **Commit Points Gate Irreversibility** `[VERIFIED FROM CURRENT CODE: DestructiveActionManager.swift]`
   - Destructive, non-undoable operations (e.g. `system.sleep`, `rm -rf`, emptying trash) MUST require a two-phase `PREVIEW -> COMMIT` protocol with an explicit 60-second expiration window. Spoken single-shot commands can only generate previews.
7. **Evidence Before Green** `[VERIFIED FROM CURRENT CODE: ToolDefinitions.swift:48-84, SelfTest.swift]`
   - No task, step, or PR is considered green or completed based on assertion of intent. Success requires deterministic physical or mechanical postcondition verification (`VerificationOutcome.passed`).
8. **Zero-Model-Call Coverage Should Increase** `[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift:18-23, PlannerExtraction.swift:151-176]`
   - Engineering effort should continually expand deterministic, zero-model-call routing to cover more common macOS actions.
9. **Fast Interaction Loop Must Never Wait for Deep Task Execution** `[VERIFIED FROM CURRENT CODE: AgentLoop.swift:34-45]`
   - Voice responses, UI animations, HUD feedback, and Emergency Stop monitors run asynchronously and concurrently off long-running execution workers. The main UI thread never blocks on tool execution.

---

## Section 3 — Complete Architecture & Execution Pipeline

### Execution Pipeline Flow

```
[ User Input (Voice / HotKey / Text) ]
           │
           ▼
[ SENSE ] ──────────────────────────────────────────┐
  AudioCapture / SFSpeechRecognizer / FloatingPanel  │
           │                                        │
           ▼                                        │
[ L0: Deterministic Router ]                        │
  Matches known regex / prefixes?                   │
  ├── YES ──► Fast Path Execution (< 1ms, 0 models) ┘
  └── NO
       │
       ▼
[ L1: Small Intent Classification & Direct Answer ]
  DirectAnswerRouter / IntentClassifier (Reflex slot: Qwen2.5-3B)
  ├── Static Fact / Chit-Chat ──► Fast Direct Answer (No Planner)
  ├── Recency Fact ("current", "today's") ──► Forces Tool/Web Path
  └── Action / Complex Goal
       │
       ▼
[ L2: Agent Loop Engagement ]
  TaskStateMachine registers task (state = CREATED)
  Captures live TaskEnvironmentContext (frontmost app from NSWorkspace)
       │
       ▼
[ Planning Phase (PLANNING) ]
  Bounded Single-Action Extraction OR Whole-Plan Generation
  (Local MLX Qwen2.5-0.5B-4bit on Metal)
  ├── Single-line explicit echo: PlannerExtraction.explicitShellEchoExtraction (0 model calls)
  ├── Supported single-action goal: Bounded prompt emits {"tool": ..., "arguments": ..., "literal": ...}
  └── Arbitrary multi-step goal: Legacy whole-plan AgentPlan JSON
       │
       ▼
[ Deterministic Compiler & Validator ]
  PlannerExtraction.compile produces PlanStep / AgentPlan
  PlanValidator checks:
  - Valid JSON extraction & schema conformance
  - Registered tools only (in live ToolRegistry)
  - Required arguments present & correct scalar types
  - No smuggled/undeclared arguments
  - DAG reference validation ($step.M references M < currentStep)
  - CommandSandbox safety check (deferred if reference tokens present)
  ├── Validation Failure ──► Tier-A Repair (bounded to 1 attempt)
  ├── Tier-A Exhausted ──► EscalationPipeline (Milestone 3 Lossless Escalation)
  └── Passes Validation
       │
       ▼
[ Permission & Authority Check ]
  PermissionGate checks AutonomyLevel (L0, L1, L2, L3)
  ├── Destructive (keywords / verbs) ──► DestructiveActionManager (PREVIEW -> COMMIT)
  └── Authorized
       │
       ▼
[ Pre-Execution Reference Resolution ]
  ReferenceResolver resolves $step.<N>.output, $step.<N>.<field>, $ambient.<slot>
  CommandSandbox & PermissionGate evaluate concrete resolved command
       │
       ▼
[ Execution Phase (RUNNING) ]
  TaskWorkerPool executes tool via ToolExecutor
  (BuiltinTools / AccessibilityTools / ShellExecutor / FileManager / SystemControl)
       │
       ▼
[ Observation & Verification (VERIFYING) ]
  Tool observes deterministic state mutation (NSWorkspace, AX readback, file check, URL check)
  ToolVerificationResult evaluates outcome:
  - .passed: Mechanically confirmed side effect
  - .failed / .inconclusive / .unavailable: Non-passing outcome
  AgentStepOutcomePolicy: empty output accepted only if outcome == .passed
  StepResolutionRecord saved to TaskStateMachine (only .passed is referenceable)
       │
       ▼
[ Task State Update ]
  TaskStateMachine updates progress and step verification
  ├── Step Failed ──► Replan / Recovery / Escalation
  ├── More steps ──► Loop next step
  └── All steps complete & verified ──► State = COMPLETED
```

### Complete Recovery Escalation Ladder
1. **Cheap Retry:** Immediate re-attempt if transient I/O glitch.
2. **Tier-A Repair:** Feed exact validator error string + live tool schema back to `MLXPlanner` (bounded to 1 repair attempt).
3. **Tier-A Replan:** Prunes invalid steps and preserves valid prior observations; limited by `maxRetries` (default 3).
4. **Tier-B Lossless Escalation:** Pass full structured task IR, completed steps, verified outputs, failure reasons, and privacy sensitivity to `EscalationPipeline` (OpenRouter or designated Tier-B provider).
5. **Fail-Closed / User Clarification:** If budgets, retries, or escalation exhaust, report actionable diagnostic failure to user.

---

## Section 4 — Repository Map

```
/Users/jayanthpranaykonada/Zia/
├── Package.swift                    # SPM manifest (Swift 6 mode, macOS 14+, HotKey, KeychainAccess)
├── PROJECT_CONTEXT.md               # [THIS FILE] Canonical repository handoff & engineering state
├── Sources/
│   └── Jarvis/
│       ├── Actions/
│       │   ├── ActionEngine.swift             # Central executor routing actions to subsystems
│       │   ├── DeterministicRouter.swift      # L0 regex/prefix router for instant macOS actions
│       │   ├── PermissionGate.swift           # Autonomy level enforcement (L0-L3)
│       │   ├── Automation/
│       │   │   └── AppleScriptBridge.swift    # Sandboxed AppleScript execution with timeout
│       │   ├── Browser/
│       │   │   └── BrowserManager.swift       # Safari, Chrome, Arc, Brave automation
│       │   ├── System/
│       │   │   ├── AppLauncher.swift          # NSWorkspace app launch / quit
│       │   │   ├── ClipboardManager.swift     # NSPasteboard read/write/clear
│       │   │   ├── DestructiveActionManager.swift # Two-phase PREVIEW->COMMIT manager (Principle 6)
│       │   │   ├── FileManagerJarvis.swift    # Safe sandboxed file operations in ~
│       │   │   ├── NotificationSender.swift   # macOS UserNotifications
│       │   │   └── SystemControl.swift        # Volume, brightness, lock, sleep, screenshot
│       │   ├── Terminal/
│       │   │   ├── CommandSandbox.swift       # Shell command blocklist and validation
│       │   │   └── ShellExecutor.swift        # Process-group isolated async shell executor
│       │   └── Web/
│       │       ├── SourceManager.swift        # Citation tracker and URL deduplicator
│       │       ├── URLFetcher.swift           # Asynchronous web page scraper
│       │       └── WebSearch.swift            # Web search provider integration
│       ├── Agent/
│       │   ├── AgentLoop.swift                # Autonomous orchestration loop & StepOutcomePolicy
│       │   ├── DirectAnswerRouter.swift       # Direct answer classification & recency gating
│       │   ├── DirectComposer.swift           # Tool-null step composer
│       │   ├── EscalationPipeline.swift       # Milestone 3 lossless escalation to Tier B
│       │   ├── MLXPlanner.swift               # Local MLX planner with ledger & extraction wiring
│       │   ├── PlanNormalizerB.swift          # Experiment B single-shape normalizer (disabled in prod)
│       │   ├── PlannerExtraction.swift        # Bounded extraction IR, parser, repair, compiler
│       │   ├── PlanValidator.swift            # Deterministic schema, reference & sandbox validator
│       │   ├── ReferenceResolver.swift        # Milestone 1 & 8 typed reference parser and resolver
│       │   ├── TaskStateMachine.swift         # Thread-safe task lifecycle state machine
│       │   ├── TaskWorker.swift               # Worker unit executing single tool steps
│       │   └── TaskWorkerPool.swift           # GCD queue worker pool with M4 concurrency limits
│       ├── App/
│       │   ├── AppDelegate.swift              # App lifecycle and menu bar wiring
│       │   ├── AppState.swift                 # Global state machine: OFF, SLEEP, ACTIVE
│       │   └── JarvisApp.swift                # App entry point (supports --self-test, --goal, etc.)
│       ├── Brain/
│       │   ├── BrainRouter.swift              # Model router based on task domain
│       │   ├── IntentClassifier.swift         # Classifies intent into domains (.coding, .web, etc.)
│       │   ├── ProviderManager.swift          # Manages provider registry & fallback chains
│       │   ├── UsageManager.swift             # Token budget and USD spend tracker
│       │   ├── Conversation/
│       │   │   ├── ContextBuilder.swift       # Builds context window with system prompt
│       │   │   ├── ConversationManager.swift  # Manages active conversation sessions
│       │   │   └── Message.swift              # Chat message model
│       │   ├── Providers/
│       │   │   ├── ClaudeProvider.swift       # Anthropic Claude API provider
│       │   │   ├── GeminiProvider.swift       # Google Gemini API provider
│       │   │   ├── GroqProvider.swift         # Groq API provider (external speed accelerator)
│       │   │   ├── MLXProvider.swift          # Local Python MLX worker bridge (Apple Metal)
│       │   │   ├── OpenAIProvider.swift       # OpenAI API provider
│       │   │   ├── OpenRouterProvider.swift   # OpenRouter multi-model provider
│       │   │   └── Provider.swift             # LLMProvider protocol & capability matrix
│       │   ├── Tools/
│       │   │   ├── AccessibilityTools.swift   # inspect_ui, click_element, set_text
│       │   │   ├── BuiltinTools.swift         # run_shell, open_app, write_file, browser DOM tools
│       │   │   ├── ToolDefinitions.swift      # ToolVerificationResult, ObservationResult, specs
│       │   │   ├── ToolExecutor.swift         # Dynamic tool execution dispatcher & verification
│       │   │   └── ToolRegistry.swift         # Central registry of available tools
│       │   └── Workers/
│       │       └── mlx_worker.py              # Persistent Python MLX inference daemon
│       ├── Core/
│       │   ├── Config.swift                   # Persistent configuration (autonomy, model slots)
│       │   ├── DataClassifier.swift           # PII and credential privacy detector
│       │   ├── Errors.swift                   # Typed JarvisError enum
│       │   ├── EscalationAudit.swift          # Milestone 3 escalation test assertions
│       │   ├── EventBus.swift                 # Publish-subscribe decoupled event bus
│       │   ├── Events.swift                   # Typed event declarations (EmergencyStop, etc.)
│       │   ├── HotkeyManager.swift            # Global hotkey binding
│       │   ├── IntegrationAudit.swift         # System integration verification suite
│       │   ├── KeychainManager.swift          # macOS Keychain CRUD
│       │   ├── LockedValue.swift              # Thread-safe @unchecked Sendable NSLock box
│       │   ├── Logger.swift                   # os.Logger logging categories
│       │   ├── NetworkMonitor.swift           # NWPathMonitor network reachability
│       │   ├── PhysicalDemonstration.swift    # Physical verification test harness
│       │   ├── PipelineTimer.swift            # Latency and telemetry stage timer
│       │   ├── PlannerRoutingBenchmark.swift  # 10-case live and offline routing benchmark
│       │   ├── ResourceManager.swift          # Memory pressure monitor & model eviction
│       │   ├── SchemaExperiment.swift         # Schema contract experiment harness (D-A to D-F)
│       │   ├── SelfTest.swift                 # Canonical test suite (624 deterministic tests)
│       │   └── SequentialExperiment.swift     # Experiment A harness (B1-B5 multi-step benchmarks)
│       ├── Memory/
│       │   ├── ConversationStore.swift        # SQLite persistent chat history
│       │   ├── EmbeddingEngine.swift          # Local embedding generation via Accelerate vDSP
│       │   ├── MemoryManager.swift            # Context retrieval orchestrator
│       │   ├── UserProfile.swift              # User preferences and persistent facts
│       │   └── VectorSearch.swift             # Cosine similarity vector search
│       ├── UI/
│       │   ├── MenuBar/                       # MenuBarManager & status item view
│       │   ├── Overlay/                       # FloatingPanel HUD, WaveformView, ResponseBubble
│       │   ├── Settings/                      # APIKeysView and SettingsView
│       │   └── Theme/                         # DesignTokens (24pt corner radius, spacing, glassmorphism)
│       ├── Vision/
│       │   ├── AccessibilityBridge.swift      # AXUIElement desktop inspection
│       │   ├── DeepVisualMode.swift           # Multimodal vision pipeline
│       │   ├── FastUIMode.swift               # Lightweight UI element extraction
│       │   └── ScreenCapture.swift            # ScreenCaptureKit display capture
│       └── Voice/
│           ├── AudioCapture.swift             # AVAudioEngine 16kHz PCM capture
│           ├── AudioPlayer.swift              # AVAudioPlayer audio playback
│           ├── EmergencyInterrupt.swift       # Real-time spoken safety monitor & event publisher
│           ├── SpeechRecognizer.swift         # SFSpeechRecognizer on-device transcription
│           ├── TTSEngine.swift                # AVSpeechSynthesizer TTS
│           ├── VoiceActivityDetector.swift    # Energy-based speech activity detector
│           ├── VoicePipeline.swift            # Full audio capture -> STT -> Agent -> TTS pipeline
│           ├── VoiceTraceState.swift          # Latency instrumentation for voice pipeline
│           └── WakeWordDetector.swift         # Spoken wake-alias detector ("Jarvis", "Zia")
├── Tests/
│   └── JarvisTests/
│       ├── AppStateTests.swift                # Unit tests for state transitions (XCTest)
│       ├── EventBusTests.swift                # Unit tests for EventBus (XCTest)
│       ├── PipelineTimerTests.swift           # Unit tests for timer telemetry (XCTest)
│       ├── PlanNormalizerBTests.swift         # Unit tests for normalizer B (XCTest)
│       ├── SequentialLifecycleTests.swift     # Unit tests for Bug A/B sequential fixes (XCTest)
│       └── ShellExecutorTests.swift           # Unit tests for ShellExecutor lifecycle (XCTest)
└── Scripts/
    ├── build-app.sh                           # Assembles build/Jarvis.app bundle with Info.plist
    ├── package_app.sh                         # Package helper script
    └── setup.sh                               # Environment setup script
```

---

## Section 5 — Model, Intelligence & Provider Strategy

`[VERIFIED FROM CURRENT CODE: Config.swift, ProviderManager.swift, MLXProvider.swift, GroqProvider.swift, OpenRouterProvider.swift]`

### Intended Intelligence Philosophy
```
Deterministic Matchers (0 model calls, < 1ms)
            │
            ▼ (non-deterministic)
Cheapest Sufficient Local Intelligence (Qwen2.5-3B reflex / 0.5B MLX bounded planner)
            │
            ▼ (complex reasoning / general tasks)
Stronger Local Intelligence (Qwen2.5-7B normal production model)
            │
            ▼ (when justified by complexity / speed / failure)
External / Cloud Escalation (Groq for ultra-low latency, OpenRouter/Claude/OpenAI for Tier B)
            │
            ▼ (if offline or quota exhausted)
Graceful Local Fallback (return to local intelligence, never fail open)
```

### Component Model Assignments
| Component / Role | Config Slot | Assigned Model | Provider / Execution Medium | Status |
|---|---|---|---|---|
| Intent Classifier & Fast Reflex | `reflex` | `qwen2.5-3b` | Local on-device MLX | Verified default in `Config.swift:188` |
| General Queries & Chit-Chat | `normal` | `qwen2.5-7b` | Local on-device MLX | Verified default in `Config.swift:193` |
| Bounded Planning & Extraction | In-process | `mlx-community/Qwen2.5-0.5B-Instruct-4bit` | Local Metal via persistent `mlx_worker.py` | Verified in `mlx_worker.py:8`, `MLXPlanner.swift:8` |
| Low-Latency Speed Acceleration | `speed` | `llama-3.3-70b-versatile` | `GroqProvider` (`api.groq.com`) | Implemented provider, optional accelerator |
| Deep Reasoning / Tier-B Escalation | `deep` / `openrouter` | `nvidia/nemotron-3-ultra-550b-a55b:free` or Anthropic Claude | `OpenRouterProvider` / `ClaudeProvider` | Implemented in `EscalationPipeline.swift` |
| Vision / Multimodal Understanding | `vision` | Configurable | `GeminiProvider` / `ClaudeProvider` | Implemented provider slot |
| Desktop-assisted generation (no API key) | `chatgptDesktop` | via ChatGPT Desktop app | `ChatGPTDesktopProvider` (local Agent Bridge, `127.0.0.1:8765`) | Implemented provider; off unless the bridge runs |

### Groq Architectural Positioning
- **What Groq Is:** An external, high-throughput cloud provider (`GroqProvider.swift`) accessing LPUs at ~300 tokens/sec.
- **What Groq Is NOT:**
  - Groq is **NOT** the deterministic execution authority (Principle 1).
  - Groq is **NOT** a required architectural dependency. Zia must boot, route, validate, and execute fully offline without Groq.
  - Groq's finite quota must **NEVER** become a hidden architectural bottleneck.
- **Local Fallback Invariant:** If Groq is unreachable, offline, or returns HTTP 429/5xx, execution must cleanly fall back to local models or return an explicit user error.
- **Benchmark Status:** Local Qwen 7B and Groq latencies have **not yet been benchmarked on the current production configuration**. Any proposed local-vs-Groq routing threshold is marked `[PROPOSED / NOT YET BENCHMARKED]`.

---

## Section 6 — Deterministic Mac Control

`[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift, SystemControl.swift, SelfTest.swift:202-237]`

The system implements 11 high-reliability, zero-model-call native controls executing in < 1ms:

| Action Intent | Example Utterance | Impact Level | Verification Mechanism | SelfTest Verified |
|---|---|---|---|---|
| `app.open` | "open Safari" | `.safeMutation` | `NSWorkspace.shared.runningApplications` check | ✅ Yes |
| `app.quit` | "quit Notes", "close Notes" | `.safeMutation` | Running process absence confirmation | ✅ Yes |
| `app.switch` | "bring Safari to front", "focus Notes" | `.safeMutation` | `NSRunningApplication.activate(options:)` | ✅ Yes |
| `system.volume.set` / `.up` / `.down` / `.get` | "set volume to 45", "volume down", "what is the volume" | `.safeMutation` / `.readOnly` | CoreAudio volume level readback (0–100%) | ✅ Yes |
| `system.brightness.set` / `.up` / `.down` / `.get` | "set brightness to 60", "dim screen", "what is the brightness" | `.safeMutation` / `.readOnly` | `DisplayServicesGetBrightness` physical check | ✅ Yes |
| `clipboard.read` / `.write` / `.clear` | "what's on my clipboard", "copy hello to clipboard", "clear clipboard" | `.readOnly` / `.safeMutation` | `NSPasteboard.general` read/write roundtrip | ✅ Yes |
| `folder.open` / `folder.list` | "open downloads", "list desktop", "show documents files" | `.safeMutation` / `.readOnly` | FileManager directory listing / NSWorkspace open | ✅ Yes |
| `system.screenshot` | "take a screenshot", "capture screen" | `.readOnly` | File generation & non-zero byte size verification | ✅ Yes |
| `system.lock` | "lock mac", "lock screen" | `.safeMutation` | `SACLockScreenImmediate` call | ✅ Yes |
| `system.sleep` | "sleep mac", "put mac to sleep" | `.destructive` | Two-phase PREVIEW -> COMMIT protocol (`DestructiveActionManager`) | ✅ Yes (dry-run) |
| `shell.echo` | "echo hello", "run echo hello" | `.safeMutation` | ShellExecutor stdout capture (guarded against compound commands) | ✅ Yes |

### Compound-Command Routing Hardening
`[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift:188-218, SelfTest.swift:1535-1542]`
- Compound requests containing `echo` (such as `"echo recovery_started, then use audit_failing_tool, then echo recovery_completed"`) are rejected by the fast echo path and routed to `MLXPlanner`.
- Strict compound guards reject any goal containing `, then`, `;`, `&&`, `|`, or shell metacharacters from deterministic bypass.

---

## Section 7 — Voice Subsystem

`[VERIFIED FROM CURRENT CODE: AudioCapture.swift, SpeechRecognizer.swift, WakeWordDetector.swift, EmergencyInterrupt.swift, VoicePipeline.swift]`

- **Microphone Capture:** `AudioCapture.swift` uses `AVAudioEngine` tapping the input node with 16kHz, mono 16-bit PCM format.
- **Speech Recognition:** `SpeechRecognizer.swift` utilizes Apple's `SFSpeechRecognizer` configured with `requiresOnDeviceRecognition = true` for zero-cloud, offline processing.
- **Wake Word Detection (`WakeWordDetector.swift`):**
  - **IMPLEMENTED:** Transcript wake-alias spotting operating on partial and final transcripts from `SFSpeechRecognizer`. Matches configured aliases: `"Jarvis"`, `"Zia"`, `"Ziya"`. Supports conversational prefixes: `"hey"`, `"hi"`, `"hello"`, `"ok"`, `"okay"`, `"please"`, `"yo"`.
  - **DEFERRED:** Acoustic DSP wake-word engine (e.g. Porcupine, openWakeWord, or CoreML micro-model on raw audio buffers).
- **Text-to-Speech:** `TTSEngine.swift` wraps `AVSpeechSynthesizer` with rate `0.52`, pitch `1.0`, and neural voices.
- **Barge-In / Emergency Voice Stop:** If speaking when a wake word or emergency phrase is uttered, `AudioPlayer` and `TTSEngine` stop immediately (< 50ms).
- **Authoritative Agent Routing (`ae8b0ca`):** Non-deterministic voice requests enter `AgentLoop.run(goal:)`, the same authoritative path used by the text overlay, removing the prior provider-only `BrainRouter` bypass for spoken requests.

---

## Section 8 — Task State & Authoritative Lifecycle

`[VERIFIED FROM CURRENT CODE: TaskStateMachine.swift:1-320]`

The authoritative `JarvisTask` and `TaskStep` structures hold:
- `id: UUID`, `title: String`, `goal: String`
- `state: TaskState` (`CREATED`, `PLANNING`, `RUNNING`, `VERIFYING`, `COMPLETED`, `FAILED`, `RECOVERING`, `REPLANNING`, `CANCELLED`)
- `steps: [TaskStep]` (`id`, `stepNumber`, `description`, `toolName`, `arguments: [String: String]`, `state`, `output`, `error`, `verification: VerificationOutcome?`)
- `resolutionRecords: [StepResolutionRecord]` (structured records of verified step outputs)
- `environmentContext: TaskEnvironmentContext?` (snapshot of frontmost app and ambient state)
- `currentStepIndex: Int`, `maxRetries: Int`, `retryCount: Int`
- `createdAt: Date`, `updatedAt: Date`, `completedAt: Date?`, `error: String?`

### Task State Transition Invariants
- `CREATED` $\rightarrow$ `PLANNING`, `RUNNING`, `CANCELLED`
- `PLANNING` $\rightarrow$ `RUNNING`, `FAILED`, `CANCELLED`
- `RUNNING` $\rightarrow$ `VERIFYING`, `FAILED`, `CANCELLED`
- `VERIFYING` $\rightarrow$ `COMPLETED`, `FAILED`, `RUNNING`, `CANCELLED`
- `FAILED` $\rightarrow$ `RECOVERING`, `CANCELLED`
- `RECOVERING` $\rightarrow$ `REPLANNING`, `FAILED`, `CANCELLED`
- `REPLANNING` $\rightarrow$ `RUNNING`, `FAILED`, `CANCELLED`
- `COMPLETED` and `CANCELLED` are terminal states.
- **Bug A Fix [VERIFIED]:** Recovery transition table guarantees `REPLANNING -> RUNNING` before verifying, preventing invalid `REPLANNING -> VERIFYING` transitions.
- **Bug B Fix [VERIFIED]:** `COMPLETED` is reachable **only if** `!steps.isEmpty && steps.allSatisfy { $0.verification == .passed }`. Zero-step or unverified tasks strictly fail closed.

---

## Section 9 — Reference Resolution Subsystem

`[VERIFIED FROM CURRENT CODE: ReferenceResolver.swift, AgentLoop.swift:316,667, PlanValidator.swift:370-385, SelfTest.swift:1700-1940]`

- **Status:** **FULLY IMPLEMENTED & CANONICALLY VERIFIED (Phase 15, 25/25 Tests Passing).**
  *(Any older note claiming Reference Resolution is absent was true only prior to commit `9971809` and is strictly historical).*

### Grammar & Token Specification
- `$step.<N>.output` or `$step.<N>`: Full raw string output of prior step $N$.
- `$step.<N>.<field>`: Deterministic JSON key extraction from step $N$'s structured output.
- `$ambient.<slot>`: Environmental slot snapshot.
  - `$ambient.current_app`: Authoritative live frontmost application name via `NSWorkspace.shared.frontmostApplication?.localizedName`. Volatile age threshold is 300.0s (5 minutes). Stale snapshots throw `staleAmbientSlot`.
  - Remaining slots (`current_file`, `current_webpage`, `current_selection`, `last_search_results`, `last_artifact`, `pending_confirmation`) deterministically throw `ambientSlotUnavailable(slot)`.
- **Literal Dollar Preservation:** Non-reference strings (e.g. `"$100"`, `"$HOME"`, `"costs $5.00"`) remain `.literal` strings and are never corrupted.
- **Template / Embedded References:** Commands like `echo $step.1.output` or `cat $step.1.url` are parsed as `.template` containing identified `ReferenceTokenMatch` items.

### Invariants & Validation Rules
1. **DAG Ordering:** Step $N$ can only reference Step $M$ where $M < N$. Forward references ($M > N$) and self-references ($M == N$) are rejected at both plan-validation time and resolution time.
2. **Pre-Execution Concrete Resolution:** Arguments are resolved **immediately before execution** in `AgentLoop.swift`.
3. **Authority Evaluates Resolved Command:** `PermissionGate` and `CommandSandbox.shared.isSafe` evaluate the **concrete, resolved command** (e.g. `cat /etc/passwd`, NOT `cat $step.1.output`).
4. **Verified Outputs Only:** Prior step outputs are addressable **ONLY IF** `verification == .passed`. Steps with `.failed`, `.inconclusive`, or `.unavailable` deterministically block resolution.

---

## Section 10 — Accessibility Subsystem & Fast UI Mode

`[VERIFIED FROM CURRENT CODE: AccessibilityBridge.swift, FastUIMode.swift, AccessibilityTools.swift, ToolRegistry.swift, SelfTest.swift:2030-2200]`

- **Status:** **IMPLEMENTED & VERIFIED (Phase 17 Suite, 29/29 Tests Passing).**
- **Architecture:** Provides deterministic AX interactions for the frontmost application without requiring vision models, OCR, or screenshots.

### Registered Tools
1. `inspect_ui` (`InspectUITool`):
   - Impact: `.readOnly` (L0 Authorized).
   - Inspects and lists actionable UI hierarchy (buttons, text fields, menu items) via `FastUIMode.shared.describeCurrentUI()`.
   - Supports optional `filter` argument for targeted substring matching.
2. `click_element` (`ClickElementTool`):
   - Impact: `.safeMutation` (L1 Authorized) by default.
   - **Destructive Verb Screening:** If `element_label` matches destructive keywords (`delete`, `erase`, `format`, `empty trash`, `shut down`, `restart`, `wipe`, `uninstall`, `drop table`, `remove all`), impact is dynamically upgraded to `.destructive`. At L1 Supervised, `PermissionGate` blocks execution unless authorized via `DestructiveActionManager`.
   - Declared postconditions: `expected_app`, `expected_element_exists`, `expected_element_disappears`, `expected_focused`.
   - Post-action verification: Re-inspects AX state. A bare `AXPress` without an observed postcondition returns `.inconclusive`.
3. `set_text` (`SetTextTool`):
   - Impact: `.safeMutation` (L1 Authorized).
   - Enters text into editable or focused field via `FastUIMode.shared.setText`.
   - Post-action verification: Performs fresh AX target resolution and exact post-mutation value read-back. Observed field mismatch returns `.failed`; missing handle returns `.unavailable`.

### Operational Boundaries
- Physical UI automation requires macOS Accessibility trust (`AXIsProcessTrusted()`). If untrusted, tools return explicit `unavailable` errors.
- Broad, arbitrary UI automation across background apps is **NOT** supported; actions are bounded to frontmost application elements.

---

## Section 11 — Post-Action Verification & False-Success Defenses

`[VERIFIED FROM CURRENT CODE: ToolDefinitions.swift:48-84, AgentLoop.swift:6-12, SelfTest.swift:2520-2720]`

- **Status:** **IMPLEMENTED & VERIFIED (Milestone 4A, Phase 19 Suite).**
- **Core Principle:** Execution success (`ToolResult.success == true`) alone **never** marks a step verified. Verification requires mechanical post-action observation.

### 5-State Verification Model (`VerificationOutcome`)
- `.passed`: Observed postcondition matches expected state. The step is verified and output is referenceable.
- `.failed`: Observed state contradicts expected state (e.g. wrong frontmost app, wrong field text, file missing).
- `.inconclusive`: Action executed, but no deterministic postcondition was declared to verify state mutation (e.g. bare click).
- `.unavailable`: Observation mechanism was unreachable (e.g. Accessibility permission denied, browser AppleScript blocked).
- `.notApplicable`: Read-only action with no side effects.

### Verified Silent Action Fix (`AgentStepOutcomePolicy`, Commit `fd4bf87`)
- **Problem Fixed:** Previously, `AgentLoop` treated any empty stdout as a step failure. Redirecting commands (`echo hello > file.txt`) legitimately write artifacts and produce zero stdout, which triggered spurious replanning loops despite successful exit codes and file creation.
- **Current Policy:**
  ```swift
  enum AgentStepOutcomePolicy {
      static func accepts(_ result: ToolResult) -> Bool {
          guard result.success else { return false }
          let hasOutput = !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          return hasOutput || result.verification?.outcome == .passed
      }
  }
  ```
  Both whole-plan and sequential execution modes use this policy. An action with empty output is accepted **only** if its mechanical verification passed. Failed execution or non-passing verification strictly fails closed.

---

## Section 12 — Lossless Escalation Pipeline (Milestone 3)

`[VERIFIED FROM CURRENT CODE: EscalationPipeline.swift, EscalationAudit.swift, AgentLoop.swift, SelfTest.swift:2330-2520]`

- **Status:** **IMPLEMENTED & VERIFIED (Phase 18 Suite, 15/15 Tests Passing).**
- **Mission:** When Tier A (0.5B local planner) exhausts repairs or replanning, execution escalates losslessly to Tier B without restarting from unstructured chat logs.

### Escalation Context Schema (`EscalationContext`)
Transfers authoritative structured state:
- `taskId: UUID`, `originalGoal: String` (byte-for-byte preserved)
- `currentStepNumber: Int`, `completedSteps: [TaskStep]`, `verifiedOutputs: [Int: String]`
- `failedStep: TaskStep?`, `failureReason: String?`, `priorObservations: [String]`
- `environmentContext: TaskEnvironmentContext?`
- `sensitivity: DataClassifier.SensitivityLevel`
- `triggerReason: TriggerReason` (`tierAPlanningExhausted`, `tierARecoveryExhausted`, `executionFailureReplanning`)
- `attemptCount: Int`, `escalationTimestamp: Date`

### Invariants & Defenses
1. **Deterministic Privacy Gate:** Evaluated synchronously before any cloud provider is contacted. If `sensitivity` is `.sensitive` or `.highlySensitive`, cloud escalation is refused with `JarvisError.privacyPolicyViolation`.
2. **Authority Boundary (Principle 1):** Every escalated plan must strictly pass `PlanValidator.validate(plan)`. Unregistered tools, missing arguments, or sandbox violations fail closed.
3. **No Duplicate Execution:** Completed steps in `TaskStateMachine` are never re-executed.
4. **Reference Continuity:** Verified step outputs from Tier A remain accessible to Tier B continuation steps.
5. **Emergency Stop Invariant:** `EscalationPipeline.escalate` refuses handoff before invoking providers if emergency stop is latched, and discards returned plans if stop latches during generation.

---

## Section 13 — Planner Subsystem & Bounded Extraction

`[VERIFIED FROM CURRENT CODE: MLXPlanner.swift, PlannerExtraction.swift, DirectAnswerRouter.swift, SelfTest.swift:2720-2820]`

### Architecture
```
MODEL OUTPUT
    │
    ▼
Bounded Structured Extraction (JSON matching schema {"tool": ..., "arguments": ..., "literal": ...})
    │
    ▼
Typed Intermediate Representation (ExtractedAction)
    │
    ▼
Deterministic Compiler (PlannerExtraction.compile)
    │
    ▼
Existing AgentPlan / PlanStep
    │
    ▼
Canonical PlanValidator (Schema, arguments, references, CommandSandbox)
    │
    ▼
PermissionGate & DestructiveActionManager
    │
    ▼
ToolExecutor
    │
    ▼
Deterministic Post-Action Verification
```

### Critical Differentiation: Deterministic vs Model Extraction
- **Deterministic Extraction Path (`explicitShellEchoExtraction`):**
  - Matches explicit single-line requests matching: `write/print the word(s)/phrase/line <payload> using run_shell/the shell`.
  - Quotes literal payload as one POSIX single-quoted argument, handles quotes as delimiters, fails closed on apostrophes/newlines.
  - **Makes 0 model calls.**
  - *Key Clarification:* The 4–5 shell cases in the routing benchmark (`ctrl-planner-shell`, `arg-spaces`, `arg-numbers`, `arg-punct`, `arg-unusual`) used this deterministic path. They represent zero-model-call routing, **NOT** general 0.5B model extraction capability.
- **Genuine Model Extraction Path:**
  - Demonstrated by the physical `write_file` E2E test (`build/e2e-physical.txt`).
  - Model received prompt, generated valid extraction JSON for `write_file`, passed validation with 0 repairs, wrote file to disk, and verified exact byte read-back.
- **Legacy Whole-Plan Fallback:**
  - Unbounded or multi-step goals that do not match bounded extraction shapes fall back to legacy `AgentPlan` whole-plan generation.

---

## Section 14 — Empirical Experiments Archive (Experiments A & B)

`[HISTORICAL EVIDENCE: Sources/Jarvis/Core/SequentialExperiment.swift, Sources/Jarvis/Agent/PlanNormalizerB.swift, build/seq-A2-*.txt, /tmp/experiment-b-preservation/offline-replay-run.txt]`

### Experiment A: Sequential Next-Step Planning
- **Status:** **REJECTED / NOT PROMOTED.**
- **Hypothesis:** Generating steps one-by-one sequentially (`.sequential`) would improve multi-step goal completion on the 0.5B model compared to single-shot whole-plan generation (`.fullPlan`).
- **Empirical Results (B1–B5 Benchmarks):**
  - Baseline (Single-Shot `.fullPlan`): Multi-step scored **3/15 PASS** (20%).
  - Experiment A (Sequential Next-Step): Multi-step scored **0/15 PASS** (0%).
- **Why It Failed:**
  1. *Repetition Loops:* 0.5B model generated the first step repeatedly across all 8 cycles rather than advancing.
  2. *Latency Explosion:* 8 separate model calls per run caused severe latency without progress.
  3. *Recovery Exhaustion:* Tasks exhausted recovery limits and aborted in `FAILED` state.
- **Permanent Value:** Discovered and fixed Bug A (recovery state transition table) and Bug B (zero-step DONE completion gate).

### Experiment B: Normalizer B Single-Shape Normalization
- **Status:** **DISABLED / NOT WIRED INTO PRODUCTION (GATE FAILED).**
- **Hypothesis:** Deterministically repairing the split command shape `{"command": "echo", "args": "token"}` to `{"command": "echo token"}` before validation would prevent model repair corruption.
- **Predeclared Gate:** $\ge 50\%$ of historical literal-bearing attempts must match this exact shape in offline replay.
- **Empirical Replay Results (`offline-replay-run.txt`):**
  - Total historical attempts examined: 29
  - Attempts matching shape: 11
  - Pass rate: **37.9%** ($11 / 29 < 50\%$)
  - **Result: GATE FAILED.** Normalizer B was never enabled in production (`normalizerBEnabled = false`).

---

## Section 15 — Performance & Latency Telemetry

`[VERIFIED FROM BENCHMARK & EVIDENCE ARTIFACTS: build/routing-benchmark-final.txt, build/FROZEN_CONTRACT_V1_REPORT.md, SelfTest]`

| Subsystem / Operation | Latency Measurement | Test Context / Conditions | Verification Source |
|---|---|---|---|
| **Deterministic Controls (L0)** | **< 1.0 ms** | Regex match & native API dispatch (volume, app, clipboard) | `SelfTest`, `FROZEN_CONTRACT_V1_REPORT.md` |
| **Deterministic Route Latency** | **1,142 ms – 1,504 ms** | End-to-end command execution (e.g. `open Safari`, `what time is it`) | `build/routing-benchmark-final.txt` |
| **Direct Answer Route** | **2,779 ms – 3,534 ms** | L1 reflex intent classification + direct answer (no planner) | `build/routing-benchmark-final.txt` |
| **Local 0.5B MLX TTFT** | **231 ms – 480 ms** | Time to first token on Apple M4 Metal via Python worker | `FROZEN_CONTRACT_V1_REPORT.md` |
| **Local 0.5B MLX Generation** | **70.3 – 119.4 tok/s** | Token generation speed on Apple M4 Metal | `FROZEN_CONTRACT_V1_REPORT.md` |
| **Tier-A Local Planner Routing** | **2,058 ms – 2,133 ms** | Bounded shell extraction path (median ~2,080 ms) | `build/routing-benchmark-final.txt` |
| **Tier-A Web Tool Routing** | **3,447 ms – 6,210 ms** | Recency / explicit search tool path with web search | `build/routing-benchmark-final.txt` |
| **Tier-B Cloud Escalation** | **53,202 ms** | End-to-end escalation across network and provider | `build/routing-benchmark-final.txt:176` |
| **Voice TTS Playback Start** | **~150 ms – 300 ms** | `AVSpeechSynthesizer` dispatch | Telemetry logs |
| **Emergency Stop Dispatch** | **43.58 ms** (bound < 50ms) | Trigger to audio halt, task cancellation, process signal | `SelfTest Phase 13` |
| **Local Qwen 7B / Groq Speed** | *Not yet benchmarked* | Current production configuration unbenchmarked | Explicitly unmeasured |

---

## Section 16 — Testing Infrastructure & Inventories

`[VERIFIED BY TEST: SelfTest.swift]`

- **Execution Command:** `swift run Jarvis --self-test` (or `./.build/debug/Jarvis --self-test`)
- **Canonical Current Result:** **1067 passed, 0 failed, 0 skipped** alongside **254 tests / 38 suites** via `swift test`. `[VERIFIED THIS SESSION]`

### Complete Phase Breakdown
- **Phase 1: Deterministic Router** (11 native controls, regex matching, compound guards)
- **Phase 2: Intent Classification** (Domain routing, reflex classification)
- **Phase 3: Task State Machine** (Lifecycle states, transitions, invalid transition rejection)
- **Phase 4: Permission Gate & Autonomy** (L0-L3 matrix, authorization levels)
- **Phase 5: Destructive Actions & Commit Window** (Two-phase Preview/Commit, 60s timeout)
- **Phase 6: ShellExecutor & Process Lifecycle** (POSIX process groups, `killpg`, pipe streaming >64KB, timeout)
- **Phase 7: CommandSandbox & Dangerous Shell AST** (Command blocklist, operator validation)
- **Phase 8: ActionEngine & Dispatch** (Subsystem dispatch, error mapping)
- **Phase 9: Hotkey & System Control** (Display brightness, system lock, clipboard)
- **Phase 10: Memory & Conversation Store** (SQLite storage, vector search, Accelerate vDSP)
- **Phase 11: Vision & ScreenCapture** (Screen capture bounds, mock vision pipelines)
- **Phase 12: Voice Pipeline & Barge-In** (Audio capture, speech recognition, TTS)
- **Phase 13: Emergency Interrupt Latency** (Voice & UI trigger halt < 50ms)
- **Phase 14: MLXPlanner & Dynamic Tool Catalog** (Live schemas, prompt injection, repair)
- **Phase 15: Reference Resolution Engine** (25 tests: `$step.<N>`, `$ambient`, DAG checks)
- **Phase 16: Live Desktop Ambient Context Binding** (8 tests: `NSWorkspace` frontmost app, freshness guard)
- **Phase 17: Accessibility Bridge & Fast UI Tooling** (29 tests: `inspect_ui`, `click_element`, `set_text`, destructive verb gating)
- **Phase 18: Lossless Escalation Pipeline** (15 tests: `EscalationContext`, privacy gate, Tier B)
- **Phase 19: High-Reliability Deterministic Verification** (25 tests: 5-state verification, browser navigation, DOM snapshots, text entry, filesystem observer)
- **Phase 20: Planner Decomposition & Direct-Answer Routing** (Router matrix, recency safety net, bounded extraction IR, structural repair replay, argument preservation recorder, compiler gates)

---

## Section 17 — Known Limitations & Operational Boundaries

`[VERIFIED CURRENT OPERATIONAL BOUNDARIES]`

1. **0.5B Model Complexity Ceiling:** Local 0.5B model is reliable for bounded extraction and single-action tasks, but fails on complex unconstrained multi-step plans without escalation.
2. **Deterministic Benchmark Cases Were Zero-Model-Call:** The 4–5 shell cases in the routing benchmark matched `explicitShellEchoExtraction` and do not demonstrate LLM extraction strength.
3. **Escalation Plan Reliability:** Cloud/Tier-B providers can occasionally emit malformed JSON or substituted literals under network variance.
4. **Escalation Latency Cost:** Cloud escalation can add tens of seconds of latency.
5. **Emergency Stop Load Sensitivity:** Emergency stop latency assertions pass near the 50ms threshold (e.g. 43.58ms) and can be sensitive to heavy CPU load.
6. **Browser DOM Physical Automation:** Safari requires explicit manual developer enablement (*"Allow JavaScript from Apple Events"*).
7. **Acoustic Wake Word Deferred:** Voice system uses speech recognizer transcript streaming; acoustic DSP micro-models remain deferred.
8. **Current test tooling:** `swift test` is operational on the installed Swift 6.4 toolchain; `SelfTest` remains the broader integration/physical-capability runner.

---

## Section 18 — Explicitly Deferred Features & Out-of-Scope Items

To prevent scope creep and maintain architectural stability, the following items are **explicitly deferred**:

1. **Acoustic DSP Wake-Word Engine:** Transcript matching via `SFSpeechRecognizer` is sufficient for current desktop interaction.
2. **Heavy External Vector Database:** SQLite + Accelerate vDSP cosine similarity meets current memory needs fully offline.
3. **Continuous Screen Video Ingestion:** ScreenCaptureKit captures frames on-demand (`system.screenshot`), avoiding constant GPU/battery drain.
4. **Autonomous Self-Modifying Code:** The assistant must never rewrite its own binaries or scripts without explicit human supervision.
5. **Distributed Microservice Swarms:** The single-process native macOS architecture is frozen.

---

## Section 19 — Git History, Key Commits & Branch State

`[VERIFIED FROM GIT: git log, git status]`

- **Active Branch:** `master` (local hardening commit pending push; `[VERIFIED FROM CURRENT SESSION]`)
- **Current HEAD Commit:** `a9f58ef` — *"fix: harden process cancellation and provider routing"*
- **Preceding Key Commits:**
  - `655bab5`: `feat: add Milestone 3 EscalationAudit harness and test evidence` (EscalationAudit harness, Phase 18 test evidence).
  - `fd4bf87`: `fix: accept verified silent actions in agent execution` (`AgentStepOutcomePolicy`, verified silent action fix).
  - `ae8b0ca`: `feat: harden voice planning and exact literal routing` (voice to agent loop, direct answer routing, planner extraction, preservation recorder).
  - `9727a4b`: `feat: add verified browser text entry` (`fill_browser_text`).
  - `b9e55f8`: `feat: add bounded browser DOM interaction` (`inspect_browser_page`, `extract_browser_text`, `click_browser_link`).
  - `c6af1b4`: `fix: harden filesystem write boundaries` (canonical parent path resolution, symlink defenses).
  - `7bb8ce8`: `feat: add verified file writing tool` (`write_file` with read-back verification).
  - `6723286`: `feat: verify bounded browser navigation` (`open_browser` with tab observation).
  - `12f1000`: `feat: add deterministic post-action verification` (5-state `VerificationOutcome`).
  - `a591fe6`: `feat: baseline milestones 1-3 verified (ambient context, accessibility tools, lossless escalation, 531 tests)`.
  - `9971809`: `fix: prevent compound echo goals from bypassing planner`.

---

## Section 20 — Evidence Artifacts & Archives

`[VERIFIED FROM REPOSITORY FILESYSTEM]`

| Artifact Path | Description | What It Proves | What It Does NOT Prove |
|---|---|---|---|
| `build/selftest-final3.txt` | Historical terminal capture of a SelfTest run | **624 passed, 0 failed** (historical; the current suite reports **1067 passed / 0 failed**) | Does not run cloud API calls live |
| `build/routing-benchmark-final.txt` | 30-run repeated routing benchmark matrix + 5-run rerun | Semantic 30/30, argument preservation 5/5 on rerun | Shell cases were deterministic extraction (0 model calls) |
| `build/e2e-physical.txt` | Physical E2E `write_file` execution trace | Genuinely exercised model extraction path; 1 attempt; literal preserved | Does not prove arbitrary complex multi-step plans |
| `build/jarvis-e2e-jarvis_e2e_k9w4t21790655668.txt` | Physical file written by model-routed E2E test | Verified deterministic disk write and byte comparison | N/A |
| `build/escalation-audit-evidence.txt` | Milestone 3 escalation test assertions capture | Structured context, privacy blocks, and emergency stop invariants pass | Does not prove external cloud provider uptime |
| `build/seq-A2-B1.txt` ... `B5.txt` | Raw logs from Experiment A sequential testing | Experiment A failed (0/15 PASS) due to repetition loops | Does not mean multi-step is impossible on larger models |
| `/tmp/experiment-b-preservation/offline-replay-run.txt` | Raw offline replay log of 29 historical attempts | Normalizer B achieved only 37.9% normalizable rate (GATE FAILED) | Does not justify enabling Normalizer B live |
| `build/FROZEN_CONTRACT_V1_REPORT.md` | Baseline contract audit report | Baseline 302/1 tests, D-A to D-F failure modes, MLX latency | Historical; superseded by 624-test suite |

---

## Section 21 — Current Engineering Roadmap

### Immediate Next Open Question
**How should Zia combine deterministic routing, bounded extraction, local models (0.5B/3B/7B), and Groq efficiently while preserving safety, strictly adhering to the 9 Frozen Principles, and minimizing unnecessary model/API usage?**

### Work Items Under Architectural Review
1. **Local-vs-Groq Latency & Accuracy Benchmark [STILL OPEN]:**
   - Benchmark local Qwen2.5-7B and Qwen2.5-3B against Groq `llama-3.3-70b-versatile` across standard macOS intent tasks.
   - Measure real TTFT, total latency, memory footprint, and token cost.
2. **Bounded Extraction Expansion [SUBSTANTIALLY IMPLEMENTED]:**
   - Current deterministic extraction already covers `open_app`, volume, URL opening/fetching, web search, file read/write, and explicit shell forms; remaining work is empirical coverage expansion rather than the original missing architecture.
3. **Hybrid Routing Policy Formalization [PARTIALLY IMPLEMENTED]:
   - Provider routing now makes live availability and quarantine state part of the auditable decision itself; benchmark-driven threshold tuning remains open.**
   - Formulate clear routing thresholds: when to use 0-model deterministic routing, when to use local reflex/extraction, when to escalate to external Groq acceleration, and how to maintain zero-cost local fallback.

---

## Section 22 — Senior Agent Handoff Rules

If you are an incoming AI coding agent (Claude Opus, Gemini, Codex, Antigravity) taking over this codebase, follow these non-negotiable rules:

1. **Accuracy Beats Optimism. Evidence Beats Narrative.**
   - Never claim a feature exists, is verified, or passes tests without inspecting the actual code and running the test suite.
2. **Never Violate the 9 Frozen Principles.**
   - Intelligence never equals authority. The LLM is an untrusted proposer. Authority belongs exclusively to `CommandSandbox`, `PermissionGate`, and `DestructiveActionManager`.
3. **Never Weaken `PlanValidator` or `CommandSandbox`.**
   - Do not bypass schema validation or sandbox checks to make tests or benchmarks appear green.
4. **Canonical Test Runner Rule:**
   - Both runners are valid and both must be green: `swift test` (Swift Testing suites in `Tests/JarvisTests`) **and** `swift run Jarvis --self-test` (in-process integration / physical-capability suite). The former claim that `swift test` is "unavailable under Command Line Tools" is false and has been removed.
5. **Do Not Reopen Rejected Experiments:**
   - Experiment A (sequential planning) and Experiment B (Normalizer B) are permanently documented and rejected. Do not re-enable them in production.
6. **Preserve Untracked Evidence:**
   - Do not delete or wipe evidence files under `build/`.
7. **Maintain Documentation Integrity:**
   - Whenever you verify code or fix bugs, update `PROJECT_CONTEXT.md` with explicit evidence tags.

---

## Section 23 — Historical Milestones Archive

### Milestone 1: Live Desktop Ambient Context Binding (Historical Milestone)
- Implemented and verified in `a591fe6`.
- Connected `NSWorkspace` frontmost application to `JarvisTask.environmentContext` with 300s freshness guard.
- SelfTest suite advanced from 454 to 487 passed, 0 failed.

### Milestone 2: Deterministic Accessibility Bridge & Fast UI Tooling (Historical Milestone)
- Implemented and verified in `a591fe6`.
- Added `inspect_ui`, `click_element`, `set_text` to `ToolRegistry` (total 9 registered tools).
- Destructive keyword scanner dynamically upgrades click actions to `.destructive` for `PermissionGate` confirmation.
- SelfTest suite advanced from 487 to 516 passed, 0 failed.

### Milestone 3: Lossless Escalation Pipeline (Historical Milestone)
- Implemented and verified in `a591fe6`.
- Added `EscalationPipeline`, `EscalationContext`, `OpenRouterTierBProvider`, and pre-cloud privacy evaluation via `DataClassifier`.
- SelfTest suite advanced from 516 to 531 passed, 0 failed.

### Milestone 4A: Deterministic Post-Action Verification (Historical Milestone)
- Implemented and verified in `12f1000`, `6723286`, `7bb8ce8`, `c6af1b4`, `b9e55f8`, `9727a4b`.
- Introduced 5-state `VerificationOutcome`, `ToolVerificationResult`, `OpenAppTool` active check, `SetTextTool` AX read-back, `RunShellTool` filesystem observer, bounded browser DOM tools (`inspect_browser_page`, `extract_browser_text`, `click_browser_link`, `fill_browser_text`), and canonical parent path resolution in `FileManagerJarvis`.
- SelfTest suite advanced from 531 to 560 passed, 0 failed.

### Voice-to-Agent Integration & Decomposed Plan Authority (Historical Milestone)
- Implemented and verified in `ae8b0ca`.
- Unified non-deterministic voice requests into `AgentLoop.run(goal:)`.
- Added `PlannerExtraction` bounded IR, compiler with mandatory `PlanValidator` check, deterministic `explicitShellEchoExtraction`, and `ArgumentPreservationRecorder`.
- SelfTest suite advanced to 624 passed, 0 failed.

### Verified Silent Action Fix (Historical Milestone)
- Implemented and verified in `fd4bf87`.
- Introduced `AgentStepOutcomePolicy`: accepts empty tool output when mechanical verification passed.
- Fixed false-failure replanning on redirecting shell commands.
- SelfTest confirmed at 624 passed, 0 failed.

### Semantic Interaction UI Contract
- Added `InteractionPhase` / `InteractionPhaseChangedEvent` and `InteractionPhaseCenter` as the stable backend-to-UI boundary. AgentLoop reports understanding, planning, execution, success, failure, and stop; the voice path reports real transcript, VAD, and deterministic action states; TTS overlays `.speaking` only while AVFoundation is actually speaking, then restores the latest backend phase.
- The existing overlay now reflects those phases and uses neutral `Ready` / `Standby` wording rather than claiming the microphone is actively listening merely because the app is enabled. Errors in the typed overlay are user-facing rather than raw exception text.
- The transcript’s older-page toggle uses an owned `@StateObject` model instead of the unavailable SwiftUI `@State` macro, allowing the supported Command Line Tools build on this host.
- Verification: `swift build` succeeded. Full `.build/out/Products/Debug/Jarvis --self-test`: **838 passed, 0 failed**. Production deterministic AgentLoop E2E observed understanding, executing, success; center tests confirm acknowledgement speech overlays but does not hide continuing backend work.
- Not physically verified: microphone capture/UI animation and actual TTS playback in the visible overlay. These remain permission/device-dependent.
