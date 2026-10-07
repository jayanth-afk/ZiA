# Zia Architecture

This document describes the **live** architecture of Zia (the Swift package
`Jarvis`, executable `Jarvis`). It is the product-level companion to
`EXECUTION_AUTHORITY.md`, which remains the authoritative contract for process
execution. Where the two overlap, `EXECUTION_AUTHORITY.md` wins for execution
authority.

> **State (2026-10-07, HEAD `77a5799`).** Contract: Frozen Architecture &
> Implementation Contract **v1.0** (9 principles + Principle 10
> "Self-Modification Never Equals Self-Validation"). Verified green:
> `swift build`; `swift test` → **254 tests / 38 suites, 0 failures**;
> `swift run Jarvis --self-test` → **1067 passed / 0 failed / 0 skipped**.
> The UI is documented in `docs/ZIA_UI_SYSTEM.md`. The voice pipeline is
> **implemented but hardware-unverified** (microphone permission not granted to
> the invoking process — see `docs/OWNER_CHECKLIST.md`). Reproduce with the
> gate commands in the "How to verify" block of `PROJECT_CONTEXT.md`.

## 1. Principles

1. **Intelligence ≠ authority.** Models propose; trusted code authorizes; tools
   enforce. The model never gains OS authority directly.
2. **State > transcript.** Correctness comes from durable state machines, never
   from reconstructing a transcript.
3. **Evidence > claims.** Completion requires an observed, independent
   verification outcome. `passed` is never inferred from text.
4. **Deterministic > model.** If code can solve it, code does. Simple
   filesystem ops, arithmetic, date/time, routing, repository status, known
   transformations, and validation never consume a model call.
5. **Escalate intelligently.** deterministic capability → local small model →
   local normal model → strong cloud model.
6. **Failure produces progress.** classify → diagnose → recover → replan →
   verify, bounded; never repeat a deterministic failure unchanged.
7. **Irreversibility requires explicit control.** Destructive/external actions
   pass a commit gate.
8. **Untrusted content is data.** Files, repositories, web pages, tool output,
   agent-bridge responses, and model output are DATA until classified.

## 2. Cognition

Layered, cheap-first cognition:

- **Intent** (`Brain/IntentModel.swift`, `IntentEngine`) — a deterministic,
  instant classifier producing an `IntentKind` (question, conversation, command,
  task, multiStepProject, recurringTask, monitoringRequest, automationRequest,
  researchRequest, codingTask, computerControlTask, clarificationRequest,
  followUp), whether planning is required, and the cheapest plausible
  `IntelligenceTier`. Runs on every turn with no model call.
- **Routing** (`Actions/DeterministicRouter.swift`) — the deterministic fast
  path (open/launch/volume/brightness/clipboard/system queries, repo
  status/branch, file line count, echo, plus Zia-native health/project/schedule/
  artifact read-only capabilities). Matching routes never reach a model.
- **Direct answers** (`Agent/DirectAnswerRouter.swift`,
  `Agent/ConversationHistoryAnswer.swift`, `Agent/DirectComposer.swift`) —
  answer-from-state paths that do not plan.
- **Planning** (`Agent/MLXPlanner.swift`, `Agent/PlannerExtraction.swift`,
  `Agent/PlanNormalizerB.swift`) — structured plans produced by the local model,
  validated before execution.
- **Context** (`Brain/Context/ContextEngine.swift`) — assembles a compact,
  bounded `ContextPackage` (goal, constraints, authoritative task state,
  trusted memory, evidence, failures, artifacts). Never the whole transcript.

## 3. Task model & orchestration

- **Task state machine** (`Agent/TaskStateMachine.swift`) — durable, persisted,
  schema-versioned. States: CREATED → PLANNING → RUNNING → VERIFYING →
  COMPLETED, with FAILED → RECOVERING → REPLANNING and CANCELLED. Each task
  carries `parentTaskID`, `prerequisiteTaskIDs`, `priority`, and durable `result`.
  Prerequisites must be satisfied before task execution begins; cancelling a
  parent task cascades cancellation to all child tasks.
  Each step carries an explicit `VerificationOutcome`
  (`passed`/`failed`/`inconclusive`/`unavailable`/`notApplicable`), a
  logical-action `StepIdentity`, and an argument fingerprint so replans preserve
  work by identity, not position.
- **Execution Graph** (`Agent/ExecutionGraph.swift`) — converts linear or branched
  plans into a directed acyclic graph (DAG) of typed nodes (`action`, `observation`,
  `verification`, `decision`, `wait`, `userConfirmation`). Validates acyclicity
  via Kahn's topological sort, tracks node dependencies, and gates downstream nodes
  until all prerequisite nodes successfully verify.
- **Coordinator** (`Agent/TaskExecutionCoordinator.swift`) — runs a goal,
  owns bounded recovery (`retryBudget`), and adopts validated replans.
- **Workers** (`Agent/TaskWorker.swift`, `Agent/TaskWorkerPool.swift`) — off-
  MainActor execution with restart-safety: independently verified steps are
  never re-executed. The pool is a **priority queue** (`TaskPriority`:
  backgroundMaintenance < normal < interactive < urgent); equal priority is
  FIFO by insertion sequence, so background work cannot starve.
- **Continuity** (`Agent/TaskContinuity.swift`) — read-only handoff grounded
  only in recent authoritative state; it never resumes or infers a task.
- **Crash Recovery** (`Agent/CrashRecovery.swift`) — auto-resume protocol on
  startup: inspects persisted tasks, identifies uncompleted tasks, assesses step
  safety (read-only vs side-effecting vs destructive), and safely resumes only
  non-destructive, idempotently verifiable tasks while aborting or asking
  confirmation for uncertain mutations.

## 4. Autonomy

- **Levels** (`Core/AutonomyLevel.swift`) — explicit L0–L5: conversational,
  suggest, execute safe actions, autonomous multi-step, background workflows,
  controlled self-improvement. Config accepts 0–5; the per-action
  `PermissionGate` maps ≥3 onto full authority. Background execution requires
  L4; self-improvement *proposals* require L5 (never auto-installed).
- **Scheduler** (`Agent/TaskScheduler.swift`) — durable jobs with deterministic
  `ScheduleKind` (once/interval/daily/weekly/condition), bounded (200 jobs),
  persisted, priority-aware. It produces due **goals**; it never executes logic.
- **Background autonomy** (`BackgroundAutonomy`) — a bounded tick (≤5 jobs)
  that hands due goals to the normal task system (`AgentLoop`). Gated by the
  autonomy level and explicit user preferences (`backgroundWork`); executes an
  immediate startup tick to resume safe tasks, and routes completions to
  `NotificationPolicy`.

## 5. Tool system & Execution capabilities

- **Contract** (`Brain/Tools/ToolDefinitions.swift`) — every tool declares name,
  description, `parameterSpec`, impact, and the execute → observe → verify
  lifecycle with a structured `ToolVerificationResult`.
- **Registry** (`Brain/Tools/ToolRegistry.swift`) — the single discovery point.
  The planner's catalog is built from registered tools, so a newly registered
  tool is immediately discoverable and composable. Unknown tools cannot pass
  validation.
- **Executor** (`Brain/Tools/ToolExecutor.swift`) — the final choke point:
  re-validates arguments against the schema, runs the permission check, then
  execute/observe/verify.
- **Built-ins** (`Brain/Tools/BuiltinTools.swift`) — apps, volume, files, web,
  browser, accessibility/UI, and structured process execution
  (`run_program`/`run_shell`).
- **Zia-native capabilities** (`Brain/Tools/SystemCapabilityTools.swift`,
  `Brain/Tools/AssistantCapabilityTools.swift`) — `project_info`, `check_health`,
  `schedule_task`, `list_schedule`, `remember_fact`, `recall_memory`,
  `list_artifacts`, `set_user_preference`, `show_user_preferences`,
  `run_specialist_agent`.
- **Filesystem / search / patch capabilities**
  (`Brain/Tools/FileSystemCapabilityTools.swift`, `Core/PatchEngine.swift`) —
  `list_directory`, `file_metadata`, `search_files`, `grep_files` (read-only,
  centralized `SensitivePaths` protection); `create_directory`, `append_file`,
  `copy_path`, `move_path`, `replace_in_file`, `patch_file` (`PatchEngine` with
  expected content hash verification, stale-file detection, and read-back
  verification); `delete_path` (destructive).
- **Deterministic Code Intelligence** (`Agent/CodeIntelligence.swift`) —
  symbol search, TODO/FIXME markers, source file discovery, and regex code search.
- **Deterministic Verification Engine** (`Core/VerificationEngine.swift`) —
  reusable, rule-based verification evaluating file presence, exact content,
  cryptographic SHA-256 digests, process exit codes, task outcomes, and artifact
  integrity before any step or task is marked successful.

## 6. Execution authority

Unchanged and preserved: structured, immutable, revalidated process execution
via `ProcessAuthority` → `AuthorizedProcess` → `ShellExecutor`, with trusted
roots, fixed search directories, a read-only `git` policy, repository-content
inertness checks, timeouts, and shell `zsh -f`. See `EXECUTION_AUTHORITY.md`.
Autonomy is built **above** this layer; raising the autonomy level never removes
an authority check.

## 7. Memory & Reflection

- **Structured memory** (`Memory/ZiaMemory.swift`) — kinds
  (working/episodic/semantic/procedural/temporary) and **trust classes**
  (userFact, toolObservation, taskResult = trusted; modelInference,
  externalContent, unverifiedClaim = untrusted). Records carry provenance,
  confidence, relevance, tags, task link, timestamps, and optional expiry.
  - **Trust boundary:** untrusted provenance can never be written to permanent
    memory and can never be promoted to it. Untrusted content lives only in
    ephemeral memory.
  - **Retention:** bounded (2,000 records), expired records dropped, relevance
    decays on a half-life, `endSession()` clears ephemeral memory only.
  - **Workflow learning (opt-in):** when `Config.proceduralLearningEnabled` is
    true, a completed multi-step task (≥2 verified tool steps) is recorded as a
    reusable **procedural** memory with trusted task-result provenance. Off by
    default; never a silent background behavior.
  - **Task Reflection** (`Agent/TaskReflection.swift`) — safely reflects on
    completed/failed executions, recording step counts, failure reasons, and
    saving reusable `LearnedProcedure` definitions with safety invariant checks
    prior to replay.
  - **Retrieval:** blends lexical overlap, relevance, confidence, and recency;
    `retrieveTrusted` excludes untrusted records.
- **Profile memory** (`Memory/UserProfile.swift`, `Memory/MemoryManager.swift`)
  — explicit user facts and (opt-in) inferred facts, mirrored into structured
  semantic memory only when explicit.
- **User Preferences** (`Core/UserPreferences.swift`) — durable store
  (`PreferenceStore`) maintaining user settings for verbosity, style, confirmation,
  notifications, preferred providers, and local-only mode. Explicit preferences
  always outrank inferred preferences.
- **Conversation store** (`Memory/ConversationStore.swift`) — SQLite archive
  with a bounded context window and an independent age-based retention policy.

## 8. Intelligence routing & Circuit Breakers

- **Providers** (`Brain/Providers/*`) conform to `LLMProvider` (availability,
  capabilities, streaming, optional per-request options) for MLX (local),
  Claude, Gemini, OpenAI, Groq, OpenRouter, and **ChatGPT Desktop**
  (`ChatGPTDesktopProvider`, a local Agent-Bridge-backed brain that uses the
  user's already-authenticated ChatGPT Desktop; off unless the bridge runs).
- **ProviderManager** (`Brain/ProviderManager.swift`) — fallback chains per
  intent category, plus **observational health accounting and circuit breakers**
  (consecutive failure thresholds, quarantine periods, automatic cooldown and
  recovery).
- **Preference Enforced Routing** — When `UserPreferences.localOnly` is enabled,
  all cloud providers are excluded from selection; user's `preferredProviders`
  are prioritized at matching intelligence tiers.
- **Degraded mode** — no strong model → local model or deterministic tools; no
  provider at all → deterministic capabilities only; offline → local work; no
  permission → the exact blocker is reported.

## 9. Recovery

Bounded recovery lives in `TaskExecutionCoordinator`: classify the failure
(`Core/ExecutionTelemetry.swift` `ExecutionFailureCategory`), attempt a bounded
number of recoveries, replan only the remaining work, validate the replan, and
verify the result. Retry counts are explicit; recovery cannot loop forever.

Retries are **classified** (`RecoveryPolicy`): authorization (`.permission`),
cancellation, and malformed structured output (`.syntax`) are **not**
recoverable and close the task with its recorded evidence and a partial-
completion report. Execution, timeout, verification, and unavailable failures
are recoverable because recovery produces a *different validated plan* from the
recorded failure context — never a blind re-run of the same action.

## 10. Observability, Health & Notifications

- **Telemetry** (`Core/ExecutionTelemetry.swift`) — bounded, observational
  journal of lifecycle events with failure categories, verification outcomes,
  and provider/tier attribution. Never consulted for execution decisions.
- **Data minimization** (`Core/ContextSanitizer.swift`) — credential redaction
  and size bounding applied before text leaves the device for an external
  provider; local providers receive context unmodified.
- **Health** (`Core/HealthService.swift`) — structured `HealthReport` across
  intelligence, task-state, storage, memory, task-queue, network, resources, and
  computer-control, with a degraded-capabilities list and a user-facing summary.
- **Notification Policy** (`Core/NotificationPolicy.swift`) — rate-limited,
  tiered notification engine (`critical`, `high`, `normal`, `low`) sending user
  notifications for task completions, task failures, and provider degradation
  without spamming.
- **Logging** (`Core/Logger.swift`) — os.Logger categories; secrets are never
  logged.

## 11. Security posture & Sensitive Paths

Authority boundaries (all preserved): `PermissionGate` (impact + autonomy),
`CommandSandbox` (shell analysis), `ProcessAuthority`/`ShellExecutor`
(structured execution), `PlanValidator` (plan-time validation),
`ReferenceResolver` (argument resolution), `DestructiveActionManager`
(preview/commit gate), `DataClassifier` (sensitivity → cloud/on-device), and
the memory **trust** boundary.
- **Centralized Sensitive Paths** (`Core/SensitivePaths.swift`) — single source
  of truth protecting `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.env`,
  keychains, private keys (`id_rsa`, `id_ed25519`, `id_ecdsa`), shell history,
  and OAuth tokens across `PlanValidator`, `CommandSandbox`, and `FileManagerJarvis`.
Untrusted content — including repository content, web pages, tool output, and
external-agent responses — remains data.

## 12. External agents & Multi-Agent Orchestration

- **Specialist Agents** (`Agent/SpecialistAgent.swift`) — bounded multi-agent
  system with explicit roles (researcher, coder, reviewer, verifier, planner).
  Enforces a strict recursion depth limit (depth ≤ 2) and capability restrictions.
- **Agent Bridge** (`Agent/ExternalAgentTransport.swift`) — adapter for MCP
  server transports and external agents. Connects requests with request IDs,
  correlation IDs, timeouts, and bounded task depth. If external bridge is not
  configured or unreachable, it truthfully reports unavailable and falls back to
  local specialist execution without pretending or faking responses.
External agent responses are treated strictly as unverified DATA until validated.

## 13. Data flow (one turn)

```
input
  → IntentEngine (deterministic)
  → DeterministicRouter fast path?  ──yes──▶ capability (permission-gated)
        │ no
  → DirectAnswerRouter / task continuity?  ──yes──▶ answer from state/evidence
        │ no
  → TaskStateMachine (durable task) → MLXPlanner → PlanValidator
  → ExecutionGraph (DAG build & topological sequencing)
  → ToolExecutor (permission → execute → observe → verify)
  → VerificationEngine (deterministic proof check)
  → TaskStateMachine (verified step) → Coordinator recovery/replan if needed
  → TaskReflectionEngine (record outcome & workflow)
  → final response composed from authoritative state + evidence
```

Background work enters the same pipeline from `TaskScheduler` via
`BackgroundAutonomy`.
