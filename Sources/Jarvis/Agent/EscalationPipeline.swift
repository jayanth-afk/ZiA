import Foundation

// MARK: - Escalation Context

/// Authoritative, structured context passed during lossless escalation from Tier A to Tier B.
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

    init(
        taskId: UUID,
        originalGoal: String,
        currentStepNumber: Int = 1,
        completedSteps: [TaskStep] = [],
        verifiedOutputs: [Int: String] = [:],
        failedStep: TaskStep? = nil,
        failureReason: String? = nil,
        priorObservations: [String] = [],
        environmentContext: TaskEnvironmentContext? = nil,
        sensitivity: DataClassifier.SensitivityLevel = .publicLevel,
        triggerReason: TriggerReason,
        escalationTimestamp: Date = Date(),
        attemptCount: Int = 1
    ) {
        self.taskId = taskId
        self.originalGoal = originalGoal
        self.currentStepNumber = currentStepNumber
        self.completedSteps = completedSteps
        self.verifiedOutputs = verifiedOutputs
        self.failedStep = failedStep
        self.failureReason = failureReason
        self.priorObservations = priorObservations
        self.environmentContext = environmentContext
        self.sensitivity = sensitivity
        self.triggerReason = triggerReason
        self.escalationTimestamp = escalationTimestamp
        self.attemptCount = attemptCount
    }
}

// MARK: - Tier B Planner Provider Protocol

protocol TierBPlannerProvider: Sendable {
    var id: String { get }
    var isCloud: Bool { get }
    func isAvailable() async -> Bool
    func plan(context: EscalationContext) async throws -> AgentPlan
}

// MARK: - Mock Provider (Deterministic Testing)

final class MockTierBProvider: TierBPlannerProvider, @unchecked Sendable {
    let id: String
    let isCloud: Bool
    private let _available = LockedValue(true)
    private let _planToReturn = LockedValue<AgentPlan?>(nil)
    private let _errorToThrow = LockedValue<(any Error)?>(nil)
    private let _lastContext = LockedValue<EscalationContext?>(nil)
    private let _callCount = LockedValue(0)

    var lastReceivedContext: EscalationContext? {
        _lastContext.value
    }

    var callCount: Int {
        _callCount.value
    }

    init(id: String = "mock-tier-b", isCloud: Bool = false) {
        self.id = id
        self.isCloud = isCloud
    }

    func isAvailable() async -> Bool {
        _available.value
    }

    func setAvailable(_ val: Bool) {
        _available.value = val
    }

    func setPlanToReturn(_ plan: AgentPlan?) {
        _planToReturn.value = plan
    }

    func setErrorToThrow(_ err: (any Error)?) {
        _errorToThrow.value = err
    }

    func plan(context: EscalationContext) async throws -> AgentPlan {
        _callCount.value += 1
        _lastContext.value = context

        if let err = _errorToThrow.value {
            throw err
        }
        if let plan = _planToReturn.value {
            return plan
        }
        return AgentPlan(
            goal: context.originalGoal,
            steps: [
                PlanStep(id: "escalated_s1", toolName: "inspect_ui", arguments: [:], purpose: "Fallback observation after escalation")
            ]
        )
    }

    func reset() {
        _lastContext.value = nil
        _callCount.value = 0
        _available.value = true
        _planToReturn.value = nil
        _errorToThrow.value = nil
    }
}

// MARK: - OpenRouter Tier B Provider (Injection Shielded)

final class OpenRouterTierBProvider: TierBPlannerProvider, @unchecked Sendable {
    let id = "openrouter-tier-b"
    let isCloud = true

    func isAvailable() async -> Bool {
        return await ProviderManager.shared.openrouter.isAvailable
    }

    func plan(context: EscalationContext) async throws -> AgentPlan {
        var promptLines = [
            "GOAL: \(context.originalGoal)",
            "TRIGGER: \(context.triggerReason.rawValue)"
        ]
        if let env = context.environmentContext, let app = env.currentApp, !app.isEmpty {
            promptLines.append("ENVIRONMENT: frontmost_app=\(app)")
        }
        if !context.completedSteps.isEmpty {
            promptLines.append("COMPLETED STEPS:")
            for s in context.completedSteps {
                let rawOut = context.verifiedOutputs[s.stepNumber] ?? "verified"
                let sanitizedOut = rawOut.replacingOccurrences(of: "</verified_output>", with: "")
                promptLines.append("- Step \(s.stepNumber): [\(s.toolName ?? "none")] <verified_output step=\"\(s.stepNumber)\">\(sanitizedOut)</verified_output>")
            }
        }
        if let failed = context.failedStep {
            promptLines.append("FAILED STEP: [\(failed.toolName ?? "none")] purpose=\(failed.description)")
        }
        if let reason = context.failureReason {
            let sanitizedReason = reason.replacingOccurrences(of: "</failure_reason>", with: "")
            promptLines.append("<failure_reason>\(sanitizedReason)</failure_reason>")
        }

        let messages = [
            Message(role: .system, content: "You are JARVIS Tier-B Planner. Produce a valid JSON AgentPlan to complete the goal."),
            Message(role: .user, content: promptLines.joined(separator: "\n"))
        ]

        let stream = await ProviderManager.shared.openrouter.complete(messages: messages, tools: nil, stream: false)
        var responseText = ""
        for try await chunk in stream {
            if case .text(let t) = chunk { responseText += t }
        }

        switch AgentPlanParser.parse(responseText) {
        case .success(let plan):
            return plan
        case .failure(let err):
            throw JarvisError.actionFailed(action: id, reason: "Tier B output parse failed: \(err)")
        }
    }
}

// MARK: - Escalation Pipeline Orchestrator

@MainActor
final class EscalationPipeline {
    static let shared = EscalationPipeline()

    var isEnabled: Bool = true
    var mockProvider: (any TierBPlannerProvider)? = nil
    var cloudProvider: any TierBPlannerProvider = OpenRouterTierBProvider()

    private(set) var lastEscalationContext: EscalationContext?
    private(set) var escalationCount: Int = 0

    private init() {}

    func reset() {
        lastEscalationContext = nil
        escalationCount = 0
        mockProvider = nil
        isEnabled = true
    }

    func escalate(context: EscalationContext) async throws -> AgentPlan {
        guard isEnabled else {
            throw JarvisError.escalationFailed(reason: "EscalationPipeline is disabled")
        }

        try Task.checkCancellation()
        try refuseIfEmergencyStopLatched(stage: "pre-provider")

        lastEscalationContext = context
        escalationCount += 1

        let provider: any TierBPlannerProvider
        if let mock = mockProvider {
            provider = mock
        } else {
            provider = cloudProvider
        }

        if provider.isCloud {
            let allowed = DataClassifier.shared.isCloudAllowed(for: context.sensitivity)
            guard allowed else {
                JarvisLogger.security.error("Blocked cloud escalation for \(context.sensitivity.rawValue) task")
                throw JarvisError.privacyPolicyViolation(
                    level: context.sensitivity.rawValue,
                    reason: "Cloud escalation prohibited for \(context.sensitivity.rawValue) data"
                )
            }
        }

        guard await provider.isAvailable() else {
            JarvisLogger.brain.warning("Tier B provider '\(provider.id)' is unavailable")
            throw JarvisError.providerUnavailable(provider: provider.id)
        }

        JarvisLogger.brain.info("Escalating task '\(context.originalGoal)' to Tier B provider '\(provider.id)' [trigger: \(context.triggerReason.rawValue)]")

        let plan = try await provider.plan(context: context)

        try Task.checkCancellation()
        try refuseIfEmergencyStopLatched(stage: "post-provider")

        let validation = PlanValidator.validate(plan)
        guard case .success = validation else {
            let errorDesc = String(describing: validation)
            JarvisLogger.brain.error("Tier B generated plan failed validation: \(errorDesc)")
            throw JarvisError.actionFailed(action: "TierBPlanValidation", reason: errorDesc)
        }

        JarvisLogger.brain.info("Tier B escalation successfully produced valid plan with \(plan.steps.count) steps")
        return plan
    }

    private func refuseIfEmergencyStopLatched(stage: String) throws {
        guard AgentLoop.shared.isEmergencyCancelled else { return }
        JarvisLogger.security.fault("EscalationPipeline refused at \(stage): emergency stop latched")
        throw JarvisError.escalationFailed(reason: "Emergency stop latched; escalation refused")
    }
}