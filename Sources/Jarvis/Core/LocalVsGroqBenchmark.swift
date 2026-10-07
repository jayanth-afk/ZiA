import Foundation

/// LOCAL (cached Qwen2.5-0.5B) vs GROQ benchmark.
///
/// Purpose: produce the empirical evidence the hybrid-routing policy needs.
/// The same standard macOS intent prompts are sent to both backends through the
/// existing `LLMProvider` protocol (no bespoke model plumbing). For each task we
/// record, honestly and without fabrication:
///   • wall-clock total latency for the whole request
///   • time-to-first-token where the provider can actually report it
///   • correctness: did the model choose the expected tool (tool-name metric),
///     and does the expected user literal appear BYTE-EXACT in some argument
///     value (argument-fidelity metric)?
///   • fabricated arguments, detected against a small list of well-known
///     placeholder tokens that do not occur in the goal (e.g. `/home/user/…`,
///     `http://safari.com`) — the model invented content the user never wrote.
///   • the raw model output (truncated) so the verdict is auditable
///   • memory: the local worker's real resident footprint (Groq is remote).
///
/// Bounds and honesty:
///   • Bounded task count and per-task timeout; the whole run has a wall cap.
///   • Groq is optional: if it is offline or has no key it is reported
///     `unavailable`, never faked.
///   • The configured Groq model is injected into the provider — the harness
///     NEVER mutates persisted `Config`.
///   • Groq's provider issues a single non-streaming request, so a true TTFT is
///     not measurable there; it is reported as n/a rather than estimated.
///   • The `literal` field is NOT scored: both models paste the whole goal there,
///     so it carries no signal. Argument fidelity replaces it.
///   • No model output is scored by hand — the real parser decides.
@MainActor
enum LocalVsGroqBenchmark {

    struct BenchTask {
        let id: String
        let goal: String
        /// Expected tool family for a correct plan; nil = a direct answer is correct.
        let expectedTool: String?
        /// The user payload that must appear BYTE-EXACT in some argument value.
        /// nil when the task carries no user-supplied content (direct answer).
        let expectedLiteral: String?
    }

    /// The tool subset relevant to these intents, taken from the live registry.
    static let benchToolNames: Set<String> = [
        "open_app", "set_volume", "web_search", "fetch_url",
        "run_shell", "read_file", "list_directory", "open_browser"
    ]

    /// The actual production bounded-extraction prompt, over the live registry
    /// tools, so the production backends are measured on the SAME planner
    /// contract the product uses (fair comparison, not a hand-rolled prompt).
    static func extractionPrompt(for task: BenchTask) -> String {
        MLXPlanner.buildExtractionPrompt(goal: task.goal, tools: benchTools)
    }

    /// A deliberately NEUTRAL tool-choice prompt: no 0.5B-specific copy rules or
    /// anti-examples. It exists to separate "the production prompt is tuned for
    /// the 0.5B model" from "the large model cannot do this task". Same JSON
    /// contract shape (`tool`/`arguments`/`literal`) so the same parser scores it.
    static func neutralPrompt(for task: BenchTask) -> String {
        let catalog = benchTools.map { tool -> String in
            let params = tool.parameterSpec
                .map { spec in "\(spec.name)\(spec.required ? "" : "?")=\(spec.kind.rawValue)" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")

        var p = ""
        p += "Select the single best tool to accomplish the user's goal.\n\n"
        p += "AVAILABLE TOOLS:\n\(catalog)\n\n"
        p += "Respond with ONLY one JSON object and no other text:\n"
        p += "{\"tool\": \"<tool name>\", \"arguments\": {<argument names>: <values>}, \"literal\": \"<the user's requested content>\"}\n"
        p += "If no tool is appropriate, respond {\"tool\": null, \"arguments\": {}, \"literal\": \"\"}.\n\n"
        p += "User goal: \(task.goal)\n\n"
        p += "JSON: "
        return p
    }

    private static var benchTools: [any JarvisTool] {
        ToolRegistry.shared.allTools
            .filter { benchToolNames.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    /// The Groq model requested by this harness. The originally configured
    /// `llama-3.3-70b-versatile` is NOT available to this account (Groq returns
    /// "does not exist or you do not have access"); the closest available
    /// general model is requested and the substitution is recorded in output.
    static let groqModel = "openai/gpt-oss-120b"

    static let tasks: [BenchTask] = [
        BenchTask(id: "open-app", goal: "open Safari", expectedTool: "open_app", expectedLiteral: "Safari"),
        BenchTask(id: "volume", goal: "set the volume to 40", expectedTool: "set_volume", expectedLiteral: "40"),
        BenchTask(id: "search", goal: "search the web for the weather in Paris", expectedTool: "web_search", expectedLiteral: "the weather in Paris"),
        BenchTask(id: "fetch", goal: "fetch the url https://example.com", expectedTool: "fetch_url", expectedLiteral: "https://example.com"),
        BenchTask(id: "shell", goal: "write the word hello_benchmark using run_shell", expectedTool: "run_shell", expectedLiteral: "hello_benchmark"),
        BenchTask(id: "read", goal: "read the file ~/notes.txt", expectedTool: "read_file", expectedLiteral: "~/notes.txt"),
        BenchTask(id: "list", goal: "list the files in my Downloads folder", expectedTool: "list_directory", expectedLiteral: "Downloads"),
        BenchTask(id: "direct", goal: "what is the capital of France?", expectedTool: nil, expectedLiteral: nil)
    ]

    // MARK: - Scoring (pure; unit-tested without any model)

    /// Well-known generic placeholder tokens the 0.5B model is observed to
    /// invent. An argument value containing one of these tokens — when the token
    /// does not appear in the goal — is a fabricated argument.
    static let knownFabricationTokens = [
        "/home/user/", "/Users/user/", "/path/to/",
        "http://safari.com", "https://safari.com",
        "user@example.com"
    ]

    struct Score: Equatable {
        /// The model chose the expected tool (nil expected = a direct answer was correct).
        let toolCorrect: Bool
        /// The expected literal appears byte-exact in some argument value.
        /// nil when the task carries no expected literal.
        let argumentFidelity: Bool?
        /// Argument values containing a known fabrication token absent from the goal.
        let fabricatedArguments: [String]
    }

    /// Deterministic scoring of one parsed extraction against a task. No model
    /// is involved; this is the single definition of "correct" used by the run.
    static func score(task: BenchTask, extracted: ExtractedAction?) -> Score {
        let toolCorrect: Bool
        if let expected = task.expectedTool {
            toolCorrect = extracted?.toolName == expected
        } else {
            // A direct answer is a successful extraction of "no tool".
            toolCorrect = extracted == nil
        }

        var fidelity: Bool?
        if let expectedLiteral = task.expectedLiteral {
            fidelity = extracted?.arguments.values.contains { $0.contains(expectedLiteral) } ?? false
        }

        var fabricated: [String] = []
        if let arguments = extracted?.arguments {
            for value in arguments.values {
                for token in knownFabricationTokens
                where value.contains(token) && !task.goal.contains(token) {
                    fabricated.append(value)
                }
            }
        }
        // De-duplicate identical argument values.
        var seen = Set<String>()
        fabricated = fabricated.filter { seen.insert($0).inserted }

        return Score(toolCorrect: toolCorrect, argumentFidelity: fidelity, fabricatedArguments: fabricated)
    }

    // MARK: - Result model

    struct TaskResult {
        let taskId: String
        /// "local", "groq" (production prompt) or "groq-neutral".
        let backend: String
        let available: Bool
        let score: Score?
        let parsedTool: String?
        let ttftMs: Double?
        let totalMs: Double
        let error: String?
        let rawSample: String
    }

    private enum BenchError: Error { case timeout }

    // MARK: - Entry point

    static func run() async {
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║   ZiA — LOCAL (Qwen2.5-0.5B) vs GROQ (\(groqModel)) BENCH")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("tasks: \(tasks.count) · per-task timeout: \(Int(perTaskTimeout))s · wall cap: \(Int(wallCap))s")
        print("groq model requested: \(groqModel) (configured default \(GroqProvider.fallbackModel) is unavailable to this account)")

        // Model is INJECTED into the provider; persisted Config is never touched.
        let local = MLXProvider(id: "bench-local", modelSlot: "normal")
        let groq = GroqProvider(model: groqModel)

        let localAvailable = await local.isAvailable
        let groqAvailable = await groq.isAvailable
        print("local available: \(localAvailable) · groq available: \(groqAvailable)")
        if !groqAvailable {
            print("groq unavailable (no key or offline) — its rows will be reported unavailable, never faked.")
        }

        var results: [TaskResult] = []
        let wallStart = Date()

        for task in tasks {
            if Date().timeIntervalSince(wallStart) > wallCap {
                print("wall cap reached before task \(task.id); stopping.")
                break
            }
            if localAvailable {
                let r = await measure(task: task, provider: local, backend: "local",
                                      prompt: extractionPrompt(for: task), localTTFTFromStats: true)
                results.append(r)
                printRow(r)
            } else {
                results.append(unavailable(task.id, backend: "local", reason: "local model unavailable"))
            }

            if groqAvailable {
                // Production prompt.
                let prod = await measure(task: task, provider: groq, backend: "groq",
                                         prompt: extractionPrompt(for: task), localTTFTFromStats: false)
                results.append(prod)
                printRow(prod)
                try? await Task.sleep(nanoseconds: 1_100_000_000)

                // Neutral prompt — isolates prompt-vs-model mismatch.
                let neutral = await measure(task: task, provider: groq, backend: "groq-neutral",
                                            prompt: neutralPrompt(for: task), localTTFTFromStats: false)
                results.append(neutral)
                printRow(neutral)
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            } else {
                results.append(unavailable(task.id, backend: "groq", reason: "groq unavailable"))
                results.append(unavailable(task.id, backend: "groq-neutral", reason: "groq unavailable"))
            }
        }

        let stats = await local.latestStats()
        print("\n──────────── SUMMARY ────────────")
        summarize(results)
        if let rss = stats.workerRSSMB {
            print("local worker peak RSS: \(Int(rss)) MB (real, from the mlx_lm worker)")
        }
        print("total wall: \(String(format: "%.1f", Date().timeIntervalSince(wallStart)))s")
    }

    private static func unavailable(_ taskId: String, backend: String, reason: String) -> TaskResult {
        TaskResult(taskId: taskId, backend: backend, available: false, score: nil,
                   parsedTool: nil, ttftMs: nil, totalMs: 0, error: reason, rawSample: "")
    }

    // MARK: - One measurement

    private static let perTaskTimeout: Double = 45
    private static let wallCap: Double = 420

    private static func measure(task: BenchTask, provider: any LLMProvider, backend: String,
                                prompt: String, localTTFTFromStats: Bool) async -> TaskResult {
        let messages = [Message(role: .user, content: prompt)]
        let start = Date()
        var text = ""
        var failureNote: String?
        var providerError: String?
        // stream:false for both. GroqProvider currently parses a single JSON body
        // and cannot handle its own SSE reply (a real provider defect recorded in
        // the benchmark notes). Local still reports a real worker TTFT.
        let stream = await provider.complete(
            messages: messages, tools: nil, stream: false,
            options: ["max_tokens": 160, "temperature": 0.0])

        let collector = Task { () -> (String, String?) in
            var out = ""
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .text(let t): out += t
                    case .error(let e): return (out, e)
                    case .done, .toolCall: break
                    }
                }
            } catch { return (out, error.localizedDescription) }
            return (out, nil)
        }

        do {
            let collected = try await withThrowingTaskGroup(of: (String, String?).self) { group in
                group.addTask { await collector.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(perTaskTimeout * 1_000_000_000))
                    throw BenchError.timeout
                }
                let first = try await group.next() ?? ("", nil)
                group.cancelAll()
                return first
            }
            text = collected.0
            providerError = collected.1
        } catch {
            failureNote = "timeout after \(Int(perTaskTimeout))s"
            collector.cancel()
        }

        let totalMs = Date().timeIntervalSince(start) * 1000

        var ttft: Double?
        if localTTFTFromStats, let localProvider = provider as? MLXProvider {
            ttft = await localProvider.latestStats().ttftMs
        }

        // Score with the real parser; fall back to the structural repair the
        // production pipeline also applies, so a repairable shape is not
        // mistaken for a wrong tool.
        let parsed = (try? PlannerExtraction.parse(text).get()) ?? PlannerExtraction.structuralRepair(text)
        let score = score(task: task, extracted: parsed)

        let rawSample = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "⏎")
        return TaskResult(taskId: task.id, backend: backend, available: true, score: score,
                          parsedTool: parsed?.toolName, ttftMs: ttft, totalMs: totalMs,
                          error: failureNote ?? providerError,
                          rawSample: String(rawSample.prefix(220)))
    }

    private static func printRow(_ r: TaskResult) {
        guard let score = r.score, r.available else {
            print("  [\(r.taskId)/\(r.backend)] n/a\(r.error.map { " ERR=\($0.prefix(120))" } ?? "")")
            return
        }
        let tool = score.toolCorrect ? "toolOK" : "toolMISS"
        let fid = score.argumentFidelity.map { $0 ? "argOK" : "argMISS" } ?? "arg-"
        let fab = score.fabricatedArguments.isEmpty ? "" : " FABRICATED=\(score.fabricatedArguments.map { String($0.prefix(40)) }.joined(separator: "|"))"
        let ttft = r.ttftMs.map { String(format: "%.0f", $0) } ?? "n/a"
        let toolName = r.parsedTool ?? "none"
        let err = r.error.map { " ERR=\($0.prefix(160))" } ?? ""
        print("  [\(r.taskId)/\(r.backend)] \(tool) \(fid) tool=\(toolName) ttft=\(ttft)ms total=\(String(format: "%.0f", r.totalMs))ms\(fab)\(err)")
        if r.available { print("        raw: \(r.rawSample)") }
    }

    private static func summarize(_ results: [TaskResult]) {
        for backend in ["local", "groq", "groq-neutral"] {
            let rows = results.filter { $0.backend == backend && $0.available && $0.score != nil }
            guard !rows.isEmpty else { print("\(backend): no rows"); continue }
            let toolHit = rows.filter { $0.score!.toolCorrect }.count
            let fidRows = rows.compactMap { $0.score!.argumentFidelity }
            let fidHit = fidRows.filter { $0 }.count
            let fabricated = rows.filter { !$0.score!.fabricatedArguments.isEmpty }.count
            let avgTotal = rows.map(\.totalMs).reduce(0, +) / Double(rows.count)
            let ttfts = rows.compactMap(\.ttftMs)
            let avgTTFT = ttfts.isEmpty ? nil : ttfts.reduce(0, +) / Double(ttfts.count)
            print("\(backend): tool-correct \(toolHit)/\(rows.count) · arg-fidelity \(fidHit)/\(fidRows.count) · fabricated-args \(fabricated)/\(rows.count) · avg total \(String(format: "%.0f", avgTotal))ms · avg TTFT \(avgTTFT.map { String(format: "%.0f", $0) + "ms" } ?? "n/a")")
        }
    }
}
