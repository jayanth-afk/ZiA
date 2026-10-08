# ZiA Architecture

This is the current product architecture for ZiA. It intentionally describes the live system rather than historical milestones.

## 1. Core invariant

**ZiA is the persistent intelligence; LLMs are disposable reasoning workers.**

A provider may be swapped, throttled, cancelled, or unavailable. The user's identity, task state, memory, permissions, and execution authority remain in ZiA.

## 2. Authority boundary

```
User / request
      ↓
ZiA cognition + canonical state
      ↓
provider selection
      ↓
LLM proposes reasoning/action
      ↓
ZiA validates proposal
      ↓
PermissionGate + sandbox
      ↓
trusted tool execution
      ↓
independent verification
      ↓
canonical state / memory
```

No LLM receives direct OS authority.

## 3. Cognition

### Intent

`IntentEngine` classifies requests without requiring a model for every turn. It identifies the likely request category and the cheapest plausible intelligence tier.

### Deterministic routing

`DeterministicRouter` handles operations that code can solve reliably: system controls, known repository queries, arithmetic, direct state reads, and other bounded operations.

### Direct answers

State-backed conversational answers bypass planning when the authoritative information is already available.

### Planning

`MLXPlanner` and other reasoning workers produce structured proposals. `PlannerExtraction` and validators constrain what can reach execution.

### Context

The context compiler creates a bounded `ContextPackage` from canonical state, active goals, constraints, memory, evidence, failures, and artifacts.

## 4. Task architecture

### TaskStateMachine

Tasks are durable and stateful. They carry priority, parent/child relationships, prerequisites, and results.

### TaskDependencyGraph

Dependencies form a directed graph.

- submission validates referenced tasks
- self-cycles are rejected
- indirect cycles are rejected
- dependents remain blocked until prerequisites actually satisfy their terminal-success conditions
- dependency outcomes trigger reevaluation

### TaskOrchestration

`TaskOrchestration` is the integration layer connecting dependency eligibility, task resources, and the existing worker pool.

It deliberately extends the existing worker architecture instead of creating a competing scheduler.

### TaskResourceLock

Named task resources are exclusively owned.

- acquisition is deterministic
- multiple resources are acquired in stable order
- waiters are deterministic
- cancellation cleans wait queues
- terminal tasks release ownership
- unrelated resources remain concurrent

This protects shared task-level resources and is not a provider throttle.

### TaskWorkerPool

The worker pool remains the execution mechanism. Task priority is preserved and equal-priority work is ordered deterministically.

## 5. Provider architecture

### ProviderManager

ProviderManager owns:

- provider registry
- availability
- verified availability
- operational health
- circuit breaking
- rate-limit cooldowns
- failure accounting
- routing decisions

### ProviderResourceBroker

The broker is the admission-control layer.

```
candidate provider
      ↓
atomic broker admission
      ↓
provider request
      ↓
release on every terminal path
```

It accounts for:

- concurrent requests
- known request/token quotas
- credit/budget policy
- priority/fairness
- cancellation
- recovery/cooldown

### ProviderSuitabilityScorer

Suitability is deterministic and explainable.

Hard constraints remove ineligible workers. Soft scoring ranks the remaining workers.

Inputs include:

- required capabilities
- privacy mode
- context window
- structured output
- task complexity
- latency sensitivity
- cost class
- capacity
- observed quota
- provider health

Provider suitability is selection logic; the broker remains the final resource-admission boundary.

## 6. Current provider fleet

ProviderManager currently registers:

| Worker | Role |
|---|---|
| MLX reflex | local low-latency fallback |
| MLX normal | local general fallback |
| Groq fast | low-latency cloud reasoning |
| Groq strong | stronger cloud reasoning |
| Cerebras | independent strong cloud path |
| SambaNova | strong cloud path, policy-controlled |
| OpenRouter | external routing/escalation path |
| ChatGPT Desktop | authenticated local desktop reasoning path |
| Claude | provider integration |
| Gemini | provider integration |
| OpenAI | provider integration |

Registration is not equivalent to live availability. The runtime must report actual availability truthfully.

## 7. Canonical state and memory

Provider-specific context is compiled from ZiA's canonical state.

The system should preserve:

- current identity
- active task graph
- user constraints
- trusted memory
- evidence
- previous failures
- artifacts
- provider-independent conversation meaning

A provider switch must not reset the conversation or make a new assistant identity.

## 8. Failure and recovery

Provider failures and rate limits are different conditions.

- rate limit → temporary cooldown
- repeated provider failures → quarantine/circuit breaker
- task failure → bounded recovery/replanning
- cancellation → terminal cancellation plus resource cleanup
- verification failure → no false success

Every path must release provider reservations and task resources.

## 9. Privacy and cost

Privacy requirements are hard routing constraints.

Paid providers are policy-controlled resources. Being configured or implemented does not authorize spending.

The scheduler must never convert unknown quota into assumed capacity.

## 10. Agent Bridge integration

ChatGPT Desktop is integrated through Agent Bridge rather than receiving direct filesystem or shell authority.

Agent Bridge provides a local communication/control fabric for:

- project inspection
- file reads/writes
- safe command execution
- git operations
- task delegation
- agent messaging
- presence
- collaboration
- diagnostics
- ChatGPT/Claude desktop transport

ZiA remains the authority over its own task/state system.

## 11. Voice and UI

Voice and UI are product surfaces over the same core intelligence.

They must not create a second execution architecture.

The core architecture takes priority over visual polish. Hardware-dependent voice and physical desktop behavior must be labeled as hardware acceptance tests when not reproducible in the automated suite.

## 12. Current roadmap

### Near term

1. Expand quota intake across providers.
2. Harden adaptive scheduling under real mixed workloads.
3. Improve cross-task fairness and foreground priority.
4. Strengthen provider recovery/replanning.
5. Add end-to-end stress tests for dependencies + resources + provider capacity.
6. Validate background ChatGPT operation across real macOS Spaces.

### Medium term

- richer model capability metadata
- better latency prediction
- task cost estimation
- durable budget accounting
- persistent provider health history
- adaptive context sizing
- workload-aware concurrency
- stronger background autonomy

### Long term

ZiA should behave like a personal intelligence runtime rather than a chatbot:

```
one identity
  + persistent state
  + memory
  + task graph
  + many workers
  + adaptive scheduling
  + safe tools
  + verification
  + recovery
  = ZiA
```

Any future change that violates that model should be treated as an architectural change, not a local implementation detail.
