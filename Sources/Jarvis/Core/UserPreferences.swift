import Foundation

enum ResponseVerbosity: String, Codable, Sendable, CaseIterable {
    case concise, normal, detailed
}

enum ResponseStyle: String, Codable, Sendable, CaseIterable {
    case direct, friendly, technical
}

enum ConfirmationPreference: String, Codable, Sendable, CaseIterable {
    /// Ask before destructive/irreversible actions (default).
    case askForDestructive
    /// Ask before any externally-consequential action too.
    case askForExternal
    /// Only ask when strictly required by the authority boundary.
    case minimal
}

/// The keys the user can set explicitly. A key present in `explicitKeys` was
/// chosen by the user and can never be silently overridden by inference.
enum PreferenceKey: String, CaseIterable, Sendable {
    case verbosity
    case style
    case localOnly
    case notifyOnCompletion
    case notifyOnFailure
    case preferredLanguage
    case confirmation
    case preferredProviders
    case backgroundWork
}

/// Durable user preferences. Explicit user preference always outranks inferred
/// preference; inference is advisory and never overrides an explicit choice.
struct UserPreferences: Codable, Sendable, Equatable {
    var verbosity: ResponseVerbosity = .normal
    var style: ResponseStyle = .direct
    var preferredProviders: [String] = []
    var localOnly: Bool = false
    var notifyOnCompletion: Bool = true
    var notifyOnFailure: Bool = true
    /// nil = follow the configured autonomy level.
    var backgroundWork: Bool? = nil
    var confirmation: ConfirmationPreference = .askForDestructive
    var preferredLanguage: String = "en"
    var updatedAt: Date = .now
    /// Keys the user set explicitly (protected from inference).
    var explicitKeys: Set<String> = []
}

@MainActor
final class PreferenceStore {
    static let shared = PreferenceStore()

    private static let storageKey = "jarvis.preferences.v1"
    private let defaults = UserDefaults.standard
    private(set) var current: UserPreferences

    private init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            current = decoded
        } else {
            current = UserPreferences()
        }
    }

    /// Set a preference explicitly. This marks the key as user-owned so
    /// inference can never override it.
    @discardableResult
    func setExplicit(_ key: PreferenceKey, value: String) throws -> UserPreferences {
        guard apply(key: key, value: value) else {
            throw JarvisError.actionFailed(action: "set_preference",
                                           reason: "Unknown or invalid value '\(value)' for preference '\(key.rawValue)'")
        }
        current.explicitKeys.insert(key.rawValue)
        current.updatedAt = .now
        persist()
        return current
    }

    /// Apply an inferred preference. Refuses to override an explicit choice.
    @discardableResult
    func applyInferred(_ key: PreferenceKey, value: String) -> Bool {
        guard !current.explicitKeys.contains(key.rawValue) else {
            JarvisLogger.brain.info("Ignoring inferred preference \(key.rawValue): user set it explicitly")
            return false
        }
        guard apply(key: key, value: value) else { return false }
        current.updatedAt = .now
        persist()
        return true
    }

    /// Update preferences directly with closure and persist.
    func updateExplicit(_ mutate: (inout UserPreferences) -> Void) {
        mutate(&current)
        current.updatedAt = .now
        persist()
    }

    func reset() {
        current = UserPreferences()
        persist()
    }

    func summary() -> String {
        var lines = ["Your preferences:"]
        lines.append("• verbosity: \(current.verbosity.rawValue)\(mark(.verbosity))")
        lines.append("• style: \(current.style.rawValue)\(mark(.style))")
        lines.append("• confirmation: \(current.confirmation.rawValue)\(mark(.confirmation))")
        lines.append("• local-only: \(current.localOnly)\(mark(.localOnly))")
        lines.append("• notifications (completion/failure): \(current.notifyOnCompletion)/\(current.notifyOnFailure)")
        lines.append("• language: \(current.preferredLanguage)\(mark(.preferredLanguage))")
        if !current.preferredProviders.isEmpty {
            lines.append("• preferred providers: \(current.preferredProviders.joined(separator: ", "))")
        }
        if let background = current.backgroundWork {
            lines.append("• background work: \(background)")
        }
        return lines.joined(separator: "\n")
    }

    private func mark(_ key: PreferenceKey) -> String {
        current.explicitKeys.contains(key.rawValue) ? " (explicit)" : ""
    }

    private func apply(key: PreferenceKey, value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case .verbosity:
            guard let parsed = ResponseVerbosity(rawValue: normalized) else { return false }
            current.verbosity = parsed
        case .style:
            guard let parsed = ResponseStyle(rawValue: normalized) else { return false }
            current.style = parsed
        case .localOnly:
            guard let parsed = Bool(normalized) else { return false }
            current.localOnly = parsed
        case .notifyOnCompletion:
            guard let parsed = Bool(normalized) else { return false }
            current.notifyOnCompletion = parsed
        case .notifyOnFailure:
            guard let parsed = Bool(normalized) else { return false }
            current.notifyOnFailure = parsed
        case .backgroundWork:
            guard let parsed = Bool(normalized) else { return false }
            current.backgroundWork = parsed
        case .preferredLanguage:
            guard !normalized.isEmpty else { return false }
            current.preferredLanguage = normalized
        case .confirmation:
            guard let parsed = ConfirmationPreference.allCases.first(where: { $0.rawValue.lowercased() == normalized }) else { return false }
            current.confirmation = parsed
        case .preferredProviders:
            let providers = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            current.preferredProviders = providers.filter { !$0.isEmpty }
        }
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(current) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
