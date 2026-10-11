#!/usr/bin/env bash
# Installs Omega Notch for the current user (~/.local by default).
#
# From a release download, the binaries are already in bin/ and nothing is
# built. From a clone of the repository, the engine and the UI are built first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
APPS="$HOME/.local/share/applications"
AUTOSTART="$HOME/.config/autostart"
ICONS="$HOME/.local/share/icons/hicolor"

if [[ -x "$ROOT/bin/omega-notch-engine" && -x "$ROOT/bin/omega-notch-plasma" ]]; then
  ENGINE_SRC="$ROOT/bin/omega-notch-engine"
  UI_SRC="$ROOT/bin/omega-notch-plasma"
else
  echo "Building engine…"
  (cd "$ROOT" && cargo build --release -p omega-notch-engine)

  echo "Building Plasma UI…"
  cmake -S "$ROOT/ui/plasma" -B "$ROOT/ui/plasma/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build "$ROOT/ui/plasma/build"

  ENGINE_SRC="$ROOT/target/release/omega-notch-engine"
  UI_SRC="$ROOT/ui/plasma/build/omega-notch-plasma"
fi

# The app used to be called Mega Notch. Stop it and remove its files; the
# engine moves its settings over to the new name on first start.
pkill -f "$PREFIX/bin/mega-notch-plasma" 2>/dev/null || true
pkill -f "$PREFIX/bin/mega-notch-engine" 2>/dev/null || true
rm -f "$PREFIX/bin/mega-notch" "$PREFIX/bin/mega-notch-engine" "$PREFIX/bin/mega-notch-plasma" \
  "$PREFIX/bin/mega-notch-claude-hook" "$AUTOSTART/mega-notch.desktop" "$APPS/mega-notch.desktop" \
  "${XDG_RUNTIME_DIR:-/tmp}/mega-notch.sock"

install -Dm755 "$ENGINE_SRC" "$PREFIX/bin/omega-notch-engine"
install -Dm755 "$UI_SRC" "$PREFIX/bin/omega-notch-plasma"
install -Dm755 "$ROOT/scripts/claude-hook.sh" "$PREFIX/bin/omega-notch-claude-hook"
install -Dm755 /dev/stdin "$PREFIX/bin/omega-notch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${OMEGA_NOTCH_ENGINE:-$BIN/omega-notch-engine}"
UI="${OMEGA_NOTCH_UI:-$BIN/omega-notch-plasma}"
SOCK="${XDG_RUNTIME_DIR:-/tmp}/omega-notch.sock"

# Drop a stale socket if nothing is listening.
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
  else
    echo "Omega Notch engine already running on $SOCK" >&2
  fi
fi

if [[ ! -S "$SOCK" ]]; then
  "$ENGINE" serve &
  EPID=$!
  trap 'kill "$EPID" 2>/dev/null || true' EXIT INT TERM
  for _ in $(seq 1 50); do
    [[ -S "$SOCK" ]] && break
    sleep 0.1
  done
fi

exec "$UI"
EOF

# Icons, for the menu entry, the Settings window and notifications.
for png in "$ROOT"/packaging/icons/hicolor/*/apps/omega-notch.png; do
  size="$(basename "$(dirname "$(dirname "$png")")")"
  install -Dm644 "$png" "$ICONS/$size/apps/omega-notch.png"
done
install -Dm644 "$ROOT/packaging/icons/omega-notch.svg" "$ICONS/scalable/apps/omega-notch.svg"

# Autostart and a menu entry, both pointing at the installed launcher.
install -Dm644 "$ROOT/packaging/omega-notch.desktop" "$AUTOSTART/omega-notch.desktop"
sed -i "s|^Exec=.*|Exec=$PREFIX/bin/omega-notch|" "$AUTOSTART/omega-notch.desktop"
install -Dm644 "$AUTOSTART/omega-notch.desktop" "$APPS/omega-notch.desktop"

# A running engine keeps the old binary, and the launcher only starts one
# when nothing answers on the socket, so swap it for the new build here.
ENGINE_BIN="$PREFIX/bin/omega-notch-engine"
if pids="$(pgrep -f "^$ENGINE_BIN serve")"; then
  echo "Restarting running engine…"
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -f "^$ENGINE_BIN serve" >/dev/null || break
    sleep 0.1
  done
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/omega-notch.sock"
  setsid nohup "$ENGINE_BIN" serve >/dev/null 2>&1 </dev/null &
fi

echo "Installed to $PREFIX/bin"
echo "Autostart: ~/.config/autostart/omega-notch.desktop"
echo "Run now:   omega-notch"
echo "Doctor:    omega-notch-engine doctor"
