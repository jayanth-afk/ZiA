import Foundation
import AppKit

/// C5: measure the ChatGPT brain instead of guessing.
///
/// Real, **capped** calls only (≤ 6 synthetic prompts per transport, whole run
/// ≤ 5 minutes, spacing between calls). Prompts are synthetic and contain no
/// personal data. The engine route runs first; the UI route runs only when its
/// health is READY and ChatGPT Desktop is not frontmost. This never changes the
/// routing policy — it only gathers numbers.
enum ChatGPTBrainBenchmark {
    static let maxPromptsPerTransport = 6
    static let maxRunSeconds: TimeInterval = 300
    static let spacingSeconds: TimeInterval = 2

    static let syntheticPrompts = [
        "Reply with exactly: ZIA_BENCH_OK.",
        "What is 17 multiplied by 3? Answer with the number only.",
        "Name the capital of France in one word.",
        "Write the word 'latency' backwards.",
        "How many minutes are in two hours? Answer with the number only.",
        "Reply with the single word: ready."
    ]

    struct Attempt: Sendable {
        let transport: String
        let prompt: String
        let ok: Bool
        let reportedTransport: String?
        let firstChunkMs: Int?
        let totalMs: Int?
        let error: String?
    }

    struct Outcome: Sendable {
        let ranAt: Date
        let bridgeReachable: Bool
        let availabilityNote: String
        let attempts: [Attempt]
    }

    // MARK: - Entry point

    static func run(outputPath: String) async -> Int {
        let outputDirectory = URL(fileURLWithPath: outputPath)
        let base = URL(string: "http://127.0.0.1:8765")!
        let startedAt = Date()
        var notes: [String] = []
        var attempts: [Attempt] = []
        var reachable = false

        guard let key = KeychainManager.shared.getAPIKey(for: .agentBridge) else {
            notes.append("unavailable — no Agent Bridge API key in the Keychain (service jarvis.agentbridge.api_key)")
            persist(Outcome(ranAt: startedAt, bridgeReachable: false, availabilityNote: notes.joined(separator: "; "), attempts: []),
                    startedAt: startedAt, to: outputDirectory)
            return 0
        }

        let health = await health(base: base, key: key)
        reachable = health.reachable
        notes.append(health.note)

        let deadline = ContinuousClock.now.advanced(by: .seconds(Int(maxRunSeconds)))
        func outOfTime() -> Bool { ContinuousClock.now >= deadline }

        // Engine route first.
        if reachable {
            for prompt in syntheticPrompts.prefix(maxPromptsPerTransport) {
                if outOfTime() { notes.append("engine route stopped: 5-minute cap reached"); break }
                let attempt = await call(base: base, key: key, transport: "engine", prompt: prompt)
                attempts.append(attempt)
                if attempt.error?.contains("CODEX_CLI_NOT_FOUND") == true {
                    notes.append("engine route unavailable: bundled Codex CLI not found")
                    break
                }
                try? await Task.sleep(for: .seconds(spacingSeconds))
            }

            // UI route only when READY and ChatGPT is not frontmost.
            let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
            if !health.ready {
                notes.append("UI route skipped: bridge health is \(health.status)")
            } else if frontmost == "com.openai.chat" {
                notes.append("UI route skipped: ChatGPT Desktop is frontmost")
            } else {
                for prompt in syntheticPrompts.prefix(maxPromptsPerTransport) {
                    if outOfTime() { notes.append("UI route stopped: 5-minute cap reached"); break }
                    let attempt = await call(base: base, key: key, transport: "ui", prompt: prompt)
                    attempts.append(attempt)
                    try? await Task.sleep(for: .seconds(spacingSeconds))
                }
            }
        }

        let outcome = Outcome(ranAt: startedAt, bridgeReachable: reachable,
                              availabilityNote: notes.joined(separator: "; "), attempts: attempts)
        persist(outcome, startedAt: startedAt, to: outputDirectory)
        return 0
    }

    // MARK: - Bridge calls

    private struct Health { let reachable: Bool; let ready: Bool; let status: String; let note: String }

    private static func health(base: URL, key: String) async -> Health {
        var request = URLRequest(url: base.appendingPathComponent("api/chatgpt/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = ProviderAvailability.probeTimeout
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Health(reachable: false, ready: false, status: "no-http", note: "bridge reachable but returned no HTTP response")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let status = (json?["status"] as? String) ?? "\(http.statusCode)"
            let ready = (json?["ok"] as? Bool) == true
            return Health(reachable: true, ready: ready, status: status,
                          note: "bridge reachable; health=\(status)\(ready ? " (READY)" : "")")
        } catch {
            return Health(reachable: false, ready: false, status: "unreachable",
                          note: "bridge unreachable at 127.0.0.1:8765 (\(error.localizedDescription))")
        }
    }

    private static func call(base: URL, key: String, transport: String, prompt: String) async -> Attempt {
        var comps = URLComponents(url: base.appendingPathComponent("api/chatgpt/complete"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "stream", value: "true")]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = ChatGPTBrain.totalDeadlineSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let body: [String: Any] = [
            "transport": transport,
            "requestId": "zia_bench_\(UUID().uuidString)",
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let start = ContinuousClock.now
        func ms(since: ContinuousClock.Instant) -> Int {
            let d = since.duration(to: .now)
            return Int(Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1_000_000_000_000_000.0)
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return Attempt(transport: transport, prompt: prompt, ok: false, reportedTransport: nil,
                               firstChunkMs: nil, totalMs: ms(since: start), error: "HTTP \(status)")
            }
            var firstChunkMs: Int?
            var reported: String?
            var confirmed = false
            var errorText: String?
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data: ") else { continue }
                if firstChunkMs == nil { firstChunkMs = ms(since: start) }
                guard let data = String(trimmed.dropFirst(6)).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let t = obj["transport"] as? String { reported = t }
                if obj["done"] as? Bool == true {
                    if obj["modelTurnConfirmed"] as? Bool == true { confirmed = true }
                    if let e = obj["error"] as? String, !e.isEmpty { errorText = e }
                }
            }
            let totalMs = ms(since: start)
            if confirmed { ChatGPTBrainLatency.shared.record(totalMs) }
            return Attempt(transport: transport, prompt: prompt, ok: confirmed, reportedTransport: reported,
                           firstChunkMs: firstChunkMs, totalMs: totalMs, error: confirmed ? nil : (errorText ?? "not confirmed"))
        } catch {
            return Attempt(transport: transport, prompt: prompt, ok: false, reportedTransport: nil,
                           firstChunkMs: nil, totalMs: ms(since: start), error: error.localizedDescription)
        }
    }

    // MARK: - Output

    private static func persist(_ outcome: Outcome, startedAt: Date, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let md = markdown(outcome)
        try? md.write(to: directory.appendingPathComponent("chatgpt-brain-benchmark.md"), atomically: true, encoding: .utf8)
        try? rawLog(outcome).write(to: directory.appendingPathComponent("chatgpt-brain-benchmark.raw.txt"), atomically: true, encoding: .utf8)
        print(md)
    }

    private static func markdown(_ outcome: Outcome) -> String {
        var lines: [String] = []
        lines.append("# ChatGPT brain benchmark (measured)")
        lines.append("")
        lines.append("Run at: \(outcome.ranAt)  ")
        lines.append("Bridge reachable: \(outcome.bridgeReachable)  ")
        lines.append("Availability: \(outcome.availabilityNote)")
        lines.append("")

        if outcome.attempts.isEmpty {
            lines.append("## Numbers")
            lines.append("")
            lines.append("No prompts were sent (see availability above).")
            lines.append("")
        } else {
            lines.append("## Numbers")
            lines.append("")
            lines.append("| # | transport | ok | first chunk (ms) | total (ms) | reported | prompt |")
            lines.append("|---|-----------|----|------------------|------------|----------|--------|")
            for (index, attempt) in outcome.attempts.enumerated() {
                let first = attempt.firstChunkMs.map(String.init) ?? "—"
                let total = attempt.totalMs.map(String.init) ?? "—"
                lines.append("| \(index + 1) | \(attempt.transport) | \(attempt.ok) | \(first) | \(total) | \(attempt.reportedTransport ?? "—") | \(attempt.prompt) |")
            }
            lines.append("")
            for transport in ["engine", "ui"] {
                let group = outcome.attempts.filter { $0.transport == transport && $0.ok }
                guard !group.isEmpty else { continue }
                let totals = group.compactMap(\.totalMs).sorted()
                let firsts = group.compactMap(\.firstChunkMs).sorted()
                let medianTotal = totals.isEmpty ? 0 : totals[totals.count / 2]
                let medianFirst = firsts.isEmpty ? 0 : firsts[firsts.count / 2]
                lines.append("- \(transport): \(group.count) ok · median first chunk \(medianFirst) ms · median total \(medianTotal) ms")
            }
            lines.append("")
        }

        lines.append("## Recommendation (kept separate from the numbers)")
        lines.append("")
        let engineOk = outcome.attempts.contains { $0.transport == "engine" && $0.ok }
        let uiOk = outcome.attempts.contains { $0.transport == "ui" && $0.ok }
        if engineOk && uiOk {
            lines.append("Both transports answered. Prefer the engine transport (no window, stateless, concurrent).")
        } else if engineOk {
            lines.append("Only the engine transport answered. Keep `auto` (engine-first) as the default.")
        } else if uiOk {
            lines.append("Only the UI transport answered. Keep `auto`; the engine is not usable on this machine.")
        } else {
            lines.append("No transport answered. This is evidence, not a routing change — investigate the bridge/ChatGPT sign-in before relying on the brain.")
        }
        lines.append("")
        lines.append("_This benchmark does not change the routing policy (C5). The measured median feeds `ChatGPTDesktopProvider.currentLatencyMs`._")
        return lines.joined(separator: "\n")
    }

    private static func rawLog(_ outcome: Outcome) -> String {
        var lines = ["chatgpt-brain-benchmark raw log", "ranAt=\(outcome.ranAt)", "reachable=\(outcome.bridgeReachable)", "note=\(outcome.availabilityNote)"]
        for attempt in outcome.attempts {
            lines.append("transport=\(attempt.transport) ok=\(attempt.ok) first=\(attempt.firstChunkMs.map(String.init) ?? "-") total=\(attempt.totalMs.map(String.init) ?? "-") reported=\(attempt.reportedTransport ?? "-") error=\(attempt.error ?? "-") prompt=\(attempt.prompt)")
        }
        return lines.joined(separator: "\n")
    }
}
