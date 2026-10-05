import Foundation

/// Stable, machine-readable classification of every failure Zia can observe.
/// A category determines how the task system should respond: retry, replan,
/// escalate, ask the user, or abort. It never grants authority.
enum ErrorCategory: String, Sendable, Codable, CaseIterable {
    case userError
    case modelError
    case planningError
    case validationError
    case permissionError
    case securityError
    case executionError
    case verificationError
    case providerError
    case networkError
    case timeout
    case cancellation
    case resourceExhaustion
    case externalIntegrationFailure
    case unknown

    /// The default recovery disposition for this category. This is advisory to
    /// the task system; the authoritative decision remains the RecoveryPolicy +
    /// bounded retry budget.
    var disposition: RecoveryDisposition {
        switch self {
        case .timeout, .networkError, .providerError:
            return .retry
        case .executionError, .verificationError, .planningError, .modelError, .validationError:
            return .replan
        case .resourceExhaustion:
            return .escalate
        case .permissionError, .securityError, .userError, .externalIntegrationFailure:
            return .askUser
        case .cancellation:
            return .abort
        case .unknown:
            return .replan
        }
    }

    /// Whether a plain retry of the same action is ever appropriate. A
    /// deterministic or authorization failure is never blindly retried.
    var isBlindlyRetryable: Bool {
        switch self {
        case .timeout, .networkError, .providerError:
            return true
        default:
            return false
        }
    }
}

/// How the task system should proceed after a classified failure.
enum RecoveryDisposition: String, Sendable, Codable {
    /// Retry the same action (transient).
    case retry
    /// Produce a different validated plan from the failure context.
    case replan
    /// Raise the intelligence tier / use a stronger provider.
    case escalate
    /// Ask the user (authorization, ambiguity, external limits).
    case askUser
    /// Stop; do not continue.
    case abort
}

/// A structured, user-safe error envelope: a stable category, a human-readable
/// message, recovery metadata, and machine-readable details. This is what the
/// assistant surfaces instead of raw stack traces.
struct ErrorEnvelope: Sendable, Equatable {
    let category: ErrorCategory
    let message: String
    let disposition: RecoveryDisposition
    let retryable: Bool
    let metadata: [String: String]

    var userFacingSummary: String {
        var text = message
        switch disposition {
        case .retry: text += " This looks transient and can be retried."
        case .replan: text += " I can try a different approach."
        case .escalate: text += " I need more resources or a stronger model."
        case .askUser: text += " This needs your input or authorization."
        case .abort: text += " I have stopped this work."
        }
        return text
    }
}

/// Classifies any thrown error into the taxonomy. Deterministic; no model call.
enum ErrorTaxonomy {
    static func classify(_ error: any Error) -> ErrorCategory {
        if error is CancellationError { return .cancellation }
        if error is ToolVerificationFailure { return .verificationError }
        if error is ReferenceResolutionError { return .planningError }
        if let patch = error as? PatchError { return classifyPatch(patch) }
        if error is MemoryWriteError { return .securityError }
        if let validation = error as? PlanValidationError {
            switch validation {
            case .noJSONFound, .malformedJSON: return .modelError
            default: return .validationError
            }
        }
        guard let jarvis = error as? JarvisError else {
            return providerDomain(error)
        }
        switch jarvis {
        case .permissionDenied, .privacyPolicyViolation:
            return .permissionError
        case .commandBlocked:
            return .securityError
        case .timeout, .providerTimeout:
            return .timeout
        case .providerUnavailable, .allProvidersFailed:
            return .providerError
        case .providerRateLimited, .providerError:
            return .providerError
        case .offline, .apiKeyMissing:
            return .networkError
        case .verificationFailed:
            return .verificationError
        case .insufficientMemory, .modelLoadFailed:
            return .resourceExhaustion
        case .invalidState:
            return .validationError
        case .notInitialized:
            return .externalIntegrationFailure
        case .actionFailed:
            return .executionError
        case .databaseError, .embeddingFailed:
            return .executionError
        case .microphoneAccessDenied, .speechRecognitionDenied:
            return .permissionError
        case .wakeWordFailed, .ttsFailure:
            return .executionError
        case .escalationFailed:
            return .externalIntegrationFailure
        }
    }

    private static func classifyPatch(_ patch: PatchError) -> ErrorCategory {
        switch patch {
        case .staleFile, .conflict:
            return .validationError
        case .unsafePath:
            return .securityError
        case .targetMissing, .noMatch, .ioFailure:
            return .executionError
        }
    }

    /// Foundation/URLSession/other domain errors that are not JarvisError.
    private static func providerDomain(_ error: any Error) -> ErrorCategory {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return .networkError
            default:
                return .networkError
            }
        }
        return .unknown
    }

    static func envelope(for error: any Error) -> ErrorEnvelope {
        let category = classify(error)
        return ErrorEnvelope(
            category: category,
            message: error.localizedDescription,
            disposition: category.disposition,
            retryable: category.isBlindlyRetryable,
            metadata: ["type": String(describing: type(of: error))])
    }
}

// MARK: - Resource bounds

/// Centralized, bounded resource budgets. Prevents runaway retries, recovery
/// loops, background work, and concurrent model calls. Safe defaults; a single
/// source of truth rather than scattered magic constants.
enum ResourceBounds {
    /// Hard ceiling on recovery attempts per task.
    static let maximumRecoveryAttempts = 4
    /// Maximum scheduled jobs that may launch in a single background tick.
    static let maximumJobsPerTick = 5
    /// Maximum concurrent model calls Zia will start.
    static let maximumConcurrentModelCalls = 3
    /// Maximum background jobs retained by the scheduler.
    static let maximumScheduledJobs = 200
    /// Maximum structured memory records retained.
    static let maximumMemoryRecords = 2_000
    /// Maximum artifacts retained.
    static let maximumArtifacts = 1_000
    /// Default per-operation wall-clock bound for scheduled background work.
    static let defaultBackgroundTimeoutSeconds: Double = 600
}
