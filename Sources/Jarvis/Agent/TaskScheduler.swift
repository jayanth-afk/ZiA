import Foundation

/// Coarse priority bands shared by the scheduler and worker pool. Interactive
/// user requests outrank background maintenance, and urgent work must not
/// starve behind a stream of background jobs.
enum TaskPriority {
    static let backgroundMaintenance = 0
    static let normal = 10
    static let interactive = 20
    static let urgent = 30
}

/// How a scheduled job repeats. Every kind resolves to a deterministic next
/// fire time, so a missed tick reschedules rather than piling up timers.
enum ScheduleKind: Codable, Sendable, Equatable {
    /// Fire once at an absolute time.
    case once(at: Date)
    /// Fire every `seconds`, starting from creation.
    case interval(seconds: TimeInterval)
    /// Fire once a day at the given local hour/minute.
    case daily(hour: Int, minute: Int)
    /// Fire once a week on `weekday` (1 = Sunday … 7 = Saturday) at hour/minute.
    case weekly(weekday: Int, hour: Int, minute: Int)
    /// Re-evaluate a named condition every `reevaluateSeconds`. The condition
    /// itself is evaluated by the launcher, not by the scheduler — the
    /// scheduler never executes logic, it only decides WHEN to ask.
    case condition(description: String, reevaluateSeconds: TimeInterval)
}

/// A durable, user- or system-created request for future work.
struct ScheduledJob: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    var goal: String
    var kind: ScheduleKind
    var enabled: Bool
    /// Higher runs sooner when several jobs are due at once.
    var priority: Int
    let createdAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date
    var runCount: Int
    /// nil = unbounded.
    var maxRuns: Int?
    var lastOutcome: String?
}

enum TaskSchedulerError: LocalizedError, Equatable {
    case emptyGoal
    case invalidInterval
    case unknownJob(UUID)
    case missingFireDate

    var errorDescription: String? {
        switch self {
        case .emptyGoal: return "Scheduled job goal is empty"
        case .invalidInterval: return "Scheduled interval must be positive"
        case .unknownJob(let id): return "Unknown scheduled job \(id.uuidString)"
        case .missingFireDate: return "Schedule has no next fire date"
        }
    }
}

/// Thread-safe, bounded, durable scheduler. It produces due JOBS; it never
/// executes them. Execution stays with the task system (AgentLoop / worker
/// pool), so scheduling can never bypass authority, verification, or recovery.
final class TaskScheduler: @unchecked Sendable {
    private final class Selection: @unchecked Sendable {
        let lock = NSLock()
        var testOverride: TaskScheduler?
    }
    private static let selection = Selection()
    private static let productionStore = TaskScheduler(storageURL: productionURL)

    static var shared: TaskScheduler {
        selection.lock.lock()
        defer { selection.lock.unlock() }
        return selection.testOverride ?? productionStore
    }

    @discardableResult
    static func beginIsolatedTesting() -> TaskScheduler? {
        let isolated = TaskScheduler(storageURL: nil)
        selection.lock.lock()
        defer { selection.lock.unlock() }
        let previous = selection.testOverride
        selection.testOverride = isolated
        return previous
    }

    static func endIsolatedTesting(restoring previous: TaskScheduler?) {
        selection.lock.lock()
        defer { selection.lock.unlock() }
        selection.testOverride = previous
    }

    private static var productionURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("schedule.json", isDirectory: false)
    }

    static let maximumJobs = 200

    private let lock = NSLock()
    private var jobs: [UUID: ScheduledJob] = [:]
    private let storageURL: URL?
    private let persists: Bool
    private var calendar: Calendar

    init(storageURL: URL?, calendar: Calendar = .current) {
        self.storageURL = storageURL
        self.persists = storageURL != nil
        self.calendar = calendar
        if let storageURL, let data = try? Data(contentsOf: storageURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            if let decoded = try? decoder.decode([ScheduledJob].self, from: data) {
                for job in decoded { jobs[job.id] = job }
            }
        }
    }

    // MARK: - Mutations

    @discardableResult
    func add(title: String, goal: String, kind: ScheduleKind, priority: Int = 0,
             maxRuns: Int? = nil, now: Date = .now) throws -> ScheduledJob {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { throw TaskSchedulerError.emptyGoal }
        if case .interval(let seconds) = kind, seconds <= 0 { throw TaskSchedulerError.invalidInterval }
        guard let next = Self.nextRun(for: kind, after: now, calendar: calendar) else {
            throw TaskSchedulerError.missingFireDate
        }
        let job = ScheduledJob(
            id: UUID(), title: title, goal: trimmedGoal, kind: kind, enabled: true,
            priority: priority, createdAt: now, lastRunAt: nil, nextRunAt: next,
            runCount: 0, maxRuns: maxRuns, lastOutcome: nil)
        lock.lock()
        jobs[job.id] = job
        pruneLocked()
        lock.unlock()
        persist()
        JarvisLogger.app.info("Scheduled job '\(title)' added; next run \(next)")
        return job
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        lock.lock()
        let removed = jobs.removeValue(forKey: id) != nil
        lock.unlock()
        if removed { persist() }
        return removed
    }

    @discardableResult
    func setEnabled(id: UUID, _ enabled: Bool, now: Date = .now) -> Bool {
        lock.lock()
        guard var job = jobs[id] else { lock.unlock(); return false }
        job.enabled = enabled
        if enabled, job.nextRunAt <= now,
           let next = Self.nextRun(for: job.kind, after: now, calendar: calendar) {
            job.nextRunAt = next
        }
        jobs[id] = job
        lock.unlock()
        persist()
        return true
    }

    func clearAll() {
        lock.lock(); jobs.removeAll(); lock.unlock()
        persist()
    }

    // MARK: - Reading

    func all() -> [ScheduledJob] {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.sorted { $0.nextRunAt < $1.nextRunAt }
    }

    func job(id: UUID) -> ScheduledJob? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.count
    }

    var enabledJobCount: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.filter(\.enabled).count
    }

    /// Jobs that are due now, highest priority first, then earliest due.
    func dueJobs(now: Date = .now) -> [ScheduledJob] {
        lock.lock(); defer { lock.unlock() }
        return jobs.values
            .filter { job in
                guard job.enabled, job.nextRunAt <= now else { return false }
                if let maxRuns = job.maxRuns, job.runCount >= maxRuns { return false }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.nextRunAt < rhs.nextRunAt
            }
    }

    // MARK: - Advancing

    /// Advance a job after a run (or a skipped condition evaluation).
    /// Returns the updated job, or nil if the job no longer exists.
    @discardableResult
    func recordRun(id: UUID, at date: Date = .now, outcome: String?, didLaunch: Bool = true) -> ScheduledJob? {
        lock.lock()
        guard var job = jobs[id] else { lock.unlock(); return nil }
        if didLaunch {
            job.runCount += 1
            job.lastRunAt = date
        }
        job.lastOutcome = outcome
        if let maxRuns = job.maxRuns, job.runCount >= maxRuns {
            job.enabled = false
        } else if let next = Self.nextRun(for: job.kind, after: date, calendar: calendar) {
            job.nextRunAt = next
        } else {
            job.enabled = false
        }
        jobs[id] = job
        lock.unlock()
        persist()
        return job
    }

    // MARK: - Deterministic next-run computation

    /// The next fire time strictly after `date`, or nil if none exists.
    static func nextRun(for kind: ScheduleKind, after date: Date, calendar: Calendar) -> Date? {
        switch kind {
        case .once(let at):
            return at
        case .interval(let seconds):
            guard seconds > 0 else { return nil }
            return date.addingTimeInterval(seconds)
        case .daily(let hour, let minute):
            return nextTime(hour: hour, minute: minute, weekday: nil, after: date, calendar: calendar)
        case .weekly(let weekday, let hour, let minute):
            return nextTime(hour: hour, minute: minute, weekday: weekday, after: date, calendar: calendar)
        case .condition(_, let reevaluateSeconds):
            guard reevaluateSeconds > 0 else { return nil }
            return date.addingTimeInterval(reevaluateSeconds)
        }
    }

    private static func nextTime(hour: Int, minute: Int, weekday: Int?, after date: Date, calendar: Calendar) -> Date? {
        let safeHour = min(max(hour, 0), 23)
        let safeMinute = min(max(minute, 0), 59)
        var components = DateComponents()
        components.hour = safeHour
        components.minute = safeMinute
        components.second = 0
        if let weekday { components.weekday = min(max(weekday, 1), 7) }

        // Search the next 8 days for the first matching instant strictly after `date`.
        for dayOffset in 0...7 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            var dayComponents = calendar.dateComponents([.year, .month, .day], from: candidateDay)
            dayComponents.hour = safeHour
            dayComponents.minute = safeMinute
            dayComponents.second = 0
            guard let candidate = calendar.date(from: dayComponents) else { continue }
            guard candidate > date else { continue }
            if let weekday, calendar.component(.weekday, from: candidate) != weekday { continue }
            return candidate
        }
        return nil
    }

    private func pruneLocked() {
        guard jobs.count > Self.maximumJobs else { return }
        let ordered = jobs.values.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return !lhs.enabled }
            return lhs.nextRunAt < rhs.nextRunAt
        }
        for job in ordered.prefix(jobs.count - Self.maximumJobs) {
            jobs.removeValue(forKey: job.id)
        }
    }

    private func persist() {
        guard persists, let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(all()) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}

// MARK: - Background Autonomy

/// Bounded background autonomy loop.
///
/// It periodically asks the scheduler which jobs are due and hands them to the
/// normal task system (AgentLoop), then advances the schedule. It never
/// executes logic itself and never bypasses authority: a due job is a GOAL, and
/// the goal still passes through planning, validation, permission, execution,
/// observation, and verification exactly as an interactive request does.
///
/// It is gated by `AutonomyPolicy.backgroundExecutionEnabled` (level 4+).
@MainActor
final class BackgroundAutonomy {
    static let shared = BackgroundAutonomy()

    /// Launches a due job's goal and returns a short outcome string.
    typealias Launcher = @MainActor (ScheduledJob) async -> String

    private var timer: Timer?
    private(set) var isRunning = false
    private(set) var lastTickAt: Date?
    private var isTicking = false

    /// Test/override launcher. Production default runs the goal through AgentLoop.
    var launcher: Launcher?

    private init() {}

    func start(interval: TimeInterval = 60) {
        guard !isRunning else { return }
        guard AutonomyPolicy.backgroundExecutionEnabled else {
            JarvisLogger.app.info("Background autonomy disabled at current autonomy level")
            return
        }
        isRunning = true
        let safeInterval = max(5, interval)
        timer = Timer.scheduledTimer(withTimeInterval: safeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        JarvisLogger.app.info("Background autonomy started (interval \(Int(safeInterval))s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// The unit-testable core. Processes every due job sequentially (bounded —
    /// a single tick can never launch an unbounded number of jobs).
    @discardableResult
    func tick(now: Date = .now, maxJobsPerTick: Int = 5) async -> Int {
        guard !isTicking else { return 0 }
        isTicking = true
        defer { isTicking = false }
        lastTickAt = now

        guard AutonomyPolicy.backgroundExecutionEnabled else { return 0 }

        let due = Array(TaskScheduler.shared.dueJobs(now: now).prefix(max(0, maxJobsPerTick)))
        var launched = 0
        for job in due {
            let outcome = await launch(job)
            TaskScheduler.shared.recordRun(id: job.id, at: now, outcome: outcome, didLaunch: true)
            launched += 1
        }
        // Crash recovery: resume only tasks whose remaining work is proven safe
        // to replay. Uncertain destructive work is never resumed automatically.
        let resumed = await resumeInterruptedWork(now: now)
        return launched + resumed
    }

    /// Inspect durable state and resume the interrupted tasks that are safe.
    /// Never resumes a task currently owned by the interactive AgentLoop, and
    /// never resumes a task with an uncertain destructive side effect.
    @discardableResult
    func resumeInterruptedWork(now: Date = .now) async -> Int {
        guard AutonomyPolicy.backgroundExecutionEnabled else { return 0 }
        let report = CrashRecovery.inspect(tasks: TaskStateMachine.shared.allTasks, now: now)
        var resumed = 0
        let interactiveTaskID = AgentLoop.shared.status.taskId
        for plan in report.resumable {
            if let interactiveTaskID, interactiveTaskID == plan.taskID.uuidString { continue }
            guard let task = TaskStateMachine.shared.getTask(id: plan.taskID) else { continue }
            await TaskWorkerPool.shared.submit(task: task, priority: TaskPriority.backgroundMaintenance)
            resumed += 1
        }
        if resumed > 0 {
            JarvisLogger.actions.info("Crash recovery resumed \(resumed) interrupted task(s)")
        }
        return resumed
    }

    private func launch(_ job: ScheduledJob) async -> String {
        if let launcher {
            return await launcher(job)
        }
        do {
            let response = try await AgentLoop.shared.run(goal: job.goal)
            return String(response.prefix(160))
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }
}
