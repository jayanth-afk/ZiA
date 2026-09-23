# JARVIS Progress

## Current Phase
Phase D — Real Agent Loop (MLX-backed planner replacing heuristic `planSteps`)

## Verified
- Phase C baseline (still intact, unchanged): real MLX inference via persistent
  Python `mlx_lm` worker, worker persistence/health, 3-run benchmark,
  worker crash → relaunch → reload, Emergency Stop propagation (section 7),
  `swift build` PASS.
- `swift build` PASS after Phase D code (21s, only benign ld search-path warnings).
- Component-level (SelfTest Phase 13, not yet run this session): PlanValidator
  rejects unknown tools / missing args / undeclared args / wrong int types /
  unsafe shell at plan time; parser extracts fenced JSON; composition steps
  (tool:null) validate; PlannerContext clipping.

## Implemented but Not Yet E2E Verified
- `MLXPlanner` (Sources/Jarvis/Agent/MLXPlanner.swift): compact registry-grounded
  prompt → MLXProvider (slot "normal") → parse → validate; metrics recorded
  (request latency, real worker TTFT, tokens, tok/s, attempt, repaired flag).
- Real planning path in `AgentLoop.run()`: deterministic fast path
  (DeterministicRouter hit → ActionEngine, no LLM) vs MLX planner path
  (CREATED→PLANNING→[planner]→RUNNING→per-step EXECUTE→OBSERVE→VERIFY→…→
  VERIFYING→COMPLETED), bounded replans with real failure context, emergency
  cancel checks, `agent:C violations` none known.
- REAL AGENT LOOP audit section 6B (items D-A…D-J) in IntegrationAudit —
  code written, NOT yet executed.
- Emergency Stop → AgentLoop.emergencyCancel() subscriber (6th production
  subscriber) — wiring written, NOT yet executed.

## Known Failures
- None at build level. Audit-level behavior unknown until first run.
- Anticipated risk (honest): Qwen2.5-0.5B may produce unparseable/malformed
  plans for some goals; planner has bounded repair (see Retry Bounds) and then
  fails safely. Audit items may honestly come out YELLOW/BLUE/RED — do not fake.

## Build
- `swift build` PASS (Swift 6, CommandLineTools, no XCTest usable; use
  `swift run Jarvis --self-test` and `--audit`).

## Tests
- `swift run Jarvis --self-test` — includes new Phase 13 parser/validator
  component tests + all prior phases (regression check). NOT yet run this session.
- Full suite is `swift run Jarvis --audit` (12 sections incl. new 6B). NOT yet run.

## Audit
- Baseline (Phase C): 48 items — 24 GREEN, 7 BLUE, 13 YELLOW, 0 RED, 4 GRAY.
- Section 6.1 "End-to-End Agent Execution" intentionally reclassified BLUE→YELLOW:
  "pwd and echo …" now takes the deterministic fast path (no LLM planning there;
  LLM path is proven in section 6B instead).
- Phase D section 6B adds 8 items (D-A real planner E2E, D-B plan+bounded repair,
  D-C/D/E execute+observe+verify, D-F failure→recovery→replan, D-G cancellation,
  D-H emergency stop halts agent, D-I deterministic fast path preserved,
  D-J no hallucinated tools). Expected honest classifications: D-A/D-C/D-E/D-I
  GREEN when the model cooperates; D-B likely BLUE (repair rarely triggered);
  D-F model-strength dependent; D-H GREEN (wiring proof).

## Retry Bounds
- planner repair: 1 initial generation + 1 repair generation = max 2 planner
  generations per planning request (MLXPlanner.plan, while attempt < 2).
- agent replan: max total step attempts per task = 3 + initial step count
  (AgentLoop maxTotalAttempts); each failure does FAILED→RECOVERING→REPLANNING
  with real failure text + last 2 observations (clipped to 160 chars) injected
  into the repair prompt. Planning failure: 1 retry then propagate (fail safe).

## Files Changed
- NEW Sources/Jarvis/Agent/PlanValidator.swift (PlanStep/AgentPlan/
  PlanValidationError/AgentPlanParser/@MainActor PlanValidator + validateAsync)
- NEW Sources/Jarvis/Agent/MLXPlanner.swift (actor MLXPlanner, PlannerMetrics,
  PlannerContext, prompt builder + targeted repair feedback)
- Sources/Jarvis/Agent/AgentLoop.swift (heuristic planSteps removed → fast path
  + MLX planner + execute/observe/verify loop + bounded replan + emergencyCancel
  + latestPlannerMetrics/latestReplanCount)
- Sources/Jarvis/Brain/Tools/ToolDefinitions.swift (ToolParameterSpec +
  parameterSpec on JarvisTool with default [])
- Sources/Jarvis/Brain/Tools/BuiltinTools.swift (parameterSpec for all 6 tools)
- Sources/Jarvis/Brain/Tools/ToolRegistry.swift (real parametersJSON in
  getToolDefinitions)
- Sources/Jarvis/Core/IntegrationAudit.swift (auditRealAgentLoop section 6B;
  6.1 details updated)
- Sources/Jarvis/Core/SelfTest.swift (Phase 13: 12 component checks)
- Sources/Jarvis/Voice/EmergencyInterrupt.swift (6th subscriber → AgentLoop
  cancel; Task<Void,Never> disambiguation for new SDK)
- Sources/Jarvis/Actions/DeterministicRouter.swift (Match: Sendable +
  @Sendable action closures; MainActor.run inside closures for Swift 6)

## Current Task
- Run `swift run Jarvis --self-test` (Checkpoint B), then
  `swift run Jarvis --audit` (Checkpoint C), iterating ONLY on real observed
  planner output if the 0.5B model fails simple goals.

## NEXT EXACT ACTION
1. `swift run Jarvis --self-test 2>&1 | tail -30` → expect "ALL TESTS PASSED".
2. `swift run Jarvis --audit 2>&1 | tee /tmp/audit_d.txt` → inspect section
   6B output + totals; record real planner latency/TTFT/tok from D-A details.
3. If planner fails simple goals: read raw model output from logs
   (JarvisLogger.brain MLXPlanner lines), tighten prompt minimally, re-run.
4. Update this file with actual audit totals + metrics.

## Important Decisions
- Planner uses MLXProvider slot "normal" (not "reflex") to avoid competing with
  the reflex classifier; same worker architecture as Phase C (do NOT replace).
- PlanValidator is @MainActor (registry/sandbox are MainActor); MLXPlanner uses
  await PlanValidator.validateAsync(...). MainActor callers use validate().
- Composition steps (tool:null) are valid plans: 0.5B model can answer directly
  without a tool; loop appends step.purpose without executing anything.
- Deterministic fast path lives INSIDE AgentLoop.run (before task creation) so
  AgentLoop.run(goal:) keeps a single entry point for UI/audit.
- Emergency cancellation = static cancellationObserved flag checked at every
  loop iteration + TaskWorkerPool.cancelAll() unchanged + 6th EventBus
  subscriber calling AgentLoop.emergencyCancel().
- Do NOT mark D items GREEN without the production-path run proving them;
  D-B expected BLUE unless a repair actually triggers in the audit run.
