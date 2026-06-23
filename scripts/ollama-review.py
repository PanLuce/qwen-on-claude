#!/usr/bin/env python3
"""
PR-specific Qwen-Ollama review harness.

Inputs (environment variables):
  PR_DIFF          — full PR diff text (required)
  PR_INTENT        — JSON intent block from the pre-pass (optional, defaults to empty)
  CLAUDE_MD_PATHS  — newline-separated list of CLAUDE.md relative paths (optional)

Output (stdout):
  JSON array of findings: [{"file": str, "line": int, "why": str, ...}]
  OR {"__fallback__": true, "parse_failures": int, "total": int}  if >20% chunks fail

Exit codes:
  0 — normal (even if fallback sentinel emitted)
  1 — required env var missing
"""
import json
import os
import re
import sys
from concurrent.futures import as_completed

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPTS_DIR)
from lib.ollama_client import call_ollama, call_ollama_batch  # noqa: E402


def main():
    diff = os.environ.get("PR_DIFF")
    if not diff:
        print("ollama-review.py: PR_DIFF not set", file=sys.stderr)
        sys.exit(1)

    pr_intent = os.environ.get("PR_INTENT", "")
    claude_md_paths = os.environ.get("CLAUDE_MD_PATHS", "")

    claude_md_content = ""
    for p in claude_md_paths.splitlines():
        p = p.strip()
        if p and os.path.isfile(p):
            try:
                claude_md_content += f"\n\n# {p}\n" + open(p).read()
            except Exception:
                pass

    chunks = re.split(r"(?=^diff --git )", diff, flags=re.MULTILINE)
    chunks = [c for c in chunks if c.strip()]

    intent_preamble = ""
    if pr_intent.strip():
        intent_preamble = (
            "PR INTENT (whole-PR context — use to suppress false positives):\n"
            f"{pr_intent}\n\n"
            "Per the intent above: do NOT flag removals of symbols listed in 'deleted_symbols' "
            "or files in 'deleted_files'. "
            "Do NOT flag rename-related changes that match the 'renames' list. "
            "Treat 'intentional_removals' as ground truth — these are deliberate, safe deletions.\n\n"
        )

    default_bug_system = (
        "You are a code reviewer scanning a diff for bugs and logic errors.\n"
        "Review ONLY changed lines (starting with +). Do not flag pre-existing issues.\n"
        "Focus on: null/undefined dereferences, missing error handling, incorrect async/await, "
        "logic errors, order-of-operations bugs, off-by-one, security issues, silent failures.\n"
        'Return ONLY a JSON array. Each item: {"file": string, "line": number, "why": string}.\n'
        "If no bugs, return []. Do NOT wrap in markdown fences."
    )

    default_compliance_system = (
        "You are a code reviewer checking whether a PR diff complies with the project CLAUDE.md guidelines.\n"
        "Review ONLY changed lines (starting with +). Do not flag pre-existing issues.\n"
        'Return ONLY a JSON array. Each item: {"file": string, "line": number, "why": string, "claude_md_quote": string}.\n'
        "If no violations, return []. Do NOT wrap in markdown fences."
    )

    bug_system = intent_preamble + os.environ.get("BUG_SYSTEM_PROMPT", default_bug_system)
    compliance_system = intent_preamble + os.environ.get("COMPLIANCE_SYSTEM_PROMPT", default_compliance_system)

    def review_chunk(chunk):
        if len(chunk.strip()) < 50:
            return []
        results = []
        bugs = call_ollama(bug_system, f"Review this diff:\n\n{chunk}\n\nReturn raw JSON array only.", skill="code-review-local")
        if isinstance(bugs, list):
            results.extend(bugs)
        if claude_md_content:
            compliance = call_ollama(
                compliance_system,
                f"CLAUDE.md:\n{claude_md_content}\n\nDiff:\n{chunk}\n\nReturn raw JSON array only.",
                skill="code-review-local",
            )
            if isinstance(compliance, list):
                results.extend(compliance)
        return results

    all_findings = []
    parse_failures = 0

    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(review_chunk, chunk): chunk for chunk in chunks}
        for future in as_completed(futures):
            try:
                result = future.result()
                all_findings.extend(result)
            except Exception:
                parse_failures += 1

    total = len(chunks)
    if total > 0 and parse_failures / total > 0.20:
        print(json.dumps({"__fallback__": True, "parse_failures": parse_failures, "total": total}))
    else:
        print(json.dumps(all_findings))


if __name__ == "__main__":
    main()