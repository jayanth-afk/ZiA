# ZiA — ChatGPT as a Brain (safe, measured, opt-in tier)

> Contract: **Frozen Architecture & Implementation Contract v1.0** (9 frozen
> principles + Principle 10 "Self-Modification Never Equals Self-Validation").
>
> This document is the evidence base for making "ChatGPT as ZiA's smart brain" a
> safe, measured, **opt-in** tier. It records what exists today (C0 recon), the
> trust boundaries, and — in later sections — the design that was implemented.
>
> Status: **C0 recon complete** (current state). Architecture/trust-boundary
> sections filled in C6.

---

## 1. Current state (C0 recon)

### 1.1 The two ChatGPT routes

The Agent Bridge (`/Users/jayanthpranaykonada/agent-bridge`, Node) exposes two
routes to the user's own authenticated ChatGPT:

| Route | Code | Transport | Properties |
|---|---|---|---|
| **(a) UI route** | `src/control-plane/chatgpt-autonomous-session.js` (aliased by `zia-background-gpt.js`) | macOS Accessibility (Swift AX helper) + optional Apple Events JS, driving the **real ChatGPT Desktop app** | Needs the app running with a window; drives ONE dedicated conversation; accumulates context; needs Accessibility grant; `backgroundTransport ∈ {auto, apple-events-javascript}` only — it is explicitly *not* the Codex engine (see comment at `chatgpt-autonomous-session.js:28`). |
| **(b) Headless engine route** | `src/control-plane/chatgpt-local-engine.js` (`ChatGptLocalEngineAdapter`) | Spawns the **Codex CLI bundled inside ChatGPT.app** | No window; streaming JSONL on stdout; concurrent turns; uses the user's ChatGPT sign-in. Marked `trueHeadlessEngine: true`. |

Route (b) is already wired into the control plane: `desktop-control-plane.js:64`
selects `chatgpt-local-engine` when `isChatGpt && this.chatgptLocalEngine.isInstalled()`.
So the **control plane already prefers the engine**, but the Zia HTTP endpoint does not.

### 1.2 The Zia endpoint (`/api/chatgpt/complete`)

`src/http-server.js` (uncommitted working tree, ~line 225) implements
`POST /api/chatgpt/complete` and `GET /api/chatgpt/health`. The completion
handler builds a single prompt string and calls `getBackgroundGPT()` →
`ZiABackgroundGPT` → `ChatGptAutonomousSession` — i.e. it uses **only route (a),
the UI route**. The headless engine is not consulted by the endpoint.

**Auth enforcement (verified this session):**

- `http-server.js:68` `isAuthorized(req)`: `if (!this.apiKey) return true;` — when
  no key is configured **every route is open**. The key check runs before all
  handlers (`http-server.js:104`), but it is only *meaningful* when a key exists.
- `apiKey` resolves to `CONFIG.CONTROL_PLANE.API_KEY` only when
  `requireApiKey` is true (`http-server.js:35-39`).
  `CONFIG.CONTROL_PLANE.REQUIRE_API_KEY` is `true` only when env
  `CONTROL_PLANE_REQUIRE_API_KEY ∈ {1, true}` (`config.js:80-83`) — **default false**.
- **Conclusion: by default the ChatGPT endpoint is NOT key-enforced.** The
  mission's "UNVERIFIED" premise is now verified: unauthenticated by default.
- Listener binds `127.0.0.1` only (`http-server.js:16`, and `mcp-server.js:68`
  passes `host: '127.0.0.1'`). Good — but the bind host is an option.
- **CORS is wide open**: `res.setHeader('Access-Control-Allow-Origin', '*')`
  is set for *every* response, including `/api/chatgpt/*` (`http-server.js:92`),
  with `Access-Control-Allow-Headers: Content-Type, Authorization`. There is **no
  `Origin` rejection and no `Host` validation** → a web page in any browser and
  DNS-rebinding from a hostile domain can reach the endpoint.
- Constant-time compare exists (`timingSafeEqualString`, `http-server.js:71`).
- The key is read from `x-api-key` or `Authorization: Bearer …` (`http-server.js:58`).

### 1.3 The headless engine adapter — exact invocation

`chatgpt-local-engine.js` `executeTurn` (line 229):

```
args = ['exec', prompt, '--skip-git-repo-check', '--json']                       // fresh
args = ['exec', 'resume', threadId, prompt, '--skip-git-repo-check', '--json']   // resume
[+ '--ephemeral'] when ephemeral; [+ '-m', model] when a model is set
spawn(cliPath, args, { stdio: ['ignore','pipe','pipe'], env: process.env })
```

**Hardening gaps (all directly addressed by C2):**

- **No `cwd`** → the child inherits the bridge process's working directory (the
  `agent-bridge` repo). A model-generated shell command could therefore touch that
  tree. C2 requires `cwd` = a fresh EMPTY temp dir.
- **No sandbox flag, no approval flag** → relies on the user's `~/.codex/config.toml`.
  C2 requires an explicit read-only sandbox + no approvals.
- **Cancellation kills only the direct child** (`job.child.kill('SIGTERM')` then a
  500 ms SIGKILL fallback, lines 143-150 and 321-336) — **not the process group**.
  A grandchild survives cancellation.
- **No first-token timeout**; only a single total `defaultTimeoutMs` (60 s).
- Final text is taken from the **last** `item.completed`/`agent_message` event
  (`responseText = event.item.text`), i.e. it overwrites rather than assembles.
  Usage comes from `turn.completed`. Malformed JSONL lines are tolerated (good).

### 1.4 The Zia provider today

`Sources/Jarvis/Brain/Providers/ChatGPTDesktopProvider.swift`:

- `id = "chatgpt-desktop"`, capabilities `{textGeneration, codeGeneration, longContext, structuredOutput}`.
- `currentLatencyMs = 1200` is a **hard-coded guess** (line 20) — not measured. C5 replaces it with a rolling measured median.
- `isAvailable` = a 1.2 s HTTP probe of `/api/chatgpt/health` (fallback `/health`),
  cached for **2 s** (not the N1 ~10 min verified state), and treats a reachable
  bridge as "usable".
- `complete()` POSTs to `/api/chatgpt/complete` (streaming variant appended
  `?stream=true`); the text is DATA only, never authority.

### 1.5 Routing today — ChatGPT is the FIRST provider in every chain

`ProviderManager.getFallbackChain(for:)` (line ~318) puts `chatgptDesktop` **first**
in the `coding`, `deepReasoning`, `webSearch`, and `conversation/systemQuery`
chains. There is **no opt-in switch, no data-class gate, and no daily cap** in the
provider path today. This is the central safety gap the mission closes: an
opt-in tier (default OFF), a DataClassifier gate (fail closed to local), and a
context sanitizer on untrusted segments.

### 1.6 Baselines captured this session

| Check | Result |
|---|---|
| `swift build` | Build complete |
| `swift test --skip ZiaVoicePipelineBenchmarkTests --skip VoiceTurnLifecycleRegressionTests` | **282 tests / 42 suites, 0 failures** |
| agent-bridge `npm test` | **336 tests, 328 pass, 8 skipped, 0 fail** |

### 1.7 Committed vs. uncommitted (important)

`agent-bridge` HEAD is `07e9f82 feat: keep background GPT minimized`. The working
tree carries **uncommitted** changes (Oct 6) I did not author: the entire
`/api/chatgpt/health` + `/api/chatgpt/complete` endpoint in `http-server.js`, the
untracked `src/control-plane/persistent-swift-ax-bridge.js`, plus
`zia-background-gpt-target.js`, `swift-ax-bridge.js`, `mcp-server.js`,
`helper.swift`, and tests. The engine adapter (`chatgpt-local-engine.js`) and its
control-plane routing **are committed** at HEAD. The owner confirmed (this
session) that C1/C2 may be built **on top of** this uncommitted work; nothing was
reverted.

---

## 2. Installed Codex CLI capabilities (verified, non-model probes only)

Binary: `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`
(`codex-cli 0.160.0`; `codex login status` → **"Logged in using ChatGPT"**).

Flags this build actually supports (`codex exec --help`), used by C2:

| Flag | Meaning |
|---|---|
| `-s, --sandbox <read-only\|workspace-write\|danger-full-access>` | sandbox policy for model-generated shell commands |
| `-C, --cd <DIR>` | working root for the agent |
| `--skip-git-repo-check` | allow running outside a Git repo |
| `--ephemeral` | do not persist session files to disk |
| `--json` | emit events to stdout as JSONL |
| `-m, --model <MODEL>` | model selection |
| `-c, --config <k=v>` / `--ignore-user-config` / `--ignore-rules` | config control |
| `-o, --output-last-message <FILE>` | write final message to a file |
| `--dangerously-bypass-approvals-and-sandbox` | **never used by ZiA** |

> No `--approval` flag is needed for a read-only, non-interactive Q&A turn; C2
> pins sandbox `read-only` and never enables bypass flags.

---

## 3. Trust boundaries (filled in C6)

_To be completed in C6: architecture diagram, data classes that never leave the
machine, quota/terms notes._

## 4. Risks / gaps closed by this mission

| # | Gap (today) | Closed by |
|---|---|---|
| G1 | ChatGPT endpoint unauthenticated by default; wildcard CORS; no Origin/Host check | C1 |
| G2 | Endpoint uses UI route only; engine adapter has no `cwd`, no sandbox, kills only the child | C2 |
| G3 | Provider has no opt-in switch, no data-class gate, no deadlines, guessed latency | C3, C5 |
| G4 | ChatGPT is first in every routing chain with no policy | C4 |
| G5 | No measured latency | C5 |
