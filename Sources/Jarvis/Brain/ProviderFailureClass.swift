import Foundation

/// Stable classification of a provider-call failure. The point is that retry,
/// fallback, and cooldown behaviour depend on the *class*, not on a raw string
/// (§13). Deterministic and side-effect free.
enum ProviderFailureClass: String, Sendable, CaseIterable, Equatable {
    case cancellation
    case authentication
    case rateLimited
    case quotaExhausted
    case timeout
    case network
    case malformedResponse
    case providerUnavailable
    case invalidRequest
    case unknown

    /// Whether retrying the SAME provider could plausibly succeed.
    var isRetryableSameProvider: Bool {
        switch self {
        case .rateLimited, .timeout, .network: return true
        case .cancellation, .authentication, .quotaExhausted,
             .malformedResponse, .providerUnavailable, .invalidRequest, .unknown:
            return false
        }
    }

    /// Whether trying a *different* worker is appropriate.
    var allowsFallback: Bool {
        switch self {
        case .cancellation: return false          // terminal: never fall back
        case .authentication, .invalidRequest: return true  // another worker may differ
        case .rateLimited, .quotaExhausted, .timeout, .network,
             .malformedResponse, .providerUnavailable, .unknown:
            return true
        }
    }

    /// Whether this failure should count toward quarantining the provider.
    /// A cancellation or a request we built badly is not the provider's fault.
    var countsAsProviderFailure: Bool {
        switch self {
        case .cancellation, .invalidRequest: return false
        case .authentication, .rateLimited, .quotaExhausted, .timeout,
             .network, .malformedResponse, .providerUnavailable, .unknown:
            return true
        }
    }
}

/// Classifies an error thrown by a provider call into a `ProviderFailureClass`.
enum ProviderFailureClassifier {
    static func classify(_ error: any Error, isCancelled: Bool = false) -> ProviderFailureClass {
        if isCancelled || error is CancellationError { return .cancellation }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancellation
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return .network
            default: return .unknown
            }
        }
        if let jarvis = error as? JarvisError {
            switch jarvis {
            case .providerRateLimited: return .rateLimited
            case .providerTimeout, .timeout: return .timeout
            case .providerUnavailable: return .providerUnavailable
            case .providerError(_, let message): return classify(message: message)
            case .allProvidersFailed: return .providerUnavailable
            default: break
            }
        }
        return classify(message: error.localizedDescription)
    }

    /// Classify from a provider's textual error (many providers surface the HTTP
    /// status inside the message rather than as a typed error).
    static func classify(message: String) -> ProviderFailureClass {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized")
            || lower.contains("invalid api key") || lower.contains("authentication") {
            return .authentication
        }
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("rate-limited") {
            return .rateLimited
        }
        if lower.contains("quota") || lower.contains("insufficient_quota") || lower.contains("credit") {
            return .quotaExhausted
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return .timeout
        }
        if lower.contains("could not connect") || lower.contains("network")
            || lower.contains("offline") || lower.contains("connection") {
            return .network
        }
        if lower.contains("empty response") || lower.contains("unparseable")
            || lower.contains("malformed") {
            return .malformedResponse
        }
        if lower.contains("400") || lower.contains("422") || lower.contains("invalid request") {
            return .invalidRequest
        }
        if lower.contains("model") && (lower.contains("not available") || lower.contains("not found")) {
            return .providerUnavailable
        }
        return .unknown
    }
}
