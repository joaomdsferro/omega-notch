#!/usr/bin/env bash
# Removes what install.sh put in place. Settings and the Copilot sign-in stay
# in ~/.config/omega-notch and ~/.local/share/omega-notch; delete those too
# to remove everything.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"

pkill -f "$PREFIX/bin/omega-notch-plasma" 2>/dev/null || true
pkill -f "$PREFIX/bin/omega-notch-engine" 2>/dev/null || true

rm -f "$PREFIX/bin/omega-notch" "$PREFIX/bin/omega-notch-engine" "$PREFIX/bin/omega-notch-plasma" \
  "$PREFIX/bin/omega-notch-claude-hook" \
  "$HOME/.config/autostart/omega-notch.desktop" "$HOME/.local/share/applications/omega-notch.desktop" \
  "${XDG_RUNTIME_DIR:-/tmp}/omega-notch.sock"
rm -f "$HOME"/.local/share/icons/hicolor/*/apps/omega-notch.png \
  "$HOME/.local/share/icons/hicolor/scalable/apps/omega-notch.svg"

echo "Omega Notch removed. Your settings are still in ~/.config/omega-notch."
