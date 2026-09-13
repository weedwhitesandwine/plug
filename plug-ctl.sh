#!/bin/bash
# Plug settings helper. Runs ONLY when the user applies a choice in
# Plug's settings — never on its own.
#
#   plug-ctl.sh bind "SUPER + SHIFT + C"   manage the hotkey as a marked block
#                                           in ~/.config/hypr/bindings.lua
#                                           (replaces only its own block,
#                                           never other lines)
#   plug-ctl.sh unbind                     remove that block
#   plug-ctl.sh bar on|off [section]       add/remove the icon in the bar
#                                           layout (~/.config/omarchy/shell.json)
#
# Both edits are made by plug-edit.py beside this script, which holds the
# target's parent directory open by descriptor for the whole edit rather than
# naming it again at each step.
set -e

HERE=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
EDIT="$HERE/plug-edit.py"

case "$1" in
  bind|unbind)
    python3 "$EDIT" "$@"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    exec python3 "$EDIT" bar "$2" "${3:-right}"
    ;;
  *)
    echo "usage: plug-ctl.sh bind <keys> | unbind | bar on|off [section]" >&2
    exit 2
    ;;
esac
