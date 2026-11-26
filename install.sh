#!/bin/bash
# Install Monitor Play into the Omarchy shell.
# Safe to re-run.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="monitor.play"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
MENU_EXT="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok() { printf '    \033[32m✓\033[0m %s\n' "$*"; }

step "Command"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
chmod +x "$APP_DIR/bin/monitor-play" "$APP_DIR/apply.py" "$APP_DIR/monitor_play.py"
ln -sfn "$APP_DIR/bin/monitor-play" "$HOME/.local/bin/monitor-play"
ok "~/.local/bin/monitor-play"

step "Omarchy plugin"
if [[ $APP_DIR != "$PLUGIN_DIR" ]]; then
  # Dev checkout: the shell refuses symlinks, so copy the plugin tree in.
  # `omarchy plugin add` already lands the git repo at $PLUGIN_DIR.
  mkdir -p "$PLUGIN_DIR"
  cp "$APP_DIR/manifest.json" "$APP_DIR/Arrange.qml" "$APP_DIR/apply.py" "$APP_DIR/monitor_play.py" "$PLUGIN_DIR/"
fi
chmod +x "$APP_DIR/apply.py" "$APP_DIR/monitor_play.py"
chmod +x "$PLUGIN_DIR/apply.py" "$PLUGIN_DIR/monitor_play.py"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 0.4
omarchy plugin enable "$PLUGIN_ID"
ok "$PLUGIN_ID enabled"

step "Omarchy menu"
mkdir -p "$(dirname "$MENU_EXT")"
if [[ ! -f $MENU_EXT ]]; then
  printf '{\n}\n' >"$MENU_EXT"
fi
if ! grep -q '"trigger.hardware.monitor-play"' "$MENU_EXT"; then
  python3 - "$MENU_EXT" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
snippet = '''  "trigger.hardware.monitor-play": {"icon":"󰍺","label":"Monitor Play","action":"omarchy-shell shell summon monitor.play '{}'","description":"Drag your screens around and apply the layout"},
'''
text = path.read_text()
idx = text.rfind("}")
if idx < 0:
    path.write_text("{\n" + snippet + "}\n")
else:
    inner = text[:idx]
    probe = re.sub(r"//.*?$", "", inner, flags=re.M)
    probe = re.sub(r"/\*.*?\*/", "", probe, flags=re.S).rstrip()
    comma = ",\n" if re.search(r'[:\]]\s*$', probe) else ""
    path.write_text(inner.rstrip() + comma + "\n" + snippet + "}\n")
PY
fi
ok "Trigger → Hardware → Monitor Play"

step "App launcher"
cat >"$HOME/.local/share/applications/monitor-play.desktop" <<EOF
[Desktop Entry]
Name=Monitor Play
Comment=Drag your screens around and apply the layout
Exec=$HOME/.local/bin/monitor-play
Icon=video-display
Terminal=false
Type=Application
Categories=Settings;Utility;
EOF
ok "Monitor Play in the app launcher"

printf '\n\033[1;32mDone.\033[0m Open \033[1mTrigger → Hardware → Monitor Play\033[0m or run \033[1mmonitor-play\033[0m.\n'
