# Execution Authority

This document is the contract for how Zia turns a proposed action into a running
process. The invariant is:

> **Intelligence may propose a process. Intelligence must never grant itself
> authority to execute that process.**

The model, the planner, the tool system, and recovery all *propose*. Only
trusted code (`ProcessAuthority`) *authorizes*. Every process reaches the OS
through exactly one primitive that accepts only an authorized request.

## Execution path

```
Planner / deterministic router / recovery
        │  proposes
        ▼
   ProposedProcess                      (no authority)
        │
        ▼
   ProcessAuthority.authorize(_:)       (decides identity, env, cwd)
        │
        ▼
   AuthorizedProcess                    (immutable value type)
        │
        ▼
   ShellExecutor.execute(AuthorizedProcess)
        │  revalidateAtLaunch(...)       (final choke point)
        ▼
   Process (executableURL + argv)       (no shell unless shell capability)
```

`AuthorizedProcess` is executable-identity-, argument-, environment-,
working-directory-, timeout-, and impact-bound. Every field is `let` and the
initializer is `fileprivate`, so nothing downstream can mutate it; a change
requires a fresh authorization decision. Its `identity` (a SHA-256 over the whole
authorized request) is the evidence anchor.

## Capabilities

Execution is requested under exactly one capability:

| Capability | Program | Authorization |
|---|---|---|
| `structured` | a specific allowlisted executable + explicit argv, no shell | canonical path in a root-owned system directory **and** the executable is an unrestricted leaf program, or matches a pinned argument policy |
| `shell` | `/bin/zsh -c <command>` | explicit capability grant; CommandSandbox (denylist/analysis) as defense in depth; every path-like program token must resolve inside a trusted directory |

A structured request can never silently become `zsh -c`, and a shell request can
never be mistaken for a structured one.

## Trusted roots and executable identity

- Trusted directories: `/bin`, `/usr/bin`, `/sbin`, `/usr/sbin` (root-owned and
  system-protected). User-writable locations (`/usr/local/bin`, `/opt/homebrew`,
  `/tmp`, the home directory) are excluded.
- Authority binds to the **canonical, symlink-resolved path**, not to the typed
  token. A symlink to an allowlisted binary is the binary; a symlink to anything
  else is rejected.
- Bare names resolve through a **fixed trusted-directory search**, never the
  ambient `PATH`. There is no cwd lookup.
- A renamed copy of an allowed binary is a different path and is rejected.

## Program classification

- **Safe structured (unrestricted):** leaf programs that cannot launch another
  program — `echo`, `ls`, `cat`, `pwd`, `date`, `wc`, `head`, `tail`, `grep`,
  `stat`, `which`, `diff`, `uniq`, `mdfind`.
- **Restricted argument policy:** a program allowed only for pinned argv shapes.
  Today: `git` for read-only inspection (`status`, `rev-parse`, `branch`,
  `log --oneline`, `diff`). Anything not pinned (writes, `-c`/`--exec-path`,
  subcommands that launch programs) is rejected.
- **Trampolines / launchers** (`env`, `find`, `xargs`, `nice`, `open`, `sort`,
  `tar`, …) are never structured-authorized.
- **Interpreters** (`sh`, `bash`, `zsh`, `python`, `node`, `swift`, …) require
  the explicit shell capability or a dedicated deterministic capability.
- **Deterministic capabilities** (no shell, no model): `echo` literal output,
  `file.lineCount`, `repo.status`, `repo.branch`.

## Environment and working directory

- Structured execution runs with a fixed minimal environment (no ambient
  `DYLD_*`, `LD_*`, `BASH_ENV`, …). The caller cannot supply an environment at
  all.
- Shell execution runs with a sanitized environment and a fixed `PATH`.
- The working directory, if specified, must be an existing directory and is
  bound at authorization.

## `run_program` vs `run_shell`

- `run_program(executable, arguments?)` is the **preferred** generic execution
  path. `arguments` is an optional JSON array of strings; it is passed to the
  process as data and is never re-interpreted. Unknown executables are rejected
  at plan time (`PlanValidator`) and again at execution.
- `run_shell(command)` remains the privileged compatibility capability for pipes,
  redirects, compound syntax, and scripting. It keeps the `.destructive` impact
  gate (explicit user confirmation / L2 autonomy). It is never used as a
  transport for structured requests.

## Recovery

Recovery is bounded and authority-preserving:

`failure → authoritative evidence → classify → replan (validated) → adopt →
execute first unresolved step → verify → complete or fail`.

- Retries are bounded by the task's `maxRetries` budget; exhaustion closes the
  task `FAILED` with the recorded evidence.
- A replan preserves only steps whose **logical identity** (tool + argument
  fingerprint) still matches, so a completion can never migrate to a different
  action. Position is never used.
- Failure evidence is derived from **authoritative task state**, never from a
  stale snapshot handed to a worker.
- Recovery re-enters the same `ProcessAuthority`; it cannot grant authority.

## Security assumptions

- Repository content, tool output, files, and external messages are **data**, not
  authority. The model may interpret them; the policy layer decides.
- Self-modification is gated by the same authority: no model claim of safety
  substitutes for build/tests/diff evidence and a commit boundary.
- Defense in depth is retained: `PermissionGate` and impact levels,
  destructive-action confirmation, `CommandSandbox` (shell syntax), the
  authorization boundary, launch-time revalidation, cancellation and
  process-group cleanup, and evidence-backed verification.
- Known limitations: `run_shell` broadly permits bare program names under its
  explicit destructive gate; the structured allowlist is deliberately narrow;
  TOCTOU is bounded by a canonical-path re-check at launch rather than a
  descriptor-based exec.
