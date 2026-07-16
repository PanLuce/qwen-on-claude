#!/usr/bin/env bash
# install.sh — Symlink qwen-on-claude into ~/.claude/
#
# Idempotent: safe to re-run. Already-correct symlinks are left alone.
# Existing non-symlink files are backed up to <file>.bak-<timestamp>.
#
# Usage:
#   ./install.sh
#
# After running this script, follow the MANUAL STEPS printed at the end.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
TS=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

link() {
    local src="$1"
    local dst="$2"
    mkdir -p "$(dirname "$dst")"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" = "$src" ]; then
            echo "  ✓ already linked: $dst"
            return
        fi
        echo "  ↻ relinking:      $dst"
        rm "$dst"
    elif [ -e "$dst" ]; then
        echo "  ⚠ backing up:     $dst → $dst.bak-$TS"
        mv "$dst" "$dst.bak-$TS"
    fi

    ln -s "$src" "$dst"
    echo "  ✔ linked:         $dst → $src"
}

check_dep() {
    if ! command -v "$1" &>/dev/null; then
        echo "  ⚠ missing: $1 — $2"
    else
        echo "  ✓ found:   $1"
    fi
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

echo ""
echo "── Checking dependencies ──────────────────────────────────────────────"
check_dep ollama    "install from https://ollama.com"
check_dep python3   "Python 3.9+ required"
check_dep curl      "required for Ollama HTTP calls"
check_dep gh        "optional — needed for /code-review-local PR fetching"

# ---------------------------------------------------------------------------
# Symlinks
# ---------------------------------------------------------------------------

echo ""
echo "── Linking agents ─────────────────────────────────────────────────────"
link "$REPO_DIR/agents/qwen-coder.md"        "$CLAUDE_DIR/agents/qwen-coder.md"
link "$REPO_DIR/agents/qwen-reviewer.md"     "$CLAUDE_DIR/agents/qwen-reviewer.md"

echo ""
echo "── Linking commands ───────────────────────────────────────────────────"
link "$REPO_DIR/commands/code-review-local.md" "$CLAUDE_DIR/commands/code-review-local.md"

echo ""
echo "── Linking scripts ────────────────────────────────────────────────────"
link "$REPO_DIR/scripts/lib/__init__.py"     "$CLAUDE_DIR/scripts/lib/__init__.py"
link "$REPO_DIR/scripts/lib/ollama_client.py" "$CLAUDE_DIR/scripts/lib/ollama_client.py"
link "$REPO_DIR/scripts/ollama-call.sh"      "$CLAUDE_DIR/scripts/ollama-call.sh"
link "$REPO_DIR/scripts/ollama-review.py"    "$CLAUDE_DIR/scripts/ollama-review.py"

# ---------------------------------------------------------------------------
# Manual steps
# ---------------------------------------------------------------------------

cat <<MANUAL

── Manual steps (one-time) ─────────────────────────────────────────────────

1. SOURCE the zsh file from ~/.zshrc
   Add this line AFTER your existing CLAUDE_AGENTS / toggle-agent block:

     source "$REPO_DIR/shell/qwen-agent.zsh"

   Then update the Qwen block inside your claude() function.
   Replace the inline heredoc that sets QWEN_AGENT_PROMPT with:

     if [[ "\${CLAUDE_AGENTS[qwen]}" == "1" ]] && [[ -n "\$QWEN_DELEGATION_AGENT_PROMPT" ]]; then
         FINAL_PROMPT="\$FINAL_PROMPT \$QWEN_DELEGATION_AGENT_PROMPT"
     fi

   (Remove the original local QWEN_AGENT_PROMPT heredoc and the
    FINAL_PROMPT="\$FINAL_PROMPT \$QWEN_AGENT_PROMPT" line below it.)

   Then reload: source ~/.zshrc

2. ADD PERMISSIONS to ~/.claude/settings.local.json (inside "allow" array):
   NOTE: use the port that matches your $OLLAMA_HOST — 11434 is the default;
   include the 11435 variants too if you run the metering setup on 11435.

     "Bash(curl -s http://localhost:11434/v1/chat/completions -H 'Content-Type: application/json' -d '{ *)",
     "Bash(curl -s --max-time 1 http://localhost:11434/api/tags)",
     "Bash(curl -s --max-time 0.3 http://localhost:11434/api/tags)",
     "Bash(curl -s http://localhost:11435/v1/chat/completions -H 'Content-Type: application/json' -d '{ *)",
     "Bash(curl -s --max-time 1 http://localhost:11435/api/tags)",
     "Bash(curl -s --max-time 0.3 http://localhost:11435/api/tags)",
     "Bash(mkdir -p ~/.claude/run/ollama-active)",
     "Bash(touch ~/.claude/run/ollama-active/test-flag)",
     "WebFetch(domain:ollama.com)"

3. PULL the model if you haven't already:

     ollama pull qwen2.5-coder:14b

   NOTE: the Ollama activity indicator (🦙⚡) and the whole statusline are now
   rendered by the separate ai-statusline project (~/GIT/ai-statusline). This
   repo only produces the activity flags under ~/.claude/run/ollama-active/
   (via scripts/lib/ollama_client.py); it no longer ships a statusLine renderer.

────────────────────────────────────────────────────────────────────────────
Installation complete. Run the manual steps above, then open a new Claude
Code session to activate the Qwen routing.
MANUAL
