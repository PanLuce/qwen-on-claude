#!/bin/bash
# Single source of truth for the local Ollama base URL, mirroring the Python
# _resolve_ollama_url() in ollama_client.py. Source this and call ollama_base;
# never hardcode a port. Precedence: OLLAMA_HOST > default localhost:11434.
#
#   source "$(dirname "$0")/lib/ollama-base.sh"
#   curl -s "$(ollama_base)/api/tags"
ollama_base() {
    local host="${OLLAMA_HOST:-http://localhost:11434}"
    case "$host" in
        http://*|https://*) ;;
        *) host="http://$host" ;;
    esac
    printf '%s' "${host%/}"
}
