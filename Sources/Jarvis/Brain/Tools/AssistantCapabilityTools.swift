import Foundation

// MARK: - Code intelligence

/// Deterministic symbol/definition search.
struct FindSymbolTool: JarvisTool {
    let name = "find_symbol"
    let description = "Finds code definitions (func/class/struct/enum/protocol/…) whose name contains a substring, under a directory. Read-only, bounded."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "root", kind: .string, required: false, description: "Directory to search (default: current directory)"),
        ToolParameterSpec(name: "name", kind: .string, required: false, description: "Substring of the symbol name"),
        ToolParameterSpec(name: "max_results", kind: .int, required: false, description: "Maximum results (default 50)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let root = (arguments["root"] as? String) ?? FileManager.default.currentDirectoryPath
        let name = (arguments["name"] as? String) ?? ""
        let maxResults = min(max((arguments["max_results"] as? Int) ?? 50, 1), 200)
        let symbols = CodeIntelligence.findSymbols(root: root, name: name, maxResults: maxResults)
        guard !symbols.isEmpty else {
            return ToolResult(success: true, output: "No matching definitions.", metadata: ["count": "0"])
        }
        let lines = symbols.map { "\($0.file):\($0.line): \($0.kind) \($0.name)" }
        return ToolResult(success: true, output: lines.joined(separator: "\n"),
                          metadata: ["count": String(symbols.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("cannot re-read source tree")
    }
}

/// Deterministic TODO/FIXME discovery.
struct FindMarkersTool: JarvisTool {
    let name = "find_markers"
    let description = "Finds unfinished-work markers (TODO/FIXME/HACK/XXX) in source files under a directory. Read-only, bounded."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "root", kind: .string, required: false, description: "Directory to search (default: current directory)"),
        ToolParameterSpec(name: "markers", kind: .string, required: false, description: "Comma-separated markers (default TODO,FIXME,HACK,XXX)"),
        ToolParameterSpec(name: "max_results", kind: .int, required: false, description: "Maximum results (default 100)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let root = (arguments["root"] as? String) ?? FileManager.default.currentDirectoryPath
        let markers = (arguments["markers"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let maxResults = min(max((arguments["max_results"] as? Int) ?? 100, 1), 500)
        let found = CodeIntelligence.findMarkers(root: root, markers: markers ?? CodeIntelligence.defaultMarkers,
                                                 maxResults: maxResults)
        guard !found.isEmpty else {
            return ToolResult(success: true, output: "No markers found.", metadata: ["count": "0"])
        }
        let lines = found.map { "\($0.file):\($0.line): [\($0.marker)] \($0.text)" }
        return ToolResult(success: true, output: lines.joined(separator: "\n"),
                          metadata: ["count": String(found.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("cannot re-read source tree")
    }
}

/// Structured list of changed files (working tree vs index).
struct ChangedFilesTool: JarvisTool {
    let name = "changed_files"
    let description = "Lists files with uncommitted changes via structured git (no shell). Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "working_directory", kind: .string, required: false, description: "Repository directory (default: current)")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let directory = arguments["working_directory"] as? String
        let output = try await ShellExecutor.shared.executeStructured(
            executable: "git", arguments: ["diff", "--name-only"],
            workingDirectory: directory, timeoutSeconds: 15.0, requestedImpact: .readOnly)
        guard output.exitCode == 0 else {
            throw JarvisError.actionFailed(action: name,
                                           reason: "git diff exited with code \(output.exitCode) (not a repository?)")
        }
        let files = output.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return ToolResult(
            success: true,
            output: files.isEmpty ? "No uncommitted changes." : files.joined(separator: "\n"),
            metadata: ["count": String(files.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("git did not answer")
    }
}

// MARK: - Self-awareness & capabilities

/// Lists Zia's capability surface.
struct CapabilitiesTool: JarvisTool {
    let name = "capabilities"
    let description = "Lists what Zia can currently do (tools and subsystems). Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = []

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let summary = await MainActor.run { CapabilityRegistry.capabilitySummary() }
        return ToolResult(success: true, output: summary,
                          metadata: ["count": String(ToolRegistry.shared.allTools.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("capability registry did not answer")
    }
}

/// A state-derived self-report (health, providers, tasks, schedule, project).
struct SelfStatusTool: JarvisTool {
    let name = "self_status"
    let description = "Reports Zia's real current state: health, providers, running tasks, schedule, artifacts, project, degraded capabilities. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = []

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let report = await CapabilityRegistry.selfAwarenessReport()
        return ToolResult(success: true, output: report, metadata: [:])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("self-report unavailable")
    }
}

/// Interrupted-work recovery report.
struct RecoveryStatusTool: JarvisTool {
    let name = "recovery_status"
    let description = "Reports interrupted/failed tasks found in durable state and what Zia will do about each (resume/verify/confirm). Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = []

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let report = CrashRecovery.inspect(tasks: TaskStateMachine.shared.allTasks)
        return ToolResult(success: true, output: report.summary,
                          metadata: ["count": String(report.plans.count),
                                     "resumable": String(report.resumable.count)])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("task state did not answer")
    }
}

// MARK: - Preferences

/// Reads the user's preferences.
struct GetPreferencesTool: JarvisTool {
    let name = "get_preferences"
    let description = "Reports the user's stored preferences. Read-only."
    let impact: PermissionGate.ActionImpact = .readOnly
    let parameterSpec: [ToolParameterSpec] = []

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        let summary = await MainActor.run { PreferenceStore.shared.summary() }
        return ToolResult(success: true, output: summary, metadata: [:])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        observed.isAvailable ? .passed : .unavailable("preference store did not answer")
    }
}

/// Sets an explicit user preference.
struct SetPreferenceTool: JarvisTool {
    let name = "set_preference"
    let description = "Sets an explicit user preference (verbosity, style, localOnly, notifyOnCompletion, notifyOnFailure, preferredLanguage, confirmation, preferredProviders, backgroundWork). Explicit preferences cannot be overridden by inference."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "key", kind: .string, required: true, description: "Preference key"),
        ToolParameterSpec(name: "value", kind: .string, required: true, description: "Preference value")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let keyText = arguments["key"] as? String,
              let value = arguments["value"] as? String,
              let key = PreferenceKey(rawValue: keyText) else {
            throw JarvisError.actionFailed(action: name,
                                           reason: "Requires a valid 'key' (\(PreferenceKey.allCases.map(\.rawValue).joined(separator: ", "))) and 'value'")
        }
        let updated = try await MainActor.run {
            try PreferenceStore.shared.setExplicit(key, value: value)
        }
        return ToolResult(success: true, output: "Preference \(key.rawValue) set to \(value).",
                          sideEffects: ["preference_set"],
                          metadata: ["key": key.rawValue, "updated": "\(updated.updatedAt.timeIntervalSince1970)"])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let key = expected.metadata["key"] else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no key recorded")
        }
        let explicit = await MainActor.run { PreferenceStore.shared.current.explicitKeys.contains(key) }
        return ObservationResult(observations: ["explicit": explicit ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("preference store did not answer") }
        guard observed.observations["explicit"] == "true" else {
            return .failed("preference was not stored as explicit")
        }
        return .passed(reason: "preference stored explicitly")
    }
}

// MARK: - Patch engine

/// Applies a first-class file patch with optional preview and stale-file
/// detection. Prefers an exact replacement; records a backup for rollback.
struct PatchFileTool: JarvisTool {
    let name = "patch_file"
    let description = "Applies an exact text patch to a file with optional stale-file detection (expected_sha256) and a rollback backup. Set dry_run=1 to preview without writing. Default replaces the first occurrence."
    let impact: PermissionGate.ActionImpact = .safeMutation
    let parameterSpec: [ToolParameterSpec] = [
        ToolParameterSpec(name: "path", kind: .string, required: true, description: "File to patch"),
        ToolParameterSpec(name: "find", kind: .string, required: true, description: "Exact text to find"),
        ToolParameterSpec(name: "replace", kind: .string, required: true, description: "Replacement text"),
        ToolParameterSpec(name: "all", kind: .int, required: false, description: "1 to replace every occurrence (default: first only)"),
        ToolParameterSpec(name: "reason", kind: .string, required: false, description: "Why this patch is being applied"),
        ToolParameterSpec(name: "expected_sha256", kind: .string, required: false, description: "SHA-256 of the file the patch was authored against (stale detection)"),
        ToolParameterSpec(name: "dry_run", kind: .int, required: false, description: "1 to preview without writing")
    ]

    func execute(arguments: [String: any Sendable]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String,
              let find = arguments["find"] as? String, !find.isEmpty,
              let replace = arguments["replace"] as? String else {
            throw JarvisError.actionFailed(action: name, reason: "Requires non-empty 'path', 'find', and 'replace'")
        }
        let all = (arguments["all"] as? Int) == 1
        let dryRun = (arguments["dry_run"] as? Int) == 1
        let reason = (arguments["reason"] as? String) ?? "unspecified"
        let expectedHash = arguments["expected_sha256"] as? String

        let patch = FilePatch(
            target: path, find: find, replacement: replace,
            scope: all ? .allOccurrences : .firstOccurrence,
            reason: reason, expectedOldSHA256: expectedHash)

        let preview = try await MainActor.run { try PatchEngine.preview(patch) }
        if dryRun {
            return ToolResult(
                success: true, output: "Preview: \(preview.summary) (\(preview.replacements) replacement(s))",
                metadata: ["dryRun": "true", "replacements": String(preview.replacements),
                           "path": preview.target, "find": find, "countBefore": String(preview.replacements)])
        }
        let result = try await MainActor.run { try PatchEngine.apply(patch) }
        return ToolResult(
            success: true,
            output: "Patched \(result.preview.target): \(result.preview.replacements) replacement(s); " +
                    (result.backupPath.map { "backup at \($0)" } ?? "no backup needed"),
            sideEffects: ["file_patched"],
            metadata: ["path": result.preview.target, "find": find,
                       "replacements": String(result.preview.replacements),
                       "countBefore": String(result.preview.replacements),
                       "backup": result.backupPath ?? "",
                       "beforeSHA256": result.preview.beforeSHA256])
    }

    func observe() async throws -> ObservationResult {
        ObservationResult(observations: ["status": "completed"], isAvailable: true)
    }

    func observe(expected: ToolResult) async throws -> ObservationResult {
        guard let path = expected.metadata["path"], let find = expected.metadata["find"],
              let replacements = Int(expected.metadata["replacements"] ?? ""),
              let countBefore = Int(expected.metadata["countBefore"] ?? "") else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "no patch metadata recorded")
        }
        guard let after = FileSystemObserver.shared.readText(path: path) else {
            return ObservationResult(observations: [:], isAvailable: false, reason: "patched file could not be re-read")
        }
        let remaining = ReplaceInFileTool.countOccurrences(of: find, in: after)
        let expectedRemaining = countBefore - replacements
        return ObservationResult(observations: [
            "remaining": String(remaining),
            "expectedRemaining": String(expectedRemaining),
            "matches": remaining == expectedRemaining ? "true" : "false"], isAvailable: true)
    }

    func verifyDetailed(expected: ToolResult, observed: ObservationResult) -> ToolVerificationResult {
        guard observed.isAvailable else { return .unavailable("filesystem did not answer") }
        guard observed.observations["matches"] == "true" else {
            return .failed("patch verification failed: remaining occurrences \(observed.observations["remaining"] ?? "?") did not match expected \(observed.observations["expectedRemaining"] ?? "?")")
        }
        return .passed(reason: "patch verified by read-back")
    }
}
