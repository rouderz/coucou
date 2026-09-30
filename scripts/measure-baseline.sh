#!/usr/bin/env bash
# Baseline measurements for issue #1 (compare against them after the F2 work).
#
#   bash scripts/measure-baseline.sh cpu [seconds]   Sample Coucou's CPU and memory (default 60 s)
#   bash scripts/measure-baseline.sh tokens          Stream per-request token usage from the chat
#
# Suggested runs:
#   1. Island hidden, nothing running:      cpu 60
#   2. Island hidden, integrations enabled: cpu 60
#   3. Island open (hover the notch):       cpu 30
#   4. `tokens`, then ask 10 questions in one chat with a PDF attached
set -euo pipefail

mode="${1:-cpu}"

case "$mode" in
  cpu)
    secs="${2:-60}"
    pid=$(pgrep -x Coucou | head -1) || { echo "Coucou is not running." >&2; exit 1; }
    echo "Sampling Coucou (pid $pid) for ${secs}s…"
    # top's first sample has no CPU delta, so take one extra and drop it.
    top -l "$((secs + 1))" -s 1 -pid "$pid" -stats pid,cpu,mem 2>/dev/null | awk -v pid="$pid" '
      function mb(v,  n, u) {
        n = v + 0; u = substr(v, length(v), 1)
        if (u == "K") return n / 1024
        if (u == "G") return n * 1024
        if (u == "B") return n / 1048576
        return n
      }
      $1 == pid {
        if (++seen == 1) next
        c = $2 + 0; m = mb($3)
        sc += c; sm += m; n++
        if (c > mc) mc = c
        if (m > mm) mm = m
      }
      END {
        if (n == 0) { print "No samples collected."; exit 1 }
        printf "Samples:   %d\n", n
        printf "CPU:       avg %.2f %%   max %.2f %%\n", sc / n, mc
        printf "Memory:    avg %.1f MB   max %.1f MB\n", sm / n, mm
      }'
    ;;
  tokens)
    echo "Streaming token usage (Ctrl-C to stop). Ask questions in the island chat…"
    log stream --level info --style compact \
      --predicate 'subsystem == "fr.louisraille.NotchBuddy" AND category == "claude"'
    ;;
  *)
    echo "Usage: $0 cpu [seconds] | tokens" >&2
    exit 2
    ;;
esac
