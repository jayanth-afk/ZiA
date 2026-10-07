import Foundation

/// Real ChatGPT Desktop brain for ZiA.
///
/// This provider does NOT call an API or impersonate ChatGPT. It asks the
/// user's already-authenticated ChatGPT Desktop worker through the local
/// Agent Bridge. The worker uses the real ChatGPT UI/model on its dedicated
/// macOS Space without taking foreground focus.
///
/// Failure is intentionally ordinary: ProviderManager falls through to the
/// next provider, eventually reaching the local MLX providers.
actor ChatGPTDesktopProvider: LLMProvider {
    nonisolated let id = "chatgpt-desktop"
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .codeGeneration,
        .longContext,
        .structuredOutput
    ]
    nonisolated let currentLatencyMs = 1200

    /// Resolves the Agent Bridge control-plane API key. The bridge's ChatGPT
    /// brain endpoints always require it, so an absent key FAILS CLOSED (the
    /// brain is disabled) rather than sending an unauthenticated request.
    /// Injectable so tests pin both the configured and missing paths without
    /// touching the real keychain.
    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = {
        KeychainManager.shared.getAPIKey(for: .agentBridge)
    }) {
        self.apiKeyProvider = apiKeyProvider
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
    private let timeoutSeconds: TimeInterval = 45

    private var cachedAvailability: (value: Bool, timestamp: ContinuousClock.Instant)?
    private let availabilityTTL: Duration = .seconds(2)

    var isAvailable: Bool {
        get async {
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
            let (data, response) = try await URLSession.shared.data(for: request)
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
            if let (_, resp) = try? await URLSession.shared.data(for: fallbackReq),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
            return false
        }
        return false
    }

    /// N1: the bridge is verified-available only when its health endpoint answers.
    /// `probe: false` never touches the network — it returns the fresh cached
    /// probe or a truthful `.unverified`. C3 extends this with key + opt-in gates.
    func verifiedAvailability(probe: Bool) async -> ProviderAvailability {
        guard bridgeKey() != nil else {
            return .unavailable(reason: "Agent Bridge API key is not configured; ChatGPT brain is disabled")
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
            Task {
                if stream {
                    await self.streamFromBridge(messages: messages, options: options, continuation: continuation)
                } else {
                    do {
                        let response = try await self.askBridge(messages: messages, options: options)
                        continuation.yield(.text(response))
                        continuation.yield(.done(usage: .zero))
                        continuation.finish()
                    } catch {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                    }
                }
            }
        }
    }

    private func streamFromBridge(
        messages: [Message],
        options: [String: any Sendable],
        continuation: AsyncThrowingStream<StreamChunk, any Error>.Continuation
    ) async {
        let requestId = "zia_gpt_\(UUID().uuidString)"
        guard let streamURL = URL(string: "http://127.0.0.1:8765/api/chatgpt/complete?stream=true") else {
            continuation.yield(.error("Invalid stream URL"))
            continuation.finish()
            return
        }

        guard bridgeKey() != nil else {
            continuation.yield(.error("Agent Bridge API key is not configured; ChatGPT brain is disabled"))
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

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                cachedAvailability = (value: false, timestamp: .now)
                continuation.yield(.error("ChatGPT Desktop streaming HTTP error"))
                continuation.finish()
                return
            }

            var confirmed = false
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || !trimmed.hasPrefix("data: ") { continue }
                let jsonStr = String(trimmed.dropFirst(6))
                guard let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
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
                cachedAvailability = (value: true, timestamp: .now)
                continuation.yield(.done(usage: .zero))
            } else {
                cachedAvailability = nil
                continuation.yield(.error("ChatGPT Desktop turn was not confirmed"))
            }
            continuation.finish()
        } catch {
            cachedAvailability = (value: false, timestamp: .now)
            continuation.yield(.error(error.localizedDescription))
            continuation.finish()
        }
    }

    private func askBridge(
        messages: [Message],
        options: [String: any Sendable]
    ) async throws -> String {
        guard bridgeKey() != nil else {
            throw ProviderError.unavailable("Agent Bridge API key is not configured; ChatGPT brain is disabled")
        }
        let requestId = "zia_gpt_\(UUID().uuidString)"

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
            "options": options.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
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
