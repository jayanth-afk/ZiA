import Foundation

// MARK: - Milestone 3 Peer Audit — Lossless Escalation Edge Cases
//
// Independent peer contribution (parallel to the primary Milestone 3 implementer).
//
// WHAT THIS IS:
//   A read-mostly audit harness for the Tier A → Tier B escalation seam. It
//   deliberately does NOT re-test what SelfTest Phase 18 already covers; it
//   probes the edges around it:
//     H1  Lossless structured state crossing the provider boundary (no
//         reconstruction from transcript text — the mock receives the typed
//         EscalationContext and every field is asserted verbatim).
//     H2  Privacy asymmetry: identical SENSITIVE context, the ONLY variable is
//         provider.isCloud — the DataClassifier gate must be the discriminator.
//     H3  Unavailable Tier B provider is never invoked (availability precedes
//         plan()); failure stays explicit, no false success.
//     H4  Tier B plans failing PlanValidator are rejected AND the attempt is
//         still recorded in escalation accounting (evidence before green).
//     H5  Disabled pipeline fails closed with zero provider invocations.
//     H6  Emergency Stop is a pipeline gate: while the latch is set,
//         escalate() fails closed with zero provider invocations.
//     H7  Escalation composes with structured-concurrency cancellation
//         plumbing (the shape AgentLoop runs under) without spuriously
//         cancelling the provider call.
//     L1  TaskStateMachine state is not erased by provider invocation:
//         completed-step state, resolution records, and environment context
//         survive the handoff (State Over Transcript).
//     L2  A reference ($ambient.current_app) resolves from the environment
//         context CARRIED ACROSS the escalation boundary — not from transcript.
//     L3  A stale ambient snapshot still fails deterministically post-escalation
//         (the system never fabricates values).
//     C1  Authority pins: at autonomy L0, read-only is authorized and
//         destructive is denied — a Tier B plan's intelligence confers zero
//         authority. PermissionGate and Config are untouched (values restored).
//     C2  Sandbox pins: CommandSandbox.isSafe accepts a benign echo and still
//         rejects a destructive command. CommandSandbox is untouched.
//     S1  DataClassifier classification and cloud-allow pins (offline, pure).
//
// ISOLATION GUARANTEES:
//   - Production Emergency Stop is enforced inside EscalationPipeline.escalate.
//     This harness uses only EscalationPipeline's test hooks (mockProvider /
//     isEnabled / reset()), exactly as SelfTest Phase 18 uses them.
//   - Config.autonomyLevel is saved and restored around C1; PermissionGate,
//     CommandSandbox, DestructiveActionManager, EmergencyInterrupt,
//     ShellExecutor, PlanValidator and DataClassifier are never modified.
//   - Zero network: the only provider used is MockTierBProvider (isCloud flag
//     simulates cloud classification; no cloud endpoint is ever contacted).
//   - Zero model calls: Tier A is never invoked; Tier A exhaustion is
//     simulated by constructing the post-exhaustion EscalationContext directly.

enum EscalationAudit {

    @MainActor private static var passed = 0
    @MainActor private static var failures: [String] = []

    @MainActor
    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failures.append(name)
            print("  ✗ \(name)")
        }
    }

    // MARK: - Entry

    @MainActor
    static func runAll() async {
        print("\n─── Escalation Audit: Milestone 3 Edge Cases (peer contribution) ───")

        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        AgentLoop.shared.resetEmergencyCancellation()

        // ── Section C: authority & sandbox pins (read-only around the edges) ──
        await authorityPins()

        // ── Section S: DataClassifier pins (pure, offline) ──
        classifierPins()

        // ── Section H: escalation pipeline edge cases (mock provider only) ──
        do {
            try await providerBoundaryLosslessness()
        } catch {
            check(false, "H1: unexpected error escaping audit flow: \(error.localizedDescription)")
        }
        await privacyAsymmetry()
        await providerUnavailableNeverInvoked()
        await tierBInvalidPlanRejectedAndRecorded()
        await disabledPipelineFailsClosed()
        await emergencyStopFindingPin()
        await cancellationComposition()

        // ── Section L: state losslessness across the handoff ──
        do {
            try await stateMachineSurvivesProviderInvocation()
        } catch {
            check(false, "L1: unexpected error escaping audit flow: \(error.localizedDescription)")
        }

        // Leave the singleton exactly as SelfTest expects to find it.
        pipeline.reset()

        print("\n══════════════════════════════════════════")
        print("  Escalation Audit Results: \(passed) passed, \(failures.count) failed")
        print("══════════════════════════════════════════\n")

        if failures.isEmpty {
            print("✅ ALL ESCALATION AUDIT CHECKS PASSED")
        } else {
            print("❌ ESCALATION AUDIT FAILURES (\(failures.count)):")
            for failure in failures { print("   - \(failure)") }
        }
    }

    // MARK: - Helpers

    /// Deterministic dispatch suppression for the pipeline singleton. This is
    /// audit-harness machinery, NOT production behavior: with the pipeline
    /// disabled and no mock installed, any accidental escalation attempt would
    /// fail closed instead of reaching a provider.
    @MainActor
    private static func withProviderDispatchSuppressed<T>(
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        EscalationPipeline.shared.mockProvider = nil
        EscalationPipeline.shared.isEnabled = false
        do {
            let result = try await body()
            EscalationPipeline.shared.reset()
            return result
        } catch {
            EscalationPipeline.shared.reset()
            throw error
        }
    }

    private static func auditPublicContext(goal: String) -> EscalationContext {
        EscalationContext(
            taskId: UUID(),
            originalGoal: goal,
            currentStepNumber: 1,
            sensitivity: .publicLevel,
            triggerReason: .tierAPlanningExhausted
        )
    }

    /// A plan the real PlanValidator accepts (inspect_ui declares no required
    /// arguments), so validation never masks the behavior under test.
    private static var auditValidPlan: AgentPlan {
        AgentPlan(
            goal: "escalation_audit_goal",
            steps: [PlanStep(id: "audit_s1", toolName: "inspect_ui", arguments: [:], purpose: "Audit observation step")]
        )
    }

    // MARK: - Section C: authority & sandbox pins

    @MainActor
    private static func authorityPins() async {
        // C1: Authority matrix pins (Intelligence Never Equals Authority).
        let originalLevel = Config.shared.autonomyLevel
        Config.shared.autonomyLevel = 0 // L0 Read-Only

        var l0ReadonlyAuthorized = false
        do {
            l0ReadonlyAuthorized = try PermissionGate.shared.isAuthorized(actionName: "escalation_audit.readonly", impact: .readOnly)
        } catch {
            l0ReadonlyAuthorized = false
        }
        check(l0ReadonlyAuthorized, "C1a: L0 authorizes read-only impact")

        var l0DestructiveDenied = false
        do {
            _ = try PermissionGate.shared.isAuthorized(actionName: "escalation_audit.destructive", impact: .destructive)
        } catch {
            l0DestructiveDenied = true
        }
        check(l0DestructiveDenied, "C1b: L0 denies destructive impact (escalation never confers authority)")

        Config.shared.autonomyLevel = originalLevel // restore exact prior value

        // C2: Sandbox pins (untouched boundary).
        check(CommandSandbox.shared.isSafe("echo escalation_audit_ok"), "C2a: CommandSandbox accepts benign echo")
        check(!CommandSandbox.shared.isSafe("rm -rf /"), "C2b: CommandSandbox rejects destructive command")
    }

    // MARK: - Section S: DataClassifier pins

    @MainActor
    private static func classifierPins() {
        check(DataClassifier.shared.classify("my password is hunter2") == .highlySensitive, "S1a: password text classifies HIGHLY_SENSITIVE")
        check(DataClassifier.shared.classify("read /Users/jay/Documents/tax.csv") == .sensitive, "S1b: local path + financial text classifies SENSITIVE")
        check(DataClassifier.shared.classify("what is the capital of France") == .publicLevel, "S1c: general knowledge classifies PUBLIC")
        check(!DataClassifier.shared.isCloudAllowed(for: .highlySensitive), "S1d: HIGHLY_SENSITIVE never cloud-allowed")
        check(!DataClassifier.shared.isCloudAllowed(for: .sensitive), "S1e: SENSITIVE not cloud-allowed by default")
        check(DataClassifier.shared.isCloudAllowed(for: .publicLevel), "S1f: PUBLIC cloud-allowed")
        check(DataClassifier.shared.isCloudAllowed(for: .personal), "S1g: PERSONAL cloud-allowed (documented standard policy)")
    }

    // MARK: - Section H: pipeline edge cases

    /// H1: Every structured field of EscalationContext arrives at the provider
    /// verbatim, with zero model calls and zero network. This is the core
    /// losslessness proof: state crosses the boundary as typed data, not as
    /// transcript text to be re-parsed.
    @MainActor
    private static func providerBoundaryLosslessness() async throws {
        try await withProviderDispatchSuppressed {
            let pipeline = EscalationPipeline.shared
            let mock = MockTierBProvider(id: "audit-mock-tier-b", isCloud: false)
            pipeline.isEnabled = true
            pipeline.mockProvider = mock

            let goal = "escalation_audit_lossless_goal_2026"
            let completedStep = TaskStep(
                stepNumber: 1,
                description: "Capture account balance",
                toolName: "run_shell",
                arguments: ["command": "echo 1000 USD"],
                state: .completed,
                output: "1000 USD",
                verification: .passed
            )
            let failedStep = TaskStep(
                stepNumber: 2,
                description: "Query conversion rate",
                toolName: "totally_unregistered_tool_zz",
                arguments: [:],
                state: .failed,
                error: "unknownTool"
            )
            let env = TaskEnvironmentContext(currentApp: "AuditApp")
            let expectedPlan = auditValidPlan
            mock.setPlanToReturn(expectedPlan)

            let context = EscalationContext(
                taskId: UUID(),
                originalGoal: goal,
                currentStepNumber: 2,
                completedSteps: [completedStep],
                verifiedOutputs: [1: "1000 USD"],
                failedStep: failedStep,
                failureReason: "PlanValidationError.unknownTool(totally_unregistered_tool_zz)",
                priorObservations: ["Attempt 1 failed: schema invalid", "Attempt 2 failed: tool unregistered"],
                environmentContext: env,
                sensitivity: .publicLevel,
                triggerReason: .tierAPlanningExhausted,
                attemptCount: 2
            )

            let returnedPlan = try await pipeline.escalate(context: context)
            check(returnedPlan == expectedPlan, "H1a: Tier B mock invoked offline; structured plan returned through provider boundary")
            check(mock.callCount == 1, "H1b: exactly one Tier B invocation")

            let received = mock.lastReceivedContext
            check(received?.originalGoal == goal, "H1c: original user goal arrives byte-for-byte")
            check(received?.completedSteps.count == 1 && received?.completedSteps.first?.verification == .passed, "H1d: completed VERIFIED step crosses the boundary intact")
            check(received?.verifiedOutputs[1] == "1000 USD", "H1e: verified output map crosses the boundary intact")
            check(received?.failedStep?.toolName == "totally_unregistered_tool_zz" && received?.failedStep?.state == .failed, "H1f: failed step (tool + state) crosses the boundary intact")
            check(received?.failureReason == "PlanValidationError.unknownTool(totally_unregistered_tool_zz)", "H1g: exact structured validation error crosses the boundary (not paraphrased)")
            check(received?.priorObservations.count == 2 && received?.priorObservations.first == "Attempt 1 failed: schema invalid", "H1h: repair/observation history crosses the boundary intact")
            check(received?.environmentContext?.currentApp == "AuditApp", "H1i: environment context crosses the boundary intact")
            check(received?.triggerReason == .tierAPlanningExhausted && received?.attemptCount == 2, "H1j: trigger reason and attempt count cross the boundary intact")
            check(received?.taskId == context.taskId, "H1k: task identity (run→task attribution) crosses the boundary intact")
        }
    }

    /// H2: With an IDENTICAL SENSITIVE context, the only variable is
    /// provider.isCloud. The DataClassifier gate must be the discriminator:
    /// local Tier B is permitted (by design, on-device), cloud Tier B is
    /// blocked before the provider is ever invoked.
    @MainActor
    private static func privacyAsymmetry() async {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        pipeline.isEnabled = true

        let sensitiveContext = EscalationContext(
            taskId: UUID(),
            originalGoal: "escalation_audit_sensitive_goal (contains bank balance)",
            sensitivity: .sensitive,
            triggerReason: .tierAPlanningExhausted
        )

        // Local Tier B: permitted by design (classification drives CLOUD gating only).
        let localMock = MockTierBProvider(id: "audit-local-tier-b", isCloud: false)
        localMock.setPlanToReturn(auditValidPlan)
        pipeline.mockProvider = localMock
        var localPlan: AgentPlan?
        do {
            localPlan = try await pipeline.escalate(context: sensitiveContext)
        } catch {
            localPlan = nil
        }
        check(localPlan != nil && localMock.callCount == 1, "H2a: LOCAL Tier B permitted for SENSITIVE context (on-device by design)")

        // Cloud Tier B: blocked deterministically, provider never invoked.
        let cloudMock = MockTierBProvider(id: "audit-cloud-tier-b", isCloud: true)
        cloudMock.setPlanToReturn(auditValidPlan)
        pipeline.mockProvider = cloudMock
        var cloudBlocked = false
        do {
            _ = try await pipeline.escalate(context: sensitiveContext)
        } catch {
            cloudBlocked = true
        }
        check(cloudBlocked && cloudMock.callCount == 0, "H2b: CLOUD Tier B blocked for SENSITIVE context; provider never invoked (no Tier A failure leaks data to cloud)")

        pipeline.reset()
    }

    /// H3: An unavailable Tier B provider must fail BEFORE plan() — no
    /// invocation, explicit failure, no false success.
    @MainActor
    private static func providerUnavailableNeverInvoked() async {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        pipeline.isEnabled = true

        let mock = MockTierBProvider(id: "audit-unavailable-tier-b", isCloud: false)
        mock.setPlanToReturn(auditValidPlan)
        mock.setAvailable(false)
        pipeline.mockProvider = mock

        var failedExplicitly = false
        do {
            _ = try await pipeline.escalate(context: auditPublicContext(goal: "escalation_audit_availability_goal"))
        } catch {
            failedExplicitly = true
        }
        check(failedExplicitly && mock.callCount == 0, "H3: unavailable Tier B provider fails explicitly and is never invoked")

        pipeline.reset()
    }

    /// H4: A Tier B plan referencing an unregistered tool must be rejected by
    /// the deterministic validation gate AND the failed attempt must remain
    /// visible in escalation accounting (evidence before green).
    @MainActor
    private static func tierBInvalidPlanRejectedAndRecorded() async {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        pipeline.isEnabled = true

        let mock = MockTierBProvider(id: "audit-hostile-tier-b", isCloud: false)
        let invalidPlan = AgentPlan(
            goal: "escalation_audit_invalid_plan_goal",
            steps: [PlanStep(id: "bad_s1", toolName: "malicious_unregistered_tool", arguments: [:], purpose: "Authority bypass attempt")]
        )
        mock.setPlanToReturn(invalidPlan)
        pipeline.mockProvider = mock

        var rejectedByValidationGate = false
        do {
            _ = try await pipeline.escalate(context: auditPublicContext(goal: "escalation_audit_invalid_plan_goal"))
        } catch {
            rejectedByValidationGate = true
        }
        check(rejectedByValidationGate && mock.callCount == 1, "H4a: Tier B plan with unregistered tool rejected (Intelligence != Authority preserved at Tier B)")

        check(pipeline.escalationCount == 1, "H4b: rejected Tier B attempt remains recorded in escalation accounting (evidence before green)")

        pipeline.reset()
    }

    /// H5: A disabled pipeline must fail closed with zero provider activity.
    @MainActor
    private static func disabledPipelineFailsClosed() async {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()

        let mock = MockTierBProvider(id: "audit-disabled-tier-b", isCloud: false)
        pipeline.mockProvider = mock
        pipeline.isEnabled = false

        var failedClosed = false
        do {
            _ = try await pipeline.escalate(context: auditPublicContext(goal: "escalation_audit_disabled_goal"))
        } catch {
            failedClosed = true
        }
        check(failedClosed && mock.callCount == 0, "H5: disabled pipeline fails closed with zero provider invocations")

        pipeline.reset()
    }

    /// H6: EscalationPipeline refuses the handoff while Emergency Stop is latched.
    @MainActor
    private static func emergencyStopFindingPin() async {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        pipeline.isEnabled = true

        let mock = MockTierBProvider(id: "audit-stop-tier-b", isCloud: false)
        mock.setPlanToReturn(auditValidPlan)
        pipeline.mockProvider = mock

        AgentLoop.shared.emergencyCancel()
        check(AgentLoop.shared.isEmergencyCancelled, "H6a: emergency stop latches deterministically")

        var refusedWhileLatched = false
        do {
            _ = try await pipeline.escalate(context: auditPublicContext(goal: "escalation_audit_stop_goal"))
        } catch JarvisError.escalationFailed {
            refusedWhileLatched = true
        } catch {}
        check(refusedWhileLatched && mock.callCount == 0 && pipeline.escalationCount == 0,
              "H6b: pipeline refuses escalation while Emergency Stop is latched (zero provider invocations)")

        AgentLoop.shared.resetEmergencyCancellation()
        check(!AgentLoop.shared.isEmergencyCancelled, "H6c: emergency stop resets cleanly")

        pipeline.reset()
    }

    /// H7: escalate() composes with structured-concurrency cancellation
    /// plumbing (the exact shape AgentLoop.runInternal runs under) without
    /// spurious cancellation of the provider call.
    @MainActor
    private static func cancellationComposition() async {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        pipeline.isEnabled = true

        let mock = MockTierBProvider(id: "audit-cancel-tier-b", isCloud: false)
        mock.setPlanToReturn(auditValidPlan)
        pipeline.mockProvider = mock

        let cancellationObserved = LockedValue(false)
        var completed = false
        do {
            _ = try await withTaskCancellationHandler {
                try await pipeline.escalate(context: auditPublicContext(goal: "escalation_audit_cancellation_goal"))
            } onCancel: {
                cancellationObserved.value = true
            }
            completed = true
        } catch {
            completed = false
        }
        check(completed && !cancellationObserved.value, "H7: escalation completes under cancellation plumbing with no spurious cancellation")

        pipeline.reset()
    }

    // MARK: - Section L: state losslessness

    /// L1–L3: the state machine's structured state must survive provider
    /// invocation, remain resolvable across the boundary, and keep its
    /// freshness invariants — State Over Transcript end to end.
    @MainActor
    private static func stateMachineSurvivesProviderInvocation() async throws {
        let pipeline = EscalationPipeline.shared
        pipeline.reset()
        pipeline.isEnabled = true

        let mock = MockTierBProvider(id: "audit-state-tier-b", isCloud: false)
        mock.setPlanToReturn(auditValidPlan)
        pipeline.mockProvider = mock

        let goal = "escalation_audit_state_preservation_goal"
        let completedStep = TaskStep(
            stepNumber: 1,
            description: "Echo audit marker",
            toolName: "run_shell",
            arguments: ["command": "echo audit_marker"],
            state: .completed,
            output: "audit_marker",
            verification: .passed
        )
        let failedStep = TaskStep(
            stepNumber: 2,
            description: "Use unregistered tool",
            toolName: "no_such_tool_qq",
            arguments: [:],
            state: .failed,
            error: "unknownTool"
        )
        let env = TaskEnvironmentContext(currentApp: "StateAuditApp")

        let task = TaskStateMachine.shared.createTask(
            title: "EscalationAudit State Task",
            goal: goal,
            steps: [completedStep, failedStep],
            environmentContext: env
        )
        _ = try? TaskStateMachine.shared.appendResolutionRecord(
            StepResolutionRecord(
                stepNumber: 1,
                toolName: "run_shell",
                rawOutput: "audit_marker",
                verification: .passed
            ),
            for: task.id
        )

        // Build the escalation context the way AgentLoop does: exclusively
        // from TaskStateMachine structured state — never from transcript text.
        let liveTask = TaskStateMachine.shared.getTask(id: task.id)
        let resolutionRecords = TaskStateMachine.shared.resolutionRecords(for: task.id)
        var verifiedOutputs: [Int: String] = [:]
        for record in resolutionRecords.values where record.verification == .passed {
            verifiedOutputs[record.stepNumber] = record.rawOutput
        }
        let context = EscalationContext(
            taskId: task.id,
            originalGoal: liveTask?.goal ?? goal,
            currentStepNumber: 2,
            completedSteps: liveTask?.steps.filter { $0.state == .completed } ?? [],
            verifiedOutputs: verifiedOutputs,
            failedStep: liveTask?.steps.last,
            failureReason: "PlanValidationError.unknownTool(no_such_tool_qq)",
            priorObservations: ["Attempt 1 failed: unregistered tool"],
            environmentContext: TaskStateMachine.shared.environmentContext(for: task.id),
            sensitivity: .publicLevel,
            triggerReason: .executionFailureReplanning,
            attemptCount: 2
        )

        _ = try await pipeline.escalate(context: context)

        // L1: provider invocation erased nothing.
        let after = TaskStateMachine.shared.getTask(id: task.id)
        check(
            after?.steps[0].state == .completed && after?.steps[1].state == .failed &&
            TaskStateMachine.shared.resolutionRecords(for: task.id).count == 1 &&
            TaskStateMachine.shared.environmentContext(for: task.id)?.currentApp == "StateAuditApp",
            "L1: step states, resolution records, and environment context survive provider invocation without erasure"
        )

        // L2: a reference resolves from the state CARRIED ACROSS the boundary.
        let shellSpec = ToolRegistry.shared.getTool(named: "run_shell")?.parameterSpec ?? []
        let resolved = try? ReferenceResolver.resolveStepArguments(
            rawArguments: ["command": "echo $ambient.current_app"],
            currentStepNumber: 1,
            toolParameterSpecs: shellSpec,
            resolutionRecords: [:],
            environmentContext: context.environmentContext
        )
        check(
            (resolved?["command"] as? String) == "echo StateAuditApp",
            "L2: ambient reference resolves from environment context carried across the escalation boundary"
        )

        // L3: freshness invariant survives — stale snapshots fail, never fabricate.
        let staleEnv = TaskEnvironmentContext(
            currentApp: "StateAuditApp",
            snapshotTimestamp: Date().addingTimeInterval(-(TaskEnvironmentContext.maxVolatileAgeSeconds + 30.0))
        )
        let resolvedStale = try? ReferenceResolver.resolveStepArguments(
            rawArguments: ["command": "echo $ambient.current_app"],
            currentStepNumber: 1,
            toolParameterSpecs: shellSpec,
            resolutionRecords: [:],
            environmentContext: staleEnv
        )
        check(
            resolvedStale == nil,
            "L3: stale ambient snapshot fails deterministically post-escalation (system never fabricates values)"
        )

        pipeline.reset()
    }
}
