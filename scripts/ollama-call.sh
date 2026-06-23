#!/usr/bin/env bash
# Thin shell entry point to ollama_client.py for use in skill files.
#
# Usage:
#   echo "$USER_CONTENT" | ollama-call.sh --system "..." [options]
#
# Options:
#   --system  STR     System prompt (required)
#   --skill   NAME    Skill name for usage logging (optional)
#   --temp    FLOAT   Temperature (default: 0.1)
#   --timeout INT     Timeout seconds (default: 120)
#   --autostart       Attempt to start ollama if not running
#
# Exit codes:
#   0  success — result printed to stdout
#   1  Ollama unavailable (even after autostart if requested)
#   2  Call returned no result (parse failure)
#
# The result is printed as-is to stdout:
#   - JSON arrays/objects → raw JSON
#   - plain text → raw string
#
# Sandbox note: caller must use dangerouslyDisableSandbox to reach localhost:11434.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 -c "
import sys
sys.path.insert(0, '${SCRIPTS_DIR}')
from lib.ollama_client import _cli
_cli()
" "$@"