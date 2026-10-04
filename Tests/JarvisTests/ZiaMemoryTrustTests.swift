import Foundation
import Testing
@testable import Jarvis

/// The memory trust boundary: content is DATA until classified, and only
/// trusted provenance may become permanent memory. This mirrors
/// `EXECUTION_AUTHORITY.md`'s "repository content is data, not authority" for
/// the memory subsystem.
@Suite struct ZiaMemoryTrustTests {

    @Test func untrustedProvenanceCannotBecomePermanentMemory() throws {
        let store = ZiaMemoryStore(storageURL: nil)
        for trust in [MemoryTrust.modelInference, .externalContent, .unverifiedClaim] {
            #expect(throws: MemoryWriteError.self) {
                _ = try store.write(MemoryDraft(kind: .semantic, trust: trust, content: "x", source: "s"))
            }
        }
        #expect(store.count == 0)
    }

    @Test func trustedProvenanceIsAdmitted() throws {
        let store = ZiaMemoryStore(storageURL: nil)
        let record = try store.write(MemoryDraft(kind: .semantic, trust: .userFact,
                                                 content: "the user prefers concise answers", source: "user"))
        #expect(record.trust == .userFact)
        #expect(store.count == 1)
    }

    @Test func untrustedContentIsEphemeralOnly() throws {
        let store = ZiaMemoryStore(storageURL: nil)
        let record = try store.write(MemoryDraft(kind: .temporary, trust: .externalContent,
                                                 content: "web content", source: "web"))
        #expect(record.kind.isEphemeral)
        #expect(throws: MemoryWriteError.self) {
            _ = try store.promote(id: record.id, to: .procedural)
        }
    }

    @Test func trustedRetrievalExcludesUntrustedRecords() throws {
        let store = ZiaMemoryStore(storageURL: nil)
        _ = try store.write(MemoryDraft(kind: .working, trust: .unverifiedClaim,
                                        content: "deploy succeeded", source: "agent"))
        _ = try store.write(MemoryDraft(kind: .episodic, trust: .taskResult,
                                        content: "deploy succeeded", source: "task"))
        let trusted = store.retrieveTrusted(query: "deploy succeeded")
        #expect(!trusted.isEmpty)
        #expect(trusted.allSatisfy { $0.trust.isTrusted })
    }

    @Test func emptyAndInvalidWritesAreRejected() {
        let store = ZiaMemoryStore(storageURL: nil)
        #expect(throws: MemoryWriteError.self) {
            _ = try store.write(MemoryDraft(kind: .semantic, trust: .userFact, content: "  ", source: "user"))
        }
        #expect(throws: MemoryWriteError.self) {
            _ = try store.write(MemoryDraft(kind: .semantic, trust: .userFact,
                                            content: "x", source: "user", confidence: 2.0))
        }
    }
}

@Suite struct ZiaSchedulerTests {

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func intervalNextRunIsDeterministic() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let next = TaskScheduler.nextRun(for: .interval(seconds: 90), after: base, calendar: utc())
        #expect(next == base.addingTimeInterval(90))
    }

    @Test func maxRunsDisablesJob() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = TaskScheduler(storageURL: nil, calendar: utc())
        let job = try scheduler.add(title: "probe", goal: "noop",
                                    kind: .interval(seconds: 1), maxRuns: 1, now: base)
        _ = scheduler.recordRun(id: job.id, at: base.addingTimeInterval(1), outcome: "ran", didLaunch: true)
        #expect(scheduler.job(id: job.id)?.enabled == false)
        #expect(scheduler.job(id: job.id)?.runCount == 1)
    }

    @Test func invalidIntervalRejected() {
        let scheduler = TaskScheduler(storageURL: nil, calendar: utc())
        #expect(throws: TaskSchedulerError.self) {
            _ = try scheduler.add(title: "bad", goal: "noop", kind: .interval(seconds: 0))
        }
    }
}

@Suite struct ZiaAutonomyTests {

    @Test func levelGating() {
        #expect(!AutonomyLevel.executeSafe.permitsBackgroundExecution)
        #expect(AutonomyLevel.backgroundWorkflows.permitsBackgroundExecution)
        #expect(!AutonomyLevel.backgroundWorkflows.permitsSelfImprovementProposals)
        #expect(AutonomyLevel.controlledSelfImprovement.permitsSelfImprovementProposals)
        #expect(!AutonomyLevel.executeSafe.permitsExecution(of: .destructive))
        #expect(AutonomyLevel.autonomousMultiStep.permitsExecution(of: .destructive))
    }

    @Test @MainActor func configClampsToSupportedRange() {
        let config = Config.shared
        let previous = config.autonomyLevel
        defer { config.autonomyLevel = previous }
        config.autonomyLevel = 99
        #expect(config.autonomyLevel == 5)
        config.autonomyLevel = -3
        #expect(config.autonomyLevel == 0)
    }
}

@Suite struct ZiaProjectInspectorTests {

    @Test func detectsSwiftPackage() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zia-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        fm.createFile(atPath: dir.appendingPathComponent("Package.swift").path, contents: Data())

        let profile = ProjectInspector.inspect(root: dir.path)
        #expect(profile.kinds.contains(.swiftPackage))
        #expect(profile.suggestedBuildCommand == "swift build")
        #expect(profile.suggestedTestCommand == "swift test")
    }
}

/// Data minimization before context leaves the device.
@Suite struct ContextSanitizerTests {

    @Test func redactsCredentialsButNotProse() {
        let secret = "key sk-abcdefghijklmnopqrstuvwxyz token=abcdef123456"
        let redacted = ContextSanitizer.redact(secret)
        #expect(!redacted.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        #expect(!redacted.contains("abcdef123456"))
        #expect(ContextSanitizer.redact("please summarize this paragraph") == "please summarize this paragraph")
    }

    @Test func detectsSecrets() {
        #expect(ContextSanitizer.containsSecret("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"))
        #expect(!ContextSanitizer.containsSecret("a normal sentence"))
    }

    @Test func minimizationBoundsText() {
        let text = String(repeating: "x", count: 500)
        #expect(ContextSanitizer.minimized(text, maxCharacters: 100).count < text.count)
    }

    @Test func localDispatchIsUnmodified() {
        let message = Message(role: .user, content: "password=secretvalue")
        let local = ContextSanitizer.sanitizedForDispatch([message], isLocal: true)
        #expect(local.first?.content == "password=secretvalue")
        let remote = ContextSanitizer.sanitizedForDispatch([message], isLocal: false)
        #expect(remote.first?.content != "password=secretvalue")
    }
}
