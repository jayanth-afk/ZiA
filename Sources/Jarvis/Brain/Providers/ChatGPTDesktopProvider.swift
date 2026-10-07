import Foundation

/// Real ChatGPT Desktop brain for ZiA.
///
/// This provider does NOT call an API or impersonate ChatGPT. It asks the
/// user's already-authenticated ChatGPT worker through the local Agent Bridge
/// (`/api/chatgpt/*`). The bridge selects a transport (headless Codex engine or
/// the Accessibility-driven UI route) and reports which one answered.
///
/// **Safety gates (all must pass before anything leaves the machine):**
///   1. Opt-in — "Allow ChatGPT as a brain" is OFF by default.
///   2. An Agent Bridge control-plane API key is configured.
///   3. DataClassifier: sensitive/highly-sensitive requests NEVER go to ChatGPT
///      (fail closed to local).
///   4. ContextSanitizer redacts credentials on untrusted segments.
///
/// Failure is intentionally ordinary: ProviderManager falls through to the next
/// provider, eventually reaching the local MLX providers.
actor ChatGPTDesktopProvider: LLMProvider {
    nonisolated let id = "chatgpt-desktop"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .codeGeneration,
        .longContext,
        .structuredOutput
    ]
    /// Measured, not guessed: the rolling median of real turn latencies (C5),
    /// floored at a documented 1200 ms fallback until samples exist.
    nonisolated var currentLatencyMs: Int { ChatGPTBrainLatency.shared.median }

    /// Resolves the Agent Bridge control-plane API key. The bridge's ChatGPT
    /// brain endpoints always require it, so an absent key FAILS CLOSED (the
    /// brain is disabled) rather than sending an unauthenticated request.
    /// Injectable so tests pin both the configured and missing paths without
    /// touching the real keychain.
    private let apiKeyProvider: @Sendable () -> String?
    /// Resolves the opt-in flag. Injectable so tests pin both states without
    /// mutating global UserDefaults (which would race across suites).
    private let isEnabledProvider: @Sendable () -> Bool
    /// Injectable so tests exercise the real request path against a URLProtocol
    /// stub with no network access.
    private let session: URLSession

    init(session: URLSession = .shared,
         apiKeyProvider: @escaping @Sendable () -> String? = {
             KeychainManager.shared.getAPIKey(for: .agentBridge)
         },
         isEnabledProvider: @escaping @Sendable () -> Bool = { ChatGPTBrain.isEnabled }) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.isEnabledProvider = isEnabledProvider
    }

    /// The bridge key, or nil when the ChatGPT brain is not configured.
    nonisolated func bridgeKey() -> String? { apiKeyProvider() }

    /// Attach the control-plane key. Never logs or echoes the value.
    private func applyBridgeAuth(_ request: inout URLRequest) {
        if let key = bridgeKey() { request.setValue(key, forHTTPHeaderField: "x-api-key") }
    }

    private let chatgptHealthURL = URL(string: "http://127.0.0.1:8765/api/chatgpt/health")!
    private let fallbackHealthURL = URL(string: "http://127.0.0.1:8765/health")!
    private let brainURL = URL(string: "http://127.0.0.1:8765/api/chatgpt/complete")!
    private let timeoutSeconds: TimeInterval = ChatGPTBrain.totalDeadlineSeconds

    private var cachedAvailability: (value: Bool, timestamp: ContinuousClock.Instant)?
    private let availabilityTTL: Duration = .seconds(2)

    /// Transport the bridge reported for the most recent turn ("engine"/"ui").
    private var lastResolvedTransport: String?
    /// Provenance for the decision record; nil until a turn has completed.
    func lastTransport() -> String? { lastResolvedTransport }

    var isAvailable: Bool {
        get async {
            // Gate 1 + 2: opt-in and a configured key. Without both, the brain is
            // honestly unavailable and routing skips it.
            guard isEnabledProvider(), bridgeKey() != nil else { return false }
            if let cached = cachedAvailability, cached.timestamp.duration(to: .now) < availabilityTTL {
                return cached.value
            }
            let available = await probeAvailability()
            cachedAvailability = (value: available, timestamp: .now)
            return available
        }
    }

    private func probeAvailability() async -> Bool {
        var request = URLRequest(url: chatgptHealthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.2
        applyBridgeAuth(&request)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let ok = json["ok"] as? Bool {
                        return ok
                    }
                    return true
                } else if http.statusCode == 503 {
                    return false
                }
            }
        } catch {
            var fallbackReq = URLRequest(url: fallbackHealthURL)
            fallbackReq.httpMethod = "GET"
            fallbackReq.timeoutInterval = 0.8
            applyBridgeAuth(&fallbackReq)
            if let (_, resp) = try? await session.data(for: fallbackReq),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
            return false
        }
        return false
    }

    /// N1 + C3: availability uses the tri-state, gated by opt-in, key, and health.
    /// `probe: false` never touches the network.
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard isEnabledProvider() else {
            return .unavailable(reason: "ChatGPT brain is off — enable \"Allow ChatGPT as a brain\" in Settings")
        }
        guard bridgeKey() != nil else {
            return .unavailable(reason: "Agent Bridge API key is not configured; ChatGPT brain is disabled")
        }
        if ChatGPTBrain.isDailyCapReached() {
            return .unavailable(reason: "ChatGPT brain daily cap reached (\(ChatGPTBrain.dailySoftCap) requests); resets tomorrow")
        }
        if probe {
            return await isAvailable
                ? .available
                : .unavailable(reason: "Agent Bridge ChatGPT endpoint is not responding")
        }
        if let cached = cachedAvailability, cached.timestamp.duration(to: .now) < availabilityTTL {
            return cached.value
                ? .available
                : .unavailable(reason: "Agent Bridge ChatGPT endpoint is not responding")
        }
        return .unverified(reason: "Agent Bridge ChatGPT endpoint not probed this cycle")
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        complete(messages: messages, tools: tools, stream: stream, options: [:])
    }

    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        stream: Bool,
        options: [String: any Sendable]
    ) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Gate 1: explicit opt-in.
                guard self.isEnabledProvider() else {
                    continuation.yield(.error("ChatGPT brain is off — enable it in Settings"))
                    continuation.finish()
                    return
                }
                // Gate 2: a configured bridge key.
                guard self.bridgeKey() != nil else {
                    continuation.yield(.error("Agent Bridge API key is not configured; ChatGPT brain is disabled"))
                    continuation.finish()
                    return
                }
                // Gate 3: data classification. Sensitive classes stay local.
                let originalText = messages.map(\.content).joined(separator: "\n")
                let level = await MainActor.run { DataClassifier.shared.classify(originalText) }
                let cloudAllowed = await MainActor.run { DataClassifier.shared.isCloudAllowed(for: level) }
                guard cloudAllowed else {
                    continuation.yield(.error(
                        "ChatGPT brain refused: request classified \(level.rawValue); staying on-device"))
                    continuation.finish()
                    return
                }
                // Gate 4: data minimization — redact credentials on dispatch.
                let safeMessages = ContextSanitizer.sanitizedForDispatch(messages, isLocal: false)

                if stream {
                    await self.streamFromBridge(messages: safeMessages, options: options, continuation: continuation)
                } else {
                    do {
                        let response = try await self.askBridge(messages: safeMessages, options: options)
                        continuation.yield(.text(response))
                        continuation.yield(.done(usage: .zero))
                        continuation.finish()
                    } catch {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                    }
                }
            }
            // Cancellation propagation: cancel the whole turn (including the
            // bridge read + first-token watchdog) when the consumer stops.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming

    private func streamFromBridge(
        messages: [Message],
        options: [String: any Sendable],
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation
    ) async {
        let requestId = "zia_gpt_\(UUID().uuidString)"
        let started = ContinuousClock.now
        guard let streamURL = URL(string: "http://127.0.0.1:8765/api/chatgpt/complete?stream=true") else {
            continuation.yield(.error("Invalid stream URL"))
            continuation.finish()
            return
        }

        var request = URLRequest(url: streamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        applyBridgeAuth(&request)

        let body: [String: Any] = [
            "messages": messages.map {
                ["role": $0.role.rawValue, "content": $0.content]
            },
            "requestId": requestId,
            "stream": true,
            "transport": "auto",
            "options": options.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            continuation.yield(.error("Failed to serialize request"))
            continuation.finish()
            return
        }
        request.httpBody = bodyData

        // First-token deadline: if the bridge never produces output, fall through
        // to the next provider instead of hanging until the total deadline.
        let firstTokenSeen = LockedValue<Bool>(false)
        let readTask = Task { [session] in
            await Self.readBridgeEvents(request: request, session: session,
                                        continuation: continuation, firstTokenSeen: firstTokenSeen,
                                        onTransport: { [weak self] transport in await self?.setTransport(transport) })
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(ChatGPTBrain.firstTokenDeadlineSeconds))
            if Task.isCancelled { return }
            if firstTokenSeen.value == false {
                readTask.cancel()
                continuation.yield(.error(
                    "ChatGPT brain produced no first token within \(Int(ChatGPTBrain.firstTokenDeadlineSeconds))s"))
                continuation.finish()
            }
        }
        await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            // The turn was interrupted: stop the bridge read and the watchdog
            // instead of leaving an orphaned stream running to completion.
            readTask.cancel()
            watchdog.cancel()
        }
        watchdog.cancel()
        if firstTokenSeen.value {
            let elapsed = started.duration(to: .now)
            let ms = Int(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0)
            ChatGPTBrainLatency.shared.record(ms)
        }
    }

    private func setTransport(_ transport: String?) {
        if let transport, !transport.isEmpty { lastResolvedTransport = transport }
    }

    private static func readBridgeEvents(
        request: URLRequest,
        session: URLSession,
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation,
        firstTokenSeen: LockedValue<Bool>,
        onTransport: @Sendable (String?) async -> Void
    ) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                continuation.yield(.error("ChatGPT Desktop streaming HTTP error"))
                continuation.finish()
                return
            }

            var confirmed = false
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                firstTokenSeen.value = true
                guard trimmed.hasPrefix("data: ") else { continue }
                let jsonStr = String(trimmed.dropFirst(6))
                guard let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let transport = obj["transport"] as? String {
                    await onTransport(transport)
                }
                if let chunk = obj["chunk"] as? String, !chunk.isEmpty {
                    continuation.yield(.text(chunk))
                }
                if let done = obj["done"] as? Bool, done {
                    if let modelConfirmed = obj["modelTurnConfirmed"] as? Bool, modelConfirmed {
                        confirmed = true
                    }
                    if let err = obj["error"] as? String, !err.isEmpty {
                        continuation.yield(.error(err))
                    }
                }
            }

            if confirmed {
                ChatGPTBrain.recordRequest()
                continuation.yield(.done(usage: .zero))
            } else {
                continuation.yield(.error("ChatGPT Desktop turn was not confirmed"))
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.yield(.error(error.localizedDescription))
            continuation.finish()
        }
    }

    // MARK: - One-shot

    private func askBridge(
        messages: [Message],
        options: [String: any Sendable]
    ) async throws -> String {
        let requestId = "zia_gpt_\(UUID().uuidString)"
        let started = ContinuousClock.now

        var request = URLRequest(url: brainURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        applyBridgeAuth(&request)

        let body: [String: Any] = [
            "messages": messages.map {
                ["role": $0.role.rawValue, "content": $0.content]
            },
            "requestId": requestId,
            "transport": "auto",
            "options": options.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            cachedAvailability = (value: false, timestamp: .now)
            throw ProviderError.unavailable("ChatGPT Desktop network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            cachedAvailability = (value: false, timestamp: .now)
            throw ProviderError.unavailable("ChatGPT Desktop brain returned non-HTTP response")
        }

        if !(200...299).contains(http.statusCode) {
            cachedAvailability = (value: false, timestamp: .now)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errMsg = json["error"] as? String {
                throw ProviderError.unavailable("ChatGPT Desktop: \(errMsg)")
            }
            throw ProviderError.unavailable("ChatGPT Desktop brain HTTP \(http.statusCode)")
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedAvailability = nil
            throw ProviderError.invalidResponse("ChatGPT Desktop brain returned malformed JSON")
        }

        if let transport = result["transport"] as? String { setTransport(transport) }

        guard result["ok"] as? Bool == true,
              result["modelTurnConfirmed"] as? Bool == true,
              let responseText = result["response"] as? String,
              !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cachedAvailability = nil
            throw ProviderError.unavailable(
                (result["error"] as? String) ?? "ChatGPT Desktop did not confirm a model turn"
            )
        }

        cachedAvailability = (value: true, timestamp: .now)
        ChatGPTBrain.recordRequest()
        let elapsed = started.duration(to: .now)
        let ms = Int(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0)
        ChatGPTBrainLatency.shared.record(ms)
        return responseText
    }

    enum ProviderError: LocalizedError {
        case unavailable(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .invalidResponse(let message):
                return message
            }
        }
    }
}
