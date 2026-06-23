#!/bin/bash
# Claude Code statusLine wrapper — shows Ollama activity state before the normal status.
# Three states:
#   Active  → bold orange 🦙  (Qwen call in flight, flag file present)
#   Idle    → dim peach  🦙  (Ollama reachable, no call in flight)
#   Off     → dim grey   ●   (Ollama unreachable)

INPUT=$(cat)

ACTIVE_DIR="$HOME/.claude/run/ollama-active"
ACTIVE=0
if [ -d "$ACTIVE_DIR" ]; then
    NOW=$(date +%s)
    for f in "$ACTIVE_DIR"/*; do
        [ -f "$f" ] || continue
        MTIME=$(stat -f %m "$f" 2>/dev/null) || continue
        AGE=$((NOW - MTIME))
        if [ "$AGE" -lt 3 ]; then
            ACTIVE=1
            break
        fi
    done
fi

if [ "$ACTIVE" -eq 1 ]; then
    INDICATOR='🦙⚡'
elif curl -s --max-time 0.3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    INDICATOR='🦙'
else
    INDICATOR=$(printf '\033[2;90m●\033[0m')
fi

model=$(echo "$INPUT" | jq -r '.model.display_name')
dir=$(echo "$INPUT" | jq -r '.workspace.current_dir' | sed "s|$HOME|~|")
used=$(echo "$INPUT" | jq -r '.context_window.used_percentage // empty')
cost=$($HOME/.claude/cost-watch/cost-watch.sh --week-cost 2>/dev/null)

if [ -n "$used" ]; then
    pct=$(printf '%.0f' "$used")
    filled=$((pct / 5))
    if [ $pct -lt 50 ]; then color='\033[32m'; elif [ $pct -lt 75 ]; then color='\033[33m'; else color='\033[31m'; fi
    reset='\033[0m'
    bar=''
    i=0
    while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i + 1)); done
    while [ $i -lt 20 ]; do bar="${bar}░"; i=$((i + 1)); done
    printf '%b %s | %s | %b%s %d%%%b | %s' "$INDICATOR" "$model" "$dir" "$color" "$bar" "$pct" "$reset" "$cost"
else
    printf '%b %s | %s | %s' "$INDICATOR" "$model" "$dir" "$cost"
fi
