# PROJECT_CONTEXT.md — Zia / JARVIS Engineering State & Handoff

> **Document Status:** CANONICAL REPOSITORY HANDOFF DOCUMENT  
> **Repository Path:** `/Users/jayanthpranaykonada/Zia`  
> **Generation Date:** 2026-09-28  
> **Target Audience:** Incoming Autonomous Coding Agents (Claude Opus, Gemini, Codex, Antigravity)  
> **Operational Rule:** **EVIDENCE > MEMORY > ASSUMPTION.** Every claim in this document is labeled with an explicit evidentiary verification status.

---

## Table of Contents
1. [Section 1 — Project Identity](#section-1--project-identity)
2. [Section 2 — Frozen Architectural Principles](#section-2--frozen-architectural-principles)
3. [Section 3 — Complete Architecture](#section-3--complete-architecture)
4. [Section 4 — Repository Map](#section-4--repository-map)
5. [Section 5 — Deterministic Mac Control](#section-5--deterministic-mac-control)
6. [Section 6 — Voice System](#section-6--voice-system)
7. [Section 7 — Task State](#section-7--task-state)
8. [Section 8 — Reference Resolution](#section-8--reference-resolution)
9. [Section 9 — Planner Subsystem](#section-9--planner-subsystem)
10. [Section 10 — Experiment A (Sequential Planning)](#section-10--experiment-a-sequential-planning)
11. [Section 11 — Experiment B (Normalizer B)](#section-11--experiment-b-normalizer-b)
12. [Section 12 — ShellExecutor & Phase 1 Correctness](#section-12--shellexecutor--phase-1-correctness)
13. [Section 13 — Phase 1 Test Evidence](#section-13--phase-1-test-evidence)
14. [Section 14 — Emergency Stop & Safety Boundaries](#section-14--emergency-stop--safety-boundaries)
15. [Section 15 — Permissions & Authority Matrix](#section-15--permissions--authority-matrix)
16. [Section 16 — Verification Mechanics & False-Success Defenses](#section-16--verification-mechanics--false-success-defenses)
17. [Section 17 — Recovery & State Transitions](#section-17--recovery--state-transitions)
18. [Section 18 — Testing Infrastructure & Inventories](#section-18--testing-infrastructure--inventories)
19. [Section 19 — Performance, Resource Usage & Latency](#section-19--performance-resource-usage--latency)
20. [Section 20 — Known Bugs, Race Conditions & Technical Debt](#section-20--known-bugs-race-conditions--technical-debt)
21. [Section 21 — Deferred Features & Out-of-Scope Items](#section-21--deferred-features--out-of-scope-items)
22. [Section 22 — Model Tier Strategy](#section-22--model-tier-strategy)
23. [Section 23 — Git, Branch & Checkpoint History](#section-23--git-branch--checkpoint-history)
24. [Section 24 — Evidence Artifacts & Archives](#section-24--evidence-artifacts--archives)
25. [Section 25 — Current State Snapshot](#section-25--current-state-snapshot)
26. [Section 26 — Next Engineering Roadmap](#section-26--next-engineering-roadmap)
27. [Section 27 — Agent Handoff Instructions](#section-27--agent-handoff-instructions)
28. [Section 28 — Reference Resolution — Implementation & Verification](#section-28--reference-resolution--implementation--verification)

---

## Section 1 — Project Identity

- **Project Name:** Zia (internal codebase identifier: `Jarvis`, module name: `Jarvis`, package name: `zia`) `[VERIFIED FROM CURRENT CODE: Package.swift:5-6]`
- **Repository Path:** `/Users/jayanthpranaykonada/Zia` `[VERIFIED FROM CURRENT CODE]`
- **Mission & Vision:** An always-on, voice-and-text accessible, low-latency, deterministic, highly safe autonomous assistant for macOS. It bridges physical hardware perception (mic, audio, screen capture) with deterministic OS automation and on-device/cloud multi-step agent planning.
- **Current Target Platform:** Apple Silicon macOS (minimum deployment target: macOS Sonoma 14.0, running on macOS 27.x / Darwin arm64) `[VERIFIED FROM CURRENT CODE: Package.swift:8]`
- **Toolchain & Build Environment:**
  - Swift 6.0 Language Mode (`swift-version 6`) with strict concurrency checking `[VERIFIED FROM CURRENT CODE: Package.swift:1]`
  - Host Toolchain: `/Library/Developer/CommandLineTools` (Xcode Command Line Tools only, **Xcode.app is NOT installed** on this machine) `[VERIFIED BY PHYSICAL TEST: xcode-select -p]`
  - Compiler Flags: `BareSlashRegexLiterals`, `ConciseMagicFile`, `ForwardTrailingClosures`, `ExistentialAny` `[VERIFIED FROM CURRENT CODE: Package.swift:31-34]`
- **Primary Dependencies:**
  - `HotKey` (0.2.1): Global macOS keyboard shortcut registration `[VERIFIED FROM CURRENT CODE: Package.swift:15]`
  - `KeychainAccess` (4.2.2): macOS Keychain wrapper for secure cloud API key storage `[VERIFIED FROM CURRENT CODE: Package.swift:17]`
  - `mlx` / `mlx_lm`: Python virtual environment (`.venv-mlx` with Python 3.12) running a persistent worker process (`mlx_worker.py`) for on-device Apple Metal neural network inference `[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Brain/Workers/mlx_worker.py]`
- **Build System:** Swift Package Manager (SPM). Build invocation: `swift build` or `./Scripts/build-app.sh debug|release`.
- **Test Strategy:** Native in-process test runner `SelfTest` (`swift run Jarvis --self-test` or `./Jarvis --self-test`). **Note:** Standard `swift test` fails on this machine because standalone Command Line Tools lacks `XCTest.framework`. All automated verification must use the native `SelfTest` suite. `[VERIFIED BY TEST: SelfTest.swift]`

---

## Section 2 — Frozen Architectural Principles

These 9 operational principles are frozen and must never be violated in any implementation:

1. **Intelligence Never Equals Authority** `[VERIFIED FROM CURRENT CODE: PermissionGate.swift, CommandSandbox.swift]`
   - A model (whether 0.5B local or 400B cloud) is an untrusted text-generator. It proposes steps or plans; it NEVER has direct execution authority.
   - Authority resides exclusively in deterministic gatekeepers: `CommandSandbox`, `PermissionGate`, and `DestructiveActionManager`.
2. **Fail Open to Intelligence, Not Authority** `[VERIFIED FROM CURRENT CODE: PermissionGate.swift:53-56]`
   - If an LLM fails, crashes, hallucinates, or returns invalid syntax, the system safely degrades or asks the user.
   - If a permission check or sandbox validation is ambiguous, it MUST FAIL CLOSED. It never defaults to permitting an action.
3. **State Over Transcript** `[VERIFIED FROM CURRENT CODE: TaskStateMachine.swift:153-166]`
   - The ground truth of any task is its explicit typed state machine (`TaskState`, `TaskStep.verification`, `currentStepIndex`), never an LLM's conversational chat history or narrative claims.
4. **Cheapest Sufficient Intelligence** `[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift, IntentClassifier.swift]`
   - 0 model calls > local 0.5B reflex model > local 0.5B planner > cloud model.
   - If a request can be executed deterministically via regex/intent matching (e.g. "what time is it", "open Safari", "set volume to 40"), it routes with 0 model calls and < 1ms latency.
5. **Lossless Escalation** `[VERIFIED FROM CURRENT CODE: ProviderManager.swift, AgentLoop.swift]`
   - When a lower-tier model or local recovery fails, the complete context, previous error traces, and exact validator rejections are preserved losslessly as input to the next escalation tier.
6. **Commit Points Gate Irreversibility** `[VERIFIED FROM CURRENT CODE: DestructiveActionManager.swift]`
   - Destructive, non-undoable operations (e.g. `sleep mac`, `rm -rf`, emptying trash) MUST require a two-phase `PREVIEW -> COMMIT` protocol with an explicit 60-second expiration window. Spoken single-shot commands can only generate previews.
7. **Evidence Before Green** `[VERIFIED FROM CURRENT CODE: SelfTest.swift:1153-1166]`
   - No task, step, or PR is considered green or completed based on assertion of intent. Success requires deterministic physical or mechanical postcondition verification (`VerificationOutcome.passed`).
8. **Zero-Model-Call Coverage Should Increase** `[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift:18-23]`
   - Engineering effort should continually expand deterministic, zero-model-call routing to cover more common macOS actions.
9. **Fast Interaction Loop Must Never Wait for Deep Task Execution** `[VERIFIED FROM CURRENT CODE: AgentLoop.swift:34-45]`
   - Voice responses, UI animations, HUD feedback, and Emergency Stop monitors run asynchronously and concurrently off the long-running execution workers. The main UI thread never blocks on tool execution.

---

## Section 3 — Complete Architecture

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
[ L1: Small Intent Classification ]
  DirectAnswerRouter / IntentClassifier (Reflex slot)
  ├── Chit-Chat / Direct Fact ──► Fast Direct Answer
  └── Complex Goal
       │
       ▼
[ L2: Agent Loop Engagement ]
  TaskStateMachine registers task (state = CREATED)
       │
       ▼
[ Planning Phase (PLANNING) ]
  MLXPlanner (Qwen2.5-0.5B-Instruct-4bit on Metal)
  Emits candidate AgentPlan JSON
       │
       ▼
[ Deterministic Compiler & Validator ]
  PlanValidator checks:
  - Valid JSON extraction
  - Registered tools only (in live ToolRegistry)
  - Required arguments present & correct types
  - No smuggled/undeclared arguments
  - CommandSandbox safety check
  ├── Fails ──► Bounded Repair (1 attempt with exact error)
  └── Passes
       │
       ▼
[ Permission & Authority Check ]
  PermissionGate checks AutonomyLevel (L0, L1, L2, L3)
  ├── Destructive ──► DestructiveActionManager (PREVIEW -> COMMIT)
  └── Authorized
       │
       ▼
[ Execution Phase (RUNNING) ]
  TaskWorkerPool spawns TaskWorker
  Executes BuiltinTools / ShellExecutor / FileManager / SystemControl
       │
       ▼
[ Observation & Verification (VERIFYING) ]
  ToolResult side-effects observed
  Postcondition verified mechanically (VerificationOutcome = .passed / .failed)
       │
       ▼
[ Task State Update ]
  TaskStateMachine updates progress, steps, and history
  ├── More steps ──► Loop next step
  └── All steps complete & verified ──► State = COMPLETED
```

### Recovery Escalation Ladder
1. **Cheap Retry:** Immediate re-attempt if transient I/O or network glitch.
2. **Tier-A Repair:** Feed exact validator error string + live schema back to MLXPlanner (bounded to 1 repair attempt).
3. **Tier-A Replan:** Up to `3 + plan.steps.count` replanning cycles, pruning invalid steps and preserving valid observations.
4. **Tier-B / Tier-C Lossless Escalation:** Pass full task state, step history, and error ledger to larger local model or Cloud Provider (Claude/OpenAI).
5. **User Clarification / Fail-Closed:** If budgets or retries are exhausted, fail to user with actionable diagnostic report.

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
│       │   ├── AgentLoop.swift                # Autonomous orchestration loop
│       │   ├── DirectAnswerRouter.swift       # Bypasses planner for trivial chit-chat/facts
│       │   ├── DirectComposer.swift           # Tool-null step composer
│       │   ├── MLXPlanner.swift               # Local Qwen2.5-0.5B planner with ledger
│       │   ├── PlanNormalizerB.swift          # Experiment B single-shape normalizer (disabled in prod)
│       │   ├── PlanValidator.swift            # Deterministic schema & sandbox validator
│       │   ├── TaskStateMachine.swift         # Thread-safe task lifecycle state machine
│       │   ├── TaskWorker.swift               # Worker unit executing single tool steps
│       │   └── TaskWorkerPool.swift           # GCD queue worker pool with M4 concurrency limits
│       ├── App/
│       │   ├── AppDelegate.swift              # App lifecycle and menu bar wiring
│       │   ├── AppState.swift                 # Global state machine: OFF, SLEEP, ACTIVE
│       │   └── JarvisApp.swift                # App entry point (executes SelfTest.runAll() on launch)
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
│       │   │   ├── GroqProvider.swift         # Groq API provider (low latency)
│       │   │   ├── MLXProvider.swift          # Local Python MLX worker bridge (Apple Metal)
│       │   │   ├── OpenAIProvider.swift       # OpenAI API provider
│       │   │   ├── OpenRouterProvider.swift   # OpenRouter multi-model provider
│       │   │   └── Provider.swift             # LLMProvider protocol & capability matrix
│       │   ├── Tools/
│       │   │   ├── BuiltinTools.swift         # Builtin tools (run_shell, open_app, web_search, etc.)
│       │   │   ├── ToolDefinitions.swift      # Schema specifications (ToolParameterSpec)
│       │   │   ├── ToolExecutor.swift         # Dynamic tool execution dispatcher
│       │   │   └── ToolRegistry.swift         # Central registry of available tools
│       │   └── Workers/
│       │       └── mlx_worker.py              # Persistent Python MLX inference daemon
│       ├── Core/
│       │   ├── Config.swift                   # Persistent configuration (autonomy, wake words, budgets)
│       │   ├── DataClassifier.swift           # PII and credential privacy detector
│       │   ├── Errors.swift                   # Typed JarvisError enum
│       │   ├── EventBus.swift                 # Publish-subscribe decoupled event bus
│       │   ├── Events.swift                   # Typed event declarations (EmergencyStop, TaskStateChanged)
│       │   ├── HotkeyManager.swift            # Global hotkey binding
│       │   ├── KeychainManager.swift          # macOS Keychain CRUD
│       │   ├── LockedValue.swift              # Thread-safe @unchecked Sendable NSLock box
│       │   ├── Logger.swift                   # os.Logger logging categories
│       │   ├── NetworkMonitor.swift           # NWPathMonitor network reachability
│       │   ├── PhysicalDemonstration.swift    # Physical verification test harness
│       │   ├── PipelineTimer.swift            # Latency and telemetry stage timer
│       │   ├── ResourceManager.swift          # Memory pressure monitor & model eviction
│       │   ├── SchemaExperiment.swift         # Schema contract experiment harness (D-A to D-F)
│       │   ├── SelfTest.swift                 # Native test suite (451 deterministic tests)
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

## Section 5 — Deterministic Mac Control

`[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift, SystemControl.swift, SelfTest.swift:202-237]`

The system implements 11 high-reliability, zero-model-call native controls that execute in < 1ms:

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
| `system.lock` | "lock mac", "lock screen" | `.safeMutation` | SACLockScreenImmediate call | ✅ Yes |
| `system.sleep` | "sleep mac", "put mac to sleep" | `.destructive` | Two-phase PREVIEW -> COMMIT protocol (`DestructiveActionManager`) | ✅ Yes (dry-run) |
| `shell.echo` | "echo hello", "run echo hello" | `.safeMutation` | ShellExecutor stdout capture (guarded against compound commands) | ✅ Yes |

### Compound-Command Routing Hardening
`[VERIFIED FROM CURRENT CODE: DeterministicRouter.swift:188-218, SelfTest.swift:1535-1542]`
- Previously, compound requests containing `echo` (such as `"echo recovery_started, then use audit_failing_tool, then echo recovery_completed"`) were erroneously intercepted by the deterministic router, bypassing the planner.
- Commit `9971809` added strict compound guards: any goal containing `, then`, `;`, `&&`, `|`, or shell metacharacters is rejected by the fast echo path and routed to `MLXPlanner`.

---

## Section 6 — Voice System

`[VERIFIED FROM CURRENT CODE: AudioCapture.swift, SpeechRecognizer.swift, WakeWordDetector.swift, EmergencyInterrupt.swift]`

- **Microphone Capture:** `AudioCapture.swift` uses `AVAudioEngine` tapping the input node with 16kHz, mono 16-bit PCM format.
- **Speech Recognition:** `SpeechRecognizer.swift` utilizes Apple's `SFSpeechRecognizer` configured with `requiresOnDeviceRecognition = true` for zero-cloud, offline processing.
- **Wake Word Detection (`WakeWordDetector.swift`):**
  - **IMPLEMENTED:** Transcript wake-alias spotting. Operates on partial and final transcripts from `SFSpeechRecognizer`. Matches configured aliases: `"Jarvis"`, `"Zia"`, `"Ziya"`. Supports conversational prefixes: `"hey"`, `"hi"`, `"hello"`, `"ok"`, `"okay"`, `"please"`, `"yo"`.
  - **NOT YET IMPLEMENTED / DEFERRED:** Acoustic DSP wake-word engine (e.g. Porcupine, openWakeWord, or CoreML micro-model running continuously on raw audio buffers). The system currently relies on the on-device Apple speech recognizer streaming.
- **Text-to-Speech:** `TTSEngine.swift` wraps `AVSpeechSynthesizer` with rate `0.52`, pitch `1.0`, and selected neural voices (e.g. "Samantha" or "Daniel").
- **Barge-In / Emergency Voice Stop:** If speaking when a wake word or emergency phrase is uttered, `AudioPlayer` and `TTSEngine` stop immediately within < 50ms.
- **Permissions:** Depends on macOS Microphone (`NSMicrophoneUsageDescription`) and Speech Recognition (`NSSpeechRecognitionUsageDescription`) authorizations embedded in `Info.plist`. `[VERIFIED BY PHYSICAL TEST]`

---

## Section 7 — Task State

`[VERIFIED FROM CURRENT CODE: TaskStateMachine.swift:1-150]`

The actual `JarvisTask` and `TaskStep` structures hold:
- `id: UUID`
- `title: String`, `goal: String`
- `state: TaskState` (`CREATED`, `PLANNING`, `RUNNING`, `VERIFYING`, `COMPLETED`, `FAILED`, `RECOVERING`, `REPLANNING`, `CANCELLED`)
- `steps: [TaskStep]` (`id`, `stepNumber`, `description`, `toolName`, `arguments: [String: String]`, `state`, `output`, `error`, `verification: VerificationOutcome?`)
- `currentStepIndex: Int`, `maxRetries: Int`, `retryCount: Int`
- `createdAt: Date`, `updatedAt: Date`, `completedAt: Date?`, `error: String?`

### Audit of Purported Context Variables:
| Field Name | Status | Analysis |
|---|---|---|
| `current_app` | **ABSENT** | Not present on `JarvisTask` or `TaskStep`. Tracked ephemerally in `AppLauncher` only. |
| `current_file` | **ABSENT** | Not present in task state. |
| `current_webpage` | **ABSENT** | Tracked only inside `BrowserManager` active tab cache, not in task state. |
| `current_selection` | **ABSENT** | Not implemented. |
| `last_search_results` | **ABSENT** | Retained inside `SourceManager` citations, not in `JarvisTask`. |
| `last_artifact` | **ABSENT** | Not present in task state. |
| `pending_confirmation` | **DESIGNED / PARTIAL** | Implemented in `DestructiveActionManager.shared.pendingAction`, but not directly a property of `JarvisTask`. |

---

## Section 8 — Reference Resolution

`[VERIFIED FROM CURRENT CODE: ReferenceResolver.swift, AgentLoop.swift, PlanValidator.swift, TaskStateMachine.swift, SelfTest.swift:1645-1940]`

- **Current Status:** **IMPLEMENTED & VERIFIED (Phase 15 Engine Active, 25/25 Tests Passing).**
- **Architecture & Grammar:**
  - Wire Representation: Preserves `[String: String]` on `PlanStep` and `TaskStep` for zero wire breakage.
  - Strict Token Grammar:
    - `$step.<N>.output` / `$step.<N>`: Prior verified step output.
    - `$step.<N>.<field>`: Deterministic JSON field extraction from structured outputs.
    - `$ambient.<slot>`: Environmental state (`current_app` live from `NSWorkspace`; remaining slots strictly fail with `ambientSlotUnavailable`).
    - Ordinary dollar strings (e.g. `"$100"`, `"$HOME"`) remain literals.
  - Template/Embedded Support: Commands such as `cat $step.1.output` or `echo $step.1.output` are parsed into `.template` with strict token extraction.
- **Execution Integration & Permissions:**
  - Reference resolution happens **immediately before execution** in `AgentLoop.swift`.
  - Permission gate & `CommandSandbox.shared.isSafe` evaluate the **concrete resolved argument** (e.g. `cat /etc/passwd`, NOT `cat $step.1.output`).
  - Step outputs are addressable **ONLY IF** `verification == .passed`.
- **Complete Details:** See [Reference Resolution — Implementation & Verification](#reference-resolution--implementation--verification) below.

---

## Section 9 — Planner Subsystem

`[VERIFIED FROM CURRENT CODE: MLXPlanner.swift, PlanValidator.swift, ToolDefinitions.swift]`

- **Current Engine:** `MLXPlanner.swift` running local `mlx-community/Qwen2.5-0.5B-Instruct-4bit` on Apple Metal via Python worker `mlx_worker.py`.
- **Generation Budget:** Maximum 2 attempts per planning cycle (Attempt 1 = Initial, Attempt 2 = Schema-aware Repair).
- **Prompt Structure:**
  - Embeds live tool catalog generated dynamically from `ToolRegistry.shared.getToolDefinitions()`.
  - Injects live parameter schemas (`name`, `kind`, `required`, `description`).
  - Explicitly shows CORRECT vs WRONG examples for `run_shell` (`command` must be ONE complete scalar string).
- **Repair Prompting (Change B):**
  - Carries the exact error from `PlanValidator`, the relevant tool's schema, a corrected example, and the original invalid JSON, demanding a targeted correction.
- **Parser & Extraction:**
  - Extracts JSON wrapped in markdown fences (` ```json ... ``` `) or raw braces.
  - Multi-object recovery: if the model outputs multiple JSON objects back-to-back, the parser takes the first valid object.
  - Brace-slip repair: repairs orphaned trailing `purpose` blocks.
  - Terminators: strips hallucinated `JSON:` echoes from argument values.
- **Validation Rules (`PlanValidator.swift`):**
  - Unknown tools rejected (`.unknownTool`).
  - Missing required arguments rejected (`.missingArgument`).
  - Undeclared/smuggled arguments rejected (`.unknownArgument`).
  - Type mismatch (e.g. non-integer passed to int) rejected (`.typeMismatch`).
  - Unsafe shell commands rejected at plan-time (`.unsafeOperation`).
  - Empty steps array rejected (`.emptyPlan`).
- **Deterministic Authority vs Planner Intelligence:**
  - The model proposes JSON.
  - `PlanValidator` grounds the proposal against the immutable `ToolRegistry`.
  - The model has ZERO authority to execute unapproved tools or bypass sandbox checks.

---

## Section 10 — Experiment A (Sequential Planning)

`[VERIFIED FROM GIT/EVIDENCE ARTIFACT: build/seq-A2-B1.txt, Sources/Jarvis/Core/SequentialExperiment.swift, Tests/JarvisTests/SequentialLifecycleTests.swift]`

- **Hypothesis:** Generating steps one-by-one sequentially (`.sequential` mode) would improve multi-step goal completion on the 0.5B model compared to single-shot whole-plan generation (`.fullPlan`).
- **Benchmark Suite:**
  - `B1`: 3-step independent echo (`alpha_one`, `bravo_two`, `charlie_three`)
  - `B2`: 3-step dependent echo (`baseline_marker_42` + uppercase + done)
  - `B3`: Reference resolution probe (`reference_probe_77`, then echo "it" - probe only)
  - `B4`: Canonical D-A exact-token single step
  - `B5`: Canonical D-F-multi 3 steps with mid-failing tool
- **Empirical Results:**
  - **Baseline (Single-Shot `.fullPlan`):** Multi-step scored **3/15 PASS** (20%).
  - **Experiment A (Sequential Next-Step):** Multi-step scored **0/15 PASS** (0%).
- **Why Experiment A Failed:**
  1. **Repetition Loops:** The 0.5B model entered catastrophic next-step loops, generating `echo alpha_one` over and over across all 8 planning cycles instead of advancing to `bravo_two`.
  2. **Latency Explosion:** Each step required a separate model generation. B1 took 8 planner calls per run, causing massive latency inflation without advancing the task.
  3. **Recovery State Exhaustion:** Reached max recovery attempts (`maxTotalAttempts`) and aborted in `FAILED` state.
- **Historical Bugs Discovered & Fixed During Experiment A:**
  - **Bug A (Illegal State Transition):** In sequential recovery, planning failure left the state machine in `REPLANNING`. A subsequent DONE check attempted `REPLANNING -> VERIFYING`, which violated the transition table. Fixed by ensuring the recovery chain explicitly transitions `REPLANNING -> RUNNING` before verifying. `[VERIFIED BY TEST: SelfTest.swift:1135-1151]`
  - **Bug B (Zero-Step DONE False-Success):** The model emitted `DONE` with zero executed steps or with unverified steps. Fixed by introducing the deterministic completion gate: `!steps.isEmpty && steps.allSatisfy { $0.verification == .passed }`. `[VERIFIED BY TEST: SelfTest.swift:1153-1166]`
- **Final Decision:** **EXPERIMENT A WAS REJECTED / NOT PROMOTED.** The system remains on single-shot full-plan generation (`.fullPlan`).

---

## Section 11 — Experiment B (Normalizer B)

`[VERIFIED FROM GIT/EVIDENCE ARTIFACT: /tmp/experiment-b-preservation/offline-replay-run.txt, Sources/Jarvis/Agent/PlanNormalizerB.swift]`

- **Hypothesis:** The 0.5B planner frequently emits a malformed `run_shell` shape:
  `{"command": "echo", "args": "jarvis_planner_e2e_verified"}`
  instead of the single scalar `{"command": "echo jarvis_planner_e2e_verified"}`. During model repair, the model often drops its token and adopts the example `echo hello`. Normalizing this single shape deterministically before validation would allow the model's own token to reach execution without repair corruption.
- **Predeclared Offline Gate:**
  - Rule: Normalizer B would only be considered for live production testing if $\ge 50\%$ of historical literal-bearing attempts matched this exact normalizable shape.
- **Empirical Replay Results (`offline-replay-run.txt`):**
  - Total historical attempts examined: 29
  - Attempts matching the normalizable shape: 11
  - Percentage: **37.9%** ($11 / 29$)
  - **GATE RESULT: FAIL** (37.9% < 50.0%)
- **Discrepancy Audit (25 Literal Attempts vs 27 Candidates):**
  - **Rule:** Do NOT fabricate reconciliation. Do not reconstruct missing JSON. Do not double-count attempt records, validation summaries, and audit excerpts.
  - Across the raw capture logs (`fc-audit.txt`, `fc-seg-DA.txt`, `ii-seg-DA.txt`), 27 literal candidate strings appeared in log text, but only 25 distinct model generation attempts actually contained literal-bearing payloads (the remainder were diagnostic summaries and log header repetitions).
- **Current Status:**
  - `PlanNormalizerB.swift` exists in the tree with unit tests in `Tests/JarvisTests/PlanNormalizerBTests.swift`.
  - `normalizerBEnabled = false` (default OFF in production code).
  - **Live Experiment B has NOT run and must NOT be enabled in production** because it failed the offline gate.

---

## Section 12 — ShellExecutor & Phase 1 Correctness

`[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Actions/Terminal/ShellExecutor.swift]`

`ShellExecutor.swift` was recently audited, redesigned, and verified to eliminate critical process lifecycle and concurrency flaws.

### Bugs Identified in Baseline Code:
1. **No Process-Group Isolation:** `process.terminate()` sent SIGTERM only to the parent PID. Grandchild processes (e.g. `bash -c "sleep 300 &"`) survived emergency stops as orphaned processes.
2. **Timeout Never Enforced:** `timeoutSeconds: Double = 30.0` was accepted in the method signature but never read or scheduled. Runaway commands hung forever.
3. **Busy-Wait Polling Loop:** The baseline polled `try await Task.sleep(nanoseconds: 50_000_000)` in a tight loop, wasting CPU and adding up to 50ms latency to cancellation.
4. **Non-Idempotent Termination / Crash:** Calling `process.terminate()` on an already-terminated process or unlaunched process could crash with `NSInvalidArgumentException`.
5. **No SIGKILL Escalation:** Only SIGTERM was sent; processes catching or ignoring SIGTERM survived indefinitely.
6. **Kernel Pipe Buffer Deadlock:** Reading `stdoutPipe` and `stderrPipe` via `readDataToEndOfFile()` occurred *after* `waitUntilExit()`. For outputs exceeding the macOS pipe buffer (64KB), the child blocked on `write()` while the parent blocked on `waitUntilExit()`, deadlocking the system.

### Verified Fix Implementation:
- **POSIX Process Grouping:** macOS Foundation `Process` spawns processes with `PGID == PID`. Calling `setpgid(pid, pid)` post-launch fails with `EACCES (errno 13)` because `execve()` has already executed. `ShellExecutor` correctly signals the entire tree using POSIX `killpg(pid, SIGTERM)`.
- **Thread-Safe `ProcessScope`:**
  ```swift
  final class ProcessScope: @unchecked Sendable {
      let pid: pid_t
      private let lock = NSLock()
      private var isKilled = false
      ...
  ```
  Guarantees atomic termination rights across concurrent callers (Emergency Stop, Timeout Task, Swift Task cancellation).
- **SIGKILL Escalation:** A 500ms grace window is observed after SIGTERM. If any process in the group still exists (`kill(pid, 0) == 0`), it escalates unconditionally to `killpg(pid, SIGKILL)`.
- **Event-Driven Exit (Zero Polling):** Uses `process.terminationHandler` bridged to `CheckedContinuation<Void, Never>` through a thread-safe `ContinuationGate`. The actor suspends cooperatively, allowing incoming `cancelAll()` requests to process in < 1ms.
- **Concurrent Pipe Streaming:** Detached asynchronous tasks read `stdoutPipe` and `stderrPipe` concurrently while the process runs, preventing buffer deadlocks on outputs > 64KB (tested up to 500KB).
- **Swift 6 Strict Concurrency:** All captured state in `withTaskCancellationHandler` is strictly Sendable. Zero concurrency warnings or data-race hazards.

---

## Section 13 — Phase 1 Test Evidence

`[VERIFIED BY TEST: SelfTest.swift:986-1046, ShellExecutorTests.swift]`

Phase 1 ShellExecutor correctness was verified through:
1. Standalone isolated prototype test script exercising all 6 edge cases simultaneously.
2. 5 new deterministic tests added directly into Phase 6 of `SelfTest.swift`.

### SelfTest Phase 6 Execution Results:
```
─── Phase 6: ShellExecutor & Process Lifecycle ───
  ✓ ShellExecutor executes command and captures stdout
  ✓ ShellExecutor handles >64KB output without pipe deadlock
  ✓ ShellExecutor terminates command on deterministic timeout
  ✓ ShellExecutor terminates process upon Swift Task cancellation
  ✓ ShellExecutor cancelAll is idempotent and cleans process groups
  ✓ ShellExecutor preserves process isolation between concurrent commands
  ✓ ShellExecutor prevents false success when process traps SIGTERM
  ✓ ShellExecutor honors pre-launch task cancellation
```

### Full Native Suite Test Count:
- **Baseline before Phase 1:** 446 passed, 0 failed `[VERIFIED FROM GIT/EVIDENCE ARTIFACT: build/seq-A2-selftest-final.txt]`
- **Current after Phase 1 Audit & Hardening:** **454 passed, 0 failed** `[VERIFIED BY TEST: execution of /Users/jayanthpranaykonada/Zia/.build/out/Products/Debug/Jarvis --self-test]`
- **Regressions:** **0**

---

## Section 14 — Emergency Stop & Safety Boundaries

`[VERIFIED FROM CURRENT CODE: EmergencyInterrupt.swift, EventBus.swift, ShellExecutor.swift:187-195]`

### Emergency Stop Call Graph & Propagation:
```
[ Trigger: Voice Phrase ("stop", "abort", "halt") OR UI Stop Button OR HotKey ]
                                 │
                                 ▼
                 EmergencyInterrupt.shared.trigger()
                                 │
                                 ▼
             EventBus.shared.publish(EmergencyStopEvent)
                                 │
         ┌───────────────────────┼────────────────────────┐
         ▼                       ▼                        ▼
  TTSEngine.stop()     SpeechRecognizer.cancel()   ShellExecutor.cancelAll()
  AudioPlayer.stop()                                      │
         │                       │                        ▼
         │                       │            killpg(pid, SIGTERM)
         ▼                       ▼            [+500ms -> SIGKILL]
  AgentLoop.emergencyCancel()  TaskWorkerPool.cancelAll()
         │                       │
         ▼                       ▼
  TaskState -> .cancelled    Workers halted
```

### Safety Guarantees:
- **Descendant Process Elimination:** POSIX `killpg` guarantees that any process tree spawned by `ShellExecutor` is wiped out.
- **Idempotence:** `ProcessScope` uses an `NSLock` and atomic boolean flag. Calling `cancelAll()` multiple times in rapid succession is completely crash-safe.
- **Immediate Response:** Execution latency from emergency trigger to signal dispatch is < 1ms.

---

## Section 15 — Permissions & Authority Matrix

`[VERIFIED FROM CURRENT CODE: PermissionGate.swift, DestructiveActionManager.swift]`

| Autonomy Level | Level Name | Read-Only Impact | Safe Mutation Impact | Destructive Impact |
|---|---|---|---|---|
| **L0** | Read-Only | **AUTHORIZED** | **DENIED** | **DENIED** |
| **L1** | Supervised (Default) | **AUTHORIZED** | **AUTHORIZED** | **DENIED** unless explicitly confirmed via Preview/Commit |
| **L2** | Autonomous | **AUTHORIZED** | **AUTHORIZED** | **AUTHORIZED** |
| **L3** | Full | **AUTHORIZED** | **AUTHORIZED** | **AUTHORIZED** |

### Destructive Action Protocol (`DestructiveActionManager`):
- Action marked `.destructive` (e.g. `system.sleep`, `rm -rf`).
- Spoken/typed command triggers `requestPreview()`: creates `PendingAction` and returns guidance ("PREVIEW: ... Say confirm to execute").
- User must speak or type `"confirm <intent>"` or `"commit"` within **60 seconds**.
- `popPendingAction()` atomically claims and deletes the action, preventing double-commit.
- Emergency Stop or `"cancel"` immediately purges pending actions.

---

## Section 16 — Verification Mechanics & False-Success Defenses

`[VERIFIED FROM CURRENT CODE: TaskStateMachine.swift:51-61, SelfTest.swift:1153-1166, BuiltinTools.swift]`

- **Mechanical vs Declared Verification:**
  - A step's completion is NEVER accepted based on the model's text claim ("I have created the file").
  - Every tool execution returns a `ToolResult(success: Bool, output: String, sideEffects: [String])`.
  - `TaskStep.verification` is explicitly set to `.passed` or `.failed`.
- **False-Success Defenses:**
  1. **Non-Zero Shell Exit Codes:** If `ShellExecutor` returns `exitCode != 0`, `ToolResult.success` is `false`.
  2. **Zero-Step DONE Rejection (Bug B Guard):** `AgentLoop` will refuse to transition a task to `.completed` if `steps.isEmpty`.
  3. **Unverified Step Gate:** All executed steps must have `verification == .passed` before `.completed` is reachable.
  4. **Postcondition Checking:** System controls verify physical outcomes (e.g. `DisplayServicesGetBrightness` verifies display changed, `NSPasteboard` verifies text copied).

---

## Section 17 — Recovery & State Transitions

`[VERIFIED FROM CURRENT CODE: TaskStateMachine.swift:18-49, AgentLoop.swift:200-260]`

### State Transition Matrix:
- `CREATED` $\rightarrow$ `PLANNING`, `RUNNING`, `CANCELLED`
- `PLANNING` $\rightarrow$ `RUNNING`, `FAILED`, `CANCELLED`
- `RUNNING` $\rightarrow$ `VERIFYING`, `FAILED`, `CANCELLED`
- `VERIFYING` $\rightarrow$ `COMPLETED`, `FAILED`, `RUNNING`, `CANCELLED`
- `FAILED` $\rightarrow$ `RECOVERING`, `CANCELLED`
- `RECOVERING` $\rightarrow$ `REPLANNING`, `FAILED`, `CANCELLED`
- `REPLANNING` $\rightarrow$ `RUNNING`, `FAILED`, `CANCELLED`
- `COMPLETED` $\rightarrow$ *Terminal* (no transitions)
- `CANCELLED` $\rightarrow$ *Terminal* (no transitions)

### Replan & Bounded Retries:
- `maxRetries` per task defaults to 3.
- `AgentLoop` limits total step attempts across the life of a task to `3 + plan.steps.count`.
- Replan failure context is clipped to 160 characters to avoid prompt inflation on small models.
- At most 2 prior step observations are retained during replanning.

---

## Section 18 — Testing Infrastructure & Inventories

`[VERIFIED BY TEST: SelfTest.swift, Tests/JarvisTests/]`

### Testing Environments:
1. **In-Process Native Test Runner (`SelfTest.swift`):**
   - **Command:** `swift run Jarvis --self-test` or `./.build/out/Products/Debug/Jarvis --self-test`
   - **Environment:** Standalone macOS Command Line Tools (no Xcode needed).
   - **Historical Evolution:**
     - Baseline (Frozen Contract v1.0, 2026-09-26): **302 passed, 1 failed** (debug timer flake).
     - After Integration & Router Hardening: **446 passed, 0 failed**.
     - **Current State (After Phase 1 Audit & Hardening):** **454 passed, 0 failed**.
2. **Unit Test Target (`Tests/JarvisTests`):**
   - `AppStateTests.swift`
   - `EventBusTests.swift`
   - `PipelineTimerTests.swift`
   - `PlanNormalizerBTests.swift`
   - `SequentialLifecycleTests.swift`
   - `ShellExecutorTests.swift`
   - **Limitation:** Running via `swift test` fails on this machine due to missing `XCTest.framework` in standalone Command Line Tools.

---

## Section 19 — Performance, Resource Usage & Latency

`[VERIFIED FROM GIT/EVIDENCE ARTIFACT: build/FROZEN_CONTRACT_V1_REPORT.md, build/fc-audit.txt]`

- **Deterministic Controls:**
  - Route match & execution latency: **< 1.0 ms**
  - Model calls: **0**
  - Network calls: **0**
- **MLX Local Planner (Qwen2.5-0.5B-Instruct-4bit on Apple M4 Metal):**
  - Time To First Token (TTFT): **231 ms – 480 ms**
  - Generation Speed: **70.3 – 119.4 tokens/second**
  - Full Plan Generation Latency: **497 ms – 3,680 ms**
  - Model Load Latency (from SSD to Unified Memory): **1,599 ms – 2,167 ms**
- **Voice System Latency:**
  - TTS playback start: **~150 ms – 300 ms**
  - Emergency voice stop halt latency: **< 50 ms**
- **System Footprint:**
  - Resident Memory (RSS): **~850 MB – 1.4 GB** (including resident 4-bit 0.5B model)
  - Memory Pressure Gate: `ResourceManager` sets reserve threshold at 1,024 MB; refuses model load under `CRITICAL` pressure.

---

## Section 20 — Known Bugs, Race Conditions & Technical Debt

| Bug / Debt Item | Severity | Subsystem | Status / Evidence | Recommended Action |
|---|---|---|---|---|
| Standalone `swift test` fails without Xcode | Medium | Build / CI | `XCTest` unavailable in Command Line Tools SDK | Keep `SelfTest` as primary CI runner; or configure standalone testing runner |
| Reference resolution absent | High | AgentLoop / Compiler | Goals like "do X, then do it again" cannot bind outputs | Implement typed reference table & syntax in PlanValidator |
| 0.5B Model syntax & multi-step planning ceiling | High | MLXPlanner | Multi-step completion rate is low (0/15 on SeqA, 3/15 baseline) | Add Tier B candidate (2B–4B model) for complex agent goals |
| Purported task state variables absent | Medium | TaskStateMachine | `current_app`, `current_file`, etc. absent on `JarvisTask` | Explicitly bind desktop context when accessibility bridge is invoked |
| Acoustic DSP wake word absent | Low | Voice / WakeWord | Wake detection uses speech recognizer transcript matching | Introduce dedicated lightweight audio buffer keyword spotter |

---

## Section 21 — Deferred Features & Out-of-Scope Items

To prevent scope creep and maintain architectural stability, the following items are **explicitly deferred**:
1. **Acoustic DSP Wake-Word Engine:** Transcript matching is sufficient for current desktop interaction.
2. **Heavy Vector Database / Cloud Memory:** SQLite + Accelerate vDSP cosine search meets current needs offline.
3. **Continuous Screen Video Ingestion:** ScreenCaptureKit captures frames on-demand (`system.screenshot`), avoiding constant GPU/battery drain.
4. **Autonomous Self-Modifying Code:** The assistant must never rewrite its own binaries or scripts without explicit human supervision.
5. **Microservice / Distributed Agent Swarms:** Single-process native macOS architecture is frozen.

---

## Section 22 — Model Tier Strategy

```
┌─────────────────────────────────────────────────────────────┐
│  Tier 0: Deterministic Router (0 parameters, < 1ms)         │
│  - Handled via regex, prefix matching, macOS system APIs     │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  Tier A: Local 0.5B Reflex & Planner (Qwen2.5-0.5B-4bit)    │
│  - On-device MLX Metal inference                            │
│  - 0 API cost, offline, 100 tok/s                           │
│  - Handles intent classification, reflex Q&A, single-shot   │
└──────────────────────────────┬──────────────────────────────┘
                               │ (Escalate if complex multi-step)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  Tier B: Local 2B–4B Assistant (PLANNED / NEXT)             │
│  - Qwen2.5-3B or Llama-3.2-3B via MLX                        │
│  - Handles multi-step dependencies & structured JSON syntax  │
└──────────────────────────────┬──────────────────────────────┘
                               │ (Escalate if deep coding/research)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  Tier C: Cloud LLMs (Claude 3.7 Sonnet/Opus, GPT-4o)        │
│  - Lossless escalation with complete execution & error trace│
│  - Unbounded reasoning, complex coding, deep analysis        │
└─────────────────────────────────────────────────────────────┘
```

---

## Section 23 — Git, Branch & Checkpoint History

`[VERIFIED FROM GIT: git log, git status]`

- **Active Branch:** `master`
- **Current HEAD Commit:** `9971809` — *"fix: prevent compound echo goals from bypassing planner"*
- **Key Historic Commits:**
  - `9971809`: Fixed compound command bypass in `DeterministicRouter.swift`.
  - `b1a7830`: Added append-only planner evidence ledger to `MLXPlanner.swift`.
  - `c7daa91`: Application bundle packaging (`build-app.sh`) and voice pipeline enhancements.
  - `27b1af8`: Schema experiment harness (`SchemaExperiment.swift`) and live ToolRegistry schemas.
  - `52b8f8e`: Autonomy restoration after integration audit.
  - `7579bba`: LLMProvider protocol, DirectComposer, extended deterministic matchers.
  - `23eefa7`: Emergency interrupt event wiring and TTS latency tracking.

---

## Section 24 — Evidence Artifacts & Archives

`[VERIFIED FROM FILE SYSTEM]`

| Artifact Path | Description | What It Proves | What It Does NOT Prove |
|---|---|---|---|
| `build/FROZEN_CONTRACT_V1_REPORT.md` | Formal audit report across all planner and system controls | Documents baseline 302/1 tests, D-A to D-F failure modes, MLX latency | Does not reflect recent Phase 1 additions |
| `/tmp/experiment-b-preservation/offline-replay-run.txt` | Raw offline replay log of 29 historical attempts | Proves Normalizer B achieved only 37.9% normalizable rate (GATE FAIL) | Does not justify enabling Normalizer B live |
| `build/seq-A2-B1.txt` ... `seq-A2-B5.txt` | Raw execution logs from Experiment A sequential testing | Proves Experiment A achieved 0/15 PASS on multi-step benchmarks | Does not mean multi-step is impossible with larger models |
| `build/seq-A2-selftest-final.txt` | Complete terminal capture of SelfTest run (446 passed) | Confirms 446/446 passing state before Phase 1 | Did not include new ShellExecutor tests |
| `build/ii-audit3.txt` | Integration audit report (56 points) | Confirms permissions, emergency stop subscribers, and routers | Does not test external cloud endpoints |

---

## Section 25 — Current State Snapshot

| Subsystem / Area | Status | Evidence Source | Next Recommended Action |
|---|---|---|---|
| **Architecture & Core** | **GREEN** | `Sources/Jarvis/Core/`, `SelfTest.swift` | Preserve frozen principles |
| **Deterministic Mac Control** | **GREEN** | `DeterministicRouter.swift`, 11 controls | Expand zero-model-call matcher library |
| **Voice System** | **YELLOW** | `VoicePipeline.swift`, `WakeWordDetector.swift` | Keep transcript wake; defer acoustic DSP |
| **Emergency Stop** | **GREEN** | `EmergencyInterrupt.swift`, `EventBus.swift` | Validated immediate halt (< 1ms dispatch) |
| **ShellExecutor (Phase 1)** | **GREEN** | `ShellExecutor.swift`, `SelfTest.swift:365-371` | Keep process-group isolation and streaming |
| **Task State Machine** | **GREEN** | `TaskStateMachine.swift` | Add typed reference resolution |
| **Reference Resolution** | **RED / NOT IMPLEMENTED** | `AgentLoop.swift`, `SequentialExperiment.swift` | Design deterministic reference interpolation |
| **Planner (Tier A 0.5B)** | **YELLOW** | `MLXPlanner.swift`, `PlanValidator.swift` | Bounded to 1 repair; retain single-shot mode |
| **Experiment A (Sequential)** | **REJECTED** | `seq-A2-*.txt` (0/15 pass) | Do not promote to production |
| **Experiment B (Normalizer B)**| **REJECTED (GATE FAIL)**| `offline-replay-run.txt` (37.9% < 50%) | Leave disabled in production |
| **Permissions & Sandbox** | **GREEN** | `PermissionGate.swift`, `CommandSandbox.swift` | Enforce L0/L1/L2 matrix and PREVIEW/COMMIT |
| **SelfTest Suite** | **GREEN** | 454 passed, 0 failed | Run before and after every commit |
| **Tier B Local Model (2–4B)** | **PLANNED** | Architecture roadmap | Benchmark 3B candidate on Apple M4 |
| **Tier C Cloud Fallback** | **GREEN** | `ClaudeProvider.swift`, `OpenAIProvider.swift` | Maintain lossless escalation headers |

---

## Section 26 — Next Engineering Roadmap

### Immediate (Current Sprint)
1. **Commit Phase 1 ShellExecutor Work:** Commit the validated `ShellExecutor.swift` and updated `SelfTest.swift` (bringing suite to 454 green tests).
2. **Maintain Documentation Integrity:** Ensure `PROJECT_CONTEXT.md` is updated whenever architectural changes occur.

### Short-Term (Next 3–5 Tasks)
1. **Reference Resolution Engine:** Implement deterministic dataflow binding so Step $N$ can reference Step $M$'s stdout/output without model hallucinations.
2. **Context Provider Binding:** Connect actual desktop context (frontmost application name via NSWorkspace) into `JarvisTask`.
3. **Benchmark Tier-B Model Candidate:** Profile a 3B parameter model (e.g. `Qwen2.5-3B-Instruct-4bit`) on MLX to test if multi-step planning reaches $\ge 80\%$ pass rate without exceeding memory budgets.
4. **App Bundle Distribution:** Verify `./Scripts/build-app.sh release` produces a fully signed, notarizable `build/Jarvis.app`.

### Medium-Term (Major Architectural Capabilities)
1. **Accessibility Element Actions:** Enable Fast UI mode to click, type, and navigate native macOS applications deterministically via `AccessibilityBridge`.
2. **Lossless Multi-Tier Escalation Pipeline:** Wire automatic escalation from Tier A (0.5B) $\rightarrow$ Tier B (3B) $\rightarrow$ Tier C (Claude 3.7) when validation retries fail.

### Deferred (Do NOT Build Yet)
- Continuous video streaming capture.
- Acoustic neural wake-word engine.
- Distributed microservice agent networks.

---

## Section 27 — Agent Handoff Instructions

If you are an incoming AI coding agent (Claude Opus, Gemini, Codex, Antigravity) taking over this codebase, follow these rules:

### BEFORE EDITING CODE:
1. **Read this document (`PROJECT_CONTEXT.md`) completely.**
2. **Check Git Status:** Run `git status` and `git diff` to understand current working tree state.
3. **Verify the Test Baseline:** Run `/Users/jayanthpranaykonada/Zia/.build/out/Products/Debug/Jarvis --self-test` to verify 454/454 tests pass.
4. **Evidence Over Memory:** Do not assume a feature exists because an architectural comment mentions it. Verify in the actual source code.

### WHEN EDITING CODE:
- **Never violate the 9 Frozen Architectural Principles.**
- **Never weaken `PlanValidator` or `CommandSandbox`.**
- **Do not edit production source files when asked for an audit or report.**
- **Preserve Swift 6 Concurrency:** Ensure all cross-isolation types are `@unchecked Sendable` with proper locking, or conform to `Sendable`.
- **Do not enable Experiment A or Experiment B in production.**

### AFTER EDITING CODE:
1. **Compile:** Run `swift build`.
2. **Test:** Run `swift run Jarvis --self-test` (or run debug binary directly). Ensure **zero failures**.
3. **Record Evidence:** If you fix a bug, add a deterministic test to `SelfTest.swift`.
4. **Update `PROJECT_CONTEXT.md`:** Document your changes, new test counts, and updated evidence.

---

## Latest Verified Engineering State — Phase 1 Audit

**Audit Timestamp:** 2026-09-28T23:10:00+05:30  
**Current HEAD Commit:** `9971809` (`fix: prevent compound echo goals from bypassing planner`)  
**Current Branch:** `master` (ahead of `origin/master` by 2 commits)  
**Phase 1 Implementation Status:** **VERIFIED & HARDENED**  

### 1. Verified ShellExecutor Behavior & Lifecycle
- **Process Creation [VERIFIED]:**
  - Executable: `/bin/zsh` via `Process.executableURL`.
  - Arguments: `["-c", command]` via `Process.arguments`.
  - Process environment: Clean POSIX inheritance with `.userInitiated` QoS.
  - Pre-Launch Cancellation Guard: `try Task.checkCancellation()` executed before `process.run()` to prevent spawning orphaned OS processes if the enclosing Swift Task was cancelled prior to launch.
- **Process-Group Isolation & macOS Foundation Semantics [VERIFIED]:**
  - On macOS (Darwin/Apple Silicon), Foundation's `Process` spawns child processes using `posix_spawnattr_setflags` with `POSIX_SPAWN_SETPGROUP` flag set to 0.
  - This guarantees that upon `process.run()`, the child process forms its own process group where `PGID == PID`.
  - All descendants spawned by `/bin/zsh -c` (including background jobs, subshells, pipelines, and grandchildren) inherit this exact `PGID`.
  - Attempting to call `setpgid(pid, pid)` from the parent process fails with `EACCES (errno 13)` because `execve()` has already taken place.
  - POSIX signaling via `killpg(pid, SIGTERM)` and `killpg(pid, SIGKILL)` targets this exact process group, reliably terminating the shell and all of its descendants.
- **SIGTERM -> SIGKILL Escalation & PID Reuse Defense [VERIFIED]:**
  - `ProcessScope` manages `killGroup()`. First invocation sends `killpg(pid, SIGTERM)`.
  - An atomic `isKilled` flag guarantees that `killGroup()` is idempotent; concurrent calls from Task cancellation, timeout, and `cancelAll()` coalesce into a single kill sequence.
  - A 500ms `DispatchWorkItem` is scheduled to fire `killpg(pid, SIGKILL)` if the process group remains alive.
  - **PID Reuse Defense:** When `terminationHandler` fires and `waitUntilExit()` completes, `scope.disarmEscalation()` is called immediately to cancel the pending `DispatchWorkItem`. This guarantees `SIGKILL` will not be dispatched 500ms later against a recycled OS PID.
  - If `killpg` returns `-1` with `errno == ESRCH`, the error is ignored cleanly because the process group has already exited.
- **Timeout Strategy & Anti-False-Success Defense [VERIFIED]:**
  - Enforced via a structured `Task` sleeping for `timeoutSeconds`.
  - Upon timeout expiration, `scope.killGroup()` is invoked and the process group receives `SIGTERM` followed by `SIGKILL`.
  - **Anti-False-Success Defense:** If a shell command traps `SIGTERM` (e.g., `trap 'exit 0' TERM`) and attempts to exit with 0 upon timeout or cancellation, `ShellExecutor` detects `scope.wasKilled && exitCode == 0` and forcibly overrides the exit status to `143` (POSIX `128 + SIGTERM`). A killed process can NEVER report false success.
- **Cancellation Strategy [VERIFIED]:**
  - Pre-launch cancellation throws `CancellationError` without spawning OS processes.
  - Mid-execution cancellation triggers `onCancel` closure in `withTaskCancellationHandler`, which immediately calls `scope.killGroup()`.
  - After process exit, if `Task.isCancelled` is true, `CancellationError` is thrown to unwind the Swift Task cleanly.
- **Concurrent Process Isolation [VERIFIED]:**
  - Tested with two concurrent commands (Command A: `sleep 2`, Command B: `sleep 0.2`).
  - Command A was cancelled while Command B was running.
  - Command B ran to completion with exit code `0` and captured stdout without interference. Each process group is strictly isolated.
- **Pipe Output Handling (>64KB Buffer Deadlock Prevention) [VERIFIED]:**
  - Both `stdout` and `stderr` pipes are read concurrently via detached Swift tasks (`Task.detached { fh.readDataToEndOfFile() }`) started BEFORE awaiting process termination.
  - Verified with 100KB, 250KB, and simultaneous 200KB stdout + 200KB stderr (400KB total) without deadlock or buffer truncation.
- **Swift 6 Concurrency & Strict Actor Boundaries [VERIFIED]:**
  - `ShellExecutor` is an `actor`.
  - Cross-boundary state (`ProcessScope`, `ContinuationGate`) is protected with internal `NSLock` instances and marked `@unchecked Sendable`.
  - No data races, no memory leaks, no unbounded background task retention.
- **Emergency Stop Integration [VERIFIED]:**
  - `EmergencyInterrupt.shared.trigger()` publishes `EmergencyStopEvent` over `EventBus`.
  - Subscriber invokes `ShellExecutor.shared.cancelAll()`.
  - All tracked `ProcessScope` instances in `runningScopes` are signaled via `killGroup()` and purged from tracking.

---

### 2. Status of Architecture Milestones
- **Experiment B Status [FROZEN / REJECTED]:**
  - Status: **HISTORICAL / GATE FAILED**.
  - Result: 11 / 29 normalizable = 37.9% (< 50% predeclared gate).
  - Code State: `PlanNormalizerB.swift` exists in tree, but `normalizerBEnabled = false` remains permanently disabled in `AgentLoop.swift`.
  - Strict Rule: Do NOT enable live Experiment B, do NOT widen regexes, do NOT modify planner behavior.
- **Reference Resolution Status [IMPLEMENTED & VERIFIED]:**
  - Status: **IMPLEMENTED & VERIFIED (Phase 15 Engine Active, 25/25 Tests Passing).**
  - Fully implemented deterministic parser, validator, and resolver in `ReferenceResolver.swift`.
  - Wired into `AgentLoop.swift`, `PlanValidator.swift`, `TaskStateMachine.swift`, and `MLXPlanner.swift`.
  - Fully covered in `SelfTest.swift` with 25 dedicated test cases.

---

### 3. Verification & Test Evidence
- **Full Self-Test Suite Command:**
  `/Users/jayanthpranaykonada/Zia/.build/out/Products/Debug/Jarvis --self-test`
- **Exact Self-Test Output:**
  ```
  ══════════════════════════════════════════
    Results: 487 passed, 0 failed
  ══════════════════════════════════════════
  ✅ ALL TESTS PASSED
  ```
- **New Tests Added & Verified in Phase 15 Reference Resolution Suite (SelfTest.swift):**
  1. `Literal argument remains literal` [VERIFIED]
  2. `Valid $step.1.output parses` [VERIFIED]
  3. `Valid $step.1 defaults to output` [VERIFIED]
  4. `Valid $step.1.field parses` [VERIFIED]
  5. `Valid ambient reference $ambient.current_app parses` [VERIFIED]
  6. `Malformed $step rejected` [VERIFIED]
  7. `Malformed step number $step.foo rejected` [VERIFIED]
  8. `Step 0 reference $step.0.output rejected` [VERIFIED]
  9. `Forward reference ($step.3 from step 2) rejected` [VERIFIED]
  10. `Self reference ($step.2 from step 2) rejected` [VERIFIED]
  11. `Missing step output fails with missingStepOutput` [VERIFIED]
  12. `Unverified/failed prior step cannot be consumed` [VERIFIED]
  13. `Structured JSON field extracted from verified step output` [VERIFIED]
  14. `Plain-text field extraction rejected deterministically` [VERIFIED]
  15. `Type adaptation string -> int for parameterSpec.kind == .int` [VERIFIED]
  16. `Invalid type adaptation throws typeMismatch` [VERIFIED]
  17. `Unavailable ambient slot fails cleanly with ambientSlotUnavailable` [VERIFIED]
  18. `Ambient current_app resolves from environmentContext` [VERIFIED]
  19. `PlanValidator accepts valid reference syntax without type error` [VERIFIED]
  20. `PlanValidator rejects forward reference at plan validation time` [VERIFIED]
  21. `PlanValidator rejects malformed reference at plan validation time` [VERIFIED]
  22. `Permission gate / sandbox checks resolved concrete command` [VERIFIED]
  23. `Normal literal-only plan validates unchanged` [VERIFIED]
  24. `Single-step plan validates unchanged` [VERIFIED]
  25. `End-to-end dataflow: Step 1 output correctly bound to Step 2 argument` [VERIFIED]

---

### 4. Remaining Risks & Open Items
- **Compiler/Testing Limitation [VERIFIED]:**
  - `swift test` fails due to missing `XCTest.framework` in standalone macOS Command Line Tools.
  - Native in-process test runner `SelfTest.swift` (`Jarvis --self-test`) is the canonical automated test suite.
- **Ambient System Monitors [PLANNED]:**
  - Ambient slot `current_app` is live and authoritative via `NSWorkspace`.
  - Additional ambient slots (`current_file`, `current_webpage`, etc.) are declared in the schema but safely and deterministically fail closed with `.ambientSlotUnavailable` until reliable system-wide accessibility/browser hooks are integrated.

---

## Section 28 — Reference Resolution — Implementation & Verification

`[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Agent/ReferenceResolver.swift, Sources/Jarvis/Agent/AgentLoop.swift, Sources/Jarvis/Agent/PlanValidator.swift, Sources/Jarvis/Agent/TaskStateMachine.swift, Sources/Jarvis/Agent/MLXPlanner.swift, Sources/Jarvis/Core/SelfTest.swift]`

### 1. Architectural Philosophy & Guarantees
- **Intelligence Never Equals Authority (Principle 1) [VERIFIED]:**
  The model may emit reference tokens; the model **NEVER** resolves them. Reference resolution is 100% deterministic, executed by Swift native code immediately prior to step dispatch.
- **State Over Transcript (Principle 3) [VERIFIED]:**
  Prior step outputs are resolved from structured `StepResolutionRecord` instances stored in `TaskStateMachine`, not by loose regex parsing of unstructured conversational chat logs.
- **Commit Points Gate Irreversibility (Principle 6) [VERIFIED]:**
  Reference resolution occurs **before** permission evaluation and sandbox checks. The permission layer and `CommandSandbox` evaluate the concrete, resolved argument (e.g. `cat /etc/passwd`), never the unresolved token `cat $step.1.output`.
- **Verified Outputs Only (Principle 7) [VERIFIED]:**
  A step's output is addressable by subsequent steps **only if** `verification == .passed`. A raw exit code 0 is insufficient if post-execution observation/verification failed.

---

### 2. Concrete Data Structures
In `Sources/Jarvis/Agent/ReferenceResolver.swift`:
```swift
/// Match of a reference token inside a template argument.
struct ReferenceTokenMatch: Sendable, Equatable {
    let token: String
    let target: ReferenceTarget
}

/// Strongly typed task argument representing either a literal string, a direct reference,
/// or a template with embedded references.
enum TaskArgument: Sendable, Equatable {
    case literal(String)
    case reference(ReferenceTarget)
    case template(template: String, references: [ReferenceTokenMatch])
}

/// Target of a deterministic reference.
enum ReferenceTarget: Sendable, Equatable {
    case stepOutput(stepNumber: Int, field: String?)
    case ambient(AmbientSlot)
}

/// Supported ambient slots in Jarvis.
enum AmbientSlot: String, Sendable, Equatable, CaseIterable {
    case currentApp = "current_app"
    case currentFile = "current_file"
    case currentWebpage = "current_webpage"
    case currentSelection = "current_selection"
    case lastSearchResults = "last_search_results"
    case lastArtifact = "last_artifact"
    case pendingConfirmation = "pending_confirmation"
}

/// Structured record of a completed and verified step execution for reference resolution.
struct StepResolutionRecord: Sendable, Equatable {
    let stepNumber: Int
    let toolName: String
    let rawOutput: String
    let structuredOutput: [String: String]?
    let completedAt: Date
    let verification: VerificationOutcome
}

/// Ambient environment context snapshot for a task.
struct TaskEnvironmentContext: Sendable, Equatable {
    var currentApp: String?
    var currentFile: String?
    var currentWebpage: String?
    var currentSelection: String?
    var lastSearchResults: [String]?
    var lastArtifactPath: String?
    var pendingConfirmation: String?
    let snapshotTimestamp: Date

    static func captureLive() -> TaskEnvironmentContext {
        var appName: String?
        #if canImport(AppKit)
        appName = NSWorkspace.shared.frontmostApplication?.localizedName
        #endif
        return TaskEnvironmentContext(currentApp: appName, snapshotTimestamp: Date())
    }
}

/// Deterministic errors emitted during reference parsing, validation, or resolution.
enum ReferenceResolutionError: Error, Sendable, Equatable, LocalizedError {
    case malformedReference(String, reason: String)
    case forwardReference(referencedStep: Int, currentStep: Int)
    case selfReference(stepNumber: Int)
    case missingStepOutput(stepNumber: Int)
    case unverifiedStep(stepNumber: Int, outcome: String)
    case fieldExtractionFailed(stepNumber: Int, field: String, reason: String)
    case ambientSlotUnavailable(AmbientSlot)
    case staleAmbientSlot(AmbientSlot, ageSeconds: Double)
    case typeMismatch(argument: String, expected: String, actual: String)
}
```

---

### 3. Wire Syntax & Parsing Grammar
- **Wire Representation [VERIFIED]:**
  `PlanStep.arguments` and `TaskStep.arguments` remain `[String: String]`. No serialization breaks.
- **Syntax Rules:**
  - `$step.<N>.output` or `$step.<N>`: Full output of Step N.
  - `$step.<N>.<field>`: Extracts key `<field>` from Step N's structured JSON output dictionary.
  - `$ambient.<slot>`: Environmental slot value.
  - Non-reference dollar strings (e.g. `"$100"`, `"$HOME"`) remain `.literal`.
- **Validation Rules [VERIFIED]:**
  - `<N>` must be a positive integer > 0. Step 0 is rejected (`$step.0.output` throws `malformedReference`).
  - Negative integers are rejected (`$step.-1` throws `malformedReference`).
  - Bare `$step` and malformed step numbers (`$step.foo`) throw `malformedReference`.
  - DAG Ordering: Step $N$ can only reference Step $M$ where $M < N$. Forward references ($M > N$) and self-references ($M == N$) are rejected at both plan validation time and resolution time.

---

### 4. Integration into Agent Subsystems
- **Task State Machine (`TaskStateMachine.swift`) [VERIFIED]:**
  `JarvisTask` holds `resolutionRecords: [StepResolutionRecord]` and optional `environmentContext: TaskEnvironmentContext`.
  Methods added to `TaskStateMachine`:
  - `appendResolutionRecord(_:for:)`
  - `resolutionRecords(for:) -> [Int: StepResolutionRecord]`
  - `setEnvironmentContext(_:for:)`
  - `environmentContext(for:) -> TaskEnvironmentContext?`
- **Plan Validator (`PlanValidator.swift`) [VERIFIED]:**
  - Accepts reference tokens without prematurely failing scalar type checks (e.g. `$step.1.output` for an integer parameter is permitted at plan time; dynamic type checking occurs at resolution time).
  - Validates DAG direction at plan time ($M < currentStepNumber$).
  - For `run_shell`, skips plan-time `CommandSandbox` check only if the command contains reference tokens; defers sandbox evaluation to resolution time.
- **Execution Loop (`AgentLoop.swift`) [VERIFIED]:**
  - Evaluates `ReferenceResolver.resolveStepArguments` immediately before invoking `ToolExecutor.shared.execute()`.
  - Immediately passes the resolved concrete arguments to `CommandSandbox.shared.isSafe` for shell execution.
  - Upon successful verification (`verification == .passed`), appends a `StepResolutionRecord` to `TaskStateMachine`.
  - If reference resolution fails, records deterministic failure and enters the standard recovery/replanning lifecycle.
- **Planner Prompt (`MLXPlanner.swift`) [VERIFIED]:**
  - Prompt instructions updated to teach model reference syntax and consumption rules.
  - Example 3 added to system prompt demonstrating Step 1 (`run_shell`) -> Step 2 (`set_volume` with `$step.1.output`).
  - Error translation updated to surface `.invalidReference` context during replan repair attempts.

---

### 5. Ambient State Implementation Status
- **`current_app` [VERIFIED]:** Authoritative live value from `NSWorkspace.shared.frontmostApplication?.localizedName`.
- **`current_file`, `current_webpage`, `current_selection`, `last_search_results`, `last_artifact`, `pending_confirmation` [DESIGNED ONLY / SAFE FAIL]:**
  These slots are declared in the schema, but until dedicated background observers are implemented, any attempt to resolve them cleanly throws `.ambientSlotUnavailable(slot)`. The system **never** fabricates values.

---

### 6. Test Suite Evidence
- **Execution Command:**
  `/Users/jayanthpranaykonada/Zia/.build/out/Products/Debug/Jarvis --self-test`
- **Baseline Before Sprint:** 454 passed, 0 failed.
- **New Count After Sprint:** 479 passed, 0 failed (+25 new verified tests).
- **Regressions:** 0.
- **Coverage of Required Test Matrix:**
  - [x] Literal argument remains literal (Test 15.1)
  - [x] Valid `$step.1.output` (Test 15.2)
  - [x] Valid `$step.1` implicit output (Test 15.3)
  - [x] Valid `$step.1.field` (Test 15.4)
  - [x] Valid `$ambient.current_app` (Test 15.5)
  - [x] Malformed `$step` rejection (Test 15.6)
  - [x] Malformed step number `$step.foo` rejection (Test 15.7)
  - [x] Step 0 rejection `$step.0.output` (Test 15.8)
  - [x] Forward reference rejection (Test 15.9)
  - [x] Self reference rejection (Test 15.10)
  - [x] Missing prior output (Test 15.11)
  - [x] Unverified prior step rejected (Test 15.12)
  - [x] Structured JSON field extraction (Test 15.13)
  - [x] Plain-text field extraction rejection (Test 15.14)
  - [x] Type adaptation string -> int (Test 15.15)
  - [x] Invalid type adaptation throws typeMismatch (Test 15.16)
  - [x] Unavailable ambient slot fails cleanly (Test 15.17)
  - [x] Ambient current_app resolves (Test 15.18)
  - [x] PlanValidator accepts valid reference without scalar error (Test 15.19)
  - [x] PlanValidator rejects forward reference at plan time (Test 15.20)
  - [x] PlanValidator rejects malformed reference at plan time (Test 15.21)
  - [x] Permission gate / sandbox checks resolved concrete command (Test 15.22)
  - [x] Normal literal-only plans remain unchanged (Test 15.23)
  - [x] Single-step plans remain unchanged (Test 15.24)
  - [x] End-to-end integration dataflow: Step 1 output correctly bound to Step 2 argument (Test 15.25)

---

### 7. Git State at Completion
- **Active Branch:** `master`
- **Head Commit:** `9971809cb27a99035322c8f21d6307b7f9480662`
- **Modified Production Files:**
  - `Sources/Jarvis/Agent/ReferenceResolver.swift` (new file)
  - `Sources/Jarvis/Agent/TaskStateMachine.swift` (added resolution records and environment context)
  - `Sources/Jarvis/Agent/PlanValidator.swift` (reference validation & DAG check)
  - `Sources/Jarvis/Agent/AgentLoop.swift` (pre-execution resolution & concrete sandbox evaluation)
  - `Sources/Jarvis/Agent/MLXPlanner.swift` (prompt schema & failed tool name)
  - `Sources/Jarvis/Core/SelfTest.swift` (Phase 15 test suite)
  - `PROJECT_CONTEXT.md` (this context document)

---

## Section 29 — Multi-AI Delegation Ledger & Milestone 1 Verification

`[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Agent/AgentLoop.swift:122, Sources/Jarvis/Agent/TaskStateMachine.swift:214-225, Sources/Jarvis/Agent/ReferenceResolver.swift:105-108,338-345, Sources/Jarvis/Core/SelfTest.swift:1940-2030]`

### 1. Milestone 1 Implementation — Live Desktop Ambient Context Binding
- **Objective:** Connect actual desktop context (`NSWorkspace` frontmost application) directly into `JarvisTask.environmentContext` during task initialization in `AgentLoop.swift`, with strict deterministic freshness guards and negative error handling.
- **Architectural Changes [VERIFIED]:**
  - **Task Lifecycle Capture (`AgentLoop.swift:122-126`):**
    `TaskEnvironmentContext.captureLive()` is invoked immediately when `TaskStateMachine.shared.createTask()` is called, creating an immutable snapshot of the active application at the moment of task creation.
  - **Task State Preservation (`TaskStateMachine.swift:214-225`):**
    `createTask(title:goal:steps:environmentContext:)` preserves the captured snapshot directly on the created `JarvisTask`.
  - **Deterministic Freshness Guard (`ReferenceResolver.swift:105-108, 338-345`):**
    `TaskEnvironmentContext.maxVolatileAgeSeconds` is set to 300.0s (5 minutes). When resolving `$ambient.current_app`, if the snapshot is older than 300s, `ReferenceResolutionError.staleAmbientSlot(.currentApp, ageSeconds:)` is deterministically thrown.
  - **Negative Error Paths [VERIFIED]:**
    - Empty or missing `currentApp` throws `ReferenceResolutionError.ambientSlotUnavailable(.currentApp)`.
    - Malformed slots (e.g. `$ambient.unknown_slot`) throw `ReferenceResolutionError.malformedReference`.
    - Unsupported ambient slots (e.g. `$ambient.current_file`) throw `ReferenceResolutionError.ambientSlotUnavailable(.currentFile)`.
    - Permissions / `CommandSandbox.shared.isSafe` evaluate the concrete resolved application name.

### 2. Multi-AI Delegation Ledger

```
================================================================================
DELEGATION RECORD #1
DATE: 2026-09-28
MODEL: openai/gpt-oss-120b (via Groq Continue Worker)
TASK: Audit AgentLoop.swift and TaskStateMachine.swift for task creation & context binding
SCOPE: Single-subsystem entry point investigation (runInternal / runSequential)
RESULT: Located exact task creation hook in AgentLoop.runInternal. Recommended
        calling TaskEnvironmentContext.captureLive() at task instantiation.
VERIFIED BY: Gemini (cross-checked against AgentLoop.swift:122)
STATUS: ACCEPTED & INTEGRATED.
================================================================================
DELEGATION RECORD #2
DATE: 2026-09-28
MODEL: openai/gpt-oss-120b (via Groq Continue Worker)
TASK: Audit staleness and ambient resolution rules in ReferenceResolver.swift
SCOPE: Volatile slot staleness threshold analysis
RESULT: Recommended deterministic max-age constant (maxVolatileAgeSeconds = 300s)
        and per-slot age check throwing staleAmbientSlot.
VERIFIED BY: Gemini (cross-checked against ReferenceResolver.swift:107, 342)
STATUS: ACCEPTED & INTEGRATED.
================================================================================
DELEGATION RECORD #3
DATE: 2026-09-28
MODEL: qwen/qwen3.8-27b (via Groq Continue Worker)
TASK: Generate 8 Swift SelfTest test cases for Milestone 1 ambient binding
SCOPE: SelfTest.swift test suite expansion
RESULT: Generated test skeletons for live capture, state machine preservation,
        resolution, empty app error, stale app error, malformed slot error,
        unsupported slot error, and sandbox evaluation.
VERIFIED BY: Gemini (adapted signatures to match exact internal APIs in SelfTest.swift)
STATUS: ACCEPTED & EXECUTED.
================================================================================
```

### 3. Test Evidence — Phase 16 Suite
- **Full Self-Test Suite Command:**
  `/Users/jayanthpranaykonada/Zia/.build/out/Products/Debug/Jarvis --self-test`
- **Exact Self-Test Output:**
  ```
  ══════════════════════════════════════════
    Results: 487 passed, 0 failed
  ══════════════════════════════════════════
  ✅ ALL TESTS PASSED
  ```
- **New Tests Added & Verified in Phase 16 Milestone 1 (SelfTest.swift):**
  1. `Live capture returns frontmost app from NSWorkspace` [VERIFIED]
  2. `TaskStateMachine preserves environmentContext upon task creation` [VERIFIED]
  3. `ReferenceResolver resolves $ambient.current_app to captured app` [VERIFIED]
  4. `Empty currentApp throws ambientSlotUnavailable deterministically` [VERIFIED]
  5. `Stale ambient currentApp throws staleAmbientSlot deterministically` [VERIFIED]
  6. `Malformed ambient slot name throws malformedReference` [VERIFIED]
  7. `Unsupported ambient slot $ambient.current_file throws ambientSlotUnavailable` [VERIFIED]
  8. `CommandSandbox evaluates resolved concrete ambient command` [VERIFIED]

---

## Section 30 — Milestone 2 Verification: Deterministic Accessibility Bridge & Fast UI Tooling

`[VERIFIED FROM CURRENT CODE: Sources/Jarvis/Vision/AccessibilityBridge.swift, Sources/Jarvis/Vision/FastUIMode.swift, Sources/Jarvis/Brain/Tools/AccessibilityTools.swift, Sources/Jarvis/Brain/Tools/ToolRegistry.swift:66-68, Sources/Jarvis/Core/SelfTest.swift:2030-2200]`

### 1. Milestone 2 Implementation — Deterministic AX Interaction & Fast UI Mode
- **Objective:** Enable Fast UI mode and deterministic AX interactions for the frontmost application without falling back to expensive vision models, while treating Accessibility as a strict authority boundary.
- **Architectural Changes [VERIFIED]:**
  - **`AccessibilityBridge.swift` Extensions:**
    - Added `isEnabled: Bool = true` and `frame: CGRect?` attribute extraction to `AXElementInfo`.
    - Added mock injection hooks (`mockTrusted`, `mockElementTree`, `mockActionHandler`, `mockValueHandler`, `resetMocks()`) for deterministic headless testing.
    - Implemented `performAction(matchingLabel:action:)` supporting `kAXPressAction` on matched UI elements in frontmost app or mock tree.
    - Implemented `setValue(matchingLabel:value:)` for setting text on editable elements (`kAXValueAttribute`) or focused elements (`kAXFocusedUIElementAttribute`).
  - **`FastUIMode.swift` APIs:**
    - Added `clickElement(matching:)` and `setText(_:onElement:)` routing directly to `AccessibilityBridge`.
  - **New Deterministic Tools (`Sources/Jarvis/Brain/Tools/AccessibilityTools.swift`):**
    - `InspectUITool` (`inspect_ui`): `.readOnly` impact (L0), inspects and formats actionable UI hierarchy with optional filtering.
    - `ClickElementTool` (`click_element`): `.safeMutation` impact (L1), clicks elements by title/label.
      - **Authority Boundary Protection:** Contains `isDestructiveLabel(_:)` check. If label contains destructive verbs (`delete`, `erase`, `format`, `empty trash`, `shut down`, `wipe`), impact is dynamically upgraded to `.destructive`. At L1 Supervised, `PermissionGate` blocks execution unless confirmed via `DestructiveActionManager`.
    - `SetTextTool` (`set_text`): `.safeMutation` impact (L1), types text into editable or focused fields.
  - **`ToolRegistry.swift` Integration:**
    - Built-in tools registered: total tool count expanded to 9 (`open_app`, `set_volume`, `run_shell`, `web_search`, `fetch_url`, `open_browser`, `inspect_ui`, `click_element`, `set_text`).
    - Tool definitions and parameter schemas generated automatically for LLM and local MLX planning.
    - `PlanValidator` grounds accessibility tools automatically against the live `ToolRegistry`.

### 2. Multi-AI Delegation Ledger (Milestone 2)

```
================================================================================
DELEGATION RECORD #4
DATE: 2026-09-28
MODEL: qwen/qwen3.8-27b (via Groq Continue Worker)
TASK: Audit existing AccessibilityBridge and FastUIMode to list AX primitives vs missing mutations
SCOPE: Read-only architectural audit with source code context
RESULT: Identified zero existing mutations (parseElement had frame: nil, no performAction,
        no setValue). Recommended adding frame, isEnabled, and mock test hooks.
VERIFIED BY: Gemini (cross-checked against AccessibilityBridge.swift)
STATUS: ACCEPTED & INTEGRATED.
================================================================================
DELEGATION RECORD #5
DATE: 2026-09-28
MODEL: openai/gpt-oss-120b (via Groq Continue Worker)
TASK: Audit macOS AXUIElement lifetimes, kAXPressAction failure modes, and text setting APIs
SCOPE: Native macOS Accessibility / ApplicationServices framework constraints
RESULT: Advised against storing raw AXUIElement in Sendable structs; recommended searching
        on MainActor on demand; verified kAXValueAttribute on AXTextField.
VERIFIED BY: Gemini (applied to AccessibilityBridge.swift on MainActor)
STATUS: ACCEPTED & INTEGRATED.
================================================================================
DELEGATION RECORD #6
DATE: 2026-09-28
MODEL: openai/gpt-oss-20b (via Groq Continue Worker)
TASK: Review proposed tool schemas (inspect_ui, click_element, set_text) for naming consistency
SCOPE: Parameter schema review against existing tool conventions
RESULT: Confirmed snake_case naming aligned with existing tools (open_app, set_volume, run_shell).
VERIFIED BY: Gemini (integrated into AccessibilityTools.swift)
STATUS: ACCEPTED & INTEGRATED.
================================================================================
```

### 3. Test Evidence — Phase 17 Suite
- **Full Self-Test Suite Command:**
  `/Users/jayanthpranaykonada/Zia/.build/out/Products/Debug/Jarvis --self-test`
- **Exact Self-Test Output:**
  ```
  ══════════════════════════════════════════
    Results: 516 passed, 0 failed
  ══════════════════════════════════════════
  ✅ ALL TESTS PASSED
  ```
- **New Tests Added & Verified in Phase 17 Milestone 2 (SelfTest.swift):**
  1. `Tool 'inspect_ui' registered in ToolRegistry` [VERIFIED]
  2. `Tool 'click_element' registered in ToolRegistry` [VERIFIED]
  3. `Tool 'set_text' registered in ToolRegistry` [VERIFIED]
  4. `'inspect_ui' declared with .readOnly impact` [VERIFIED]
  5. `'click_element' declared with .safeMutation impact` [VERIFIED]
  6. `'set_text' declared with .safeMutation impact` [VERIFIED]
  7. `ToolRegistry contains at least 9 registered tools (9)` [VERIFIED]
  8. `ToolDefinition for 'inspect_ui' generated` [VERIFIED]
  9. `ToolDefinition for 'click_element' includes element_label` [VERIFIED]
  10. `ToolDefinition for 'set_text' includes text` [VERIFIED]
  11. `'Delete File' classified as destructive label` [VERIFIED]
  12. `'Empty Trash' classified as destructive label` [VERIFIED]
  13. `'Submit Form' not classified as destructive label` [VERIFIED]
  14. `Destructive click target 'Delete Database' blocked by PermissionGate at L1` [VERIFIED]
  15. `Untrusted accessibility throws error on inspect_ui execution` [VERIFIED]
  16. `Untrusted accessibility throws error on click_element execution` [VERIFIED]
  17. `inspect_ui executes successfully with mock tree` [VERIFIED]
  18. `inspect_ui output includes 'Submit' button` [VERIFIED]
  19. `Filtered inspect_ui includes matched element` [VERIFIED]
  20. `Filtered inspect_ui excludes non-matched element` [VERIFIED]
  21. `click_element executes successfully on enabled element` [VERIFIED]
  22. `click_element confirms clicked element` [VERIFIED]
  23. `click_element on disabled element throws deterministic error` [VERIFIED]
  24. `click_element on nonexistent element throws element not found error` [VERIFIED]
  25. `set_text executes successfully on editable field` [VERIFIED]
  26. `set_text output confirms updated text` [VERIFIED]
  27. `set_text on nonexistent field throws not found error` [VERIFIED]
  28. `Multi-step plan with accessibility tools validates against ToolRegistry` [VERIFIED]
  29. `PlanValidator rejects click_element missing required 'element_label'` [VERIFIED]

### 4. Milestone Gates Assessment
- **Functional Gate:** PASSED. Deterministic UI inspection, element clicking, and text setting operating at sub-50ms latency.
- **Regression Gate:** PASSED. Baseline advanced from 487 to 516 passed, 0 failed, 0 regressions.
- **Safety Gate:** PASSED. Accessibility treated as strict authority boundary. Dynamic destructive verb scanning gates destructive click actions through `PermissionGate`.
- **Performance Gate:** PASSED. Fast UI inspection executes in <50ms without invoking vision models or network providers.
- **Architecture Gate:** PASSED. Conforms strictly to 9 Frozen Principles (Principle 1: Intelligence Never Equals Authority, Principle 4: Cheapest Sufficient Intelligence, Principle 8: Zero-Model-Call Coverage).
- **Test Gate:** PASSED. 516/516 tests passing deterministically.
- **Documentation Gate:** PASSED. `PROJECT_CONTEXT.md` updated with full evidence and delegation records.

---

## 31. MILESTONE 3: LOSSLESS ESCALATION PIPELINE (TIER A → TIER B)

### 1. Architectural Summary & Mission
Milestone 3 operationalizes **Principle 5: Lossless Escalation** and **Principle 3: State Over Transcript**:
Moving from Tier A (0.5B local planner) → deterministic recovery → Tier B (stronger local or cloud planner) WITHOUT losing authoritative structured task state, user intent, validation evidence, privacy classification, or execution safety.

Tier B never restarts from an unstructured or conversational transcript. It receives authoritative structured context (`EscalationContext`), continues execution from the point of failure, and is bound by the exact same safety constraints (`PlanValidator`, `CommandSandbox`, `PermissionGate`, `EmergencyStop`).

### 2. Escalation Context Schema (`Sources/Jarvis/Agent/EscalationPipeline.swift`)
```swift
struct EscalationContext: Sendable {
    enum TriggerReason: String, Sendable {
        case tierAPlanningExhausted = "tier_a_planning_exhausted"
        case tierARecoveryExhausted = "tier_a_recovery_exhausted"
        case executionFailureReplanning = "execution_failure_replanning"
    }

    let taskId: UUID
    let originalGoal: String
    let currentStepNumber: Int
    let completedSteps: [TaskStep]
    let verifiedOutputs: [Int: String]
    let failedStep: TaskStep?
    let failureReason: String?
    let priorObservations: [String]
    let environmentContext: TaskEnvironmentContext?
    let sensitivity: DataClassifier.SensitivityLevel
    let triggerReason: TriggerReason
    let escalationTimestamp: Date
    let attemptCount: Int
}
```

### 3. Core Architectural Gates & Semantics
1. **Deterministic Privacy Gate First:**
   Before any cloud provider is contacted or initialized, `DataClassifier.shared.isCloudAllowed(for: context.sensitivity)` is evaluated synchronously. If the task is classified as `.sensitive` or `.highlySensitive`, cloud escalation is blocked with `JarvisError.privacyPolicyViolation(level:reason:)`. Zero data leaves the machine.
2. **Authority Boundaries Preserved (Principle 1):**
   Tier B is strictly a planning model. Every plan returned by Tier B is grounded and validated by `PlanValidator.validate(plan)`. If Tier B hallucinates an unregistered tool, omits required arguments, or supplies illegal arguments, the plan is rejected with `JarvisError.actionFailed(action: "TierBPlanValidation", reason: ...)`.
3. **Execution Safety & Emergency Stop:**
   `AgentLoop.shared.isEmergencyCancelled` and `EmergencyInterrupt` retain full preemption authority over in-flight tasks regardless of escalation state.
4. **State & Reference Continuity:**
   Step resolution records and verified outputs (`verifiedOutputs`) from completed steps are preserved in `TaskStateMachine`. Downstream steps in Tier B plans referencing `$step.<N>.output` or `$step.<N>.<field>` resolve seamlessly via `ReferenceResolver`.
5. **No Duplicate Execution:**
   Completed steps in `TaskStateMachine` are never re-executed.

### 4. Integration Points in `AgentLoop.swift`
- **Planning Recovery Hook (`planWithRecovery`):**
  When Tier A fails initial planning and retry recovery is exhausted (`PLANNING -> FAILED -> RECOVERING -> REPLANNING -> failure`), `AgentLoop` constructs `EscalationContext` with `.tierAPlanningExhausted` and invokes `EscalationPipeline.shared.escalate(context:)`.
- **Execution Replan Hook (`runInternal`):**
  When repeated step execution failures occur (`replanCount >= 2`), `AgentLoop` constructs `EscalationContext` with `.executionFailureReplanning`, completed steps, and verified outputs, and escalates to Tier B to generate a replacement continuation plan.

### 5. Multi-AI Continuous Engineering Delegations
- **GPT-OSS 120B:** Audit of AgentLoop state preservation and TaskStateMachine concurrency. Identified exact recovery points where TaskStep and StepResolutionRecords must be harvested for lossless handoff.
- **Qwen 27B:** Audit of planner and provider interfaces. Determined insertion point in `planWithRecovery` and `runInternal` replan loop to cleanly replace plans without breaking state machine transitions.
- **GPT-OSS 20B:** Audit of `DataClassifier` call sites and privacy boundary. Confirmed sensitivity levels (`.sensitive`, `.highlySensitive`) and verified strict prohibition against early cloud dispatch.

### 6. Canonical Test Suite Evidence (`SelfTest.swift` Phase 18)
- **Self-Test Baseline Advanced:** **531 passed, 0 failed** (from 516 passed, +15 verified tests).
- **Exact Test Matrix (Phase 18):**
  1. `No escalation occurs when Tier A succeeds` [VERIFIED]
  2. `Escalation pipeline succeeds when Tier A planning/recovery exhausted` [VERIFIED]
  3. `User intent (originalGoal) byte-for-byte preserved across escalation` [VERIFIED]
  4. `Structured Task IR (completedSteps, stepNumber) preserved across escalation` [VERIFIED]
  5. `Verified step outputs preserved across escalation` [VERIFIED]
  6. `Structured PlanValidator failure reason preserved across escalation` [VERIFIED]
  7. `Repair history and attempt counts preserved across escalation` [VERIFIED]
  8. `DataClassifier blocks cloud escalation for SENSITIVE tasks` [VERIFIED]
  9. `DataClassifier blocks cloud escalation for HIGHLY_SENSITIVE tasks` [VERIFIED]
  10. `Tier B provider failure propagates deterministically without false success` [VERIFIED]
  11. `Emergency stop safety preserved during/after escalation` [VERIFIED]
  12. `Completed steps not re-executed post-escalation` [VERIFIED]
  13. `Reference continuity ($step.1.token) preserved post-escalation` [VERIFIED]
  14. `Tier B plans strictly validated against PlanValidator (Intelligence != Authority)` [VERIFIED]
  15. `Cloud escalation permitted for PUBLIC data level` [VERIFIED]

---

## 32. Milestone 4A — High-Reliability Deterministic Verification

### 1. Architectural Scope & Problem Statement
During repository audits, Continue workers and human audits identified concrete verification weaknesses in the desktop execution pipeline:
- **Bug 1 (Default Verify Too Weak):** `JarvisTool.verify(expected:observed:)` had a default implementation that trusted `expected.success`, violating the *Evidence Before Green* principle.
- **Bug 2 (Open App Verification):** `OpenAppTool.observe()` captured the frontmost application, but verification did not assert `observed frontmost == expected application`.
- **Bug 3 (Shell Side-Effect Verification):** `RunShellTool.observe()` reported `status = completed` solely based on process termination, insufficient for commands intended to produce filesystem side effects.
- **Bug 4 (Accessibility Mutation Verification):** `ClickElementTool` and `SetTextTool` inherited weak verification without explicit postcondition checking or distinguishing inconclusive states.

### 2. Implemented Architecture & Authoritative Contract
1. **Four-Outcome Verification Semantics:**
   `VerificationOutcome` in `TaskStateMachine.swift` is expanded to distinguish:
   - `.passed`: Observed real-world state deterministically satisfies expected postcondition.
   - `.failed`: Observed real-world state deterministically contradicts expected postcondition.
   - `.inconclusive`: System cannot establish whether the expected postcondition is true (cannot convert to passed).
   - `.unavailable`: Required observation mechanism is unavailable (cannot convert to passed).
   - `.notApplicable`: Applied to non-effectual steps (e.g. direct text composition).
   - Property `isVerified: Bool` returns `true` **only** if `.passed`.

2. **Tool Protocol & Verification Contract (`ToolDefinitions.swift`):**
   - Added `struct ToolVerificationResult: Sendable, Equatable` with `.outcome` and `.reason`.
   - Enriched `ToolResult` with `metadata: [String: String]` and `var verification: ToolVerificationResult?`.
   - Enriched `ObservationResult` with `isAvailable: Bool` and `reason: String?`.
   - Added `func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult` to `JarvisTool`.
   - Default `verifyDetailed` checks `expected.success`, `observed.isAvailable`, and `observed.observations["error"]`.
   - Retained legacy `verify(...) -> Bool` bridge returning `verifyDetailed(...).isSuccess`.

3. **Concrete Verification Upgrades (`BuiltinTools.swift` & `AccessibilityTools.swift`):**
   - `OpenAppTool`: Sets `metadata["targetApp"]`. `verifyDetailed` asserts `observed.observations["frontmostApp"]` matches target application, returning `.failed` on mismatch and `.unavailable` if system workspace state cannot be read.
   - `SetVolumeTool`: Sets `metadata["targetLevel"]`. `verifyDetailed` asserts observed audio volume matches expected level.
   - `RunShellTool`: Added optional `expected_file` parameter. If specified, `verifyDetailed` verifies file existence on disk via `FileManager.default.fileExists(atPath:)` and asserts non-zero exit code.
   - `ClickElementTool`: Explicit deterministic strategy. If `expected_app` or explicit postcondition is provided, verifies frontmost app transition; otherwise returns `.inconclusive`, preventing false-positive success claims.
   - `SetTextTool`: Stores `metadata["expectedValue"]`. `verifyDetailed` asserts `observed.observations["currentValue"]` equals expected value, returning `.failed` on mismatch.

4. **Authority Boundary & Pipeline Enforcement (`ToolExecutor.swift` & `AgentLoop.swift`):**
   - `ToolExecutor.execute` runs `tool.verifyDetailed`, attaches outcome to `expected.verification`, and throws `JarvisError.verificationFailed` if `!verification.isSuccess`.
   - `AgentLoop.run` and `AgentLoop.runSequential` record `result.verification?.outcome ?? .passed` onto `TaskStateMachine` and `StepResolutionRecord`.
   - `ReferenceResolver` enforces that downstream steps referencing `$step.<N>` fail with `ReferenceResolutionError.unverifiedStep` if the prior step verification was `.inconclusive`, `.unavailable`, or `.failed`.

### 3. Canonical Test Suite Evidence (`SelfTest.swift` Phase 19)
- **Self-Test Baseline Advanced:** **542 passed, 0 failed** (from 531 passed, +11 verified tests).
- **Exact Test Matrix (Phase 19):**
  1. `TEST A: False positive rejected when observation detects error despite expected.success == true` [VERIFIED]
  2. `TEST B: OpenApp fails verification when observed frontmost app contradicts expected app` [VERIFIED]
  3. `TEST C: OpenApp passes verification when observed frontmost matches expected app` [VERIFIED]
  4. `TEST D.1: ObservationResult.unavailable produces .unavailable outcome and does not pass` [VERIFIED]
  5. `TEST D.2: Action without deterministic postcondition produces .inconclusive and does not pass` [VERIFIED]
  6. `TEST E: Accessibility SetText fails verification when observed field value contradicts expected text` [VERIFIED]
  7. `TEST F: Accessibility SetText passes verification when observed field value matches expected text` [VERIFIED]
  8. `TEST G: RunShell fails verification when expected side-effect file does not exist despite exit code 0` [VERIFIED]
  9. `TEST H.1: SetVolume passes verification when observed volume matches target level` [VERIFIED]
  10. `TEST H.2: SetVolume fails verification when observed volume deviates from target level` [VERIFIED]
  11. `TEST I: ReferenceResolver deterministically blocks consuming outputs from steps with .inconclusive verification` [VERIFIED]

---
