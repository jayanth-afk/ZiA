import Foundation

/// Narrow, deterministic routing decision made BEFORE the planner (STEP: direct-answer routing).
///
/// Routing order in AgentLoop.run(goal:):
///   1. DeterministicRouter  — deterministic commands (0ms, no model).
///   2. DirectAnswerRouter   — obvious conversational/knowledge questions get a
///      direct local-model answer; unsupported/unsafe/malformed requests get an
///      EXPLICIT typed refusal; everything else (genuine tool task, ambiguous)
///      goes to the MLX planner.
///
/// Recency safety net (direct-answer routing milestone): a request with a
/// strong recency signal ("current", "today", "latest", "as of", "right now",
/// "this week", …) is NEVER eligible for a stale direct answer — it is forced
/// onto the tool/web path. The bias is deliberately toward unnecessary lookup
/// rather than confidently answering a current-information question from
/// stale model knowledge. The check is deterministic, tiny, and composes with
/// every branch below: a recency goal can still be refused as unsafe, but it
/// can never be answered from stale knowledge.
///
/// Deliberately NOT a classifier model and not a large keyword net: a small
/// high-precision predicate set. Ambiguous goals fall FORWARD to the planner —
/// never into refusal — so over-triggering refusal is structurally impossible
/// for goals that do not match the explicit unsafe/unsupported lists.
@MainActor
enum DirectAnswerRouter {

    // MARK: - Typed refusal (FOCUS 5)

    /// Explicit, auditable refusal reasons. A validator rejection is NOT a
    /// refusal — this type exists so unsupported/unsafe requests are
    /// represented intentionally (and can be logged/reported as such) instead
    /// of silently becoming an unrelated valid tool call.
    enum RefusalReason: String, Sendable {
        case unsupportedCapability
        case unsafeRequest
        case malformedRequest
        case unresolvedReference

        var userFacingMessage: String {
            switch self {
            case .unsupportedCapability:
                return "Refused: I don't have a tool capable of that request, and I won't improvise an unrelated action instead."
            case .unsafeRequest:
                return "Refused: that request is unsafe or destructive, so I won't act on it."
            case .malformedRequest:
                return "Refused: the request was empty or malformed, so there is nothing to act on."
            case .unresolvedReference:
                return "Which app would you like to open? Please specify the application name."
            }
        }
    }

    // MARK: - Decision

    enum Decision: Sendable, Equatable {
        /// Obvious conversational/knowledge request — answer directly without planning.
        case directAnswer
        /// Explicit refusal with a typed, auditable reason.
        case refusal(RefusalReason)
        /// Genuine tool task or ambiguous goal — route to the planner.
        case planner
    }

    // MARK: - Recency safety net (deterministic freshness forcing)

    /// A goal carrying a strong recency signal must reach fresh data through a
    /// tool — never a stale direct answer. Delegates to the single documented
    /// signal list in PlannerExtraction.requiresFreshData(_:) so the router,
    /// the planner catalog hint, and the post-validation recency compiler all
    /// share ONE deterministic definition.
    nonisolated static func requiresFreshData(_ goal: String) -> Bool {
        PlannerExtraction.requiresFreshData(goal)
    }

    // MARK: - Predicate

    nonisolated static func decide(goal rawGoal: String) -> Decision {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return .refusal(.malformedRequest) }
        let g = goal.lowercased()

        // 0. RECENCY SAFETY NET (evaluated first, applies to every branch):
        // a current-information request can still be refused below if it is
        // unsafe, but it can NEVER be answered from stale model knowledge.
        // This is the CASE 3 guarantee: "What is the current capital of
        // France according to today's sources?" is forced onto the tool path
        // even though it is phrased as a plain knowledge question.
        if requiresFreshData(goal) {
            return .planner
        }

        // 1. Unsafe/destructive: explicit refusal BEFORE any planning. These
        // must never reach the planner where a 0.5B model might wrap them in
        // an unrelated valid tool call.
        let unsafePatterns = [
            "rm -rf", "rm -fr", "delete everything", "wipe the", "wipe my", "wipe all",
            "format the disk", "erase the disk", "erase my disk", "factory reset",
            "reboot the", "shut down the system", "shutdown the system", "kernel panic",
            "destroy the", "destroy all"
        ]
        if unsafePatterns.contains(where: { g.contains($0) }) {
            return .refusal(.unsafeRequest)
        }

        // 1b. Unresolved / underspecified app reference: clarify/reject before
        // app launch or planner retry so the model does not fabricate 'that_app'.
        let unresolvedAppPatterns = [
            "open that app", "launch that app", "switch to that app",
            "open the app", "launch the app"
        ]
        if unresolvedAppPatterns.contains(g) {
            return .refusal(.unresolvedReference)
        }

        // 2. Obvious knowledge/conversational question → direct answer.
        // Action verbs pull the goal back to the planner even when phrased as
        // a question ("what files should I delete..." contains "delete").
        let questionStarters = [
            "what ", "who ", "when ", "why ", "how ", "explain ", "define ",
            "describe ", "tell me about", "tell me what", "tell me why", "tell me how"
        ]
        let actionVerbs = [
            "run ", "execute ", "open ", "launch ", "search for", "search the web", "search online", "look up", "find ",
            "fetch", "download", "list ", "show ", "read ", "write ", "create ",
            "delete ", "remove ", "copy ", "move ", "set ", "print ", "make ",
            "kill ", "quit ", "close ", "empty ", "install ", "uninstall "
        ]
        let startsQuestion = questionStarters.contains { g.hasPrefix($0) }
        let hasActionVerb = actionVerbs.contains { g.contains($0) }
        if startsQuestion && !hasActionVerb {
            return .directAnswer
        }

        // 3. Unsupported capabilities in imperative phrasing: no registered
        // tool can serve these (no email/chat/media/commerce tools exist), so
        // planning would either hallucinate a tool or misuse an unrelated one.
        // Informational phrasing ("how do I send an email") is handled by the
        // question branch above and never reaches here.
        let unsupportedPatterns = [
            "send an email", "send the email", "email to", "send a text", "send a message",
            "text message", "send a tweet", "post a tweet", "post on twitter",
            "post on facebook", "post on instagram", "whatsapp", "slack message",
            "send a slack", "play music", "play a song", "play some music", "spotify",
            "netflix", "order ", "buy ", "purchase ", "set an alarm", "set a timer",
            "remind me", "make a call", "call someone", "dial "
        ]
        if unsupportedPatterns.contains(where: { g.contains($0) }) {
            return .refusal(.unsupportedCapability)
        }

        // 4. Everything else (genuine tool task, ambiguous) → planner.
        return .planner
    }

    // MARK: - Test hook

    /// Whether a goal is explicitly refused (used by self-test/audit to verify
    /// refusals are represented without invoking any model).
    nonisolated static func refusalReason(for goal: String) -> RefusalReason? {
        if case .refusal(let reason) = decide(goal: goal) { return reason }
        return nil
    }
}
