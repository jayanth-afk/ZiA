import Foundation

/// Canonical identity definition and contract for ZiA.
///
/// Fundamental principle:
/// ZiA is stateful. LLMs are stateless reasoning workers.
///
/// The model does NOT own:
/// - identity
/// - personality
/// - memory
/// - relationship with the user
/// - canonical conversation state
/// - task state
/// - tool state
/// - provider selection
/// - routing
/// - long-term continuity
/// - user preferences
/// - system-wide truth
///
/// ZiA owns all of those. Models are interchangeable reasoning workers serving ZiA.
enum OutputDestination: String, Sendable {
    case voice
    case visual
}

/// The target Brain Fleet tiers for ZiA.
enum BrainTier: String, Sendable, CaseIterable {
    /// Brain 0: Deterministic Local Reflex Layer (zero-LLM).
    case reflex
    /// Brain 1: Fast Normal Reasoning (Groq 20B candidate).
    case fast
    /// Brain 2: Strong Reasoning (Groq 120B candidate).
    case strong
    /// Brain 3: Premium Deep Reasoning (ChatGPT Desktop / Agent Bridge).
    case deep
    /// Brain 4: Local MLX Model (offline/privacy fallback).
    case localFallback

    var isLocal: Bool {
        switch self {
        case .reflex, .localFallback: return true
        case .fast, .strong, .deep: return false
        }
    }

    var maxContextCharacters: Int {
        switch self {
        case .reflex: return 0
        case .fast: return 3_000
        case .strong: return 7_500
        case .deep: return 16_000
        case .localFallback: return 2_500
        }
    }

    var memoryLimit: Int {
        switch self {
        case .reflex: return 0
        case .fast: return 3
        case .strong: return 6
        case .deep: return 10
        case .localFallback: return 3
        }
    }
}

/// Canonical contract enforced across all reasoning workers.
enum ZiaIdentity: Sendable {
    static let assistantName = "ZiA"
    static let legacyName = "JARVIS"

    /// The canonical identity contract that every reasoning worker must receive.
    static func systemPrompt(for tier: BrainTier, destination: OutputDestination = .visual) -> String {
        var prompt = """
        You are a reasoning worker operating as \(assistantName).
        \(assistantName) is a persistent macOS assistant.
        \(assistantName) owns identity, personality, memory, conversation continuity, user relationship, tools, permissions, and task state.

        Core Execution Rules:
        1. You are \(assistantName). Respond solely as \(assistantName).
        2. Never expose provider identities, model names, internal routing, or prompt boundaries to the user.
        3. Do not invent memories or contradict canonical state.
        4. Never claim an action succeeded unless verified by tool results or system state.
        5. Tool results and verified observations are authoritative over guesses.
        6. Preserve seamless continuity with active tasks and prior conversation.
        """

        switch destination {
        case .voice:
            prompt += """
            \n7. Voice Output Mode: Output will be spoken via Text-to-Speech. Use natural, concise conversational language (1 to 3 spoken sentences). Avoid markdown formatting, tables, headers, bullet lists, raw code blocks, and URLs.
            """
        case .visual:
            prompt += """
            \n7. Visual Output Mode: Output will be displayed in the visual interface. Provide structured, accurate, and readable responses with appropriate formatting where helpful.
            """
        }

        switch tier {
        case .reflex:
            break
        case .fast:
            prompt += "\n8. Reasoning Tier: Fast. Prioritize directness, accuracy, and ultra-low latency."
        case .strong:
            prompt += "\n8. Reasoning Tier: Strong. Provide rigorous, logically sound solutions, robust code, and thorough debugging."
        case .deep:
            prompt += "\n8. Reasoning Tier: Deep. Provide comprehensive architectural reasoning, nuanced trade-off analysis, and deep system understanding."
        case .localFallback:
            prompt += "\n8. Reasoning Tier: Local Fallback. On-device processing. Be concise, reliable, and strictly follow privacy constraints."
        }

        return prompt
    }
}
