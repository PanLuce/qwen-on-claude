# qwen-on-claude

Route bounded code-generation tasks from Claude Code to a locally-running Qwen model via Ollama, cutting AWS Bedrock costs for boilerplate work without compromising quality.

## What it does

When Claude Code (Opus) is about to write mechanical code — a boilerplate scaffold, a type translation, a minimal TDD green-phase implementation — this workflow intercepts and delegates to **Qwen3-Coder-30B (MoE, ~3B active)** running locally. Claude reviews the output and applies it. If Ollama is unreachable or Qwen's self-grade is below threshold, it falls back to Claude silently.

### When Qwen handles it (GOOD-fit)

- Writing the minimal implementation that makes a failing test pass (TDD Green phase)
- Boilerplate scaffolding: new route handler, controller skeleton, test file shell, new component file
- Mechanical translations: callback → Promise, Promise → async/await, CommonJS → ESM, untyped → typed signatures
- Generating JSDoc/TSDoc/docstrings for given function signatures
- Generating a TypeScript interface from an example JSON shape
- Writing a small standalone utility function with a clear contract (input → output)

### When Claude keeps it (BAD-fit — do NOT delegate)

- Anything requiring tool use — Edit, Write, Bash, Read across multiple files
- Debugging — needs context Qwen does not hold
- Multi-file refactors — judgment about cohesion and architectural fit
- Design decisions, library choices, naming/API design, code review
- TDD Red phase (test design) and Refactor phase (cleanup judgment)

---

## Requirements

- macOS or Linux
- [Ollama](https://ollama.com) installed and on `PATH`
- Model pulled: `ollama pull qwen3-coder:30b`
- Python 3.9+
- `curl`
- `gh` CLI (for `/code-review-local`)
- [Claude Code](https://claude.ai/code) with `~/.claude/` directory

---

## Install

```bash
git clone https://github.com/your-username/qwen-on-claude.git ~/GIT/qwen-on-claude
cd ~/GIT/qwen-on-claude
chmod +x install.sh uninstall.sh
./install.sh
```

Follow the **manual steps** printed by the installer (takes ~2 minutes):

### 1. Source the zsh file

Add to `~/.zshrc`, after your existing `CLAUDE_AGENTS` / `toggle-agent` block:

```zsh
source "$HOME/GIT/qwen-on-claude/shell/qwen-agent.zsh"
```

Then update the `claude()` function — replace the inline Qwen heredoc with:

```zsh
if [[ "${CLAUDE_AGENTS[qwen]}" == "1" ]] && [[ -n "$QWEN_DELEGATION_AGENT_PROMPT" ]]; then
    FINAL_PROMPT="$FINAL_PROMPT $QWEN_DELEGATION_AGENT_PROMPT"
fi
```

Reload: `source ~/.zshrc`

### 2. Add permissions to `~/.claude/settings.local.json`

Inside the `"allow"` array:

```json
"Bash(curl -s http://localhost:11434/v1/chat/completions -H 'Content-Type: application/json' -d '{ *)",
"Bash(curl -s --max-time 1 http://localhost:11434/api/tags)",
"Bash(curl -s --max-time 0.3 http://localhost:11434/api/tags)",
"Bash(~/.claude/scripts/ollama-status.sh)",
"Bash(mkdir -p ~/.claude/run/ollama-active)",
"Bash(touch ~/.claude/run/ollama-active/test-flag)",
"WebFetch(domain:ollama.com)"
```

### 3. Add statusLine to `~/.claude/settings.json`

Inside the `"ui"` section:

```json
"statusLine": {
  "command": "$HOME/.claude/scripts/ollama-status.sh"
}
```

### 4. Pull the model

```bash
ollama pull qwen3-coder:30b
```

---

## Uninstall

```bash
./uninstall.sh
```

Then follow the printed manual cleanup steps.

---

## Files

```
qwen-on-claude/
├── install.sh                   # symlinks repo → ~/.claude/, prints zsh steps
├── uninstall.sh                 # removes those symlinks
├── shell/
│   └── qwen-agent.zsh           # source from ~/.zshrc; owns QWEN_DELEGATION_AGENT_PROMPT
├── agents/
│   ├── qwen-coder.md            # subagent: code generator shim
│   └── qwen-reviewer.md         # subagent: chunk reviewer shim
├── commands/
│   └── code-review-local.md     # /code-review-local slash command
└── scripts/
    ├── lib/
    │   ├── __init__.py
    │   └── ollama_client.py     # shared library: is_available, call_ollama, call_ollama_graded
    ├── ollama-call.sh           # bash CLI wrapper for ollama_client
    ├── ollama-review.py         # PR-review harness (parallel chunk fan-out)
    └── ollama-status.sh         # Claude Code statusLine renderer
```

## Runtime data (not in repo)

| Path | Purpose |
|---|---|
| `~/.claude/run/ollama-active/` | In-flight call flag files (for status line) |
| `~/.claude/cost-watch/ollama-usage.jsonl` | Per-call usage log |
| `/tmp/ollama.log` | Ollama autostart stdout |

These are created on demand by `ollama_client.py`. You can delete them safely at any time.

## Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434/v1/chat/completions` | Override Ollama endpoint |
| `OLLAMA_MODEL` | `qwen3-coder:30b` | Override model |

## CLAUDE.md pointer

Add to your personal `~/.claude/CLAUDE.md`:

```
## Qwen routing policy

See ~/GIT/qwen-on-claude/README.md for GOOD-fit / BAD-fit delegation rules.
```
