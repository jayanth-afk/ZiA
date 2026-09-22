import Foundation

/// Unified error types for JARVIS.
///
/// Organized by subsystem. Each case carries enough context
/// for the caller to decide recovery strategy.
enum JarvisError: LocalizedError {

    // MARK: - Core
    case notInitialized(component: String)
    case invalidState(expected: String, actual: String)
    case timeout(operation: String, durationMs: Int)

    // MARK: - Provider
    case providerUnavailable(provider: String)
    case providerTimeout(provider: String, timeoutMs: Int)
    case providerRateLimited(provider: String, retryAfter: TimeInterval?)
    case providerError(provider: String, message: String)
    case allProvidersFailed

    // MARK: - Voice
    case microphoneAccessDenied
    case speechRecognitionDenied
    case wakeWordFailed(reason: String)
    case ttsFailure(provider: String, reason: String)

    // MARK: - Actions
    case permissionDenied(action: String, requiredLevel: Int, currentLevel: Int)
    case actionFailed(action: String, reason: String)
    case commandBlocked(command: String, reason: String)
    case verificationFailed(action: String, expected: String, actual: String)

    // MARK: - Memory
    case databaseError(operation: String, underlying: Error)
    case embeddingFailed(reason: String)

    // MARK: - Network / Auth
    case offline(operation: String)
    case apiKeyMissing(service: String)

    // MARK: - Resource
    case insufficientMemory(required: Int, available: Int)
    case modelLoadFailed(model: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notInitialized(let c): return "Not initialized: \(c)"
        case .invalidState(let e, let a): return "Invalid state: expected \(e), got \(a)"
        case .timeout(let op, let ms): return "\(op) timed out after \(ms)ms"
        case .providerUnavailable(let p): return "Provider unavailable: \(p)"
        case .providerTimeout(let p, let ms): return "\(p) timed out after \(ms)ms"
        case .providerRateLimited(let p, _): return "\(p) rate limited"
        case .providerError(let p, let m): return "\(p) error: \(m)"
        case .allProvidersFailed: return "All AI providers failed"
        case .microphoneAccessDenied: return "Microphone access denied"
        case .speechRecognitionDenied: return "Speech recognition access denied"
        case .wakeWordFailed(let r): return "Wake word failed: \(r)"
        case .ttsFailure(let p, let r): return "TTS (\(p)) failed: \(r)"
        case .permissionDenied(let a, let req, let cur):
            return "Permission denied for \(a) (requires L\(req), current L\(cur))"
        case .actionFailed(let a, let r): return "\(a) failed: \(r)"
        case .commandBlocked(let c, let r): return "Blocked: \(c) — \(r)"
        case .verificationFailed(let a, let e, let act):
            return "Verification failed for \(a): expected \(e), got \(act)"
        case .databaseError(let op, let e): return "DB error (\(op)): \(e.localizedDescription)"
        case .embeddingFailed(let r): return "Embedding failed: \(r)"
        case .offline(let op): return "Offline — cannot perform: \(op)"
        case .apiKeyMissing(let s): return "API key missing: \(s)"
        case .insufficientMemory(let req, let avail):
            return "Insufficient memory: need \(req)MB, have \(avail)MB"
        case .modelLoadFailed(let m, let r): return "Model load failed (\(m)): \(r)"
        }
    }
}
