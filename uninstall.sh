#!/usr/bin/env bash
# uninstall.sh — Remove symlinks installed by install.sh
#
# Only removes symlinks whose target points back into this repo.
# Will not touch files that were backed up or manually created.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

remove_if_mine() {
    local dst="$1"
    if [ -L "$dst" ]; then
        local target
        target=$(readlink "$dst")
        if [[ "$target" == "$REPO_DIR"* ]]; then
            rm "$dst"
            echo "  ✔ removed: $dst"
        else
            echo "  ✗ skipped (points elsewhere): $dst → $target"
        fi
    elif [ -e "$dst" ]; then
        echo "  ✗ skipped (not a symlink): $dst"
    else
        echo "  – not found: $dst"
    fi
}

echo ""
echo "── Removing agent symlinks ─────────────────────────────────────────────"
remove_if_mine "$CLAUDE_DIR/agents/qwen-coder.md"
remove_if_mine "$CLAUDE_DIR/agents/qwen-reviewer.md"

echo ""
echo "── Removing command symlinks ───────────────────────────────────────────"
remove_if_mine "$CLAUDE_DIR/commands/code-review-local.md"

echo ""
echo "── Removing script symlinks ────────────────────────────────────────────"
remove_if_mine "$CLAUDE_DIR/scripts/lib/__init__.py"
remove_if_mine "$CLAUDE_DIR/scripts/lib/ollama_client.py"
remove_if_mine "$CLAUDE_DIR/scripts/ollama-call.sh"
remove_if_mine "$CLAUDE_DIR/scripts/ollama-review.py"

cat <<MANUAL

── Manual cleanup ──────────────────────────────────────────────────────────

1. Remove the source line from ~/.zshrc:
     source "...qwen-on-claude/shell/qwen-agent.zsh"

2. Revert the claude() function's Qwen block back to the original inline
   heredoc (or remove the qwen agent block entirely if no longer needed).

3. Remove the Ollama permission entries from ~/.claude/settings.local.json
   if you no longer want them.

MANUAL
