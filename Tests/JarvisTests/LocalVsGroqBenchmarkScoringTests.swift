import Foundation
import Testing
@testable import Jarvis

/// The Phase 2.1 local-vs-Groq benchmark scores each model with the REAL
/// parser. These tests pin the deterministic scoring semantics: the tool-name
/// metric, the byte-exact argument-fidelity metric (which replaces the useless
/// `literal` field), and fabrication detection against the known placeholder
/// tokens the 0.5B model invents.
@Suite struct LocalVsGroqBenchmarkScoringTests {

    private func action(tool: String, _ arguments: [String: String], literal: String? = nil) -> ExtractedAction {
        ExtractedAction(toolName: tool, arguments: arguments, literal: literal)
    }

    @Test @MainActor func toolMetricMatchesExpectedTool() {
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "open-app", goal: "open Safari", expectedTool: "open_app", expectedLiteral: "Safari")
        let good = LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "open_app", ["app_name": "Safari"]))
        #expect(good.toolCorrect)
        let bad = LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "open_browser", ["url": "http://safari.com"]))
        #expect(!bad.toolCorrect)
    }

    @Test @MainActor func directTaskIsCorrectOnlyWithNoExtraction() {
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "direct", goal: "what is the capital of France?", expectedTool: nil, expectedLiteral: nil)
        // A model that emits no tool step is the correct answer for a direct task.
        #expect(LocalVsGroqBenchmark.score(task: task, extracted: nil).toolCorrect)
        // A model that invents a tool step is wrong.
        #expect(!LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "web_search", ["query": "capital of France"])).toolCorrect)
        // A direct task has no argument-fidelity expectation.
        #expect(LocalVsGroqBenchmark.score(task: task, extracted: nil).argumentFidelity == nil)
    }

    @Test @MainActor func argumentFidelityRequiresByteExactLiteral() {
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "read", goal: "read the file ~/notes.txt", expectedTool: "read_file", expectedLiteral: "~/notes.txt")
        let faithful = LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "read_file", ["path": "~/notes.txt"]))
        #expect(faithful.argumentFidelity == true)

        // The observed fabrication: the model substitutes a generic example path.
        let fabricated = LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "read_file", ["path": "/home/user/note.txt"]))
        #expect(fabricated.argumentFidelity == false)
        #expect(fabricated.fabricatedArguments == ["/home/user/note.txt"])
    }

    @Test @MainActor func literalMetricIsGoneAndGoalPasteCarriesNoSignal() {
        // Both models paste the whole goal into `literal`; that field must not be
        // scored. Fidelity is decided by ARGUMENT values only.
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "volume", goal: "set the volume to 40", expectedTool: "set_volume", expectedLiteral: "40")
        let extracted = action(tool: "set_volume", ["level": "40"], literal: "set the volume to 40")
        let score = LocalVsGroqBenchmark.score(task: task, extracted: extracted)
        #expect(score.argumentFidelity == true)
        #expect(score.fabricatedArguments.isEmpty)
    }

    @Test @MainActor func flagsInventedBrowserUrl() {
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "open-app", goal: "open Safari", expectedTool: "open_app", expectedLiteral: "Safari")
        let score = LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "open_browser", ["url": "http://safari.com"]))
        #expect(score.fabricatedArguments == ["http://safari.com"])
        // The lowercase URL does not contain the byte-exact literal "Safari".
        #expect(score.argumentFidelity == false)
    }

    @Test @MainActor func aGenuineGoalUrlIsNotFabrication() {
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "fetch", goal: "fetch the url https://example.com", expectedTool: "fetch_url", expectedLiteral: "https://example.com")
        let score = LocalVsGroqBenchmark.score(task: task, extracted: action(tool: "fetch_url", ["url": "https://example.com"]))
        #expect(score.fabricatedArguments.isEmpty)
        #expect(score.argumentFidelity == true)
    }

    @Test @MainActor func missingExtractionFailsArgumentFidelity() {
        let task = LocalVsGroqBenchmark.BenchTask(
            id: "shell", goal: "write the word hello_benchmark using run_shell", expectedTool: "run_shell", expectedLiteral: "hello_benchmark")
        let score = LocalVsGroqBenchmark.score(task: task, extracted: nil)
        #expect(!score.toolCorrect)
        #expect(score.argumentFidelity == false)
        #expect(score.fabricatedArguments.isEmpty)
    }
}
