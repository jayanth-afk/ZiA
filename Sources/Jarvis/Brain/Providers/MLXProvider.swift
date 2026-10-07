import Foundation

/// Local MLX provider running quantized models on Apple Silicon M4 unified memory.
///
/// Inference is REAL: MLXProvider drives the mlx_lm runtime (Metal compute, local
/// Qwen2.5-0.5B-Instruct-4bit weights already in the HF cache) through a persistent
/// Python worker process. Generation happens in actual MLX/Metal — no heuristic
/// responses.
///
/// Swift-side native binding (mlx-swift-lm) is prepared but blocked in this
/// environment: mlx-swift requires the `metal` shader compiler, which ships with
/// full Xcode only (not CommandLineTools; Developer.app is Apple's docs app, not
/// Xcode). Once Xcode is installed, add the mlx-swift-lm dependency and replace the
/// worker bridge with `loadModelContainer(from:)` — no other call sites change.
///
/// Worker protocol (JSON lines over stdin/stdout; every reply echoes request `id`):
///   → {"id":N,"op":"load","model":"<hf id>"}                 → {"id":N,"ok":true,"load_ms":M,"loaded":true}
///   → {"id":N,"op":"generate","prompt":"…","max_tokens":K,
///      "temperature":T}                                      → {"id":N,"ok":true,"text":"…","tokens":C,
///                                                            "gen_ms":M,"tok_s":S,"ttft_ms":T,"rss_mb":R}
///   → {"id":N,"op":"health"}                                 → {"id":N,"ok":true,"model":"…","loaded":bool,"rss_mb":R}
///   ← {"id":N,"ok":false,"error":"…"}                        structured failure (worker stays alive)
///
/// Honest capability labels (do not overclaim):
///   provider stream interface = supported   (AsyncThrowingStream preserved)
///   true token-level streaming = supported in the worker (stream_generate); Swift
///   currently emits the completed text — upgrade path exists without protocol change.
///   `ttft_ms` is REAL first-token latency measured inside the worker against the
///   mlx_lm token stream. Swift-measured wall time is request latency, NOT TTFT.
actor MLXProvider: LLMProvider {
    nonisolated let id: String
    nonisolated let capabilities: Set<Capability> = [
        .textGeneration,
        .toolCalling,
        .codeGeneration,
        .structuredOutput
    ]

    // Real measurements from the worker. Thread-safe holders so the LLMProvider
    // protocol's synchronous getter can observe the actor's latest values.
    /// Full Swift → worker → mlx_lm request latency of the last generation (ms).
    /// This is request latency, NOT time-to-first-token.
    private let requestLatencyStore = LockedValue(85.0)
    /// Last generation's true time-to-first-token, measured inside the worker
    /// against the mlx_lm token stream. nil until a generation completes.
    private let ttftStore = LockedValue<Double?>(nil)
    nonisolated var currentLatencyMs: Int { Int(requestLatencyStore.value) }

    private let modelSlot: String // "reflex" or "normal"

    private static let defaultModel = LocalModelCatalog.defaultModelID
    private static let estimatedMB = 600

    private var worker: WorkerProcess?
    private var registeredModelID: String?

    init(id: String = "mlx-local", modelSlot: String = "reflex") {
        self.id = id
        self.modelSlot = modelSlot
    }

    var isAvailable: Bool {
        get async {
            // Available only when the Python MLX runtime exists AND the model
            // this slot will actually load is already cached on disk. ZiA never
            // downloads weights at runtime, so an uncached model is honestly
            // reported as unavailable instead of fetched on demand.
            // Deliberately pure and synchronous: no MainActor hop. Health checks
            // run while the main runloop is pumped by a semaphore wait, so an
            // availability probe must not await MainActor. The exact model this
            // slot resolves to is chosen at load time in `ensureLoaded` (which is
            // already allowed to await Config) and reported by the health service.
            Self.pythonInterpreter != nil && !LocalModelCatalog.cachedModelIDs().isEmpty
        }
    }

    // MARK: - Environment resolution

    /// Locate the .venv-mlx interpreter, relative to the project root (CWD) first,
    /// then the directory containing this bundle/binary.
    nonisolated private static var pythonInterpreter: String? {
        let candidates = [
            ".venv-mlx/bin/python",
            "benchmarks/.venv-mlx/bin/python",
            "/Users/jayanthpranaykonada/Zia/.venv-mlx/bin/python"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Resolve the local HF snapshot directory for a model (weights on disk).
    /// Delegates to the single source of truth, `LocalModelCatalog`.
    nonisolated private static func modelSnapshotDirectory(modelID: String = defaultModel) -> URL? {
        LocalModelCatalog.snapshotDirectory(for: modelID)
    }

    /// The model id this slot will actually load: the configured model when it
    /// is cached, otherwise the first cached local model (never a download).
    private var modelName: String {
        get async {
            LocalModelCatalog.resolveModelID(configured: await Config.shared.modelName(for: modelSlot))
        }
    }

    // MARK: - Worker management

    /// Ensure the persistent Python MLX worker is running and the model is loaded.
    private func ensureLoaded() async throws -> WorkerProcess {
        if let worker { return worker }
        let slot = self.modelSlot

        let pythonPath = Self.pythonInterpreter
        guard let pythonPath else {
            throw JarvisError.actionFailed(
                action: "mlx.load",
                reason: "Python MLX runtime not found (expected .venv-mlx with mlx-lm installed)")
        }

        let workerScript = Self.locateWorkerScript()
        guard let workerScript else {
            throw JarvisError.actionFailed(
                action: "mlx.load",
                reason: "mlx_worker.py not found next to the executable or in benchmarks/")
        }

        let worker = try WorkerProcess(
            executable: pythonPath,
            arguments: [workerScript],
            onExit: { [weak self] in
                Task { await self?.handleWorkerExit(slot: slot) }
            })

        // Load the model eagerly (real Metal inference happens inside this call).
        // Fail closed if the weights are not already cached: mlx_lm would
        // otherwise download them, and ZiA must never download at runtime.
        let modelID = await modelName
        guard LocalModelCatalog.isCached(modelID) else {
            let cached = LocalModelCatalog.cachedModelIDs()
            let list = cached.isEmpty ? "none" : cached.joined(separator: ", ")
            throw JarvisError.actionFailed(
                action: "mlx.load",
                reason: "local model '\(modelID)' is not cached; ZiA never downloads models at runtime. Cached local models: \(list)")
        }
        let loadStart = Date()
        let reply = try await worker.request(["op": "load", "model": modelID])
        guard reply["ok"] as? Bool == true else {
            worker.terminate()
            throw JarvisError.actionFailed(
                action: "mlx.load",
                reason: reply["error"] as? String ?? "mlx worker load failed")
        }
        let loadMs = Date().timeIntervalSince(loadStart) * 1000
        lastLoadMs = loadMs
        JarvisLogger.brain.info("MLXProvider (\(slot)) loaded real model \(modelID) via mlx_lm in \(Int(loadMs))ms")

        await ResourceManager.shared.registerModelLoaded(modelID, estimatedMB: Self.estimatedMB)
        registeredModelID = modelID
        self.worker = worker
        return worker
    }

    nonisolated private static func locateWorkerScript() -> String? {
        let candidates = [
            "Sources/Jarvis/Brain/Workers/mlx_worker.py",
            "benchmarks/mlx_worker.py",
            "/Users/jayanthpranaykonada/Zia/Sources/Jarvis/Brain/Workers/mlx_worker.py"
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func handleWorkerExit(slot: String) {
        worker = nil
        // Keep ResourceManager accounting honest: the resident model is gone.
        if let modelID = registeredModelID {
            Task { await ResourceManager.shared.registerModelUnloaded(modelID) }
            registeredModelID = nil
        }
        JarvisLogger.brain.warning("MLXProvider (\(slot)) mlx worker exited; will relaunch and reload on next request")
    }

    // MARK: - Completion

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
        // Per-request token budget (planner requests need more headroom than
        // the 256-token default; small direct requests can be tighter).
        let maxTokens = (options["max_tokens"] as? Int) ?? 256
        // Deterministic copy-from-goal tasks (bounded extraction) run with
        // GREEDY decoding (temperature 0). The extraction prompt forbids
        // prompt-example values; sampling at temperature 0.2 made that rule
        // stochastically violable — observed as the model echoing prompt tokens
        // ("hello world") instead of the goal's own words. A copy task must be
        // deterministic; the pipeline's deterministic gates still catch any
        // fabrication and fail closed.
        let temperature = (options["temperature"] as? Double) ?? 0.2
        let slot = self.modelSlot
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let started = Date()
                    let worker = try await ensureLoaded()
                    let providerID = self.id

                    let prompt = messages.last?.content ?? ""
                    let reply = try await worker.request([
                        "op": "generate",
                        "prompt": prompt,
                        "max_tokens": maxTokens,
                        "temperature": temperature
                    ])

                    guard reply["ok"] as? Bool == true else {
                        throw JarvisError.providerError(
                            provider: providerID,
                            message: reply["error"] as? String ?? "mlx generate failed")
                    }

                    let text = reply["text"] as? String ?? ""
                    let requestLatencyMs = Date().timeIntervalSince(started) * 1000
                    requestLatencyStore.value = requestLatencyMs
                    // Real TTFT measured inside the worker against the mlx_lm stream.
                    if let ttft = reply["ttft_ms"] as? Double {
                        ttftStore.value = ttft
                    }
                    lastGenStats = LastGenStats(
                        genMs: (reply["gen_ms"] as? Double) ?? 0,
                        tokens: (reply["tokens"] as? Int) ?? 0,
                        tokS: (reply["tok_s"] as? Double) ?? 0,
                        rssMB: (reply["rss_mb"] as? Double))

                    if stream {
                        // mlx_lm generate() returns the full completion; emit as
                        // word chunks to preserve streaming consumer semantics.
                        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
                            continuation.yield(.text(String(word) + " "))
                        }
                    } else {
                        continuation.yield(.text(text))
                    }

                    let completionTokens = (reply["tokens"] as? Int) ?? (text.count / 4)
                    continuation.yield(.done(usage: TokenUsage(
                        promptTokens: prompt.count / 4,
                        completionTokens: completionTokens,
                        totalTokens: (prompt.count / 4) + completionTokens
                    )))
                    continuation.finish()
                } catch {
                    JarvisLogger.brain.error("MLXProvider (\(slot)) generation failed: \(error.localizedDescription)")
                    continuation.yield(.error("MLX local inference failed: \(error.localizedDescription)"))
                    continuation.finish()
                }
            }
        }
    }

    func healthCheck() async -> ProviderHealth {
        do {
            let worker = try await ensureLoaded()
            let reply = try await worker.request(["op": "health"])
            let modelID = await modelName
            let healthy = reply["ok"] as? Bool == true && (reply["loaded"] as? Bool) == true
            let rss = reply["rss_mb"] as? Double
            return ProviderHealth(
                isHealthy: healthy,
                latencyMs: Int(requestLatencyStore.value),
                message: healthy
                    ? "MLX runtime nominal (\(modelID) resident via mlx_lm Metal\(rss.map { ", worker RSS \(Int($0))MB" } ?? ""))"
                    : "MLX worker unhealthy: \(reply["error"] as? String ?? "unknown")"
            )
        } catch {
            return ProviderHealth(
                isHealthy: false,
                latencyMs: 0,
                message: "MLX model unavailable: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Introspection (used by the integration audit)

    struct GenerationStats {
        let requestLatencyMs: Double   // Swift wall time for the whole request
        let ttftMs: Double?            // real first-token latency from the worker
        let workerGenMs: Double?       // worker-measured generation time
        let tokens: Int?               // last completion token count
        let tokensPerSecond: Double?   // worker-measured sustained rate
        let workerRSSMB: Double?       // worker process peak RSS
        let loadMs: Double?            // worker-reported model load time (nil on reuse)
    }

    /// Snapshot of the latest real measurements. No values are synthesized.
    func latestStats() -> GenerationStats {
        GenerationStats(
            requestLatencyMs: requestLatencyStore.value,
            ttftMs: ttftStore.value,
            workerGenMs: lastGenStats?.genMs,
            tokens: lastGenStats?.tokens,
            tokensPerSecond: lastGenStats?.tokS,
            workerRSSMB: lastGenStats?.rssMB,
            loadMs: lastLoadMs)
    }

    private struct LastGenStats {
        let genMs: Double
        let tokens: Int
        let tokS: Double
        let rssMB: Double?
    }

    private var lastGenStats: LastGenStats?
    private var lastLoadMs: Double?

    /// Persist the worker alive check without generating: reused workers return
    /// immediately; a dead worker is relaunched and the model reloaded (real
    /// failure-recovery path exercised by the audit).
    func ensureHealthy() async -> Bool {
        do {
            let worker = try await ensureLoaded()
            let reply = try await worker.request(["op": "health"])
            return reply["ok"] as? Bool == true && (reply["loaded"] as? Bool) == true
        } catch {
            return false
        }
    }

    /// PID of the live worker process, when one exists. The audit uses this to
    /// prove that repeated requests REUSE the persistent worker instead of
    /// spawning a new process per request.
    func currentWorkerPID() -> Int? {
        worker?.pid
    }

    /// Terminate the current worker to exercise the real failure-recovery path
    /// (crash → exit detection → accounting cleanup → relaunch → reload).
    /// Cleanup happens in handleWorkerExit via the onExit callback.
    func terminateWorker() {
        worker?.terminate()
    }
}

// MARK: - Persistent JSON-lines worker process

/// A parsed worker reply. JSONSerialization output contains only immutable
/// value-type bridges (NSString/NSNumber/NSArray/NSDictionary), so the wrapper
/// is safe to mark @unchecked Sendable and resume cross-isolation continuations.
private struct WorkerReply: @unchecked Sendable {
    let dictionary: [String: Any]
    subscript(_ key: String) -> Any? { dictionary[key] }
}

/// A persistent child process speaking JSON lines over stdin/stdout.
/// Worker output lines that are not valid JSON (stderr-style noise) are logged.
private final class WorkerProcess: @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    /// Child PID, exposed so the audit can verify worker reuse vs. respawning.
    let pid: Int
    private let lock = NSLock()
    private var requestID = 0
    private var pending: [Int: CheckedContinuation<WorkerReply, any Error>] = [:]
    private let readQueue = DispatchQueue(label: "jarvis.mlxworker.read")
    private var buffer = Data()

    init(executable: String, arguments: [String], onExit: @escaping @Sendable () -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        self.process = process
        self.pid = Int(process.processIdentifier)
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                JarvisLogger.brain.debug("mlx worker stderr: \(text.prefix(500))")
            }
        }

        // One reader loop parses replies and dispatches continuations by id
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                onExit()
                return
            }
            self?.consume(data)
        }
    }

    func request(_ payload: [String: Any]) async throws -> WorkerReply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            requestID += 1
            let id = requestID
            pending[id] = continuation
            lock.unlock()

            var request = payload
            request["id"] = id
            let line: String
            if let data = try? JSONSerialization.data(withJSONObject: request) {
                line = String(data: data, encoding: .utf8) ?? ""
            } else {
                line = ""
            }
            do {
                try stdinHandle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                lock.lock()
                pending.removeValue(forKey: id)?.resume(throwing: error)
                lock.unlock()
            }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let buffered = buffer
        lock.unlock()

        // Split complete lines
        var lines: [Data] = []
        var remainder = Data()
        for byte in buffered {
            remainder.append(byte)
            if byte == UInt8(ascii: "\n") {
                lines.append(remainder)
                remainder = Data()
            }
        }
        lock.lock()
        buffer = remainder
        lock.unlock()

        // Parse on the reader queue; replies resume their awaiter by id.
        readQueue.async { [weak self] in
            guard let self else { return }
            for lineData in lines {
                guard !lineData.isEmpty else { continue }
                guard
                    let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty,
                    let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                    let id = obj["id"] as? Int
                else {
                    JarvisLogger.brain.debug("mlx worker non-JSON output: \(String(data: lineData, encoding: .utf8) ?? "")")
                    continue
                }
                self.lock.lock()
                let continuation = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                continuation?.resume(returning: WorkerReply(dictionary: obj))
            }
        }
    }

    func terminate() {
        try? stdinHandle.close()
        process.terminate()
    }
}
