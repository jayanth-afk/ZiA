# Repo Hygiene Report (Phase 1.2)

> Contract v1.0. Generated 2026-10-07 · HEAD `229d149` · read-only classification.
> **No file was deleted or moved.** Every proposed removal is queued in the
> APPROVAL QUEUE of `docs/COMPLETION_LEDGER.md`.

## Root-level entries

| Path | Tracked? | Size | Content / purpose | Referenced by code? | Verdict |
|---|---|---|---|---|---|
| `swiftly.pkg` | **TRACKED** | 10.9 MB | Swiftly toolchain installer binary | no | **Remove (proposed)** — installer artifact, never belongs in git |
| `build.log` | untracked | 13 KB | historical build log | no | already ignored (`*.log`) |
| `output.txt` | **TRACKED** | 288 B | a captured `fetch_url` result (example.com) | no | **Remove (proposed)** — tool-output residue |
| `forbidden.txt` | **TRACKED** | 3 B | contents `bad` | no | **Remove (proposed)** — sandbox-test residue |
| `...` (literal filename) | **TRACKED** | 5 B | contents `" ... "` | no | **Remove (proposed)** — accidental shell redirect |
| `PolicyEvaluator.swift` (repo root) | **TRACKED** | 2 KB | orphan `PolicyEvaluator` policy engine using a non-existent `NSHomeDirectoryPath()`; fails **open** (allow-all) | **no** — absent from `Sources/`, `Tests/`, `Package.swift` | **Remove (proposed)** — dead, unreferenced, and fails-open |
| `.aider.chat.history.md` | untracked | 4 KB | Aider session history | no | already ignored (`.aider*`) |
| `.aider.input.history` | untracked | 207 B | Aider input history | no | already ignored (`.aider*`) |
| `.aider.tags.cache.v4/` | untracked | dir | Aider tag cache | no | already ignored (`.aider*`) |
| `.DS_Store` | untracked | — | Finder metadata | no | already ignored |
| `.continuerules` | **TRACKED** | 1.5 KB | an AI-agent directive file (asserts "full unrestricted permission" to delete files) | no | **Relocate/remove (proposed)** — a prompt file that grants itself destructive authority does not belong in the repo |
| `mcp.json` | TRACKED | 288 B | Agent-Bridge MCP server config (`AGENT_ID=freebuff`) | yes — Phase 6.1 reads this path | **Keep** |
| `Package.resolved` | TRACKED | — | SPM lockfile | yes | **Keep** |

## Ignore-rule gaps found

`git check-ignore` shows the following are **not** ignored and should be:

- `.venv-mlx/` — the Python MLX virtualenv (huge, machine-specific).
- `.vscode/` — editor state.
- `*.pkg` — installer artifacts.
- `__pycache__/`, `*.pyc` — Python worker bytecode.
- `output.txt` / `forbidden.txt` — tool/test residue produced by runs.

`build/` is intentionally **not** globally ignored: it is the evidence store and
174 entries under it are tracked on purpose (rule 6 preserves it). Only
`build/zia-cross-turn-*.txt` is ignored today.

## Repo weight

- Total tracked content: **31 MB**, dominated by `swiftly.pkg` (10.9 MB) and the
  tracked `build/Jarvis.app` bundle. Removing `swiftly.pkg` from the index is the
  single largest hygiene win.

## Actions taken this task (non-destructive only)

1. Added ignore patterns for `.venv-mlx/`, `.vscode/`, `*.pkg`, `__pycache__/`,
   `*.pyc`, `output.txt`, `forbidden.txt` (see `.gitignore`).
2. Recorded the six proposed removals in the APPROVAL QUEUE.
