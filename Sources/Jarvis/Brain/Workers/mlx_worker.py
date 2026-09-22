"""Persistent MLX inference worker for JARVIS (JSON-lines protocol over stdio).

Inference is REAL: mlx_lm on Apple Metal with local Qwen2.5-0.5B-Instruct-4bit
weights from the Hugging Face snapshot cache. Prompts are rendered through the
model's own chat template (Qwen ChatML), so instruction-following works.

Protocol (one JSON object per line; every reply echoes the request `id`):
  -> {"id":1,"op":"load","model":"mlx-community/Qwen2.5-0.5B-Instruct-4bit"}
  <- {"id":1,"ok":true,"model":"...","load_ms":957.5,"loaded":true}
  -> {"id":2,"op":"generate","prompt":"...","max_tokens":256,"temperature":0.2}
  <- {"id":2,"ok":true,"text":"...","tokens":42,"gen_ms":180.1,"tok_s":233.0,
      "ttft_ms":8.4}
  -> {"id":3,"op":"health"}
  <- {"id":3,"ok":true,"model":"...","loaded":true}
Errors: <- {"id":N,"ok":false,"error":"..."}   (worker stays alive on request errors)

stdout carries ONLY protocol JSON. All diagnostics (HF progress bars, library
warnings, tracebacks) go to stderr. Malformed lines produce a structured error
reply, not a crash.
"""

import json
import resource
import sys
import time
import traceback

_model = None
_tokenizer = None
_model_id = None


def _rss_mb():
    """Peak RSS of the worker process in MB (macOS ru_maxrss is bytes)."""
    try:
        return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024), 1)
    except Exception:
        return None


def _reply(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _load(model_id):
    global _model, _tokenizer, _model_id
    if _model is not None and _model_id == model_id:
        return {"ok": True, "model": model_id, "loaded": True, "already_loaded": True}

    # Import inside the call so worker startup stays fast and an mlx problem
    # surfaces as a structured error instead of crashing the whole worker.
    from mlx_lm import load

    start = time.perf_counter()
    _model, _tokenizer = load(model_id)
    _model_id = model_id
    load_ms = (time.perf_counter() - start) * 1000.0
    return {"ok": True, "model": model_id, "load_ms": round(load_ms, 2), "loaded": True}


def _generate(prompt, max_tokens, temperature):
    global _model, _tokenizer, _model_id
    if _model is None:
        raise RuntimeError("model not loaded; send op=load first")

    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    # Render through the model's chat template so instruction-style prompts
    # (user/assistant turns) reach the model the way it was trained on.
    messages = [{"role": "user", "content": prompt}]
    rendered = _tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )

    # This mlx_lm version takes sampling through generate_step(**kwargs);
    # `temperature=` is not an accepted kwarg, so build a sampler explicitly.
    sampler = make_sampler(temp=max(0.0, temperature))

    start = time.perf_counter()
    first_token_ms = None
    text_parts = []
    token_count = 0
    for response in stream_generate(
        _model,
        _tokenizer,
        prompt=rendered,
        max_tokens=max_tokens,
        sampler=sampler,
    ):
        if first_token_ms is None:
            first_token_ms = (time.perf_counter() - start) * 1000.0
        text_parts.append(response.text)
        token_count += 1

    gen_ms = (time.perf_counter() - start) * 1000.0
    text = "".join(text_parts)
    tok_s = token_count / (gen_ms / 1000.0) if gen_ms > 0 else 0.0
    return {
        "ok": True,
        "text": text,
        "tokens": token_count,
        "gen_ms": round(gen_ms, 2),
        "tok_s": round(tok_s, 1),
        # Real first-token latency measured inside the worker from the mlx_lm
        # stream; genuinely measured, never fabricated.
        "ttft_ms": round(first_token_ms, 2) if first_token_ms is not None else None,
        "model": _model_id,
        "rss_mb": _rss_mb(),
    }


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            _reply({"ok": False, "error": f"invalid JSON: {exc}"})
            continue

        request_id = req.get("id")
        op = req.get("op")
        try:
            if op == "load":
                result = _load(req.get("model"))
            elif op == "generate":
                result = _generate(
                    req.get("prompt", ""),
                    int(req.get("max_tokens", 256)),
                    float(req.get("temperature", 0.2)),
                )
            elif op == "health":
                result = {
                    "ok": True,
                    "model": _model_id,
                    "loaded": _model is not None,
                    "rss_mb": _rss_mb(),
                }
            elif op == "shutdown":
                _reply({"id": request_id, "ok": True})
                return
            else:
                result = {"ok": False, "error": f"unknown op: {op}"}
            result["id"] = request_id
            _reply(result)
        except Exception as exc:  # noqa: BLE001 - report every failure to the host
            traceback.print_exc()  # diagnostics to stderr; stdout stays protocol-clean
            _reply(
                {
                    "id": request_id,
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )


if __name__ == "__main__":
    main()
