# ZiA Project Context — Current Canonical Engineering Handoff

**Last refreshed:** 2026-10-08  
**Repository:** `/Users/jayanthpranaykonada/Zia`  
**Branch:** `master`  
**HEAD:** `0a0a81f`  
**Working tree:** clean, aligned with `origin/master`

This file describes the current implementation only. Historical milestones and superseded architectures are intentionally omitted.

## Verification baseline

Verified during the current repository audit:

- `swift test`: **488 tests / 64 suites, 0 failures**
- `swift build -c release`: **passes**
- Targeted `TaskDependencyIntegrationTests`: **26/26 pass**
- The full in-process `Jarvis --self-test` exists, but the current Agent Bridge execution window timed out before its complete result could be observed. This is a tooling timeout, not a reported ZiA self-test failure. Treat the full self-test as **not independently re-verified in this refresh**.

Agent Bridge itself was also tested from its current repository:

- `npm test`: **372 tests**
- **364 passed**
- **8 skipped**, all explicitly gated live-model/desktop checks
- **0 failed**

## Canonical product model

ZiA is one persistent assistant. Models/providers are workers.

The persistent layer owns:

- identity
- canonical state
- conversation continuity
- memory
- tasks
- dependencies
- resource ownership
- permissions
- verification
- provider policy
- recovery
- user-facing behavior

Reasoning providers may be replaced, unavailable, throttled, or cancelled without creating a new ZiA identity.

## Cognition pipeline

A normal request should move through the cheapest trustworthy path capable of solving it:

```
request
  ↓
deterministic intent/routing
  ↓
direct answer when state already contains the answer
  ↓
task/context compilation
  ↓
provider suitability + health/quota/capacity
  ↓
resource admission
  ↓
reasoning worker
  ↓
validated tool proposal
  ↓
PermissionGate / sandbox
  ↓
tool execution
  ↓
independent verification
  ↓
canonical state + memory update
```

The model never bypasses the execution boundary.

## Task orchestration

The production task system now has a single orchestration path rather than a second independent scheduler.

### Dependencies

- `JarvisTask.prerequisiteTaskIDs` expresses task dependencies.
- `TaskDependencyGraph` validates submissions and rejects self/indirect cycles.
- Unsatisfied prerequisites leave a task blocked.
- Completion/failure/cancellation produces an outcome that reevaluates dependents.
- Failed prerequisites do not incorrectly unblock dependents.

### Task resources

`TaskResourceLock` owns named task-level exclusive resources.

Properties:

- deterministic waiter ordering
- deterministic multi-resource acquisition ordering
- independent resources can execute concurrently
- cancellation removes waiting tasks
- terminal tasks release owned resources
- released resources trigger reevaluation

This is deliberately separate from provider capacity.

### Provider resources

`ProviderResourceBroker` owns provider/model admission.

It handles:

- atomic capacity reservation
- concurrency ceilings
- known request/token quota
- credit/budget policy
- queueing
- priority/fairness
- cancellation-safe release
- retry-after/cooldown behavior
- provider recovery

Task resources answer **"may this task use this shared resource?"**  
Provider resources answer **"may this provider execute another request right now?"**

## Provider intelligence

ProviderManager currently contains the provider fleet and operational health state.

Current provider registrations include:

- MLX local reflex/normal
- Groq fast/strong
- Cerebras
- SambaNova
- OpenRouter
- ChatGPT Desktop
- Claude
- Gemini
- OpenAI

The registry is not a claim that every provider is live or configured.

### Suitability

`ProviderSuitabilityScorer` ranks eligible workers using deterministic, explainable inputs.

Hard exclusions include:

- missing required capability
- local-only privacy requirement violated
- insufficient context window
- unhealthy/throttled provider
- exhausted known quota

Soft scoring considers:

- task complexity
- reasoning/coding fit
- structured output support
- latency sensitivity
- cost class
- current capacity
- observed quota

### Health and recovery

ProviderManager tracks:

- availability vs verified availability
- consecutive failures
- quarantine/circuit-breaker state
- rate-limit cooldowns
- recent success/failure
- recent latency

A rate limit is treated as a temporary capacity condition, not automatically as a provider failure.

## Quota and budget policy

Quota data remains observational unless explicitly known.

Known values can include:

- requests remaining
- tokens remaining
- credit remaining
- reset time

Unknown quota must remain unknown; the scheduler must not fabricate capacity.

Paid providers must be blocked unless paid usage is explicitly authorized by policy. A provider being implemented is not permission to spend money.

## ChatGPT Desktop

ZiA includes a `ChatGPTDesktopProvider` backed by Agent Bridge.

The bridge can expose a headless ChatGPT/Codex engine when installed and healthy, with a UI/accessibility route as fallback.

The architectural requirement is background operation:

- no unnecessary `NSApp.activate`
- no user-facing focus theft for background work
- preserve the user's active Space when possible
- fail truthfully when the dedicated target/transport is unavailable

Physical multi-Space verification remains an environment-level acceptance test, not something to claim from unit tests alone.

## Memory and context

Context is compiled from canonical state rather than blindly replaying the transcript.

Relevant inputs include:

- active goal
- authoritative task state
- user constraints
- trusted memory
- prior evidence
- failures
- artifacts
- current provider requirements

The context compiler should preserve semantic continuity while adapting payload size and detail to the selected worker.

## Safety invariants

1. Models propose; trusted code authorizes.
2. Tool output is untrusted data until classified.
3. Verification is independent of model claims.
4. Destructive operations require explicit authority.
5. Privacy constraints are hard constraints.
6. Cancellation must release provider and task resources.
7. A failed provider must not cause an infinite retry loop.
8. Paid usage must never be implicit.
9. Provider changes must not change ZiA identity or state.
10. Self-modification never equals self-validation.

## Current gaps

These are the real remaining engineering fronts:

1. **Complete quota intelligence:** collect useful quota signals from every applicable HTTP provider, not only the providers currently emitting them.
2. **Adaptive scheduling depth:** continue integrating task priority, provider suitability, capacity, latency, cost, privacy, and fairness into one coherent decision path.
3. **Whole-workload scheduling:** validate mixed foreground/background workloads rather than testing only isolated provider admission.
4. **Recovery quality:** improve provider recovery/replanning under partial failures while preserving bounded retries.
5. **Physical desktop acceptance:** validate background ChatGPT behavior on the real macOS multi-Space setup.
6. **Hardware voice acceptance:** keep microphone/TCC validation separate from logic-test claims.
7. **Production observability:** make routing/resource decisions explainable without turning diagnostics into authority.

## Future direction

The desired end state is not "one smarter model." It is a persistent intelligence operating system:

- many reasoning workers
- one canonical ZiA state
- dynamic task graph
- adaptive provider allocation
- durable memory
- safe tools
- independent verification
- background autonomy
- graceful degradation
- recoverable execution

The scheduler should eventually make decisions such as:

> "This is a foreground conversational turn, needs strong reasoning, contains no private data, and ChatGPT Desktop is healthy; use it."

or:

> "This is a background coding task. ChatGPT is busy, Groq 120B has capacity, the task requires coding and structured output, and paid providers are unauthorized; use the strongest eligible free worker."

Those decisions should be deterministic, explainable, budget-aware, and invisible as provider changes to the user.
