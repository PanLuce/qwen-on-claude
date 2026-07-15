#!/bin/bash
# Claude Code statusLine wrapper — shows Ollama activity state before the normal status.
# Three states:
#   Active  → 🦙⚡  (Qwen call in flight, flag file present)
#   Idle    → 🦙   (Ollama reachable, no call in flight)
#   Off     → dim grey ●   (Ollama unreachable)
# Rendering of everything else is delegated to the shared default statusline.

INPUT=$(cat)

# Pileup guard: the statusline refreshes every ~1s, but under load a single run can take
# longer than the interval — without this, instances stack up (dozens seen at load avg 25)
# and starve the machine, which in turn makes UserPromptSubmit hooks miss their timeout.
# Atomic mkdir lock (house pattern from auto-sync.sh): if a prior run is still going, echo
# the last rendered line and bail immediately instead of piling on.
LOCK_DIR="$HOME/.claude/run/ollama-status.lock"
CACHE_FILE="$HOME/.claude/run/ollama-status.last"
mkdir -p "$HOME/.claude/run" 2>/dev/null || true
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Reclaim a stale lock (a run that died without cleanup) after 10s.
    if [ -d "$LOCK_DIR" ]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
        [ "$LOCK_AGE" -gt 10 ] && rmdir "$LOCK_DIR" 2>/dev/null
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        [ -f "$CACHE_FILE" ] && cat "$CACHE_FILE"
        exit 0
    fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

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

PY_STATUSLINE="/Users/lukasvitala/development/tools/core/share/utils/claude-statusline-default.py"
if [ -x "$PY_STATUSLINE" ]; then
    OUTPUT=$(printf '%s' "$INPUT" | "$PY_STATUSLINE")
    # prepend the indicator to line 1, pass remaining lines through unchanged
    RENDERED=$(printf '%b %s\n' "$INDICATOR" "$(printf '%s\n' "$OUTPUT" | head -n1 | sed 's/^ *//')"
               printf '%s\n' "$OUTPUT" | tail -n +2)
else
    # fallback so the statusline never goes blank if the shared script disappears
    model=$(printf '%s' "$INPUT" | jq -r '.model.display_name // "?"')
    dir=$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // empty' | sed "s|$HOME|~|")
    RENDERED=$(printf '%b %s | %s\n' "$INDICATOR" "$model" "$dir")
fi

# Emit, and cache for the pileup guard to echo while a slow run holds the lock.
printf '%s\n' "$RENDERED"
printf '%s\n' "$RENDERED" > "$CACHE_FILE" 2>/dev/null || true
