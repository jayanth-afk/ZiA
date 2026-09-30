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
        case unresolvedFileReference
        case unresolvedURLReference
        case unresolvedCommandReference
        case unresolvedSearchReference
        case unresolvedWriteReference
        case unresolvedVolumeReference

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
            case .unresolvedFileReference:
                return "Which file would you like me to read? Please specify the file path."
            case .unresolvedURLReference:
                return "Which URL would you like me to fetch? Please provide the URL."
            case .unresolvedCommandReference:
                return "Which command would you like me to run? Please specify the command."
            case .unresolvedSearchReference:
                return "What would you like me to search for? Please specify the search query."
            case .unresolvedWriteReference:
                return "What content and file path would you like to write to? Please specify both."
            case .unresolvedVolumeReference:
                return "What volume level would you like to set? Please specify a level (e.g. 50%)."
            }
        }
    }

    // MARK: - Decision

    enum Decision: Sendable, Equatable {
        /// Obvious conversational/knowledge request — answer directly without planning.
        case directAnswer
        /// Recent-action question answered from TaskState and observed telemetry.
        case activitySummary
        /// File-artifact question answered only from a completed, verified write.
        case verifiedArtifactSummary
        /// Checks a previously verified artifact against current filesystem state.
        case verifiedArtifactStatus
        /// Informational answer owned by a specific existing evidence source.
        case informationAnswer(InformationSource)
        /// Explicit refusal with a typed, auditable reason.
        case refusal(RefusalReason)
        /// Genuine tool task or ambiguous goal — route to the planner.
        case planner
    }

    enum InformationSource: Sendable, Equatable {
        case conversationHistory
        case userMemory
        case developmentHistory
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

        let normalizedGoal = normalize(goal)
        if let source = informationSource(for: normalizedGoal) {
            return .informationAnswer(source)
        }
        if ["is the file you created still there", "is the file you just created still there",
            "does the file you created still exist", "is that file still there"].contains(normalizedGoal) {
            return .verifiedArtifactStatus
        }
        if ["what happened when you tried writing that file",
            "what happened when you tried to write that file",
            "what happened when you tried creating that file"].contains(normalizedGoal) {
            return .activitySummary
        }

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

        // 1b. Unresolved / underspecified references: clarify/reject before
        // planner invocation or retry so the model does not fabricate arguments.
        let normalized = normalizedGoal

        let unresolvedAppPatterns = [
            "open that app", "launch that app", "switch to that app",
            "open the app", "launch the app", "switch to the app",
            "open that", "launch that", "switch to that",
            "open that application", "launch that application"
        ]
        if unresolvedAppPatterns.contains(normalized) {
            return .refusal(.unresolvedReference)
        }

        let unresolvedFilePatterns = [
            "read that file", "read that", "read the file", "read the file i mentioned",
            "read this file", "read that document", "read the document", "view that file",
            "show that file", "cat that file", "open that file", "open the file you created",
            "open the file you just created", "open the file from earlier",
            "read the file you created", "read the file you just created"
        ]
        if unresolvedFilePatterns.contains(normalized) {
            return .refusal(.unresolvedFileReference)
        }

        let unresolvedWritePatterns = [
            "write that to the file", "write that to a file", "write it to the file",
            "write that", "save that to the file", "save that to a file", "save that file",
            "write to that file", "write to the file"
        ]
        if unresolvedWritePatterns.contains(normalized) {
            return .refusal(.unresolvedWriteReference)
        }

        let unresolvedURLPatterns = [
            "fetch that url", "fetch that", "fetch the url", "download that url",
            "download that", "fetch that website", "download the url", "fetch that page",
            "fetch that link", "go back to that webpage", "go back to that page",
            "return to that webpage", "open that webpage"
        ]
        if unresolvedURLPatterns.contains(normalized) {
            return .refusal(.unresolvedURLReference)
        }

        let unresolvedCommandPatterns = [
            "run that command", "run that command again", "run that", "execute that command", "execute that",
            "run the command", "execute the command", "run that script", "execute that script",
            "run that again", "execute that again"
        ]
        if unresolvedCommandPatterns.contains(normalized) {
            return .refusal(.unresolvedCommandReference)
        }

        let unresolvedFolderPatterns = [
            "open that folder", "list that folder", "show that folder",
            "open that directory", "list that directory", "show that directory"
        ]
        if unresolvedFolderPatterns.contains(normalized) {
            return .refusal(.unresolvedReference)
        }

        let unresolvedSearchPatterns = [
            "search for that", "search for it", "look that up", "search that",
            "search for this", "look it up", "search it", "google that", "google it"
        ]
        if unresolvedSearchPatterns.contains(normalized) {
            return .refusal(.unresolvedSearchReference)
        }

        let unresolvedVolumePatterns = [
            "set it to that", "set volume to that", "increase it", "decrease it",
            "turn it up", "turn it down", "turn volume to that", "set the volume to that"
        ]
        if unresolvedVolumePatterns.contains(normalized) {
            return .refusal(.unresolvedVolumeReference)
        }

        let recentActivityQuestions = [
            "what did you do", "what did you just do", "what did you do recently",
            "what did you do a few minutes ago", "what have you done recently",
            "what happened a few minutes ago", "what did you do a moment ago"
        ]
        if recentActivityQuestions.contains(normalized) {
            return .activitySummary
        }

        let verifiedArtifactQuestions = [
            "what file did you create", "which file did you create",
            "what file did you just create", "which file did you just create",
            "what file did you save", "which file did you save"
        ]
        if verifiedArtifactQuestions.contains(normalized) {
            return .verifiedArtifactSummary
        }

        // A bare "what happened?" is a question about the latest recorded
        // interaction when one exists. Answer from TaskState/telemetry rather
        // than asking a model to reconstruct operational facts from prose.
        if normalized == "what happened" {
            return .activitySummary
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

        // 2b. Bare conversational follow-ups (CROSS-TURN MEMORY): terse one-word
        // follow-ups after a completed task ("why?", "when?", "explain") are
        // conversation-about-context, not tool tasks. Routing them to the
        // planner makes the 0.5B model hallucinate an unrelated tool call for a
        // question only the conversation history can answer. Exact-match on the
        // normalized whole goal — deliberately tiny, no grammar, no sprawl.
        let bareFollowUps: Set<String> = ["why", "why?", "how", "how?", "when", "when?", "explain", "elaborate", "what happened", "what happened?"]
        if bareFollowUps.contains(normalized) {
            return .directAnswer
        }

        // 2c. Conversation-processing instructions (CROSS-TURN MEMORY): short
        // instructions whose object is the conversation itself — "summarize
        // that in one sentence", "repeat your previous output". The referent
        // (that/this/it/previous/last) lives in conversation memory, which only
        // the direct-answer composer sees; the planner would hallucinate a tool
        // call for it. Bounded: first word must be a processing verb, a
        // conversation referent must be present, and the goal must be short.
        // Action verbs ("delete that file") never match — the verb list has no
        // execution/system verbs.
        let words = normalized.split(separator: " ")
        let processVerbs: Set<String> = ["summarize", "summarise", "repeat", "restate", "rephrase", "rewrite", "shorten", "explain", "translate", "spell"]
        let conversationReferents: Set<String> = ["that", "this", "it", "them", "those", "these", "previous", "last"]
        if let first = words.first, processVerbs.contains(String(first)),
           words.count <= 10,
           words.contains(where: { conversationReferents.contains(String($0)) }) {
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

    private nonisolated static func informationSource(for normalized: String) -> InformationSource? {
        if ["what did we talk about recently", "what have we talked about recently",
            "what did we discuss recently", "summarize our recent conversation"].contains(normalized) {
            return .conversationHistory
        }
        if ["what do you remember", "what do you remember about me",
            "what do you remember about my project", "what do you remember about my preferences"].contains(normalized) {
            return .userMemory
        }
        if ["what did you change in zia recently", "what did we change in zia recently",
            "what changed in zia recently", "what did you change in jarvis recently",
            "what did we change recently"].contains(normalized) {
            return .developmentHistory
        }
        return nil
    }

    private nonisolated static func normalize(_ goal: String) -> String {
        var result = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = result.last, ".?!".contains(last) { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespaces)
        for prefix in ["please ", "can you please ", "can you ", "could you please ", "could you "] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return result
    }
}
