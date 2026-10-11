#!/usr/bin/env bash
# Claude Code stop/notification hook → Omega Notch engine
# Usage from settings.json hooks:
#   curl -sS -X POST http://127.0.0.1:17337/hooks/session \
#     -H 'content-type: application/json' \
#     -d '{"provider":"claude_code","kind":"idle","label":"done"}'

set -euo pipefail

KIND="${1:-idle}"
LABEL="${2:-}"

payload=$(printf '{"provider":"claude_code","kind":"%s","label":"%s"}' "$KIND" "$LABEL")
curl -sS -X POST "http://127.0.0.1:17337/hooks/session" \
  -H 'content-type: application/json' \
  -d "$payload" >/dev/null || true
