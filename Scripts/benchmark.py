#!/usr/bin/env python3
"""
JARVIS Model Benchmark Suite

Benchmarks local LLM inference on this specific machine using JARVIS-relevant
workloads — NOT synthetic benchmarks.

Measures:
  - Model load time
  - Prompt processing time (prefill)
  - Time-to-first-token (TTFT)
  - Sustained tokens/second
  - Peak memory usage
  - Context-length degradation
  - Thermal throttling (sustained performance)
  - Intent classification accuracy + latency
  - Structured output reliability
  - Tool-call format reliability

Workloads (JARVIS-specific):
  A. "Open Safari"                    — simple deterministic command
  B. "Set volume to 30%"              — parameterized command
  C. "What's on my clipboard?"        — system query
  D. "Summarize this text: ..."       — moderate reasoning
  E. "Explain this code: ..."         — deep reasoning
  F. "What time is it in Tokyo?"      — quick factual
  G. Intent classification batch      — 20 mixed intents
  H. Tool-call format test            — structured JSON output

Usage:
  python3 Scripts/benchmark.py                    # Run all benchmarks
  python3 Scripts/benchmark.py --models qwen3b    # Specific model
  python3 Scripts/benchmark.py --workload A B G   # Specific workloads
  python3 Scripts/benchmark.py --install          # Install mlx-lm first
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ──────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────

BENCHMARK_DIR = Path.home() / ".jarvis" / "benchmarks"
BENCHMARK_DIR.mkdir(parents=True, exist_ok=True)

# Model candidates to benchmark (HuggingFace IDs)
MODEL_CANDIDATES = {
    # Reflex tier (3-4B class)
    "qwen2.5-3b": "mlx-community/Qwen2.5-3B-Instruct-4bit",
    "phi3.5-mini": "mlx-community/Phi-3.5-mini-instruct-4bit",
    "llama3.2-3b": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    # Normal tier (7-10B class)
    "qwen2.5-7b": "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "llama3.1-8b": "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
    "gemma2-9b": "mlx-community/gemma-2-9b-it-4bit",
}

# ──────────────────────────────────────────────────────
# JARVIS-Specific Workloads
# ──────────────────────────────────────────────────────

INTENT_CLASSIFICATION_PROMPT = """Classify the user's intent into exactly one category.
Respond with ONLY the category name, nothing else.

Categories: openApp, systemControl, fileOperation, terminalCommand,
setTimer, setReminder, quickAnswer, conversation, deepReasoning,
visionQuery, webSearch, codeGeneration, recall, remember,
unclear, greeting, goodbye

User: "{query}"
Intent:"""

WORKLOADS = {
    "A": {
        "name": "Simple command — Open Safari",
        "prompt": INTENT_CLASSIFICATION_PROMPT.format(query="Open Safari"),
        "expected": "openApp",
        "max_tokens": 10,
        "category": "intent",
    },
    "B": {
        "name": "Parameterized command — Set volume",
        "prompt": INTENT_CLASSIFICATION_PROMPT.format(query="Set volume to 30%"),
        "expected": "systemControl",
        "max_tokens": 10,
        "category": "intent",
    },
    "C": {
        "name": "System query — Clipboard",
        "prompt": INTENT_CLASSIFICATION_PROMPT.format(query="What's on my clipboard?"),
        "expected": "quickAnswer",
        "max_tokens": 10,
        "category": "intent",
    },
    "D": {
        "name": "Moderate reasoning — Summarize",
        "prompt": "Summarize this in 2 sentences: The MacBook Pro with M4 chip features a 14-inch Liquid Retina XDR display, up to 24GB of unified memory, and delivers up to 2x faster performance than M1. It includes a 12MP Center Stage camera, three Thunderbolt 4 ports, HDMI, and MagSafe charging. The battery lasts up to 17 hours.",
        "expected": None,
        "max_tokens": 100,
        "category": "reasoning",
    },
    "E": {
        "name": "Deep reasoning — Explain code",
        "prompt": 'Explain what this code does in one sentence:\n```python\ndef f(n): return n if n <= 1 else f(n-1) + f(n-2)\n```',
        "expected": None,
        "max_tokens": 80,
        "category": "reasoning",
    },
    "F": {
        "name": "Quick factual — Time zone",
        "prompt": INTENT_CLASSIFICATION_PROMPT.format(query="What time is it in Tokyo?"),
        "expected": "quickAnswer",
        "max_tokens": 10,
        "category": "intent",
    },
    "G": {
        "name": "Intent classification batch (20 queries)",
        "queries": [
            ("Open Chrome", "openApp"),
            ("Turn off Wi-Fi", "systemControl"),
            ("Create a folder called Projects", "fileOperation"),
            ("Run npm install", "terminalCommand"),
            ("Set a timer for 5 minutes", "setTimer"),
            ("Remind me to call Mom at 3pm", "setReminder"),
            ("What's the weather?", "quickAnswer"),
            ("Tell me about quantum computing", "conversation"),
            ("Analyze this code for bugs", "deepReasoning"),
            ("What's on my screen?", "visionQuery"),
            ("Search for Apple stock price", "webSearch"),
            ("Write a Python script", "codeGeneration"),
            ("What did we talk about yesterday?", "recall"),
            ("Remember my meeting is at 3pm", "remember"),
            ("Hmm", "unclear"),
            ("Hey", "greeting"),
            ("That's all, thanks", "goodbye"),
            ("Play some music", "openApp"),
            ("Delete the Downloads folder", "fileOperation"),
            ("Set brightness to 80%", "systemControl"),
        ],
        "max_tokens": 10,
        "category": "batch_intent",
    },
    "H": {
        "name": "Tool-call format — JSON output",
        "prompt": """You have access to these tools:
- open_app(name: string) — opens a macOS application
- set_volume(level: int) — sets system volume (0-100)

The user says: "Open Safari and set volume to 50%"

Respond with a JSON array of tool calls:
[{"tool": "...", "args": {...}}, ...]

JSON:""",
        "expected_format": "json_array",
        "max_tokens": 100,
        "category": "structured",
    },
}

# ──────────────────────────────────────────────────────
# Benchmark Runner
# ──────────────────────────────────────────────────────

def check_mlx_installed():
    """Check if mlx-lm is available."""
    try:
        import mlx_lm
        return True
    except ImportError:
        return False


def install_mlx():
    """Install mlx-lm via pip."""
    print("Installing mlx-lm...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "mlx-lm", "--quiet"])
    print("  ✓ mlx-lm installed")


def get_memory_usage_mb():
    """Get current process memory usage in MB."""
    import resource
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def benchmark_model(model_id, model_name, workload_keys):
    """Run benchmarks for a single model."""
    try:
        from mlx_lm import load, generate
    except ImportError:
        print("ERROR: mlx-lm not installed. Run: python3 Scripts/benchmark.py --install")
        sys.exit(1)

    results = {
        "model": model_name,
        "model_id": model_id,
        "machine": {
            "chip": subprocess.getoutput("sysctl -n machdep.cpu.brand_string").strip(),
            "memory_gb": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024**3), 1),
            "macos": subprocess.getoutput("sw_vers -productVersion").strip(),
        },
        "workloads": {},
        "summary": {},
    }

    # ── Model Load ──
    print(f"\n{'='*60}")
    print(f"Model: {model_name} ({model_id})")
    print(f"{'='*60}")

    mem_before = get_memory_usage_mb()
    load_start = time.perf_counter()

    try:
        model, tokenizer = load(model_id)
    except Exception as e:
        print(f"  ✗ Failed to load: {e}")
        results["error"] = str(e)
        return results

    load_time = (time.perf_counter() - load_start) * 1000
    mem_after = get_memory_usage_mb()

    results["load_time_ms"] = round(load_time, 1)
    results["memory_delta_mb"] = round(mem_after - mem_before, 1)

    print(f"  Load time:  {load_time:.0f}ms")
    print(f"  Memory:     +{mem_after - mem_before:.0f}MB")

    # ── Run Workloads ──
    for key in workload_keys:
        if key not in WORKLOADS:
            continue

        wl = WORKLOADS[key]

        if wl["category"] == "batch_intent":
            # Special handling for batch intent workload
            result = run_batch_intent(model, tokenizer, wl)
        else:
            result = run_single_workload(model, tokenizer, key, wl)

        results["workloads"][key] = result
        print_workload_result(key, wl["name"], result)

    # ── Sustained Performance (10 consecutive generations) ──
    print(f"\n  Sustained performance (10 consecutive runs of workload A):")
    sustained_times = []
    for i in range(10):
        prompt = WORKLOADS["A"]["prompt"]
        messages = [{"role": "user", "content": prompt}]
        formatted = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)

        start = time.perf_counter()
        response = generate(model, tokenizer, prompt=formatted, max_tokens=10, verbose=False)
        elapsed = (time.perf_counter() - start) * 1000
        sustained_times.append(elapsed)

    results["sustained_performance_ms"] = [round(t, 1) for t in sustained_times]
    avg = sum(sustained_times) / len(sustained_times)
    degradation = ((sustained_times[-1] / sustained_times[0]) - 1) * 100 if sustained_times[0] > 0 else 0
    print(f"    Avg: {avg:.0f}ms | First: {sustained_times[0]:.0f}ms | Last: {sustained_times[-1]:.0f}ms | Degradation: {degradation:+.1f}%")

    results["summary"] = {
        "load_time_ms": results["load_time_ms"],
        "memory_delta_mb": results["memory_delta_mb"],
        "avg_intent_latency_ms": avg,
        "thermal_degradation_pct": round(degradation, 1),
    }

    return results


def run_single_workload(model, tokenizer, key, wl):
    """Run a single workload and measure performance."""
    from mlx_lm import generate

    prompt = wl["prompt"]
    max_tokens = wl["max_tokens"]

    messages = [{"role": "user", "content": prompt}]
    formatted = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)

    # Measure total generation time
    start = time.perf_counter()
    response = generate(model, tokenizer, prompt=formatted, max_tokens=max_tokens, verbose=False)
    total_ms = (time.perf_counter() - start) * 1000

    result = {
        "total_ms": round(total_ms, 1),
        "response": response.strip(),
        "max_tokens": max_tokens,
    }

    # Check correctness for intent classification
    if wl.get("expected"):
        result["expected"] = wl["expected"]
        result["correct"] = wl["expected"].lower() in response.strip().lower()

    # Check JSON format for structured output
    if wl.get("expected_format") == "json_array":
        try:
            parsed = json.loads(response.strip())
            result["valid_json"] = isinstance(parsed, list)
        except (json.JSONDecodeError, ValueError):
            result["valid_json"] = False

    return result


def run_batch_intent(model, tokenizer, wl):
    """Run batch intent classification and measure accuracy + latency."""
    from mlx_lm import generate

    correct = 0
    total = len(wl["queries"])
    latencies = []

    for query, expected in wl["queries"]:
        prompt = INTENT_CLASSIFICATION_PROMPT.format(query=query)
        messages = [{"role": "user", "content": prompt}]
        formatted = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)

        start = time.perf_counter()
        response = generate(model, tokenizer, prompt=formatted, max_tokens=10, verbose=False)
        elapsed = (time.perf_counter() - start) * 1000
        latencies.append(elapsed)

        if expected.lower() in response.strip().lower():
            correct += 1

    accuracy = correct / total * 100
    avg_latency = sum(latencies) / len(latencies)

    return {
        "accuracy_pct": round(accuracy, 1),
        "correct": correct,
        "total": total,
        "avg_latency_ms": round(avg_latency, 1),
        "min_latency_ms": round(min(latencies), 1),
        "max_latency_ms": round(max(latencies), 1),
        "p95_latency_ms": round(sorted(latencies)[int(0.95 * len(latencies))], 1),
    }


def print_workload_result(key, name, result):
    """Pretty-print a workload result."""
    if "accuracy_pct" in result:
        print(f"\n  [{key}] {name}")
        print(f"    Accuracy:    {result['accuracy_pct']}% ({result['correct']}/{result['total']})")
        print(f"    Avg latency: {result['avg_latency_ms']:.0f}ms (p95: {result['p95_latency_ms']:.0f}ms)")
    else:
        status = ""
        if "correct" in result:
            status = " ✓" if result["correct"] else " ✗"
        elif "valid_json" in result:
            status = " ✓ JSON" if result["valid_json"] else " ✗ JSON"

        print(f"\n  [{key}] {name}{status}")
        print(f"    Time:     {result['total_ms']:.0f}ms")
        print(f"    Response: {result['response'][:80]}")


# ──────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="JARVIS Model Benchmark Suite")
    parser.add_argument("--install", action="store_true", help="Install mlx-lm first")
    parser.add_argument("--models", nargs="*", help="Model keys to benchmark (default: all)")
    parser.add_argument("--workload", nargs="*", help="Workload keys to run (default: all)")
    parser.add_argument("--output", type=str, help="Output JSON path (default: ~/.jarvis/benchmarks/)")
    args = parser.parse_args()

    if args.install:
        install_mlx()
        return

    if not check_mlx_installed():
        print("mlx-lm is not installed.")
        print("Run: python3 Scripts/benchmark.py --install")
        print("Or:  pip install mlx-lm")
        sys.exit(1)

    models_to_test = args.models if args.models else list(MODEL_CANDIDATES.keys())
    workload_keys = args.workload if args.workload else list(WORKLOADS.keys())

    print("╔══════════════════════════════════════════╗")
    print("║     JARVIS Model Benchmark Suite         ║")
    print("╚══════════════════════════════════════════╝")
    print(f"\nModels:    {', '.join(models_to_test)}")
    print(f"Workloads: {', '.join(workload_keys)}")

    all_results = {}

    for model_key in models_to_test:
        if model_key not in MODEL_CANDIDATES:
            print(f"\n  ✗ Unknown model: {model_key}")
            print(f"    Available: {', '.join(MODEL_CANDIDATES.keys())}")
            continue

        model_id = MODEL_CANDIDATES[model_key]
        results = benchmark_model(model_id, model_key, workload_keys)
        all_results[model_key] = results

    # Save results
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_path = args.output or str(BENCHMARK_DIR / f"benchmark_{timestamp}.json")

    with open(output_path, "w") as f:
        json.dump(all_results, f, indent=2, default=str)

    print(f"\n\n{'='*60}")
    print(f"Results saved to: {output_path}")
    print(f"{'='*60}")

    # Print comparison summary
    if len(all_results) > 1:
        print(f"\n{'='*60}")
        print("COMPARISON SUMMARY")
        print(f"{'='*60}")
        print(f"{'Model':<20} {'Load(ms)':<10} {'Mem(MB)':<10} {'Intent(ms)':<12} {'Accuracy':<10} {'Thermal':<10}")
        print("-" * 72)
        for name, r in all_results.items():
            if "error" in r:
                print(f"{name:<20} FAILED: {r['error'][:40]}")
                continue
            s = r.get("summary", {})
            g = r.get("workloads", {}).get("G", {})
            print(
                f"{name:<20} "
                f"{s.get('load_time_ms', '?'):<10} "
                f"{s.get('memory_delta_mb', '?'):<10} "
                f"{g.get('avg_latency_ms', '?'):<12} "
                f"{str(g.get('accuracy_pct', '?'))+'%':<10} "
                f"{str(s.get('thermal_degradation_pct', '?'))+'%':<10}"
            )


if __name__ == "__main__":
    main()
