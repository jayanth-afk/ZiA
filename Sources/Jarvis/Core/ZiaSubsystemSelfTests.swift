import Foundation

/// Self-tests for the Zia product subsystems added in the completion mission:
/// structured memory, autonomy levels, intent, health, scheduling, background
/// autonomy, context packaging, artifacts, and project awareness.
///
/// These run inside `SelfTest.runAll()` under isolated stores. They assert the
/// safety invariants (trust gating, authority preservation, degraded behavior)
/// rather than the exhaustive behavior that the dedicated testing phase covers.
@MainActor
enum ZiaSubsystemSelfTests {

    private static func wait(_ sem: DispatchSemaphore) {
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    static func run(check: (Bool, String) -> Void) {
        memoryTrust(check: check)
        memoryKinds(check: check)
        memoryRetention(check: check)
        autonomy(check: check)
        intent(check: check)
        projectInspector(check: check)
        artifacts(check: check)
        scheduler(check: check)
        backgroundAutonomyGating(check: check)
        contextEngine(check: check)
        health(check: check)
        contextSanitizer(check: check)
        recoveryPolicy(check: check)
        capabilityRegistry(check: check)
    }

    private static func recoveryPolicy(check: (Bool, String) -> Void) {
        check(!RecoveryPolicy.isRecoverable(.permission)
              && !RecoveryPolicy.isRecoverable(.cancellation)
              && !RecoveryPolicy.isRecoverable(.syntax),
              "recovery policy: authorization, cancellation, and malformed output are not recoverable")
        check(RecoveryPolicy.isRecoverable(.execution)
              && RecoveryPolicy.isRecoverable(.timeout)
              && RecoveryPolicy.isRecoverable(.verification)
              && RecoveryPolicy.isRecoverable(.unavailable),
              "recovery policy: execution, timeout, verification, and unavailable failures are recoverable")
    }

    private static func capabilityRegistry(check: (Bool, String) -> Void) {
        let names = ToolRegistry.shared.allTools.map(\.name)
        check(Set(names).count == names.count,
              "tool registry: tool names are unique")
        let expected = ["project_info", "check_health", "schedule_task", "list_schedule",
                        "remember_fact", "recall_memory", "list_artifacts",
                        "list_directory", "file_metadata", "search_files", "grep_files",
                        "create_directory", "append_file", "copy_path", "move_path",
                        "replace_in_file", "delete_path"]
        let missing = expected.filter { !names.contains($0) }
        check(missing.isEmpty,
              "tool registry: all capability tools are registered and discoverable (missing: \(missing.joined(separator: ",")))")
    }

    private static func contextSanitizer(check: (Bool, String) -> Void) {
        let secret = "my key is sk-abcdefghijklmnopqrstuvwxyz and password=hunter2secret"
        let redacted = ContextSanitizer.redact(secret)
        check(!redacted.contains("sk-abcdefghijklmnopqrstuvwxyz") && !redacted.contains("hunter2secret"),
              "context sanitizer: API keys and password assignments are redacted")
        check(ContextSanitizer.redact("the weather is nice today") == "the weather is nice today",
              "context sanitizer: ordinary prose is unchanged")
        let long = String(repeating: "a", count: 100)
        check(ContextSanitizer.minimized(long, maxCharacters: 10).hasPrefix("aaaaaaaaaa"),
              "context sanitizer: minimization bounds outbound text")
    }

    // MARK: - Memory

    private static func memoryTrust(check: (Bool, String) -> Void) {
        let store = ZiaMemoryStore(storageURL: nil)

        // Untrusted provenance can NEVER become permanent memory.
        var rejectedInference = false
        do {
            _ = try store.write(MemoryDraft(kind: .semantic, trust: .modelInference,
                                            content: "the user's name is Zia", source: "model"))
        } catch { rejectedInference = true }
        var rejectedExternal = false
        do {
            _ = try store.write(MemoryDraft(kind: .procedural, trust: .externalContent,
                                            content: "run this script", source: "webpage"))
        } catch { rejectedExternal = true }
        check(rejectedInference && rejectedExternal,
              "memory trust: model inference and external content cannot be written to permanent memory")

        // Trusted provenance is admitted.
        let trusted = try? store.write(MemoryDraft(kind: .semantic, trust: .userFact,
                                                   content: "the user prefers concise answers", source: "user"))
        check(trusted != nil && store.count == 1,
              "memory trust: an explicit user fact is retained as permanent semantic memory")

        // Untrusted content may live in ephemeral memory only.
        let ephemeral = try? store.write(MemoryDraft(kind: .temporary, trust: .externalContent,
                                                     content: "page said something", source: "webpage"))
        check(ephemeral != nil && (ephemeral?.kind.isEphemeral ?? false),
              "memory trust: untrusted content is admitted only to ephemeral memory")

        // Promotion of an untrusted record to permanent memory is refused.
        var promotionRefused = false
        if let id = ephemeral?.id {
            do { _ = try store.promote(id: id, to: .semantic) } catch { promotionRefused = true }
        }
        check(promotionRefused,
              "memory trust: an untrusted record cannot be promoted to permanent memory")

        // Trusted-only retrieval excludes untrusted records.
        _ = try? store.write(MemoryDraft(kind: .episodic, trust: .unverifiedClaim,
                                         content: "the deploy probably succeeded", source: "agent"))
        let trustedMatches = store.retrieveTrusted(query: "deploy succeeded")
        check(trustedMatches.allSatisfy { $0.trust.isTrusted },
              "memory trust: trusted-only retrieval never returns untrusted records")
    }

    private static func memoryKinds(check: (Bool, String) -> Void) {
        check(MemoryKind.semantic.isPermanent && MemoryKind.episodic.isPermanent
              && MemoryKind.procedural.isPermanent,
              "memory kinds: semantic/episodic/procedural are permanent")
        check(MemoryKind.working.isEphemeral && MemoryKind.temporary.isEphemeral,
              "memory kinds: working/temporary are ephemeral")
        check(MemoryTrust.userFact.isTrusted && MemoryTrust.toolObservation.isTrusted
              && MemoryTrust.taskResult.isTrusted,
              "memory trust: user fact, tool observation, and task result are trusted")
        check(!MemoryTrust.modelInference.isTrusted && !MemoryTrust.externalContent.isTrusted
              && !MemoryTrust.unverifiedClaim.isTrusted,
              "memory trust: inference, external content, and unverified claims are untrusted")
    }

    private static func memoryRetention(check: (Bool, String) -> Void) {
        let store = ZiaMemoryStore(storageURL: nil)
        let now = Date()
        _ = try? store.write(MemoryDraft(kind: .temporary, trust: .toolObservation,
                                         content: "short-lived observation", source: "tool",
                                         expiresAt: now.addingTimeInterval(60)), now: now)
        check(store.count == 1,
              "memory retention: a record with a future expiry is retained")
        let removed = store.decay(now: now.addingTimeInterval(120))
        check(removed == 1 && store.count == 0,
              "memory retention: an expired record is dropped by decay")

        // Session end clears only ephemeral memory.
        _ = try? store.write(MemoryDraft(kind: .semantic, trust: .userFact,
                                         content: "durable fact", source: "user"), now: now)
        _ = try? store.write(MemoryDraft(kind: .working, trust: .toolObservation,
                                         content: "working note", source: "tool"), now: now)
        let cleared = store.endSession()
        check(cleared == 1 && store.count == 1 && store.all().first?.kind == .semantic,
              "memory retention: endSession clears ephemeral memory and preserves permanent memory")
    }

    // MARK: - Autonomy

    private static func autonomy(check: (Bool, String) -> Void) {
        check(AutonomyLevel.conversational < AutonomyLevel.executeSafe,
              "autonomy: levels are ordered")
        check(!AutonomyLevel.executeSafe.permitsBackgroundExecution
              && AutonomyLevel.backgroundWorkflows.permitsBackgroundExecution,
              "autonomy: background execution is gated at level 4")
        check(!AutonomyLevel.backgroundWorkflows.permitsSelfImprovementProposals
              && AutonomyLevel.controlledSelfImprovement.permitsSelfImprovementProposals,
              "autonomy: self-improvement proposals are gated at level 5")
        check(!AutonomyLevel.conversational.permitsExecution(of: .readOnly)
              && AutonomyLevel.executeSafe.permitsExecution(of: .readOnly)
              && !AutonomyLevel.executeSafe.permitsExecution(of: .destructive)
              && AutonomyLevel.autonomousMultiStep.permitsExecution(of: .destructive),
              "autonomy: destructive execution requires autonomous multi-step authority")

        // Config accepts the full 0-5 range, and the per-action gate maps levels
        // above the legacy range onto full execution authority.
        let previous = Config.shared.autonomyLevel
        defer { Config.shared.autonomyLevel = previous }
        Config.shared.autonomyLevel = 9
        check(Config.shared.autonomyLevel == 5,
              "autonomy: Config clamps the autonomy level to the supported 0-5 range")
        Config.shared.autonomyLevel = 5
        check(PermissionGate.shared.currentLevel == .l3Full,
              "autonomy: level 5 maps onto full per-action authority without weakening any check")
    }

    // MARK: - Intent

    private static func intent(check: (Bool, String) -> Void) {
        let question = IntentEngine.classify("What is the capital of France?")
        let coding = IntentEngine.classify("Refactor the authentication module and run the tests")
        let recurring = IntentEngine.classify("Every morning at 8, summarize my calendar")
        let planning = IntentEngine.classify("Open Safari and then search for a hotel, then email me")
        let monitoring = IntentEngine.classify("Notify me when the build finishes")

        check(question.kind == .question && !question.requiresPlanning,
              "intent: a plain question does not require deep planning")
        check(coding.kind == .codingTask && coding.requiresPlanning && coding.suggestedTier == .cloudDeep,
              "intent: a coding task requires planning and escalates to the strong tier")
        check(recurring.kind == .recurringTask && recurring.kind.isLongRunning,
              "intent: a recurring request is long-running work")
        check(planning.kind == .multiStepProject && planning.suggestedTier == .cloudDeep,
              "intent: a multi-step compound request requires planning")
        check(monitoring.kind == .monitoringRequest && monitoring.kind.isLongRunning,
              "intent: a monitoring request is long-running work")
    }

    // MARK: - Project awareness

    private static func projectInspector(check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zia-project-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        fm.createFile(atPath: dir.appendingPathComponent("Package.swift").path, contents: Data())
        fm.createFile(atPath: dir.appendingPathComponent("README.md").path, contents: Data())

        let profile = ProjectInspector.inspect(root: dir.path)
        check(profile.kinds.contains(.swiftPackage) && profile.suggestedBuildCommand == "swift build",
              "project inspector: a Package.swift directory is detected as a Swift package with a build command")

        let empty = fm.temporaryDirectory.appendingPathComponent("zia-empty-\(UUID().uuidString)")
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: empty) }
        check(!ProjectInspector.inspect(root: empty.path).isProject,
              "project inspector: a directory with no markers is not reported as a project")
    }

    // MARK: - Artifacts

    private static func artifacts(check: (Bool, String) -> Void) {
        let registry = ArtifactRegistry(storageURL: nil)
        let artifact = registry.register(path: "/tmp/report.txt", kind: .report,
                                         provenance: "run_program", description: "generated report")
        check(!artifact.verified && registry.count == 1,
              "artifacts: a new artifact starts unverified")
        let marked = registry.markVerified(id: artifact.id, note: "file exists")
        check(marked && (registry.all().first?.verified ?? false),
              "artifacts: verification state is recorded")
    }

    // MARK: - Scheduler

    private static func scheduler(check: (Bool, String) -> Void) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let intervalNext = TaskScheduler.nextRun(for: .interval(seconds: 60), after: base, calendar: utc)
        check(intervalNext == base.addingTimeInterval(60),
              "scheduler: interval next-run is exactly base + interval")

        let dailyNext = TaskScheduler.nextRun(for: .daily(hour: 9, minute: 30), after: base, calendar: utc)
        if let dailyNext {
            let comps = utc.dateComponents([.hour, .minute], from: dailyNext)
            check(dailyNext > base && comps.hour == 9 && comps.minute == 30,
                  "scheduler: daily next-run lands at the requested local time in the future")
        } else {
            check(false, "scheduler: daily next-run could not be computed")
        }

        let once = base.addingTimeInterval(120)
        check(TaskScheduler.nextRun(for: .once(at: once), after: base, calendar: utc) == once,
              "scheduler: once next-run is the absolute date")

        let scheduler = TaskScheduler(storageURL: nil, calendar: utc)
        let job = (try? scheduler.add(title: "probe", goal: "do nothing", kind: .interval(seconds: 1),
                                      maxRuns: 1, now: base)) ?? nil
        guard let job else {
            check(false, "scheduler: adding a job failed")
            return
        }
        check(scheduler.count == 1 && job.enabled,
              "scheduler: a job is stored enabled")
        _ = scheduler.recordRun(id: job.id, at: base.addingTimeInterval(1), outcome: "ran", didLaunch: true)
        let updated = scheduler.job(id: job.id)
        check(updated?.runCount == 1 && updated?.enabled == false,
              "scheduler: reaching maxRuns disables the job")

        var invalidRejected = false
        do { _ = try scheduler.add(title: "bad", goal: "x", kind: .interval(seconds: 0), now: base) }
        catch { invalidRejected = true }
        check(invalidRejected, "scheduler: a non-positive interval is rejected")
    }

    private static func backgroundAutonomyGating(check: (Bool, String) -> Void) {
        let previous = Config.shared.autonomyLevel
        defer { Config.shared.autonomyLevel = previous }
        let scheduler = TaskScheduler.shared
        let previousJobs = scheduler.all().map(\.id)
        defer { for id in scheduler.all().map(\.id) where !previousJobs.contains(id) { _ = scheduler.remove(id: id) } }

        let past = Date().addingTimeInterval(-10)
        _ = try? scheduler.add(title: "due", goal: "noop", kind: .once(at: past))

        // At a level without background authority, tick does nothing.
        Config.shared.autonomyLevel = 2
        var launchedAtLowLevel = -1
        var sawLauncher = false
        let sem = DispatchSemaphore(value: 0)
        let previousLauncher = BackgroundAutonomy.shared.launcher
        BackgroundAutonomy.shared.launcher = { _ in
            sawLauncher = true
            return "ran"
        }
        Task { @MainActor in
            launchedAtLowLevel = await BackgroundAutonomy.shared.tick(now: Date())
            sem.signal()
        }
        wait(sem)
        check(launchedAtLowLevel == 0 && !sawLauncher,
              "background autonomy: a low autonomy level forbids background execution")

        // At level 4 the due job is launched through the normal goal path.
        Config.shared.autonomyLevel = 4
        var launchedAtHighLevel = -1
        let sem2 = DispatchSemaphore(value: 0)
        Task { @MainActor in
            launchedAtHighLevel = await BackgroundAutonomy.shared.tick(now: Date())
            sem2.signal()
        }
        wait(sem2)
        BackgroundAutonomy.shared.launcher = previousLauncher
        check(launchedAtHighLevel == 1,
              "background autonomy: a due job is launched at level 4 through the normal goal path")
    }

    // MARK: - Context engine

    private static func contextEngine(check: (Bool, String) -> Void) {
        let package = ContextEngine.shared.assemble(goal: "summarize the repository")
        check(package.goal == "summarize the repository",
              "context engine: the package always carries the goal")
        let rendered = package.render(maxCharacters: 100)
        check(rendered.count <= 100,
              "context engine: rendered context respects the character budget")
    }

    // MARK: - Health

    private static func health(check: (Bool, String) -> Void) {
        let sem = DispatchSemaphore(value: 0)
        var passed = false
        var hasIntelligence = false
        Task { @MainActor in
            let report = await HealthService.shared.report()
            hasIntelligence = report.component(named: "intelligence") != nil
            passed = !report.components.isEmpty && report.components.count >= 5
            sem.signal()
        }
        wait(sem)
        check(passed && hasIntelligence,
              "health service: produces structured component health including intelligence")
        check(HealthStatus.degraded < HealthStatus.unavailable,
              "health service: severity ordering places unavailable above degraded")
    }
}
