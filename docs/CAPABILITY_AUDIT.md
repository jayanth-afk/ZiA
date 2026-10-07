# Zia — Capability Audit (Phase 0.2)

> Contract: **Frozen Architecture & Implementation Contract v1.0** (9 frozen
> principles + Principle 10 "Self-Modification Never Equals Self-Validation").
> Generated: 2026-10-07 · HEAD `77a5799` · branch `master`.
>
> **Method.** Every registered tool was read at source. Classification is based
> on (a) whether `execute` performs a real effect/read rather than returning a
> canned value, (b) whether the tool implements a deterministic
> `observe` → `verifyDetailed` postcondition, and (c) whether that behavior has
> deterministic coverage in one of the two runners (`swift test` in
> `Tests/JarvisTests`, or the in-process `--self-test` suite). Nothing here is
> claimed as verified unless a command was actually run this session.

## Legend

| Class | Meaning |
|---|---|
| **REAL** | Real effect/read + deterministic verification + a deterministic test in `Tests/` or `--self-test` that executes the capability. |
| **PARTIAL** | Implementation is real and non-canned, but (i) lacks direct deterministic test coverage, **or** (ii) depends on a host permission (TCC / Safari-JS toggle) that is not verifiable unattended, **or** (iii) verification is weak for a read-only tool. |
| **STUB** | Placeholder / canned data / no real effect. |

**STUBs found: 0.** Every one of the 42 registered tools has a full
`execute → observe → verifyDetailed` implementation. No tool returns fabricated
or sample data.

## Registered tool count

`ToolRegistry.registerBuiltins()` performs **42 registrations** producing **42
distinct tool names** (`grep -c "register(" Sources/Jarvis/Brain/Tools/ToolRegistry.swift`
= 43 lines, one of which is the `func register(...)` definition itself;
`MoveOrCopyPathTool` is registered twice to yield `copy_path` and `move_path`).
The handoff note said "43 registered" — the correct runtime figure is 42.

## Tool table

| # | Tool | Impact | Class | Execute | Verification | Deterministic coverage |
|---|---|---|---|---|---|---|
| 1 | `open_app` | safeMutation | **PARTIAL** | NSWorkspace launch | frontmost-app match | `--self-test` (26 refs); launch itself not re-run in `swift test` |
| 2 | `set_volume` | safeMutation | **PARTIAL** | CoreAudio set | volume readback ±2 | `--self-test` (13 refs); CoreAudio not exercised in CI |
| 3 | `run_program` | safeMutation | **REAL** | `ProcessAuthority` structured exec | exit code + optional file/dir | `StructuredProgramToolTests`, `RunShellImpactBoundaryTests` |
| 4 | `run_shell` | destructive | **REAL** | `ProcessAuthority` shell exec | exit code + optional file/dir | many `CommandSandbox*` suites + `--self-test` (97 refs) |
| 5 | `write_file` | safeMutation | **REAL** | `FileManagerJarvis.writeFile` | exact byte read-back | `--self-test` (27 refs) + E2E artifact |
| 6 | `read_file` | readOnly | **REAL** | `FileManagerJarvis.readFile` | existence check | `--self-test` (35 refs) |
| 7 | `web_search` | readOnly | **PARTIAL** | `WebSearch` network | source count recorded | `--self-test` (19 refs); network-dependent |
| 8 | `fetch_url` | readOnly | **PARTIAL** | `URLFetcher` network | fetch status | `--self-test` (28 refs); network-dependent |
| 9 | `open_browser` | safeMutation | **PARTIAL** | `BrowserManager.open` | active-tab URL match | `--self-test` (5 refs); tab readback needs Safari-JS toggle |
| 10 | `inspect_browser_page` | readOnly | **PARTIAL** | DOM summary | snapshot URL == active URL | `BrowserScriptSafetyTests`; live DOM needs Safari-JS toggle |
| 11 | `extract_browser_text` | readOnly | **PARTIAL** | single-selector text | selector resolves to one element | `BrowserScriptSafetyTests`; live DOM needs Safari-JS toggle |
| 12 | `click_browser_link` | safeMutation | **PARTIAL** | DOM click + nav | active URL contains expected fragment | `BrowserScriptSafetyTests`; live DOM needs Safari-JS toggle |
| 13 | `fill_browser_text` | safeMutation | **PARTIAL** | DOM field entry | exact field value read-back | `BrowserScriptSafetyTests`; live DOM needs Safari-JS toggle |
| 14 | `inspect_ui` | readOnly | **PARTIAL** | AX tree describe | frontmost app | `--self-test` (5 refs); needs Accessibility TCC |
| 15 | `click_element` | safeMutation→destructive | **PARTIAL** | AX press | declared postcondition | `--self-test` (7 refs); needs Accessibility TCC |
| 16 | `set_text` | safeMutation | **PARTIAL** | AX set value | exact AX value read-back | `--self-test` (2 refs); needs Accessibility TCC |
| 17 | `project_info` | readOnly | **REAL** | `ProjectInspector.inspect` | re-read availability | `ProjectInspector` unit-tested in `Tests/` |
| 18 | `check_health` | readOnly | **PARTIAL** | `HealthService.report` | service answered | no direct test |
| 19 | `schedule_task` | safeMutation | **REAL** | `TaskScheduler.add` | job retained | `TaskScheduler` unit-tested (schedule retention) |
| 20 | `list_schedule` | readOnly | **PARTIAL** | scheduler read | service answered | no direct test |
| 21 | `remember_fact` | safeMutation | **REAL** | `MemoryManager.rememberUserFact` | record retained | `ZiaMemoryTrustTests` + `--self-test` |
| 22 | `recall_memory` | readOnly | **REAL** | trusted retrieval | service answered | `ZiaMemoryTrustTests` |
| 23 | `list_artifacts` | readOnly | **PARTIAL** | `ArtifactRegistry` read | registry answered | `--self-test` (2 refs) |
| 24 | `list_directory` | readOnly | **REAL** | `FileManagerJarvis.listDirectory` | re-read availability | `FileSystemCapabilityTests` |
| 25 | `file_metadata` | readOnly | **REAL** | `FileSystemObserver` | re-read availability | `FileSystemCapabilityTests` |
| 26 | `search_files` | readOnly | **REAL** | bounded enumeration | re-read availability | `FileSystemCapabilityTests` |
| 27 | `grep_files` | readOnly | **REAL** | bounded content search | re-read availability | `FileSystemCapabilityTests` |
| 28 | `create_directory` | safeMutation | **REAL** | mkdir | exists && isDirectory | `FileSystemCapabilityTests` |
| 29 | `append_file` | safeMutation | **REAL** | append | file grew | `FileSystemCapabilityTests` |
| 30 | `copy_path` | safeMutation | **REAL** | copy | destination exists | `FileSystemCapabilityTests` |
| 31 | `move_path` | safeMutation | **REAL** | move | dest exists && src gone | `FileSystemCapabilityTests` |
| 32 | `replace_in_file` | safeMutation | **REAL** | exact replace | read-back equality | `FileSystemCapabilityTests` |
| 33 | `delete_path` | destructive | **REAL** | remove | path gone | `FileSystemCapabilityTests` |
| 34 | `find_symbol` | readOnly | **PARTIAL** | `CodeIntelligence.findSymbols` | re-read availability | no direct test |
| 35 | `find_markers` | readOnly | **PARTIAL** | `CodeIntelligence.findMarkers` | re-read availability | no direct test |
| 36 | `changed_files` | readOnly | **PARTIAL** | structured `git diff` | git answered | git guard suites cover authority; tool itself untested |
| 37 | `capabilities` | readOnly | **PARTIAL** | `CapabilityRegistry` | registry answered | no direct test |
| 38 | `self_status` | readOnly | **PARTIAL** | state aggregate | report produced | no direct test |
| 39 | `recovery_status` | readOnly | **PARTIAL** | `CrashRecovery.inspect` | state answered | crash-recovery logic tested; tool wrapper untested |
| 40 | `get_preferences` | readOnly | **PARTIAL** | `PreferenceStore` | store answered | no direct test |
| 41 | `set_preference` | safeMutation | **PARTIAL** | explicit store | key stored explicit | no direct test |
| 42 | `patch_file` | safeMutation | **PARTIAL** | `PatchEngine` + backup | read-back occurrence count | no direct test |

Totals: **REAL 19 · PARTIAL 23 · STUB 0.**

## Marker scan (TODO/FIXME/HACK/XXX)

No unfinished-work markers exist in any production capability file.

- `Agent/CodeIntelligence.swift` — the only occurrence of `TODO`/`FIXME` is
  `CodeIntelligence.defaultMarkers = ["TODO", "FIXME", "HACK", "XXX"]`, i.e. the
  search set itself (line 43). Not a real marker.
- `Brain/Tools/AssistantCapabilityTools.swift` — no markers (the handoff note
  was stale).
- All other `TODO`/`placeholder` hits are legitimate domain strings: `PlanValidator`
  placeholder-rejection lists, `Events.swift` phase comments, UI `placeholder:`
  hint strings, and `ZiaTheme` build-time `${VERSION}` substitution.

## Priorities driven by this table

1. **Weak-verification read-only tools** (`check_health`, `list_schedule`,
   `capabilities`, `self_status`, `recovery_status`, `get_preferences`,
   `find_symbol`, `find_markers`, `changed_files`) should be covered with direct
   deterministic tests that assert the returned content, not merely that the
   service answered. → Phases 2–4.
2. **`set_preference` / `patch_file`** need direct tests of the store/patch
   round-trip. → Phases 3 and 8.
3. **Hardware-gated tools** (browser DOM 10–13, accessibility 14–16, ambient
   capture) remain PARTIAL by design; their live verification is OWNER-ONLY
   (docs/OWNER_CHECKLIST.md) and must never be relabeled REAL from an unattended
   run. → Phases 5 and 9.
4. **Network-dependent tools** (`web_search`, `fetch_url`) keep
   offline-degradation tests rather than live-network assertions. → Phase 8.
