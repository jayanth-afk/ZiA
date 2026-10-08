# ZiA

ZiA is a native macOS personal intelligence system built around one persistent identity, durable state, deterministic authority, and replaceable reasoning workers.

The project is no longer organized around a single model or a single agent loop. The current architecture treats models as disposable intelligence workers while ZiA owns identity, memory, task state, permissions, verification, orchestration, provider selection, and execution authority.

## Current verified repository state

- Repository: `/Users/jayanthpranaykonada/Zia`
- Branch: `master`
- Current HEAD at this documentation refresh: `0a0a81f`
- Working tree: clean and aligned with `origin/master`
- Swift test suite: **488 tests / 64 suites, 0 failures**
- Release build: **passes**
- The broader `Jarvis --self-test` runner exists and remains a separate verification gate. It was not re-counted in this documentation refresh because the Agent Bridge command window timed out before the full run completed; do not infer a self-test total from this README.

## What ZiA is now

ZiA has five important layers:

1. **Deterministic authority**
   - Intent classification, direct answers, system controls, validation, permissions, execution, and verification are code-owned.
   - Models never receive OS authority directly.

2. **Persistent cognition**
   - Canonical state, task state, memory, evidence, failures, artifacts, and user-facing continuity survive provider changes.
   - A provider can disappear without changing ZiA's identity.

3. **Multitask orchestration**
   - Tasks can run independently or through prerequisite graphs.
   - Task priorities, dependency blocking, resource locks, cancellation propagation, and terminal cleanup are implemented.
   - Independent resources remain concurrent.
   - Multi-resource acquisition is deterministic to prevent lock-order deadlocks.

4. **Adaptive intelligence**
   - Provider suitability scoring considers hard requirements and soft preferences such as capability fit, privacy, context size, structured output, complexity, latency, cost, health, quota, and capacity.
   - ProviderResourceBroker performs atomic provider/model admission, quota/capacity gating, budget policy, queueing, fairness, cancellation-safe release, and recovery.
   - ProviderManager owns provider health, circuit breaking, rate-limit cooldowns, availability reporting, and ranked routing.

5. **Safe execution**
   - LLM output is a proposal.
   - ZiA validates it, applies PermissionGate/sandbox policy, executes through trusted tools, independently verifies the result, then updates canonical state.
   - Failed verification is never silently treated as success.

## Current intelligence fleet

ProviderManager currently registers:

- local MLX reflex and normal workers
- Groq fast and strong workers
- Cerebras
- SambaNova
- OpenRouter
- ChatGPT Desktop
- Claude
- Gemini
- OpenAI

Availability is not the same as implementation. A provider may be registered in code while unconfigured, unverified, throttled, quarantined, or blocked by policy.

The intended policy is:

**deterministic/local capability first → eligible free/low-cost cloud capacity → strong external reasoning when justified → explicitly authorized paid capacity only.**

Paid providers must never become an accidental dependency.

## Multitasking model

The intended execution shape is:

```
ZiA
 └─ Task Orchestration
     ├─ Task A ── prerequisites/resources ── worker/provider
     ├─ Task B ── prerequisites/resources ── worker/provider
     └─ Task C ── prerequisites/resources ── worker/provider
                    │
                    ▼
          shared canonical ZiA state
```

The system does not create a separate identity for every worker. Workers are execution resources owned by ZiA.

## Current engineering priority

The foundation for multitasking and adaptive provider allocation is now present. The next work should improve intelligence and production robustness rather than introduce another competing scheduler.

### Next priorities

1. Finish and harden adaptive scheduling across real workload types.
2. Expand live quota/capacity intake to every provider that exposes useful signals.
3. Improve capability-aware ranking and dynamic model selection using real task requirements.
4. Integrate task priority/fairness with provider capacity without starving foreground interaction.
5. Strengthen provider recovery and re-planning under partial failure.
6. Add cross-task integration tests for mixed foreground/background workloads, provider exhaustion, dependency chains, cancellation, and recovery.
7. Continue validating the ChatGPT Desktop background path without stealing focus or changing macOS Spaces.
8. Keep voice/UI work behind core reliability unless a core integration requires it.

## Non-negotiable architecture rules

- Intelligence is not authority.
- State is more authoritative than transcript.
- Evidence is more authoritative than claims.
- Deterministic code wins when it can solve the problem.
- Provider switching must be invisible to the user's identity/session.
- Privacy constraints are hard routing constraints.
- Paid usage requires explicit policy authorization.
- Cancellation must clean up every resource reservation.
- Destructive actions require explicit control.
- No model is allowed to self-validate its own success.
- Do not create a second scheduler when an existing subsystem can be extended safely.

## Useful entry points

- `PROJECT_CONTEXT.md` — current engineering handoff and operating state
- `ZIA_ARCHITECTURE.md` — architecture and invariants
- `AGENTS.md` — task/agent execution architecture
- `JARVIS_PROGRESS.md` — implementation status and roadmap
- `Sources/Jarvis/Agent/` — task orchestration and execution
- `Sources/Jarvis/Brain/` — provider routing, capacity, quota, and cognition
- `Tests/JarvisTests/TaskDependencyIntegrationTests.swift` — current multitask integration coverage

When changing the architecture, update the canonical documentation in the same change. Never restore obsolete model/provider/test-count claims merely because they appear in older notes.
