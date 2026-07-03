#!/usr/bin/env python3
"""
Shared Ollama helper for all ~/.claude skills and commands.

Public API
----------
is_available(autostart=False) -> bool
    Check if Ollama is reachable.  When autostart=True, attempts to start
    `ollama serve` and polls up to 5 times before giving up.

call_ollama(system_prompt, user_content, *, temperature=0.1, timeout=120,
            skill=None) -> Any | None
    Single Ollama call.  Returns parsed JSON (any shape), plain text, or None
    on any failure.  Writes an activity flag so ollama-status.sh shows 🦙⚡.
    Appends a row to ~/.claude/cost-watch/ollama-usage.jsonl when skill is given.

call_ollama_batch(jobs, *, max_workers=4, skill=None) -> list
    Parallel fan-out over a list of (system_prompt, user_content) tuples.
    Returns a list of results (None entries for failed calls).
    Emits {"__fallback__": true, "parse_failures": N, "total": M} as the sole
    element when >20% of calls fail, so callers can detect and fall back.

Usage from skill files (inline Python heredoc)
-----------------------------------------------
    python3 - <<'PYEOF'
    import sys; sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
    from lib.ollama_client import is_available, call_ollama
    ...
    PYEOF

Usage from ollama-call.sh
-------------------------
    echo "$USER_CONTENT" | ollama-call.sh --system "..." [--skill NAME] [--temp 0.1]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

OLLAMA_URL: str = os.environ.get("OLLAMA_URL", "http://localhost:11434/v1/chat/completions")
MODEL: str = os.environ.get("OLLAMA_MODEL", "qwen2.5-coder:14b")

_ACTIVE_DIR: str = os.path.expanduser("~/.claude/run/ollama-active")
_USAGE_LOG: str = os.path.expanduser("~/.claude/cost-watch/ollama-usage.jsonl")
_TAGS_URL: str = OLLAMA_URL.replace("/v1/chat/completions", "/api/tags")


# ---------------------------------------------------------------------------
# Availability / autostart
# ---------------------------------------------------------------------------

def is_available(autostart: bool = False) -> bool:
    """Return True if Ollama responds on /api/tags within 1 second."""
    if _probe():
        return True
    if not autostart:
        return False
    try:
        subprocess.Popen(
            ["nohup", "ollama", "serve"],
            stdout=open("/tmp/ollama.log", "a"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except FileNotFoundError:
        return False
    for _ in range(5):
        time.sleep(1)
        if _probe():
            return True
    return False


def _probe() -> bool:
    try:
        r = subprocess.run(
            ["curl", "-s", "--max-time", "1", _TAGS_URL],
            capture_output=True, timeout=2,
        )
        return r.returncode == 0 and len(r.stdout) > 2
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Single call
# ---------------------------------------------------------------------------

def call_ollama(
    system_prompt: str,
    user_content: str,
    *,
    temperature: float = 0.1,
    timeout: int = 120,
    skill: str | None = None,
) -> Any | None:
    """
    Make one Ollama call and return the parsed result, or None on any failure.
    Plain-text responses are returned as strings; JSON responses as dicts/lists.
    """
    os.makedirs(_ACTIVE_DIR, exist_ok=True)
    # Sweep flag files older than 10 s (afterglow window is 3 s, so 10 s is safely past it)
    _now = time.time()
    for _f in os.listdir(_ACTIVE_DIR):
        _fp = os.path.join(_ACTIVE_DIR, _f)
        try:
            if _now - os.path.getmtime(_fp) > 10:
                os.unlink(_fp)
        except OSError:
            pass
    flag = os.path.join(_ACTIVE_DIR, f"{os.getpid()}-{threading.get_ident()}-{time.time_ns()}")
    open(flag, "w").close()
    t0 = time.monotonic()
    try:
        result, token_usage = _call_inner(system_prompt, user_content, temperature=temperature, timeout=timeout)
        _log_usage(skill=skill, elapsed=time.monotonic() - t0, success=result is not None, token_usage=token_usage)
        return result
    finally:
        pass  # flag left in place for 3 s afterglow; swept on next call


def _call_inner(system_prompt: str, user_content: str, *, temperature: float, timeout: int) -> tuple[Any | None, dict]:
    payload = {
        "model": MODEL,
        "temperature": temperature,
        "keep_alive": "30m",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(payload, f)
        path = f.name
    try:
        proc = subprocess.run(
            ["curl", "-s", OLLAMA_URL, "-H", "Content-Type: application/json", "-d", f"@{path}"],
            capture_output=True, text=True, timeout=timeout,
        )
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

    if proc.returncode != 0 or not proc.stdout.strip():
        return None, {}
    try:
        d = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, {}
    if "error" in d:
        return None, {}

    usage = d.get("usage", {})
    token_usage = {
        "input_tokens":  usage.get("prompt_tokens", 0),
        "output_tokens": usage.get("completion_tokens", 0),
    }
    content: str = d["choices"][0]["message"]["content"].strip()
    return _parse_content(content), token_usage


def _parse_content(content: str) -> Any:
    """Strip fences, try JSON, fall back to bracket-regex, then plain string."""
    stripped = re.sub(r"^```(?:json)?\s*", "", content)
    stripped = re.sub(r"\s*```$", "", stripped).strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass
    m = re.search(r"[\[{].*[\]}]", stripped, re.DOTALL)
    if m:
        try:
            return json.loads(m.group())
        except json.JSONDecodeError:
            pass
    return stripped


# ---------------------------------------------------------------------------
# Batch call
# ---------------------------------------------------------------------------

def call_ollama_batch(
    jobs: list[tuple[str, str]],
    *,
    max_workers: int = 4,
    skill: str | None = None,
) -> list[Any]:
    """
    Run multiple (system_prompt, user_content) jobs in parallel.

    Returns a list of results.  If >20% fail (result is None), returns the
    single-element list [{"__fallback__": True, "parse_failures": N, "total": M}]
    so callers can detect and fall back to cloud Claude.
    """
    results: list[Any | None] = [None] * len(jobs)
    failures = 0

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        future_to_idx = {pool.submit(_job_wrapper, sp, uc, skill): i for i, (sp, uc) in enumerate(jobs)}
        for future in as_completed(future_to_idx):
            idx = future_to_idx[future]
            try:
                results[idx] = future.result()
            except Exception:
                failures += 1

    none_count = sum(1 for r in results if r is None)
    total = len(jobs)
    if total > 0 and (none_count + failures) / total > 0.20:
        return [{"__fallback__": True, "parse_failures": none_count + failures, "total": total}]
    return results


def _job_wrapper(system_prompt: str, user_content: str, skill: str | None) -> Any | None:
    return call_ollama(system_prompt, user_content, skill=skill)


# ---------------------------------------------------------------------------
# Self-graded call
# ---------------------------------------------------------------------------

_GRADER_SYSTEM = (
    "You are a strict grader. Score the previous answer on a scale 0-10 for "
    "completeness and specificity to the original task. "
    "0 = empty / refusal / nonsense. "
    "5 = partial, vague, or hedged. "
    "8 = complete, specific, well-formed. "
    "10 = exceptional. "
    "Return ONLY the integer, nothing else."
)


def call_ollama_graded(
    system_prompt: str,
    user_content: str,
    *,
    min_score: int = 6,
    temperature: float = 0.1,
    timeout: int = 120,
    skill: str | None = None,
) -> tuple[Any | None, int | None]:
    """
    Call Ollama, then ask the model to grade its own output 0-10.

    Returns (result, score). If score < min_score or grading fails,
    returns (None, score) so the caller falls back to Claude.

    When min_score is 0, behaves identically to call_ollama() and skips
    the grading round-trip.
    """
    result = call_ollama(
        system_prompt, user_content,
        temperature=temperature, timeout=timeout, skill=skill,
    )
    if result is None:
        _log_grade(skill=skill, score=None)
        return None, None
    if min_score <= 0:
        _log_grade(skill=skill, score=None)
        return result, None

    grade_user = (
        f"Original task:\n{user_content[:4000]}\n\n"
        f"Previous answer:\n{json.dumps(result) if not isinstance(result, str) else result[:4000]}\n\n"
        "Score 0-10."
    )
    raw = call_ollama(
        _GRADER_SYSTEM, grade_user,
        temperature=0.0, timeout=15, skill=None,
    )
    score = _coerce_score(raw)
    _log_grade(skill=skill, score=score)
    if score is None or score < min_score:
        return None, score
    return result, score


def _coerce_score(raw: Any) -> int | None:
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        return max(0, min(10, int(raw)))
    if isinstance(raw, str):
        m = re.search(r"\b([0-9]|10)\b", raw)
        if m:
            return int(m.group(1))
    return None


def _log_grade(*, skill: str | None, score: int | None) -> None:
    if not skill:
        return
    row = {"ts": _iso_now(), "model": MODEL, "skill": skill, "grade": score}
    try:
        os.makedirs(os.path.dirname(_USAGE_LOG), exist_ok=True)
        with open(_USAGE_LOG, "a") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Usage logging
# ---------------------------------------------------------------------------

def _log_usage(*, skill: str | None, elapsed: float, success: bool, token_usage: dict | None = None) -> None:
    if not skill:
        return
    row = {
        "ts": _iso_now(),
        "model": MODEL,
        "skill": skill,
        "input_tokens":  (token_usage or {}).get("input_tokens", 0),
        "output_tokens": (token_usage or {}).get("output_tokens", 0),
        "elapsed_s": round(elapsed, 2),
        "success": success,
    }
    try:
        os.makedirs(os.path.dirname(_USAGE_LOG), exist_ok=True)
        with open(_USAGE_LOG, "a") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:
        pass


def _iso_now() -> str:
    import datetime
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


# ---------------------------------------------------------------------------
# CLI entry point (used by ollama-call.sh)
# ---------------------------------------------------------------------------

def _cli() -> None:
    """
    CLI usage:
        python3 -m lib.ollama_client --system "..." [--skill NAME] [--temp 0.1]
                                     [--timeout 120] [--autostart]
    User content is read from stdin.
    Exits 0 on success (prints result to stdout), 1 if Ollama unavailable,
    2 if call returned None.
    """
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--system", required=True)
    parser.add_argument("--skill", default=None)
    parser.add_argument("--temp", type=float, default=0.1)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--autostart", action="store_true")
    args = parser.parse_args()

    if not is_available(autostart=args.autostart):
        print("ollama_client: Ollama unavailable", file=sys.stderr)
        sys.exit(1)

    user_content = sys.stdin.read()
    result = call_ollama(
        args.system,
        user_content,
        temperature=args.temp,
        timeout=args.timeout,
        skill=args.skill,
    )
    if result is None:
        print("ollama_client: call returned None", file=sys.stderr)
        sys.exit(2)

    if isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)


if __name__ == "__main__":
    _cli()