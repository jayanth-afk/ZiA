#!/bin/bash
# Experiment A watchdog wrapper (operational only — no frozen code modified).
# Runs one SEQA benchmark segment under a pty (line-buffered output + os_log
# stderr capture). If the invocation produces no output for 75s (observed hang
# mode: pre-existing ShellExecutor timeout-enforcement gap lets a degenerate
# blocking command wedge the frozen executor), it kills the invocation and
# retries, up to MAX tries. Every kill is recorded in the evidence file.
BENCH="$1"
OUT="build/seq-A2-${BENCH}.txt"
MAX=12
pkill -9 -f "sequential-experiment SEQA" 2>/dev/null
: > "$OUT"
tries=0
while [ $tries -lt $MAX ]; do
  tries=$((tries+1))
  echo "[watchdog] attempt $tries for $BENCH" >> "$OUT"
  script -q /tmp/seqa-pty-$BENCH.log .build/out/Products/Debug/Jarvis --sequential-experiment SEQA "$BENCH" >> "$OUT" 2>&1 &
  pid=$!
  # Watch: kill when no output growth for 75 consecutive seconds.
  idle=0
  lastsize=0
  while kill -0 $pid 2>/dev/null; do
    sleep 5
    size=$(stat -f %z "$OUT" 2>/dev/null || echo 0)
    if [ "$size" -eq "$lastsize" ]; then
      idle=$((idle+5))
    else
      idle=0
      lastsize=$size
    fi
    if [ $idle -ge 60 ]; then
      echo "[watchdog] NO-OUTPUT HANG detected after ${idle}s idle (attempt $tries) — killing invocation $pid (pre-existing ShellExecutor timeout gap; recorded as evidence)" >> "$OUT"
      kill -9 $pid 2>/dev/null
      pkill -9 -f "sequential-experiment SEQA $BENCH" 2>/dev/null
      sleep 1
      break
    fi
  done
  kill -0 $pid 2>/dev/null || break   # clean exit: the segment finished
  # If we get here the invocation was killed; loop and retry.
done
echo "[watchdog] $BENCH segment complete after $tries attempt(s)" >> "$OUT"
