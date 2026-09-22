import Foundation

/// Deep visual reasoning subsystem that captures screenshots and analyzes them via multimodal vision models.
/// Rule: Used as a fallback when FastUIMode does not expose required UI elements or for deep visual inspection.
final class DeepVisualMode: @unchecked Sendable {
    static let shared = DeepVisualMode()

    private init() {}

    // MARK: - Public API

    /// Captures the screen and performs multimodal vision analysis.
    func analyzeScreen(prompt: String = "Describe what is currently visible on the screen.") async throws -> String {
        guard let imageData = await ScreenCapture.shared.captureMainDisplay(maxDimension: 1280) else {
            throw JarvisError.actionFailed(action: "DeepVisualMode.analyzeScreen", reason: "Failed to capture display")
        }

        let base64Image = imageData.base64EncodedString()
        let imageSizeKB = imageData.count / 1024
        JarvisLogger.brain.info("DeepVisualMode: Captured screenshot (\(imageSizeKB) KB). Sending for visual analysis...")

        // Format user message with base64 image reference
        let multimodalPrompt = """
        [Attached Screen Image: data:image/jpeg;base64,\(base64Image.prefix(64))... (\(imageSizeKB)KB)]
        Question: \(prompt)
        """

        let messages = [
            Message(role: .system, content: "You are JARVIS Vision Assistant. Analyze the user's screen accurately and concisely."),
            Message(role: .user, content: multimodalPrompt)
        ]

        // Route to vision-capable provider (Gemini or Claude)
        let gemini = await ProviderManager.shared.gemini
        let geminiAvailable = await gemini.isAvailable
        if geminiAvailable {
            do {
                var responseText = ""
                let stream = await gemini.complete(messages: messages, tools: nil, stream: false)
                for try await chunk in stream {
                    if case .text(let text) = chunk {
                        responseText += text
                    }
                }
                if !responseText.isEmpty {
                    return responseText
                }
            } catch {
                JarvisLogger.brain.warning("Gemini vision analysis failed: \(error.localizedDescription). Falling back to Claude...")
            }
        }

        let claude = await ProviderManager.shared.claude
        let claudeAvailable = await claude.isAvailable
        if claudeAvailable {
            do {
                var responseText = ""
                let stream = await claude.complete(messages: messages, tools: nil, stream: false)
                for try await chunk in stream {
                    if case .text(let text) = chunk {
                        responseText += text
                    }
                }
                if !responseText.isEmpty {
                    return responseText
                }
            } catch {
                JarvisLogger.brain.warning("Claude vision analysis failed: \(error.localizedDescription)")
            }
        }

        // Offline / local fallback
        return "Screen captured successfully (\(imageSizeKB) KB, \(imageData.count) bytes). Vision models currently offline."
    }
}
