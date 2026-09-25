#!/bin/bash
# Links the omarchy-dbclient launcher into ~/.local/bin.
#   ./install.sh             launcher only
#   ./install.sh --bindings  also append the shortcuts (Super+Alt+D, Super+Shift+Alt+D) to ~/.config/hypr/bindings.lua
#   ./install.sh --menu      also add "DB Client" to the Omarchy menu (Super+Alt+Space)
# Database drivers are not installed here: the app detects missing ones and
# asks before installing them (pacman or a private pip venv).

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
BINDINGS="$HOME/.config/hypr/bindings.lua"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"

mkdir -p "$BIN"
chmod +x "$DIR/bin/omarchy-dbclient" "$DIR/backend/dbclient.py"
ln -sfn "$DIR/bin/omarchy-dbclient" "$BIN/omarchy-dbclient"
echo "Linked $BIN/omarchy-dbclient"

for arg in "$@"; do
  case "$arg" in
    --bindings)
      if grep -q "omarchy-dbclient" "$BINDINGS" 2>/dev/null; then
        echo "Shortcut already present in $BINDINGS"
      else
        cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)" 2>/dev/null || true
        { echo; cat "$DIR/hypr/bindings.lua"; } >>"$BINDINGS"
        echo "Shortcuts Super+Alt+D / Super+Shift+Alt+D added to $BINDINGS"
        hyprctl reload >/dev/null 2>&1 && hyprctl configerrors
      fi
      ;;
    --menu)
      if grep -q '"dbclient"' "$MENU" 2>/dev/null; then
        echo "Menu entry already present in $MENU"
      elif [[ -f $MENU ]]; then
        cp "$MENU" "$MENU.bak.$(date +%s)"
        # Insert before the final closing brace of the JSONC object.
        python3 - "$MENU" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
entry = '  "dbclient": {"icon":"","label":"DB Client","description":"MySQL, PostgreSQL, Oracle, ClickHouse, Redis, SQLite, MongoDB","action":"omarchy-dbclient"},\n'
cut = text.rstrip().rfind("}")
open(path, "w").write(text[:cut] + entry + text[cut:])
PY
        echo "Menu entry added to $MENU"
      else
        echo "No $MENU found, skipping the menu entry"
      fi
      ;;
  esac
done

command -v python3 >/dev/null || echo "Warning: python3 is required (sudo pacman -S python)"
