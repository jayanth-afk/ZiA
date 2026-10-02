import Foundation

/// Deterministic, network-free server-side URL safety gate (SSRF defense).
///
/// Enforced at BOTH boundaries because either alone is bypassable:
///   - the PlanValidator (plan-time), so a hostile/hallucinated plan is rejected
///     before it can be scheduled, and
///   - `URLFetcher` (execute-time), so a directly-invoked tool can never skip
///     validation.
///
/// The check is purely lexical: it never parses or resolves DNS, so it cannot
/// be raced, has no network I/O, and stays deterministic. It intentionally
/// rejects loopback, private/link-local/CGNAT IPv4, IPv6 loopback/link-local/
/// unique-local, `.local`/`.internal`/`.lan`/`.localhost` names, cloud metadata
/// endpoints, embedded credentials, and numeric-obfuscated hosts (decimal/hex
/// IPv4), while leaving ordinary public `http(s)` URLs untouched.
enum URLSafety {
    /// Returns a human-readable reason when `url` must not be fetched, or nil
    /// when it is acceptable.
    static func blockedReason(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "unsupported URL scheme '\(url.scheme ?? "")'"
        }
        if let user = url.user, !user.isEmpty { return "URL contains embedded credentials" }
        if let password = url.password, !password.isEmpty { return "URL contains embedded credentials" }
        guard let host = url.host, !host.isEmpty else { return "URL has no host" }
        return blockedReason(forHost: host)
    }

    /// Host-only SSRF classification. Accepts bracketed or bare IPv6 forms.
    static func blockedReason(forHost rawHost: String) -> String? {
        var host = rawHost.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        if host.isEmpty { return "URL has no host" }

        if host == "localhost" || host.hasSuffix(".localhost") { return "loopback host is not allowed" }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") {
            return "internal hostname is not allowed"
        }
        if host == "metadata.google.internal" || host == "instance-data" || host == "metadata" {
            return "cloud metadata endpoint is not allowed"
        }

        if let octets = ipv4Octets(host) {
            let (a, b) = (octets[0], octets[1])
            if a == 127 || a == 0 { return "loopback/unspecified host is not allowed" }
            if a == 10 { return "private network is not allowed" }
            if a == 192 && b == 168 { return "private network is not allowed" }
            if a == 172 && (16...31).contains(b) { return "private network is not allowed" }
            if a == 169 && b == 254 { return "link-local host is not allowed" }
            if a == 100 && (64...127).contains(b) { return "carrier-grade NAT range is not allowed" }
            return nil
        }

        // IPv6 literals (host still contains the colon separators).
        if host.contains(":") {
            if host == "::1" || host == "::" { return "loopback host is not allowed" }
            if host.hasPrefix("fe80:") || host.hasPrefix("fe8") || host.hasPrefix("fe9")
                || host.hasPrefix("fea") || host.hasPrefix("feb") {
                return "link-local host is not allowed"
            }
            if let first = host.split(separator: ":").first, let group = Int(first, radix: 16),
               (0xfc00...0xfdff).contains(group) {
                return "unique-local host is not allowed"
            }
            return nil
        }

        // Numeric-obfuscated IPv4 (decimal single-integer or 0x-hex). A genuine
        // DNS name always ends in an alphabetic TLD, so anything all-numeric or
        // 0x-prefixed cannot be a normal hostname.
        if host.allSatisfy({ $0.isNumber }) { return "numeric host encoding is not allowed" }
        if host.hasPrefix("0x") && host.dropFirst(2).allSatisfy({ $0.isHexDigit }) {
            return "numeric host encoding is not allowed"
        }

        return nil
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber }),
                  part.count <= 3,
                  let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }
}
