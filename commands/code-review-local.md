---
description: Code review using local Ollama model (Qwen2.5-Coder-14B) — inline comments, cost-optimized, posts nothing if no findings above threshold. Requires Ollama running at localhost:11434.
argument-hint: <pr-number-or-url>
---

# /code-review-local

Review the PR provided as $ARGUMENTS using a locally-hosted LLM (Ollama) for the bug scan and CLAUDE.md compliance steps.

## Step 1 — Eligibility (Bash, NOT agent)

Run:
```
gh pr view <pr> --json state,isDraft,reviews,headRefOid,headRepository,baseRefName,author
```

- If `state != OPEN`, `isDraft == true`, or there is already a review by the current user → STOP and report to the user.
- Otherwise, capture: `HEAD_SHA`, `owner`, `repo`, `base branch`.

## Step 2 — Fetch the diff ONCE

```
gh pr diff <pr>
```

Save it to a variable. This diff will be passed to every step below — DO NOT re-fetch.

## Step 3 — Pre-flight short-circuit

If the diff is 100% noise (only `pom.xml` version bumps, `snapshots.json`, `.release-notes-snapshot`):
- Report "noise-only PR — skipping review" to the user
- POST NOTHING to GitHub
- STOP

Probe Ollama readiness (endpoint honors `$OLLAMA_HOST`, default `http://localhost:11434`):
```bash
curl -s --max-time 1 "${OLLAMA_HOST:-http://localhost:11434}/api/tags"
```

If that call fails or times out, auto-start Ollama:
```bash
nohup ollama serve > /tmp/ollama.log 2>&1 &
```
Then poll `${OLLAMA_HOST:-http://localhost:11434}/api/tags` once per second for up to 5 attempts. If still unreachable after 5 attempts, fall back to `/code-review` (Sonnet via Bedrock) and report to the user: `🦙 Ollama unavailable — fell back to Sonnet`. Then STOP (let the user invoke `/code-review` normally).

## Step 4 — CLAUDE.md inventory (Bash, NOT an agent)

No LLM needed here. Run:
```bash
# Get all dirs touched by the PR, then find CLAUDE.md files in or above them
gh pr diff <pr> --name-only | xargs -I{} dirname {} | sort -u | while read d; do
  # walk up from each dir to repo root looking for CLAUDE.md
  p="$d"
  while [ "$p" != "." ] && [ "$p" != "/" ]; do
    [ -f "$p/CLAUDE.md" ] && echo "$p/CLAUDE.md"
    p=$(dirname "$p")
  done
  [ -f "CLAUDE.md" ] && echo "CLAUDE.md"
done | sort -u
```

Capture the output as `CLAUDE_MD_PATHS` (newline-separated list of relative paths). This replaces the prior Haiku agent call — no tokens spent, no round-trip latency.

## Step 4.5 — PR-intent pre-pass (ONE Ollama call, NOT an agent)

Call Ollama directly (via Bash `curl`) to produce the intent block. This is NOT a Haiku agent — everything in this pipeline calls Qwen locally.

```bash
PR_INTENT=$(python3 - <<'PYEOF'
import json, subprocess, tempfile, os, re

payload = {
    "model": "qwen2.5-coder:14b",
    "temperature": 0.0,
    "keep_alive": "30m",
    "max_tokens": 400,
    "messages": [
        {"role": "system", "content": (
            "You are a diff analyser. Read the PR diff and return ONLY a raw JSON object — "
            "no markdown fences, no prose, no explanation:\n"
            '{"summary":"one-sentence purpose of this PR",'
            '"deleted_symbols":["ClassName or functionName fully removed in this PR"],'
            '"deleted_files":["path/to/fully/deleted.ts"],'
            '"renames":[{"from":"OldName","to":"NewName"}],'
            '"intentional_removals":["human-readable note about deliberate removals"]}'
            "\nUse empty arrays if none apply. Output raw JSON only."
        )},
        {"role": "user", "content": f"PR diff:\n\n{os.environ['PR_DIFF'][:60000]}"}
    ]
}
with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
    json.dump(payload, f)
    path = f.name
_ollama = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
if not _ollama.startswith("http"):
    _ollama = "http://" + _ollama
result = subprocess.run(
    ["curl", "-s", _ollama.rstrip("/") + "/v1/chat/completions",
     "-H", "Content-Type: application/json", "-d", f"@{path}"],
    capture_output=True, text=True, timeout=60
)
os.unlink(path)
try:
    d = json.loads(result.stdout)
    content = d["choices"][0]["message"]["content"].strip()
    content = re.sub(r'^```json\s*', '', content)
    content = re.sub(r'\s*```$', '', content).strip()
    json.loads(content)  # validate
    print(content)
except Exception:
    print('{"summary":"","deleted_symbols":[],"deleted_files":[],"renames":[],"intentional_removals":[]}')
PYEOF
)
```

Run this block with `dangerouslyDisableSandbox` so it can reach `localhost:11434`. Capture stdout as `PR_INTENT`. Pass to the Step 5 Python script via the `PR_INTENT` environment variable.

## Step 5 — Local LLM reviewers (Bash, NOT agents)

**Delegates to the shared harness at `~/.claude/scripts/ollama-review.py`.**

Emit: `🦙 local: dispatching <N> chunks (parallel-4)...` (compute N as `echo "$PR_DIFF" | grep -c '^diff --git'`).

```bash
STEP5_FINDINGS=$(PR_DIFF="$PR_DIFF" PR_INTENT="$PR_INTENT" CLAUDE_MD_PATHS="$CLAUDE_MD_PATHS" \
  python3 ~/.claude/scripts/ollama-review.py)
```

Run with `dangerouslyDisableSandbox` so it can reach `localhost:11434`. Capture stdout as `STEP5_FINDINGS`.

The script splits the diff on `diff --git` headers, runs bug-scan + CLAUDE.md-compliance Ollama calls for each chunk using `ThreadPoolExecutor(max_workers=4)`, and returns either a JSON findings array or `{"__fallback__": true, ...}` if >20% of chunks fail to parse.

## Step 6 — Filter false positives

Drop any finding that:
- Is a pre-existing issue not introduced by this PR's diff
- Is a typecheck, lint, or compile issue (CI catches these)
- Is a stylistic nitpick not explicitly called out in CLAUDE.md
- Is on a line outside the diff hunk

## Step 7 — Batch confidence scoring (ONE Ollama call, NOT an agent)

Check whether the Step 5 output contains `{"__fallback__": true, ...}`. If yes, abort the local pipeline and report to the user: `🦙 local: X/Y chunks failed to parse — fell back to Sonnet`. Then STOP (let the user invoke `/code-review` normally).

Otherwise, call Ollama directly to score all surviving findings:

```bash
SCORED=$(python3 - <<'PYEOF'
import json, subprocess, tempfile, os, re

findings = json.loads(os.environ["STEP5_FINDINGS"])
diff_snippet = os.environ["PR_DIFF"][:20000]

payload = {
    "model": "qwen2.5-coder:14b",
    "temperature": 0.0,
    "keep_alive": "30m",
    "messages": [
        {"role": "system", "content": (
            "You are a code review scorer. Given a list of findings and the PR diff, "
            "add a 'score' field (0–100) to each finding:\n"
            "0 = false positive or pre-existing issue\n"
            "25 = might be real but unverified\n"
            "50 = real but minor or nitpick\n"
            "75 = real, important, will hit in practice OR explicit CLAUDE.md violation\n"
            "100 = certain, frequent, evidence direct\n"
            "Return ONLY the same JSON array with 'score' added to each item. No prose, no fences."
        )},
        {"role": "user", "content": (
            f"Findings:\n{json.dumps(findings)}\n\n"
            f"PR diff (first 20k chars):\n{diff_snippet}"
        )}
    ]
}
with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
    json.dump(payload, f)
    path = f.name
_ollama = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
if not _ollama.startswith("http"):
    _ollama = "http://" + _ollama
result = subprocess.run(
    ["curl", "-s", _ollama.rstrip("/") + "/v1/chat/completions",
     "-H", "Content-Type: application/json", "-d", f"@{path}"],
    capture_output=True, text=True, timeout=90
)
os.unlink(path)
try:
    d = json.loads(result.stdout)
    content = d["choices"][0]["message"]["content"].strip()
    content = re.sub(r'^```json\s*', '', content)
    content = re.sub(r'\s*```$', '', content).strip()
    scored = json.loads(content)
    # fallback: if scoring failed, return findings with score=75 so nothing is silently dropped
    if not isinstance(scored, list):
        raise ValueError
    print(json.dumps(scored))
except Exception:
    # scoring failed — pass findings through with conservative score=75
    for item in findings:
        item.setdefault("score", 75)
    print(json.dumps(findings))
PYEOF
)
```

Run with `dangerouslyDisableSandbox`. Filter to `score >= 80`.

## Step 8 — Empty-review short-circuit (NON-NEGOTIABLE)

If filtered findings == 0:
- Report "No findings above threshold — nothing posted" to the user in chat
- POST NOTHING — no curl, no `gh pr comment`, no `pulls/{n}/reviews` call
- STOP

## Step 9 — Re-check eligibility (Bash, NOT agent)

Re-run the `gh pr view` from Step 1. If state changed or PR was closed/merged, abort.

## Step 10 — Post inline comments

Invoke the Skill tool: `github-pr-comment` (ai-tools, common). Use **Pattern B** — post a single review to `pulls/{pr}/reviews` with all comments anchored via `{path, line, side: "RIGHT", body}`. Use `HEAD_SHA` captured in Step 1 as `commit_id`.

DO NOT use Pattern A (overview comment). DO NOT use `gh pr comment`.

## Step 11 — Run summary footer

After Step 10 (or after any STOP that produces a real outcome), print one line to the user summarising what happened:

- Success: `🦙 local: <N> chunks parallel-4, <elapsed>s warm, <total_findings> raw → <posted> above threshold, posted`
- Empty review: `🦙 local: <N> chunks parallel-4, <elapsed>s warm, 0 above threshold — nothing posted`
- Ollama unavailable: `🦙 Ollama unavailable — fell back to Sonnet`
- Parse failure fallback: `🦙 local: <X>/<N> chunks failed to parse — fell back to Sonnet`

This footer is the user's only window into whether the local pipeline is actually working. Never suppress it.

## Notes

- Do not run builds, typechecks, or tests — CI handles those.
- Cite each finding with a full-SHA permalink:
  `https://github.com/<owner>/<repo>/blob/<HEAD_SHA>/<path>#L<start>-L<end>`
  Provide ≥1 line of context above and below the flagged line in the range.
- **Pipeline shape:** Opus-orchestrates → Qwen-intent → Qwen-executes-per-chunk (parallel-4) → Qwen-scores. No Haiku calls anywhere in this command.
- **Model:** `qwen2.5-coder:14b` via Ollama at localhost:11434. Cold start ~24s. Warm per-chunk latency and full-PR benchmark TBD after first real run.
- **Fallback:** If Ollama unavailable after 5 start attempts, or >20% chunks fail to parse, report to user and STOP — user runs `/code-review` (Sonnet) manually.
- **Routing rule** (enforce at Step 1, before any Ollama work): if `deletions/(additions+deletions) > 30%` or `file_count < 15`, this command is not appropriate — report to user and STOP, recommend `/code-review` instead.
