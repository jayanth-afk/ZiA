# ZiA Agent & Task Execution Architecture

This document describes the current autonomous execution system.

## Principle

An LLM is a reasoning worker, not an agent authority.

The authoritative agent is ZiA itself. The task system owns lifecycle, dependencies, resources, cancellation, permissions, verification, and recovery.

## Execution flow

```
request
  ↓
Intent / deterministic routing
  ↓
Task creation when work is durable or multi-step
  ↓
TaskOrchestration
  ├─ validate dependencies
  ├─ reject cycles
  ├─ wait for prerequisites
  ├─ acquire task resources
  └─ admit eligible work
       ↓
TaskWorkerPool
       ↓
provider selection / ProviderResourceBroker
       ↓
reasoning or tool execution
       ↓
verification
       ↓
terminal outcome
       ↓
resource release + dependent reevaluation
```

## Task lifecycle

Tasks have durable lifecycle state and can carry:

- priority
- parent task
- prerequisite task IDs
- result/error
- cancellation
- required resources

The state machine is authoritative. A transcript is never used as a substitute for task state.

## Dependencies

`TaskDependencyGraph`:

- validates dependency references
- rejects direct cycles
- rejects indirect cycles
- tracks waiting dependents
- reevaluates dependents after terminal outcomes

A dependent task cannot start simply because a model claims that its prerequisite is done.

## Resources

`TaskResourceLock` provides task-level exclusive resources.

Examples of the concept include a shared mutable workspace or another resource that cannot safely be touched by two tasks simultaneously.

Properties:

- deterministic ordering
- multi-resource deadlock prevention
- cancellation cleanup
- terminal release
- concurrent independent resources

Provider capacity is intentionally not implemented here.

## Provider admission

`ProviderResourceBroker` controls provider/model capacity and quota.

A task may be eligible at the task level and still wait because its selected provider is currently:

- at its concurrency ceiling
- quota exhausted
- budget blocked
- rate-limited
- unhealthy

The broker is cancellation-safe and releases reservations on every terminal path.

## Scheduling

Current scheduling is intentionally layered:

1. task eligibility
2. task priority/resource admission
3. provider suitability
4. provider capacity/quota admission
5. worker execution

Do not add another global scheduler without first proving an existing layer cannot express the required behavior.

## Cancellation

Cancellation is a first-class terminal outcome.

It must:

- stop active work where supported
- remove waiting entries
- release task resources
- release provider reservations
- prevent stale success
- reevaluate newly available work where appropriate

Foreground cancellation must not implicitly cancel unrelated background tasks.

## Failure and recovery

Failures are classified rather than blindly retried.

Provider-level behavior uses health, quarantine, and rate-limit cooldowns.

Task-level recovery uses bounded retry/replanning and preserves already verified work.

The system must never enter an infinite retry loop or repeat a deterministic failure unchanged.

## Verification

A successful model response is not proof of completion.

Tool actions require an independent verification outcome. Only verified success can advance the authoritative task state.

## Multi-agent/provider identity

Workers do not become separate ZiA identities.

The same canonical state is shared across:

- local MLX
- Groq
- Cerebras
- SambaNova
- OpenRouter
- ChatGPT Desktop
- other configured providers

Provider changes are implementation details from the user's perspective.

## Security

The model cannot directly execute shell commands or mutate files.

The path is:

```
model proposal
  → validation
  → PermissionGate / sandbox
  → trusted executor
  → verification
```

Destructive actions remain explicitly controlled.

## Current integration coverage

The repository currently has dedicated task/dependency/resource integration tests covering:

- dependency chains
- diamond dependencies
- cycle rejection
- dependency failure
- cancellation
- resource serialization
- independent-resource concurrency
- deterministic multi-resource locking
- provider capacity
- quota exhaustion
- provider recovery
- rate-limit behavior
- mixed multitask execution

The targeted integration suite currently passes **26/26**.

## Next engineering work

The next agent/scheduler work should improve the existing system rather than replace it:

1. richer task requirement extraction
2. stronger provider capability matching
3. quota intake for additional providers
4. foreground/background fairness
5. workload-aware concurrency
6. provider recovery/replanning
7. mixed-workload stress testing
8. physical desktop acceptance tests

Any new autonomous behavior must preserve the invariants above.
