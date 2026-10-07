# Local (Qwen2.5-0.5B) vs Groq — Benchmark (Phase 2.1)

> Contract: **Frozen Architecture & Implementation Contract v1.0** (9 frozen
> principles + Principle 10).
> Run 2026-10-07 · HEAD `70f1b4e` · raw log: `build/local-vs-groq-benchmark-raw.txt`.
> Harness: `Sources/Jarvis/Core/LocalVsGroqBenchmark.swift`, run via
> `Jarvis --local-vs-groq`. The harness **does not touch persisted `Config`** —
> the model is injected into the provider.

## Numbers (this run — read this first)

| Backend | Prompt | Tool-correct | Arg-fidelity (byte-exact) | Fabricated args | Avg total | Avg TTFT | Memory |
|---|---|---|---|---|---|---|---|
| local Qwen2.5-0.5B (cached) | production extraction prompt | **5/8** | **4/7** | **2/8** | **1165 ms** | 286 ms | ~527 MB RSS (real) |
| groq `openai/gpt-oss-120b` | production extraction prompt | **1/8** | 1/7 | 0/8 | 1634 ms | n/a | remote |
| groq `openai/gpt-oss-120b` | neutral tool-choice prompt | **8/8** | 6/7 | 0/8 | 1438 ms | n/a | remote |

Definitions:
- **Tool-correct**: parsed `tool` equals the expected tool (or, for the direct
  task, no tool step was produced).
- **Arg-fidelity**: the expected user literal appears **byte-exact** in at least
  one argument value. This replaces the old `literal` metric, which was
  meaningless because both models paste the whole goal into `literal`.
- **Fabricated args**: an argument value containing a known placeholder token
  (`/home/user/…`, `http://safari.com`, …) that does not occur in the goal.

## Per-task detail (tool / arg-fidelity)

| Task | Expected | local | groq (prod prompt) | groq (neutral) |
|---|---|---|---|---|
| open-app | `open_app` / "Safari" | `open_browser` ✗ / ✗ **FABRICATED** `http://safari.com` | `null` ✗ / ✗ | `open_app` ✓ / ✓ |
| volume | `set_volume` / "40" | `set_volume` ✓ / ✓ | `set_volume` ✓ / ✓ | `set_volume` ✓ / ✓ |
| search | `web_search` / "the weather in Paris" | `web_search` ✓ / ✗ | `null` ✗ / ✗ | `web_search` ✓ / ✗ (`Paris weather`) |
| fetch | `fetch_url` / "https://example.com" | `fetch_url` ✓ / ✓ | `null` ✗ / ✗ | `fetch_url` ✓ / ✓ |
| shell | `run_shell` / "hello_benchmark" | `run_shell` ✓ / ✓ | `null` ✗ / ✗ | `run_shell` ✓ / ✓ |
| read | `read_file` / "~/notes.txt" | `read_file` ✓ / ✗ **FABRICATED** `/home/user/note.txt` | `null` ✗ / ✗ | `read_file` ✓ / ✓ |
| list | `list_directory` / "Downloads" | `open_directory` ✗ / ✓ | `null` ✗ / ✗ | `list_directory` ✓ / ✓ (`/Users/$(whoami)/Downloads`) |
| direct | (no tool) | `web_search` ✗ | `web_search` ✗ | `null` ✓ |

## Method / honesty notes

- 8 standard macOS intent prompts, each sent through the existing `LLMProvider`
  protocol (no bespoke plumbing). Local is measured on the **production**
  bounded-extraction prompt (`MLXPlanner.buildExtractionPrompt`); Groq is
  measured on the production prompt **and** on a neutral tool-choice prompt.
- The production prompt is tuned for the 0.5B model (explicit copy rules and
  anti-examples). The neutral prompt is a plain "select one tool, emit JSON"
  instruction with the same output schema — it exists only to separate
  "prompt mismatch" from "model cannot do the task".
- Latency is end-to-end wall time. Local TTFT is the worker's real first-token
  latency; Groq issues a single non-streaming request so its TTFT is `n/a`,
  never estimated.
- Bounds: 8 tasks, 45 s per-task timeout, 420 s wall cap, 1.1 s spacing between
  Groq requests. Whole run: 53.1 s.
- `stream:false` is required: `GroqProvider` cannot parse its own SSE reply
  (a real provider defect; see findings).

## Findings

1. **The poor Groq result is a prompt mismatch, not a model limitation.**
   With the 0.5B-tuned production prompt, Groq returned `{"tool": null}` on 6 of
   8 clear tasks (tool-correct 1/8). With the neutral prompt it chose the correct
   tool on **8/8** tasks, including the direct-answer task it previously got
   wrong. The production extraction prompt does not transfer to a large model.
2. **The configured Groq model is unavailable to this account.** The default
   `llama-3.3-70b-versatile` returns *"does not exist or you do not have
   access."* The benchmark requests `openai/gpt-oss-120b` and records the
   substitution.
3. **`GroqProvider` cannot stream.** It issues one non-streaming request and
   parses one JSON body; requesting `stream:true` yields an unparseable SSE
   body. The benchmark uses `stream:false`.
4. **The local 0.5B fabricates content on 2/8 tasks** (`/home/user/note.txt` for
   `~/notes.txt`; `http://safari.com` for "open Safari") and mis-selects the tool
   on 3/8 (open_browser for open_app, open_directory for list_directory,
   web_search for a direct question). Its argument fidelity is 4/7.
5. **The 0.5B is the fastest measured backend** (1165 ms avg total, 286 ms real
   TTFT, ~527 MB RSS), but with the lowest tool correctness of the three
   configurations.

## Recommendation (separate from the numbers)

These are conclusions for the Phase 2.2 routing policy, not changes made here.

1. **Local remains the persistent default** for bounded extraction: it is the
   only always-available backend and the fastest measured. No routing change is
   made in Phase 2.1.
2. **Cloud is optional acceleration only**, and it must be selected on evidence
   that the local path is insufficient — the production prompt score of the
   large model (1/8) is evidence that **prompt/contract portability must be
   solved before cloud extraction is trusted**. Phase 2.2 must not send the
   0.5B-tuned prompt to a cloud model.
3. **Cloud selection must verify the configured model is actually available**
   against Groq's `/models` and fall back to local on any error, never silently
   substituting (Phase 2.2).
4. **`GroqProvider` streaming must be fixed or forced non-streaming** and
   documented (Phase 2.2).
5. Do **not** claim the large model is "at least as correct" here: on the
   production contract it is materially *worse* (1/8 vs 5/8). Any claim that a
   cloud model is more reliable requires re-measurement on the production
   contract after the prompt-portability work.
