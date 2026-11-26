#!/bin/bash
# Remove the Monitor Play launcher and menu entry.
# The saved profile in ~/.config/monitor-play is kept.
# Your Hyprland monitor layout is left as it is.
set -uo pipefail

MENU_EXT="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/monitor.play"

omarchy plugin disable monitor.play 2>/dev/null || true
rm -f "$HOME/.local/bin/monitor-play" "$HOME/.local/share/applications/monitor-play.desktop"

# Leave a git checkout from `omarchy plugin add` in place so
# `omarchy plugin remove monitor.play` can still see it.
if [[ ! -d $PLUGIN_DIR/.git ]]; then
  rm -rf "$PLUGIN_DIR"
fi

if [[ -f $MENU_EXT ]]; then
  python3 - "$MENU_EXT" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = re.sub(r',\s*"trigger\.hardware\.monitor-play"\s*:\s*\{.*?\}\s*', "\n", text, flags=re.S)
text = re.sub(r'"trigger\.hardware\.monitor-play"\s*:\s*\{.*?\}\s*,?\s*', "", text, flags=re.S)
path.write_text(text)
PY
fi

printf 'Monitor Play removed. The layout in ~/.config/hypr/monitors.lua is unchanged.\n'
