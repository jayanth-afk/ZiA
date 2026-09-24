# Jarvis System Progress & Blueprint

Welcome to the development directory of **Jarvis** (Zia Platform). This document tracks the implementation progress, architectural goals, and system state of our ultra-high-performance, native macOS desktop intelligence agent.

---

## 🌟 Architectural Vision

Jarvis is a zero-latency, highly autonomous macOS agent designed to run as a native status bar and floating overlay application. Key architectural pillars:
1. **Zero External Swift Dependencies**: Leverages pure macOS SDKs (AppKit, AVFoundation, Speech, Vision, ScreenCaptureKit) for ultra-fast, safe compilation.
2. **Local + Cloud Hybrid Brain**: Uses a unified router supporting both cloud LLMs (Claude, Gemini, OpenAI, Groq) and local execution via Python MLX server integration.
3. **Multimodal Feedback Loop**: Integration of Screen Capture (FastUI and DeepVisual) with native macOS accessibility APIs, plus dual voice wake-word/VAD detection.
4. **Deterministic Action Sandbox**: Shell execution with sandbox constraints, native browser control, and system automation via AppleScript/JXA bridges.

---

## 📊 Feature Checklist & Status

### 1. Core Architecture (`Sources/Jarvis/Core`)
- [x] **Configuration Manager (`Config.swift`)**: Unified API keys, endpoints, and toggle states with secure Keychain fallback.
- [x] **Secure Keychain Manager (`KeychainManager.swift`)**: Encrypted storage for LLM credentials via macOS Security framework.
- [x] **Thread-Safe Memory (`LockedValue.swift`)**: Atomic locks for synchronized cross-thread state.
- [x] **Event Bus (`EventBus.swift`)**: Publisher/subscriber pattern for decoupling voice, vision, and action systems.
- [x] **Logger (`Logger.swift`)**: Multi-level console logger with file rotators and performance timing hooks.
- [x] **Network Monitor (`NetworkMonitor.swift`)**: Automatic online/offline transition handling via Network framework.
- [x] **Resource Monitor (`ResourceManager.swift`)**: Monitors CPU, memory, and energy metrics to throttle agents when system load is extreme.
- [x] **Self-Testing Suite (`SelfTest.swift`)**: Validation run on startup to test API keys, microphones, and shell sandboxes.

### 2. UI & Menubar (`Sources/Jarvis/UI`)
- [x] **Menubar Manager (`MenuBarManager.swift`)**: Interactive menu bar extra showing CPU usage, active tasks, and status.
- [x] **Floating Action Overlay (`FloatingPanel.swift`)**: Custom, non-activating panel (similar to Spotlight or Siri) with a visual waveform.
- [x] **Interactive Waveform View (`WaveformView.swift`)**: Smooth, high-performance CoreGraphics audio visualizer.
- [x] **Settings Control (`SettingsView.swift`)**: SwiftUI view for managing local models, voice configurations, and prompt defaults.
- [x] **API Keys Management (`APIKeysView.swift`)**: Dedicated keychain interface.
- [x] **Dynamic Design System (`DesignTokens.swift`)**: Premium Dark/Neon aesthetic with custom blur materials.

### 3. Voice Pipeline (`Sources/Jarvis/Voice`)
- [x] **Wake-Word Detector (`WakeWordDetector.swift`)**: Real-time microphone buffer analyzer looking for triggering phonemes or energy spikes.
- [x] **Voice Activity Detector (`VoiceActivityDetector.swift`)**: Silence detection and audio segmentation to avoid shipping dead air.
- [x] **Audio Recording Engine (`AudioCapture.swift`)**: Direct AVFoundation tap managing PCM buffers.
- [x] **Speech Recognition (`SpeechRecognizer.swift`)**: Local `SFSpeechRecognizer` pipeline with prompt-inject fallback.
- [x] **TTS Engine (`TTSEngine.swift`)**: Low-latency Speech Synthesis engine (`AVSpeechSynthesizer`) using high-quality voices.
- [x] **Emergency Interruption (`EmergencyInterrupt.swift`)**: Instant stop trigger for audio playback if the user speaks or hits escape.
- [x] **Unified Pipeline Coordinator (`VoicePipeline.swift`)**: Bridges capture, wake, VAD, transcription, brain response, and TTS.

### 4. Vision Engine (`Sources/Jarvis/Vision`)
- [x] **Screen Capture System (`ScreenCapture.swift`)**: ScreenCaptureKit framework capture with selective application/window cropping.
- [x] **FastUI Visual Mode (`FastUIMode.swift`)**: Low-overhead downscaled frames analyzed for structural UI changes.
- [x] **DeepVisual Vision Mode (`DeepVisualMode.swift`)**: High-res visual reasoning frames sent directly to multimodal models (Gemini Flash/Claude).
- [x] **Accessibility Bridge (`AccessibilityBridge.swift`)**: Uses macOS AXUIElement to extract coordinates of buttons, text fields, and system menus.

### 5. Unified Brain Router (`Sources/Jarvis/Brain`)
- [x] **Provider Interface (`Provider.swift`)**: Clean protocol for standardizing text, vision, and tool-calling structures.
- [x] **Provider Suite**:
  - [x] **Claude (`ClaudeProvider.swift`)** (Anthropic Claude 3.5 Sonnet / Haiku integration)
  - [x] **Gemini (`GeminiProvider.swift`)** (Google Gemini 1.5 Pro / Flash with tool support)
  - [x] **OpenAI (`OpenAIProvider.swift`)** (GPT-4o / GPT-4o-mini support)
  - [x] **Groq (`GroqProvider.swift`)** (Ultra-fast Llama 3 / Mixtral inference)
  - [x] **Local MLX (`MLXProvider.swift`)** (Integration with python-based mlx-lm servers)
- [x] **Intent Classifier (`IntentClassifier.swift`)**: Sub-10ms prompt analysis to route conversational vs. action-driven inputs.
- [x] **Usage & Cost Tracker (`UsageManager.swift`)**: Persistent local storage counting tokens and estimating running costs.
- [x] **Conversation Memory Engine (`ConversationManager.swift` / `ContextBuilder.swift`)**: Implements dynamic conversational sliding windows.

### 6. Memory & Knowledge Manager (`Sources/Jarvis/Memory`)
- [x] **Conversation Store (`ConversationStore.swift`)**: Disk-backed JSON cache of local interactions.
- [x] **User Profiler (`UserProfile.swift`)**: Dynamic extraction of user details, preferences, and long-term context.
- [x] **Local Embedding Engine (`EmbeddingEngine.swift`)**: CoreML / NaturalLanguage embedding generator.
- [x] **Vector Search database (`VectorSearch.swift`)**: Lightweight, pure Swift vector matching for RAG context extraction.
- [x] **Unified Memory Manager (`MemoryManager.swift`)**: Orchestrates long-term semantic context, ephemeral memory, and short-term profiles.

### 7. Actions & Agent Loops (`Sources/Jarvis/Actions` & `Sources/Jarvis/Agent`)
- [x] **Deterministic Router (`DeterministicRouter.swift`)**: Maps natural language or structured tools directly to Swift handlers.
- [x] **Command Sandbox (`CommandSandbox.swift`)**: Secure `Process` executor constraining shell commands with timeout/path restrictions.
- [x] **Shell Executor (`ShellExecutor.swift`)**: Handles Zsh terminal interactions, tracking output and environment.
- [x] **AppleScript / JXA Bridge (`AppleScriptBridge.swift`)**: Native system-level automation (Calendar, Reminders, Notes, Finder).
- [x] **Browser Manager (`BrowserManager.swift`)**: Interacts with Safari/Chrome, extracting active tabs, history, and HTML content.
- [x] **File Manager Tool (`FileManagerJarvis.swift`)**: Safe local file system reading, writing, searching, and structural mapping.
- [x] **Web Search / Scraper (`WebSearch.swift` / `URLFetcher.swift`)**: Fetches live web contents and searches via SearXNG/DuckDuckGo.
- [x] **Task State Machine (`TaskStateMachine.swift`)**: Multi-step agent planning state tracking (Pending -> Planning -> Executing -> Validating -> Completed).
- [x] **Agent Planner (`MLXPlanner.swift` / `DirectComposer.swift`)**: Formulates multi-step actions to execute complex objectives.
- [x] **Task Worker & Worker Pool (`TaskWorker.swift` / `TaskWorkerPool.swift`)**: Concurrent execution workers for processing agent plans.
- [x] **Plan Validator (`PlanValidator.swift`)**: Critically examines actions before run, verifying paths, URLs, and commands against rules.
- [x] **Permission Gate (`PermissionGate.swift`)**: Interactive GUI confirmation intercepting high-risk operations (e.g. `rm -rf`, curl execution).

---

## 🛠️ Next Steps & Active Engineering Fronts

We have built out an incredibly rich, modular, and deep macOS foundation. The next phase of development centers around:
1. **End-to-End System Integration**: Fully tying the Voice pipeline to the Brain routing loop, triggering actions dynamically based on voice requests.
2. **Vision-to-Action Coordination**: Correlating accessibility element coordinates extracted by `AccessibilityBridge` with visual screenshot bounding boxes to perform actual mouse clicks.
3. **Refining Action Sandboxing**: Tightening shell security filters and perfecting the interactive permission gate dialogs.
4. **Optimizing Local LLM Execution**: Tuning local python-based MLX server scripts and establishing seamless zero-latency IPC.

Let's maintain extreme performance discipline: avoiding unnecessary heap allocations, maximizing Grand Central Dispatch (GCD) thread safety, and retaining pure native code execution.