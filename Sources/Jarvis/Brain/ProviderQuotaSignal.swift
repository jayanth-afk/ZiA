import Foundation

/// Parses provider-reported rate-limit/quota headers into a truthful
/// `ProviderQuota`.
///
/// This is the *only* sanctioned way ZiA learns a server's remaining quota: a
/// value must come from the provider itself. Absent headers yield a fully
/// `.unknown` quota — never an inferred or fabricated number (§5). The
/// standard OpenAI-compatible header family is parsed:
///
///   • `x-ratelimit-remaining-requests` — requests left in the current window
///   • `x-ratelimit-remaining-tokens`   — tokens left in the current window
///   • `x-ratelimit-reset-requests`     — when the request window resets
///   • `x-ratelimit-reset-tokens`       — when the token window resets
///
/// Reset values appear either as delta-seconds or as a duration string such as
/// `"1.2s"`, `"6m0s"`, `"500ms"`, or `"1h2m3s"`. Anything unparseable leaves
/// that dimension unknown rather than guessing.
enum ProviderQuotaSignal {
    static func parse(response: HTTPURLResponse?, now: Date = .now) -> ProviderQuota {
        guard let response else { return .unknown }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        return parse(headers: headers, now: now)
    }

    /// Report a response's quota headers to the resource broker. A no-op when
    /// the provider exposed nothing usable — unknown never becomes a value.
    static func report(_ response: URLResponse?, for providerID: String) async {
        guard let http = response as? HTTPURLResponse else { return }
        let quota = parse(response: http)
        guard quota.hasKnownValue else { return }
        await ProviderResourceBroker.shared.observeQuota(quota, for: providerID)
    }

    /// Parse an already-collected header map. Keys are matched case-insensitively.
    static func parse(headers: [String: String], now: Date = .now) -> ProviderQuota {
        var lowered: [String: String] = [:]
        for (key, value) in headers { lowered[key.lowercased()] = value }

        var quota = ProviderQuota.unknown

        if let remaining = intValue(lowered["x-ratelimit-remaining-requests"]) {
            quota.requestsRemaining = .known(Double(remaining))
        }
        if let remaining = intValue(lowered["x-ratelimit-remaining-tokens"]) {
            quota.tokensRemaining = .known(Double(remaining))
        }

        // Reset: prefer whichever window resets soonest and use its deadline.
        let resetCandidates = [
            duration(from: lowered["x-ratelimit-reset-requests"]),
            duration(from: lowered["x-ratelimit-reset-tokens"])
        ].compactMap { $0 }
        if let soonest = resetCandidates.min() {
            quota.resetAt = now.addingTimeInterval(max(0, soonest))
        }

        quota.lastUpdated = quota.hasKnownValue ? now : nil
        return quota
    }

    /// Parse a duration that is either a bare number (seconds) or a unit string
    /// such as `1.2s`, `500ms`, `6m0s`, `1h30m`. Returns nil when unparseable.
    static func duration(from raw: String?) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let text = raw.lowercased()
        if let plain = TimeInterval(text) { return max(0, plain) }

        var total: TimeInterval = 0
        var index = text.startIndex
        var matchedAny = false
        while index < text.endIndex {
            var numberText = ""
            while index < text.endIndex, text[index].isNumber || text[index] == "." {
                numberText.append(text[index])
                index = text.index(after: index)
            }
            guard let value = Double(numberText) else { return nil }

            var unit = ""
            while index < text.endIndex, text[index].isLetter {
                unit.append(text[index])
                index = text.index(after: index)
            }
            guard let multiplier = unitMultiplier(unit) else { return nil }
            total += value * multiplier
            matchedAny = true
        }
        return matchedAny ? total : nil
    }

    private static func unitMultiplier(_ unit: String) -> TimeInterval? {
        switch unit {
        case "ms": return 0.001
        case "s", "sec", "secs", "second", "seconds": return 1
        case "m", "min", "mins", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hour", "hours": return 3600
        default: return nil
        }
    }

    private static func intValue(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // Some providers send a decimal string; truncate toward zero.
        if let int = Int(raw) { return max(0, int) }
        if let double = Double(raw) { return max(0, Int(double)) }
        return nil
    }
}
