@testable import Jarvis
import Testing

/// Experiment B — offline fixtures for the single-shape deterministic
/// normalizer (PlanNormalizerB). These mirror the predeclared contract:
/// positive cases normalize the exact malformed run_shell command+args shape
/// with byte-exact literal preservation; every negative case must pass
/// through untouched (fail closed) to the existing validation/repair path.
@Suite struct PlanNormalizerBTests {

    private func shape(command: Any, args: Any, tool: String = "run_shell",
                       extraArgs: [String: Any] = [:]) -> [String: Any] {
        var arguments: [String: Any] = ["command": command, "args": args]
        for (k, v) in extraArgs { arguments[k] = v }
        return ["goal": "g", "steps": [["id": "step_1", "tool": tool, "arguments": arguments]]]
    }

    // MARK: Positive

    @Test
    func positiveLiteralPreservedExactly() {
        let outcome = PlanNormalizerB.analyze(
            shape(command: "echo", args: "jarvis_planner_e2e_verified"))
        guard case .normalized(_, let joined) = outcome else {
            Issue.record("expected normalization, got \(outcome)")
            return
        }
        #expect(joined == "echo jarvis_planner_e2e_verified")
    }

    @Test
    func positivePrintfSingleToken() {
        let outcome = PlanNormalizerB.analyze(shape(command: "printf", args: "abc123"))
        guard case .normalized(_, let joined) = outcome else {
            Issue.record("expected normalization, got \(outcome)")
            return
        }
        #expect(joined == "printf abc123")
    }

    @Test
    func positiveListArgs() {
        let outcome = PlanNormalizerB.analyze(shape(command: "echo", args: ["hello", "world"]))
        guard case .normalized(_, let joined) = outcome else {
            Issue.record("expected normalization, got \(outcome)")
            return
        }
        #expect(joined == "echo hello world")
    }

    // MARK: Negative / pass-through (fail closed)

    @Test
    func negativeMissingCommand() {
        var obj = shape(command: "echo", args: "hello")
        var steps = obj["steps"] as! [[String: Any]]
        steps[0]["arguments"] = ["args": "hello"]
        obj["steps"] = steps
        if case .normalized = PlanNormalizerB.analyze(obj) { Issue.record("must not normalize") }
    }

    @Test
    func negativeMissingArgs() {
        var obj = shape(command: "echo", args: "hello")
        var steps = obj["steps"] as! [[String: Any]]
        steps[0]["arguments"] = ["command": "echo"]
        obj["steps"] = steps
        if case .normalized = PlanNormalizerB.analyze(obj) { Issue.record("must not normalize") }
    }

    @Test
    func negativeExtraUnrelatedKey() {
        let outcome = PlanNormalizerB.analyze(
            shape(command: "echo", args: "hello", extraArgs: ["purpose": "x"]))
        if case .normalized = outcome { Issue.record("must not normalize") }
    }

    @Test
    func negativeWhitespaceInCommand() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo hi", args: "there")) { Issue.record("must not normalize") }
    }

    @Test
    func negativeEmptyArgs() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo", args: "")) { Issue.record("must not normalize") }
    }

    @Test
    func negativeWhitespaceInArgsValue() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo", args: "hello world")) { Issue.record("must not normalize") }
    }

    @Test
    func negativeNonStringArgs() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo", args: 42)) { Issue.record("must not normalize") }
    }

    @Test
    func negativeUnrelatedTool() {
        var obj = shape(command: "echo", args: "hello")
        var steps = obj["steps"] as! [[String: Any]]
        steps[0]["tool"] = "web_search"
        obj["steps"] = steps
        if case .normalized = PlanNormalizerB.analyze(obj) { Issue.record("must not normalize") }
    }

    @Test
    func negativeMalformedSteps() {
        let obj: [String: Any] = ["goal": "g", "steps": "not-an-array"]
        if case .normalized = PlanNormalizerB.analyze(obj) { Issue.record("must not normalize") }
    }

    @Test
    func negativeMultiStepPlan() {
        let obj: [String: Any] = ["goal": "g", "steps": [
            ["id": "step_1", "tool": "run_shell", "arguments": ["command": "echo", "args": "a"]],
            ["id": "step_2", "tool": "run_shell", "arguments": ["command": "echo", "args": "b"]],
        ]]
        if case .normalized = PlanNormalizerB.analyze(obj) { Issue.record("must not normalize") }
    }

    // MARK: Literal-preservation invariants

    @Test
    func normalizerNeverIntroducesExampleValues() {
        let outcome = PlanNormalizerB.analyze(shape(command: "echo", args: "jarvis_planner_e2e_verified"))
        guard case .normalized(_, let joined) = outcome else {
            Issue.record()
            return
        }
        #expect(!joined.contains("hello"))
        #expect(!joined.contains("world"))
    }

    @Test
    func operatorBearingValueIsQuotedNotAltered() {
        let outcome = PlanNormalizerB.analyze(shape(command: "echo", args: "a;b"))
        guard case .normalized(_, let joined) = outcome else {
            Issue.record()
            return
        }
        #expect(joined == "echo 'a;b'")
    }

    @Test
    func disabledToggleLeavesObjectUntouched() {
        let saved = PlanNormalizerB.normalizerBEnabled
        PlanNormalizerB.normalizerBEnabled = false
        defer { PlanNormalizerB.normalizerBEnabled = saved }
        let obj = shape(command: "echo", args: "jarvis_planner_e2e_verified")
        let result = PlanNormalizerB.normalizeObject(obj)
        guard case .notApplicable = result.result else {
            Issue.record("disabled must not normalize")
            return
        }
        #expect(result.rewritten.count == obj.count)
    }
}
