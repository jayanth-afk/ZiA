import time
import os
import sys
import gc
import json
import resource

def get_peak_rss_mb():
    # On macOS ru_maxrss is in bytes
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_maxrss / (1024 * 1024)

def run_benchmark():
    import mlx.core as mx
    from mlx_lm import load, generate, stream_generate
    
    model_id = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    results = {}
    
    # 1. Model load time
    start_load = time.perf_counter()
    model, tokenizer = load(model_id)
    load_time_ms = (time.perf_counter() - start_load) * 1000.0
    results["model_id"] = model_id
    results["model_load_ms"] = round(load_time_ms, 2)
    results["post_load_rss_mb"] = round(get_peak_rss_mb(), 2)
    
    # 2. TTFT & Sustained Tok/s benchmark
    prompt = "You are JARVIS, an AI assistant on macOS. Briefly list 3 system health indicators you monitor."
    
    prompt_tokens = len(tokenizer.encode(prompt))
    tokens = []
    start_gen = time.perf_counter()
    first_token_time = None
    
    for response in stream_generate(model, tokenizer, prompt, max_tokens=60):
        if first_token_time is None:
            first_token_time = time.perf_counter()
        tokens.append(response.text)
    
    total_gen_time = time.perf_counter() - start_gen
    ttft_ms = (first_token_time - start_gen) * 1000.0 if first_token_time else 0.0
    gen_tokens_count = len(tokens)
    sustained_tok_s = (gen_tokens_count / (total_gen_time - (ttft_ms / 1000.0))) if total_gen_time > (ttft_ms / 1000.0) else (gen_tokens_count / total_gen_time)
    
    results["prompt_tokens"] = prompt_tokens
    results["generation_tokens"] = gen_tokens_count
    results["ttft_ms"] = round(ttft_ms, 2)
    results["sustained_tok_s"] = round(sustained_tok_s, 2)
    results["peak_rss_mb"] = round(get_peak_rss_mb(), 2)
    
    # 3. Repeated Requests (3 rounds)
    repeated_timings = []
    for i in range(3):
        t0 = time.perf_counter()
        _ = generate(model, tokenizer, prompt=f"Quick status check {i+1}: What is 25 * 4?", max_tokens=20)
        dur = (time.perf_counter() - t0) * 1000.0
        repeated_timings.append(round(dur, 2))
    results["repeated_latencies_ms"] = repeated_timings
    
    # 4. Stream Cancellation
    cancelled_tokens = []
    start_cancel = time.perf_counter()
    for response in stream_generate(model, tokenizer, "Write a long essay on the architecture of modern operating systems.", max_tokens=100):
        cancelled_tokens.append(response.text)
        if len(cancelled_tokens) >= 5:
            # Simulate immediate cancellation
            break
    cancel_time_ms = (time.perf_counter() - start_cancel) * 1000.0
    results["cancellation_tokens_received"] = len(cancelled_tokens)
    results["cancellation_ms"] = round(cancel_time_ms, 2)
    
    # 5. Quality on fixed JARVIS task suite
    task_suite = [
        {"task": "app_control", "prompt": "User says: 'Open Safari'. What action should be taken? Answer in 1 short sentence."},
        {"task": "clipboard", "prompt": "User says: 'Paste the current clipboard content'. What tool is needed? Answer with tool name only."},
        {"task": "emergency", "prompt": "User says: 'STOP EVERYTHING IMMEDIATELY'. What state transition should occur?"}
    ]
    task_results = []
    for t in task_suite:
        out = generate(model, tokenizer, prompt=t["prompt"], max_tokens=40).strip()
        task_results.append({"task": t["task"], "output": out})
    results["task_suite_quality"] = task_results
    
    # 6. Unload & Eviction
    del model
    del tokenizer
    gc.collect()
    if hasattr(mx, "clear_cache"):
        mx.clear_cache()
    elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
        mx.metal.clear_cache()
    results["eviction_completed"] = True
    results["final_rss_mb"] = round(get_peak_rss_mb(), 2)
    
    return results

if __name__ == "__main__":
    res = run_benchmark()
    print(json.dumps(res, indent=2))
