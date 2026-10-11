#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ROOT}/target/release/omega-notch-engine"
UI="${ROOT}/ui/plasma/build/omega-notch-plasma"

if [[ ! -x "$ENGINE" ]]; then
  echo "Building engine…"
  (cd "$ROOT" && cargo build --release -p omega-notch-engine)
fi

if [[ ! -x "$UI" ]]; then
  echo "Building Plasma UI…"
  cmake -S "$ROOT/ui/plasma" -B "$ROOT/ui/plasma/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build "$ROOT/ui/plasma/build"
fi

SOCK="${XDG_RUNTIME_DIR:-/tmp}/omega-notch.sock"
if [[ -S "$SOCK" ]]; then
  if ! python3 - "$SOCK" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.2)
try:
    s.connect(sys.argv[1])
    s.sendall(b'{"type":"ping"}\n')
    s.recv(64)
except Exception:
    raise SystemExit(1)
PY
  then
    rm -f "$SOCK"
  fi
fi

if [[ ! -S "$SOCK" ]]; then
  "$ENGINE" serve &
  ENGINE_PID=$!
  cleanup() { kill "$ENGINE_PID" 2>/dev/null || true; }
  trap cleanup EXIT INT TERM
  for _ in $(seq 1 50); do
    [[ -S "$SOCK" ]] && break
    sleep 0.1
  done
fi

exec "$UI"
