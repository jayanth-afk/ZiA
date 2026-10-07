# ZiA — ChatGPT as a Brain (safe, measured, opt-in tier)

> Contract: **Frozen Architecture & Implementation Contract v1.0** (9 frozen
> principles + Principle 10 "Self-Modification Never Equals Self-Validation").
>
> This document is the evidence base for making "ChatGPT as ZiA's smart brain" a
> safe, measured, **opt-in** tier. It records what exists today (C0 recon), the
> trust boundaries, and — in later sections — the design that was implemented.
>
> Status: **C0–C5 implemented; C6 documents complete.** N1 (verified provider
> availability) was done first as the prerequisite.

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

## 3. Architecture and trust boundaries

```
  user request (voice / typed)
        │
        ▼
  DeterministicRouter / IntentClassifier        ← deterministic baseline, no model
        │
        ▼
  Hybrid routing policy (C4, ChatGPTBrainPolicy)
        │  eligible ONLY when: user-present AND needs deep reasoning/writing
        │  AND not scheduled/background AND not sensitive AND not the extraction
        │  prompt AND under the daily cap AND not quarantined AND available
        ▼
  ProviderManager.executeWithStreamingFallback
        │  DataClassifier gate (fail closed to local)  +  ContextSanitizer redaction
        ▼
  ChatGPTDesktopProvider  ──HTTP + x-api-key──▶  Agent Bridge 127.0.0.1:8765
        │                                          │  guardChatGPTRequest: loopback only,
        │                                          │  no browser Origin, validated Host,
        │                                          │  mandatory constant-time key
        │                                          ▼
        │                             transport auto → engine (bundled Codex CLI)
        │                                              else UI (ChatGPT Desktop AX)
        ▼
  response text — DATA ONLY, never authority
        │  still flows through PlanValidator / PermissionGate / normal verifiers
        ▼
  overlay shows “Answered by ChatGPT · engine/ui”
```

**Trust boundaries**

- **ChatGPT output is data, never authority.** It cannot call ZiA tools, change
  permissions/autonomy/memory trust, or bypass `PermissionGate` / `PlanValidator`.
  Anything it proposes goes through the normal validators.
- **Two gates before anything leaves the machine** (ProviderManager): the
  `DataClassifier` gate (sensitive/highly-sensitive fails closed to local) and
  `ContextSanitizer` (credential redaction + size bounds on untrusted segments).
- **The bridge is a local, authenticated boundary.** The ChatGPT routes are
  loopback-only, reject any browser `Origin` (CSRF), validate `Host` (DNS
  rebinding), and require a constant-time API key (503 when none is configured).
- **The engine never inherits the repo or home directory.** Engine Q&A runs in a
  fresh EMPTY temp dir with a read-only sandbox, no approvals, an ephemeral
  session, bounded timeouts, and a whole-process-group kill on cancel.
- **No credentials are ever read, logged, or transmitted.** ZiA never reads
  ChatGPT/OpenAI session tokens, cookies, or `~/.codex/auth.json`; it never
  calls `chatgpt.com`/`api.openai.com` and never reimplements ChatGPT's web API.
  Only the bridge routes above. The control-plane key lives in the Keychain and
  is never logged.

**Data classes that never leave the machine** (kept local, always)

- HIGHLY_SENSITIVE: passwords, API keys/tokens, private keys, credit cards, SSN, `sudo`.
- SENSITIVE: local paths, personal documents, private code, financial/bank/tax data.
- The tuned extraction prompt (must stay portable and local — benchmark 1/8 vs
  8/8) and any scheduled/background autonomous goal.

**Quota and terms**

- The ChatGPT brain is for **personal, user-initiated, human-scale use only** —
  never bulk or background use. It uses the user's own ChatGPT sign-in through
  their installed app.
- A **daily soft cap** (`ChatGPTBrain.dailySoftCap`, default 50) is enforced by
  the routing policy and shown to the user in Settings.
- A **circuit breaker** quarantines the brain for 60 s after 3 consecutive
  failures (existing `ProviderManager` quarantine), and the policy then skips it.

## 4. Risks / gaps closed by this mission

| # | Gap (today) | Closed by |
|---|---|---|
| G1 | ChatGPT endpoint unauthenticated by default; wildcard CORS; no Origin/Host check | C1 |
| G2 | Endpoint uses UI route only; engine adapter has no `cwd`, no sandbox, kills only the child | C2 |
| G3 | Provider has no opt-in switch, no data-class gate, no deadlines, guessed latency | C3, C5 |
| G4 | ChatGPT is first in every routing chain with no policy | C4 |
| G5 | No measured latency | C5 |

## 5. What changed (implementation summary)

| Task | Change | Evidence |
|---|---|---|
| N1 | Tri-state verified availability (`available`/`unverified`/`unavailable(reason)`), ~10-min cache, 5 s probe bound; health stops treating a key as usable | `ProviderAvailability.swift`, `ProviderAvailabilityTests` |
| C1 | Endpoint security boundary + Keychain `agentBridge` service; provider sends `x-api-key`, fails closed without it | `http-server.js`, `chatgpt-endpoint-security.test.js`, `ChatGPTBrainKeyTests` |
| C2 | Headless engine as default transport; hardened, stateless Q&A; always reports the transport | `chatgpt-local-engine.js`, `chatgpt-local-engine.test.js` |
| C3 | Opt-in (default OFF) + DataClassifier + ContextSanitizer + 15 s/60 s deadlines + transport provenance + usage counter and Settings card | `ChatGPTBrain.swift`, `ChatGPTBrainSettingsView.swift`, `ChatGPTBrainSettingsTests` |
| C4 | Hybrid policy + decision-record provenance + UI indicator | `ChatGPTBrainPolicy.swift`, `ChatGPTBrainPolicyTests`, `OverlayView` |
| C5 | `Jarvis --chatgpt-bench` measured benchmark; rolling measured median latency | `ChatGPTBrainBenchmark.swift`, `build/chatgpt-brain-benchmark.md` |

## 6. How to enable it (owner steps)

See **`docs/OWNER_CHECKLIST.md` §9 (ChatGPT brain)** for the exact steps: sign in
Desktop, confirm the bundled engine is signed in, grant Accessibility for the UI
route, keep the dedicated conversation, set the bridge key, and turn on the
Settings switch.
