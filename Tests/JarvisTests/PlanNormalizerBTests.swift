@testable import Jarvis
import XCTest

/// Experiment B — offline fixtures for the single-shape deterministic
/// normalizer (PlanNormalizerB). These mirror the predeclared contract:
/// positive cases normalize the exact malformed run_shell command+args shape
/// with byte-exact literal preservation; every negative case must pass
/// through untouched (fail closed) to the existing validation/repair path.
final class PlanNormalizerBTests: XCTestCase {

    private func shape(command: Any, args: Any, tool: String = "run_shell",
                       extraArgs: [String: Any] = [:]) -> [String: Any] {
        var arguments: [String: Any] = ["command": command, "args": args]
        for (k, v) in extraArgs { arguments[k] = v }
        return ["goal": "g", "steps": [["id": "step_1", "tool": tool, "arguments": arguments]]]
    }

    // MARK: Positive

    func testPositiveLiteralPreservedExactly() {
        let outcome = PlanNormalizerB.analyze(
            shape(command: "echo", args: "jarvis_planner_e2e_verified"))
        guard case .normalized(_, let joined) = outcome else {
            return XCTFail("expected normalization, got \(outcome)")
        }
        XCTAssertEqual(joined, "echo jarvis_planner_e2e_verified")
    }

    func testPositivePrintfSingleToken() {
        let outcome = PlanNormalizerB.analyze(shape(command: "printf", args: "abc123"))
        guard case .normalized(_, let joined) = outcome else {
            return XCTFail("expected normalization, got \(outcome)")
        }
        XCTAssertEqual(joined, "printf abc123")
    }

    func testPositiveListArgs() {
        let outcome = PlanNormalizerB.analyze(shape(command: "echo", args: ["hello", "world"]))
        guard case .normalized(_, let joined) = outcome else {
            return XCTFail("expected normalization, got \(outcome)")
        }
        XCTAssertEqual(joined, "echo hello world")
    }

    // MARK: Negative / pass-through (fail closed)

    func testNegativeMissingCommand() {
        var obj = shape(command: "echo", args: "hello")
        var steps = obj["steps"] as! [[String: Any]]
        steps[0]["arguments"] = ["args": "hello"]
        obj["steps"] = steps
        if case .normalized = PlanNormalizerB.analyze(obj) { XCTFail("must not normalize") }
    }

    func testNegativeMissingArgs() {
        var obj = shape(command: "echo", args: "hello")
        var steps = obj["steps"] as! [[String: Any]]
        steps[0]["arguments"] = ["command": "echo"]
        obj["steps"] = steps
        if case .normalized = PlanNormalizerB.analyze(obj) { XCTFail("must not normalize") }
    }

    func testNegativeExtraUnrelatedKey() {
        let outcome = PlanNormalizerB.analyze(
            shape(command: "echo", args: "hello", extraArgs: ["purpose": "x"]))
        if case .normalized = outcome { XCTFail("must not normalize") }
    }

    func testNegativeWhitespaceInCommand() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo hi", args: "there")) { XCTFail("must not normalize") }
    }

    func testNegativeEmptyArgs() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo", args: "")) { XCTFail("must not normalize") }
    }

    func testNegativeWhitespaceInArgsValue() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo", args: "hello world")) { XCTFail("must not normalize") }
    }

    func testNegativeNonStringArgs() {
        if case .normalized = PlanNormalizerB.analyze(
            shape(command: "echo", args: 42)) { XCTFail("must not normalize") }
    }

    func testNegativeUnrelatedTool() {
        var obj = shape(command: "echo", args: "hello")
        var steps = obj["steps"] as! [[String: Any]]
        steps[0]["tool"] = "web_search"
        obj["steps"] = steps
        if case .normalized = PlanNormalizerB.analyze(obj) { XCTFail("must not normalize") }
    }

    func testNegativeMalformedSteps() {
        let obj: [String: Any] = ["goal": "g", "steps": "not-an-array"]
        if case .normalized = PlanNormalizerB.analyze(obj) { XCTFail("must not normalize") }
    }

    func testNegativeMultiStepPlan() {
        let obj: [String: Any] = ["goal": "g", "steps": [
            ["id": "step_1", "tool": "run_shell", "arguments": ["command": "echo", "args": "a"]],
            ["id": "step_2", "tool": "run_shell", "arguments": ["command": "echo", "args": "b"]],
        ]]
        if case .normalized = PlanNormalizerB.analyze(obj) { XCTFail("must not normalize") }
    }

    // MARK: Literal-preservation invariants

    func testNormalizerNeverIntroducesExampleValues() {
        let outcome = PlanNormalizerB.analyze(shape(command: "echo", args: "jarvis_planner_e2e_verified"))
        guard case .normalized(_, let joined) = outcome else { return XCTFail() }
        XCTAssertFalse(joined.contains("hello"))
        XCTAssertFalse(joined.contains("world"))
    }

    func testOperatorBearingValueIsQuotedNotAltered() {
        let outcome = PlanNormalizerB.analyze(shape(command: "echo", args: "a;b"))
        guard case .normalized(_, let joined) = outcome else { return XCTFail() }
        XCTAssertEqual(joined, "echo 'a;b'")
    }

    func testDisabledToggleLeavesObjectUntouched() {
        let saved = PlanNormalizerB.normalizerBEnabled
        PlanNormalizerB.normalizerBEnabled = false
        defer { PlanNormalizerB.normalizerBEnabled = saved }
        let obj = shape(command: "echo", args: "jarvis_planner_e2e_verified")
        let result = PlanNormalizerB.normalizeObject(obj)
        guard case .notApplicable = result.result else { return XCTFail("disabled must not normalize") }
        XCTAssertEqual(result.rewritten.count, obj.count)
    }
}
