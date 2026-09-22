import Foundation

/// Lightweight test runner that works without Xcode/XCTest.
/// Run with: swift run Jarvis --self-test
@MainActor
enum SelfTest {

    static func runAll() {
        print("╔══════════════════════════════════════════╗")
        print("║      JARVIS — Self-Test Suite           ║")
        print("╚══════════════════════════════════════════╝\n")

        var passed = 0
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
                print("  ✓ \(message)")
            } else {
                failures.append(message)
                print("  ✗ FAIL: \(message)")
            }
        }

        // ── AppState Tests ──
        print("\n─── AppState ───")

        let state = AppState.shared
        if state.state != .off { state.transition(to: .off) }
        check(state.state == .off, "Initial state is OFF")

        state.transition(to: .sleep)
        check(state.state == .sleep, "OFF → SLEEP works")

        state.transition(to: .active)
        check(state.state == .active, "SLEEP → ACTIVE works")

        state.transition(to: .sleep)
        check(state.state == .sleep, "ACTIVE → SLEEP works")

        state.transition(to: .off)
        check(state.state == .off, "SLEEP → OFF works")

        state.transition(to: .active)
        check(state.state == .off, "OFF → ACTIVE rejected (invalid)")

        let t1 = state.lastTransition
        state.transition(to: .off)
        check(state.lastTransition == t1, "Same-state is no-op")

        state.updateNetworkStatus(false)
        check(!state.isOnline, "Network offline update")
        state.updateNetworkStatus(true)
        check(state.isOnline, "Network online update")

        state.updateMemoryPressure(.warning)
        check(state.memoryPressure == .warning, "Memory pressure warning")
        state.updateMemoryPressure(.nominal)
        check(state.memoryPressure == .nominal, "Memory pressure nominal")

        // ── EventBus Tests ──
        print("\n─── EventBus ───")

        struct TestEvent: JarvisEvent { let value: Int }
        struct OtherEvent: JarvisEvent { let text: String }

        let bus = EventBus.shared
        bus.removeAll()

        var received: Int?
        bus.subscribe(TestEvent.self) { e in received = e.value }
        bus.publish(TestEvent(value: 42))
        check(received == 42, "Publish delivers to subscriber")

        bus.removeAll()
        var count = 0
        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.subscribe(TestEvent.self) { _ in count += 1 }
        bus.publish(TestEvent(value: 1))
        check(count == 3, "Multiple subscribers all receive")

        bus.removeAll()
        var testFired = false
        var otherFired = false
        bus.subscribe(TestEvent.self) { _ in testFired = true }
        bus.subscribe(OtherEvent.self) { _ in otherFired = true }
        bus.publish(TestEvent(value: 1))
        check(testFired && !otherFired, "Event types are isolated")

        bus.removeAll()
        var unsCount = 0
        let subID = bus.subscribe(TestEvent.self) { _ in unsCount += 1 }
        bus.publish(TestEvent(value: 1))
        bus.unsubscribe(subID)
        bus.publish(TestEvent(value: 2))
        check(unsCount == 1, "Unsubscribe stops delivery")

        bus.removeAll()
        var afterClear = false
        bus.subscribe(TestEvent.self) { _ in afterClear = true }
        bus.removeAll()
        bus.publish(TestEvent(value: 1))
        check(!afterClear, "removeAll clears all handlers")

        bus.removeAll()
        bus.publish(TestEvent(value: 999))
        check(true, "No subscribers does not crash")

        // ── PipelineTimer Tests ──
        print("\n─── PipelineTimer ───")

        let timer1 = PipelineTimer(id: "test-1")
        timer1.mark(.wakeDetected)
        busyWait(ms: 1)
        timer1.mark(.sttStart)
        busyWait(ms: 1)
        timer1.mark(.sttFinal)
        let r1 = timer1.report()
        check(r1.id == "test-1", "Report has correct ID")
        check(r1.stages.count == 3, "Report has 3 stages")
        check(r1.totalMs > 0, "Total time greater than 0")

        let timer2 = PipelineTimer()
        timer2.mark(.providerStart)
        busyWait(ms: 2)
        timer2.mark(.firstToken)
        let elapsed = timer2.elapsed(from: .providerStart, to: .firstToken)
        check(elapsed != nil && elapsed! > 0, "Elapsed between stages greater than 0")

        let timer3 = PipelineTimer()
        timer3.mark(.wakeDetected)
        let missing = timer3.elapsed(from: .wakeDetected, to: .responseDelivered)
        check(missing == nil, "Missing stage returns nil")

        let timer4 = PipelineTimer()
        let r4 = timer4.report()
        check(r4.stages.isEmpty, "Empty timer has no stages")

        let timer5 = PipelineTimer(id: "fmt")
        timer5.mark(.wakeDetected)
        timer5.mark(.responseDelivered)
        let summary = timer5.report().summary
        check(summary.contains("fmt"), "Summary contains ID")

        // ── Config Tests ──
        print("\n─── Config ───")
        let config = Config.shared
        check(!config.wakeWord.isEmpty, "Wake word has default")
        check(config.autonomyLevel >= 0 && config.autonomyLevel <= 3, "Autonomy level in range")
        check(config.dailyBudgetUSD > 0, "Budget has default")
        check(config.memoryReserveMB > 0, "Memory reserve has default")

        // ── ResourceManager Tests ──
        print("\n─── ResourceManager ───")
        let rm = ResourceManager.shared
        check(rm.totalMemoryMB > 0, "Total memory detected: \(rm.totalMemoryMB)MB")

        rm.registerModelLoaded("test-model", estimatedMB: 100)
        check(rm.loadedModels["test-model"] != nil, "Model registered")
        check(rm.totalModelMemoryMB == 100, "Model memory tracked")
        rm.registerModelUnloaded("test-model")
        check(rm.loadedModels["test-model"] == nil, "Model unregistered")
        check(rm.totalModelMemoryMB == 0, "Model memory freed")

        // ── Phase 2: Voice Subsystem Tests ──
        print("\n─── Phase 2: Voice Activity Detector ───")
        let vad = VoiceActivityDetector.shared
        check(vad.configuration.energyThreshold > 0, "VAD default threshold is positive")
        check(vad.configuration.hangoverFrames > 0, "VAD hangover frames > 0")
        vad.reset()
        check(!vad.isSpeaking, "VAD reset clears speaking state")

        print("\n─── Phase 2: Wake Word Detector ───")
        let ww = WakeWordDetector.shared
        ww.startListening()
        check(ww.isListening, "Wake word detector is active")

        var wakeFired = false
        let wwSub = bus.subscribe(WakeWordDetectedEvent.self) { _ in wakeFired = true }
        let detected = ww.checkForWakeWord(in: "Jarvis, what is the weather?")
        check(detected, "Detects 'Jarvis' at sentence start")
        check(wakeFired, "Emits WakeWordDetectedEvent")

        check(!ww.checkForWakeWord(in: "Open Safari please"), "Ignores sentences without wake word")
        check(ww.checkForWakeWord(in: "Hey Jarvis tell me a joke"), "Detects 'Jarvis' in compound sentence")
        bus.unsubscribe(wwSub)
        ww.stopListening()
        check(!ww.isListening, "Wake word detector stopped")

        print("\n─── Phase 2: Emergency Interrupt ───")
        let emergency = EmergencyInterrupt.shared

        var emergencyFired = false
        let emSub = bus.subscribe(EmergencyStopEvent.self) { _ in emergencyFired = true }

        check(emergency.checkForEmergency(in: "stop"), "Detects standalone 'stop'")
        check(emergencyFired, "Emits EmergencyStopEvent")

        check(emergency.checkForEmergency(in: "CANCEL"), "Case-insensitive emergency detection")
        check(emergency.checkForEmergency(in: "abort!"), "Punctuation-tolerant emergency detection")
        check(!emergency.checkForEmergency(in: "don't stop the music"), "Does not false-positive on casual usage")
        bus.unsubscribe(emSub)

        print("\n─── Phase 2: TTS Engine ───")
        let tts = TTSEngine.shared
        check(!tts.isSpeaking, "TTS is idle initially")
        tts.stop() // Safe no-op when idle
        check(true, "TTS stop when idle does not crash")

        print("\n─── Phase 2: Audio Player ───")
        let player = AudioPlayer.shared
        check(!player.isPlaying, "AudioPlayer is idle initially")
        player.stopPlayback()
        check(true, "AudioPlayer stop when idle does not crash")

        print("\n─── Phase 2: Voice Pipeline ───")
        let pipeline = VoicePipeline.shared
        check(!pipeline.isRunning, "VoicePipeline initially not running before start")
        pipeline.start()
        check(pipeline.isRunning, "VoicePipeline starts cleanly")

        // ── Phase 3: Deterministic Mac Control Tests ──
        print("\n─── Phase 3: Deterministic Router ───")
        let router = DeterministicRouter.shared

        // App matching
        let appMatch = router.match("open Safari")
        check(appMatch != nil, "Matches 'open Safari'")
        check(appMatch?.intent == "app.open", "Intent is app.open")
        check(appMatch?.parameters["app"] == "safari", "Extracts app name 'safari'")

        let quitMatch = router.match("quit Mail")
        check(quitMatch?.intent == "app.quit", "Matches quit command")

        // Volume matching
        let volMatch = router.match("set volume to 65")
        check(volMatch?.intent == "system.volume.set", "Matches volume set command")
        check(volMatch?.parameters["level"] == "65", "Extracts volume level 65")

        let muteMatch = router.match("mute")
        check(muteMatch?.intent == "system.volume.mute", "Matches mute command")

        let volUpMatch = router.match("volume up")
        check(volUpMatch?.intent == "system.volume.up", "Matches volume up")

        // Time and Date matching
        let timeMatch = router.match("what time is it")
        check(timeMatch?.intent == "system.time", "Matches time query")

        let dateMatch = router.match("what is today's date")
        check(dateMatch?.intent == "system.date", "Matches date query")

        // System controls
        let lockMatch = router.match("lock screen")
        check(lockMatch?.intent == "system.lock", "Matches lock screen")

        let trashMatch = router.match("empty trash")
        check(trashMatch?.intent == "system.emptyTrash", "Matches empty trash")

        // Clipboard
        let clipMatch = router.match("read clipboard")
        check(clipMatch?.intent == "clipboard.read", "Matches read clipboard")

        // System Status
        let statusMatch = router.match("system status")
        check(statusMatch?.intent == "system.status", "Matches system status")

        // Non-deterministic commands must yield nil (forward to LLM)
        let nonDet = router.match("write a python script to fetch stock prices")
        check(nonDet == nil, "Complex queries yield nil (forwarded to LLM)")

        print("\n─── Phase 3: Clipboard Manager ───")
        let clip = ClipboardManager.shared
        clip.setClipboardText("JARVIS Test String 123")
        check(clip.getClipboardText() == "JARVIS Test String 123", "Clipboard write and read back")
        clip.clearClipboard()
        check(clip.getClipboardText() == nil || clip.getClipboardText() == "", "Clipboard cleared")

        print("\n─── Phase 3: File Manager & Security Sandbox ───")
        let fm = FileManagerJarvis.shared
        let homeResolved = fm.resolvePath("~")
        check(homeResolved != "~" && homeResolved.hasPrefix("/"), "Path resolution expands tilde")

        var blockedCaught = false
        do {
            _ = try fm.writeFile(at: "/System/malicious.txt", content: "evil")
        } catch JarvisError.commandBlocked {
            blockedCaught = true
        } catch {}
        check(blockedCaught, "Security sandbox blocks writing to /System")

        let homeListing = try? fm.listDirectory(at: "~")
        check(homeListing != nil && !homeListing!.isEmpty, "Lists home directory successfully")

        print("\n─── Phase 3: System Control ───")
        let sc = SystemControl.shared
        let currentVol = sc.getVolume()
        check(currentVol >= 0 && currentVol <= 100, "Reads valid system volume: \(currentVol)%")

        // ── Phase 4: Local Reflex & Normal Model Tests ──
        print("\n─── Phase 4: Conversation & Message Model ───")
        let conv = ConversationManager.shared
        conv.reset()
        check(conv.messages.count == 1, "Initial conversation has system prompt")
        check(conv.messages.first?.role == .system, "First message is system role")

        conv.addUserMessage("Hello JARVIS")
        check(conv.messages.count == 2, "User message appended")
        check(conv.messages.last?.role == .user, "Last message is user role")

        conv.addAssistantMessage("All systems operational.")
        check(conv.messages.count == 3, "Assistant message appended")
        check(conv.messages.last?.role == .assistant, "Last message is assistant role")

        let originalMax = conv.maxHistoryCount
        conv.maxHistoryCount = 4
        for i in 1...6 {
            conv.addUserMessage("Turn \(i)")
            conv.addAssistantMessage("Ack \(i)")
        }
        check(conv.messages.count <= 5, "Trims history to maxHistoryCount + system")
        check(conv.messages.first?.role == .system, "Preserves system prompt after trim")
        conv.maxHistoryCount = originalMax
        conv.reset()

        print("\n─── Phase 4: Provider & Capabilities ───")
        let mlxReflex = MLXProvider(id: "mlx-reflex-test", modelSlot: "reflex")
        let mlxNormal = MLXProvider(id: "mlx-normal-test", modelSlot: "normal")
        check(mlxReflex.capabilities.contains(.textGeneration), "MLXProvider has textGeneration capability")
        check(mlxNormal.capabilities.contains(.toolCalling), "MLXProvider has toolCalling capability")
        check(mlxReflex.currentLatencyMs > 0, "MLXProvider reports valid latency")

        print("\n─── Phase 4: Intent Classifier ───")
        let classifier = IntentClassifier.shared

        let codeResult = classifier.classifySync("Write a swift script to parse JSON")
        check(codeResult.category == .coding, "Classifies code request as .coding")
        check(codeResult.suggestedProvider == "claude", "Routes coding to Claude")

        let reasoningResult = classifier.classifySync("Analyze why this architecture is superior")
        check(reasoningResult.category == .deepReasoning, "Classifies deep question as .deepReasoning")

        let searchResult = classifier.classifySync("Search the web for current weather")
        check(searchResult.category == .webSearch, "Classifies web request as .webSearch")

        let chatResult = classifier.classifySync("How are you doing today?")
        check(chatResult.category == .conversation, "Classifies general chat as .conversation")

        // ── Phase 5: Provider Router & Cloud Intelligence Tests ──
        print("\n─── Phase 5: Cloud Providers ───")
        let pm = ProviderManager.shared

        check(pm.claude.id == "anthropic", "ClaudeProvider has ID 'anthropic'")
        check(pm.claude.capabilities.contains(.codeGeneration), "Claude has codeGeneration capability")

        check(pm.gemini.id == "gemini", "GeminiProvider has ID 'gemini'")
        check(pm.gemini.capabilities.contains(.vision), "Gemini has vision capability")

        check(pm.openai.id == "openai", "OpenAIProvider has ID 'openai'")
        check(pm.openai.capabilities.contains(.realtimeVoice), "OpenAI has realtimeVoice capability")

        check(pm.groq.id == "groq", "GroqProvider has ID 'groq'")
        check(pm.groq.currentLatencyMs == 150, "Groq has 150ms target latency")

        print("\n─── Phase 5: Fallback Chains ───")
        let codingChain = pm.getFallbackChain(for: .coding)
        check(codingChain.first?.id == "anthropic", "Coding fallback chain starts with Claude")
        check(codingChain.contains(where: { $0.id == "mlx-normal" }), "Coding chain includes on-device MLX fallback")

        let reasoningChain = pm.getFallbackChain(for: .deepReasoning)
        check(reasoningChain.first?.id == "anthropic", "Deep reasoning chain starts with Claude")

        let searchChain = pm.getFallbackChain(for: .webSearch)
        check(searchChain.first?.id == "groq", "Web search chain starts with Groq")

        print("\n─── Phase 5: Context Builder ───")
        let cb = ContextBuilder.shared
        let testMsgs = [
            Message(role: .system, content: "Initial system"),
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "World")
        ]
        let tokenCount = cb.estimateTokens(messages: testMsgs)
        check(tokenCount > 0, "Estimates positive token count (\(tokenCount))")

        let builtContext = cb.buildContext(messages: testMsgs, tokenLimit: 1000)
        check(builtContext.first?.role == .system, "Built context has system prompt at index 0")
        check(builtContext.first?.content.contains("JARVIS") == true, "System prompt injects JARVIS metadata")

        print("\n─── Phase 5: Usage Manager ───")
        let um = UsageManager.shared
        um.resetDailyUsage()
        check(um.dailySpentUSD == 0.0, "Reset zeroes daily spent amount")
        check(um.totalTokensToday == 0, "Reset zeroes total tokens")

        um.recordUsage(provider: "groq", usage: TokenUsage(promptTokens: 1000, completionTokens: 500, totalTokens: 1500))
        check(um.totalTokensToday == 1500, "Tracks recorded tokens")
        check(um.dailySpentUSD > 0.0, "Computes positive USD expenditure")
        check(!um.isBudgetExceeded(), "Within daily budget initially")
        um.resetDailyUsage()

        // ── Results ──
        print("\n══════════════════════════════════════════")
        print("  Results: \(passed) passed, \(failures.count) failed")
        print("══════════════════════════════════════════\n")

        if failures.isEmpty {
            print("✅ ALL TESTS PASSED")
        } else {
            print("❌ SOME TESTS FAILED (\(failures.count))")
        }
    }

    private static func busyWait(ms: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < (ms / 1000.0) {}
    }
}
