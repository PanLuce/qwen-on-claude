#!/bin/bash
# Claude Code statusLine wrapper — shows Ollama activity state before the normal status.
# Three states:
#   Active  → 🦙⚡  (Qwen call in flight, flag file present)
#   Idle    → 🦙   (Ollama reachable, no call in flight)
#   Off     → dim grey ●   (Ollama unreachable)
# Rendering of everything else is delegated to the shared default statusline.

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

PY_STATUSLINE="/Users/lukasvitala/development/tools/core/share/utils/claude-statusline-default.py"
if [ -x "$PY_STATUSLINE" ]; then
    OUTPUT=$(printf '%s' "$INPUT" | "$PY_STATUSLINE")
    # prepend the indicator to line 1, pass remaining lines through unchanged
    printf '%b %s\n' "$INDICATOR" "$(printf '%s\n' "$OUTPUT" | head -n1 | sed 's/^ *//')"
    printf '%s\n' "$OUTPUT" | tail -n +2
else
    # fallback so the statusline never goes blank if the shared script disappears
    model=$(printf '%s' "$INPUT" | jq -r '.model.display_name // "?"')
    dir=$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // empty' | sed "s|$HOME|~|")
    printf '%b %s | %s\n' "$INDICATOR" "$model" "$dir"
fi
