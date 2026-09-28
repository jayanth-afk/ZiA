import Foundation
import AVFoundation

/// Low-power wake word detector that spots configured wake aliases (e.g. "Jarvis", "Zia", "Ziya").
/// Active primarily in SLEEP state, gating full pipeline activation.
@MainActor
final class WakeWordDetector {
    static let shared = WakeWordDetector()

    // MARK: - Match Structure

    struct WakeMatch: Sendable, Equatable {
        let matchedAlias: String
        let prefixUsed: String?
        let strippedCommand: String
    }

    // MARK: - State
    private(set) var isListening = false

    private init() {}

    // MARK: - Public API

    func startListening() {
        guard !isListening else { return }
        isListening = true
        JarvisLogger.voice.info("Wake word detector listening for aliases: \(Config.shared.wakeAliases)")
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        JarvisLogger.voice.info("Wake word detector stopped")
    }

    /// Allowed conversational salutations preceding a wake alias.
    private static let conversationalPrefixes: [String] = [
        "hey", "hi", "hello", "ok", "okay", "please", "yo"
    ]

    private static let punctuationSeparators = CharacterSet(charactersIn: ",:;-!?.\"'")
    private static let wordBoundarySeparators = CharacterSet.whitespaces.union(punctuationSeparators)

    /// Primary pattern matcher: checks if text starts with an allowed wake alias or prefix + alias.
    /// Strips ONLY the wake phrase/prefix from the command.
    /// Case-insensitive, enforces strict word boundaries to avoid matching substrings in ordinary words.
    static func findWakeMatch(in transcript: String, aliases: [String] = Config.shared.wakeAliases) -> WakeMatch? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let sortedAliases = aliases.sorted { $0.count > $1.count }

        // 1. Check conversational prefix + alias: e.g. "Hey Zia, what time is it?"
        for prefix in conversationalPrefixes {
            if lower.hasPrefix(prefix) {
                let prefixEndIdx = lower.index(lower.startIndex, offsetBy: prefix.count)
                if prefixEndIdx == lower.endIndex {
                    continue
                }
                let nextChar = lower[prefixEndIdx]
                let isSep = nextChar.unicodeScalars.allSatisfy { wordBoundarySeparators.contains($0) }
                if isSep {
                    let afterPrefixLower = String(lower[prefixEndIdx...]).trimmingCharacters(in: wordBoundarySeparators)
                    let afterPrefixOrig = String(trimmed[prefixEndIdx...]).trimmingCharacters(in: wordBoundarySeparators)

                    for alias in sortedAliases {
                        let aliasLower = alias.lowercased()
                        if afterPrefixLower.hasPrefix(aliasLower) {
                            let aliasEndIdx = afterPrefixLower.index(afterPrefixLower.startIndex, offsetBy: aliasLower.count)
                            if aliasEndIdx == afterPrefixLower.endIndex {
                                return WakeMatch(matchedAlias: aliasLower, prefixUsed: prefix, strippedCommand: "")
                            }
                            let charAfterAlias = afterPrefixLower[aliasEndIdx]
                            let isAliasSep = charAfterAlias.unicodeScalars.allSatisfy { wordBoundarySeparators.contains($0) }
                            if isAliasSep {
                                let origAfterAlias = afterPrefixOrig.index(afterPrefixOrig.startIndex, offsetBy: aliasLower.count)
                                var cmd = String(afterPrefixOrig[origAfterAlias...]).trimmingCharacters(in: wordBoundarySeparators)
                                while let last = cmd.last, ".?!".contains(last) {
                                    cmd = String(cmd.dropLast()).trimmingCharacters(in: .whitespaces)
                                }
                                return WakeMatch(matchedAlias: aliasLower, prefixUsed: prefix, strippedCommand: cmd)
                            }
                        }
                    }
                }
            }
        }

        // 2. Check direct alias: e.g. "Zia, open Safari" or "Jarvis what time is it"
        for alias in sortedAliases {
            let aliasLower = alias.lowercased()
            if lower.hasPrefix(aliasLower) {
                let aliasEndIdx = lower.index(lower.startIndex, offsetBy: aliasLower.count)
                if aliasEndIdx == lower.endIndex {
                    return WakeMatch(matchedAlias: aliasLower, prefixUsed: nil, strippedCommand: "")
                }
                let nextChar = lower[aliasEndIdx]
                let isSep = nextChar.unicodeScalars.allSatisfy { wordBoundarySeparators.contains($0) }
                if isSep {
                    let origAfterAlias = trimmed.index(trimmed.startIndex, offsetBy: aliasLower.count)
                    var cmd = String(trimmed[origAfterAlias...]).trimmingCharacters(in: wordBoundarySeparators)
                    while let last = cmd.last, ".?!".contains(last) {
                        cmd = String(cmd.dropLast()).trimmingCharacters(in: .whitespaces)
                    }
                    return WakeMatch(matchedAlias: aliasLower, prefixUsed: nil, strippedCommand: cmd)
                }
            }
        }

        return nil
    }

    /// Check if recognized text contains the wake word or alias.
    /// Returns true and publishes WakeWordDetectedEvent if detected.
    @discardableResult
    func checkForWakeWord(in transcript: String) -> Bool {
        guard isListening else { return false }

        guard let match = Self.findWakeMatch(in: transcript) else {
            return false
        }

        JarvisLogger.voice.info("Wake alias '\(match.matchedAlias)' detected in transcript: '\(transcript)'")
        EventBus.shared.publish(WakeWordDetectedEvent())
        return true
    }
}
