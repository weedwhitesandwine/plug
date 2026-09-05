#!/bin/bash
# Plug's consent edits — the only code in this plugin that touches files
# outside ~/.local/state/plug, and it runs only when the user applies a
# choice in Settings:
#
#   plug-ctl.sh bind "SUPER + P"   write Plug's hotkey as a marked block in
#                                  ~/.config/hypr/bindings.lua
#   plug-ctl.sh unbind             remove that block
#   plug-ctl.sh bar on|off [sec]   add/remove Plug's own entry in
#                                  ~/.config/omarchy/shell.json
#
# Everything else Plug does runs through plugd.py.
set -e

ID="io.github.weedwhitesandwine.plug"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> plug hotkey (managed by Plug settings — change it there)"
MARK_OUT="-- <<< plug hotkey"

# A dotfiles manager legitimately symlinks bindings.lua, so resolve it and
# write to the real file in its own directory — the link survives, and the
# rename stays on one filesystem. Target and directory must be the user's own
# and writable by nobody else.
resolve_bind_file() {
  local real dir mode
  real=$(realpath -- "$BIND_FILE" 2>/dev/null) || return 1
  [[ -f $real ]] || return 1
  dir=$(dirname -- "$real")
  if [[ ! -O $real || ! -O $dir ]]; then
    echo "refusing to write $real — it is not yours" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
  if (( 8#$mode & 8#022 )); then
    echo "refusing to write into $dir — it is writable by others" >&2
    return 1
  fi
  printf '%s' "$real"
}

# A block is only safe to rewrite when its markers are a matched, ordered
# pair — an opener with no closer would otherwise swallow every line after it.
check_markers() {
  local file="$1" opens closes o c
  opens=$(grep -c -- ">>> plug hotkey" "$file" || true)
  closes=$(grep -c -- "<<< plug hotkey" "$file" || true)
  if (( opens != closes )); then
    echo "plug-ctl: refusing to edit $file — its hotkey block is not a matched pair ($opens opening, $closes closing)" >&2
    return 1
  fi
  if (( opens > 1 )); then
    echo "plug-ctl: refusing to edit $file — $opens hotkey blocks, expected at most one" >&2
    return 1
  fi
  if (( opens == 1 )); then
    o=$(grep -n -- ">>> plug hotkey" "$file" | head -1 | cut -d: -f1)
    c=$(grep -n -- "<<< plug hotkey" "$file" | head -1 | cut -d: -f1)
    if (( c < o )); then
      echo "plug-ctl: refusing to edit $file — its hotkey block closes before it opens" >&2
      return 1
    fi
  fi
  return 0
}

# Remove the block and the one blank line Plug wrote above it; every other
# line, blank lines included, is copied through untouched.
strip_block() {
  awk '
    function flush(  i) { for (i = 0; i < pending; i++) print ""; pending = 0 }
    index($0, ">>> plug hotkey") { if (pending > 0) pending--; flush(); skip = 1; next }
    index($0, "<<< plug hotkey") { skip = 0; next }
    skip { next }
    $0 == "" { pending++; next }
    { flush(); print }
    END { flush() }
  ' "$1"
}

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    # The value becomes Lua source in bindings.lua, so it is validated here as
    # well as in the settings view — the settings file can be edited without
    # going near the UI. Literal spaces, not [[:space:]], which also matches
    # newline and tab. Refused rather than escaped.
    KEY_SHAPE='^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$'
    if ! [[ $key =~ $KEY_SHAPE ]]; then
      echo "plug-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers "$REAL_BIND" || exit 1
    strip_block "$REAL_BIND" > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Plug (plugin manager)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    chmod --reference="$REAL_BIND" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$REAL_BIND"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers "$REAL_BIND" || exit 1
    strip_block "$REAL_BIND" > "$tmp"
    chmod --reference="$REAL_BIND" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$REAL_BIND"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    exec python3 - "$2" "${3:-right}" <<'PY'
import json, os, stat, sys, tempfile

state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.plug"
link = os.path.expanduser("~/.config/omarchy/shell.json")
# shell.json belongs to the user and may be a dotfiles symlink: resolve it,
# require the real file and its directory to be the user's own, and edit only
# Plug's entry.
p = os.path.realpath(link)
MAX_SHELL_JSON = 4 * 1024 * 1024


def fail(why):
    sys.stderr.write(why + "\n")
    raise SystemExit(1)


home_cfg = os.path.dirname(p)
try:
    st = os.stat(home_cfg)
    if st.st_uid != os.getuid() or (st.st_mode & 0o022):
        fail("%s is not yours, or is writable by others" % home_cfg)
except OSError as e:
    fail("could not check %s: %s" % (home_cfg, e))

try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            fail("%s is not a plain file" % p)
        with os.fdopen(fd, "rb") as f:
            fd = None
            raw = f.read(MAX_SHELL_JSON + 1)
    finally:
        if fd is not None:
            os.close(fd)
    if len(raw) > MAX_SHELL_JSON:
        fail("%s is larger than %d bytes" % (p, MAX_SHELL_JSON))
    d = json.loads(raw.decode("utf-8", "replace"))
except SystemExit:
    raise
except Exception as e:
    fail("could not read %s: %s" % (p, e))
if os.stat(p).st_uid != os.getuid():
    fail("%s is not yours" % p)
if not isinstance(d, dict):
    fail("%s is not a JSON object" % p)


def eid(w):
    return w.get("id") if isinstance(w, dict) else w


bar = d.get("bar")
lay = bar.get("layout") if isinstance(bar, dict) else None
if isinstance(lay, dict):
    for s in lay:
        if isinstance(lay[s], list):
            lay[s] = [w for w in lay[s] if eid(w) != ID]
if isinstance(d.get("plugins"), list):
    d["plugins"] = [w for w in d["plugins"] if eid(w) != ID]

if state == "on":
    if not isinstance(d.get("bar"), dict):
        d["bar"] = {}
    if not isinstance(d["bar"].get("layout"), dict):
        d["bar"]["layout"] = {}
    if not isinstance(d["bar"]["layout"].get(sec), list):
        d["bar"]["layout"][sec] = []
    d["bar"]["layout"][sec].append({"id": ID})
else:
    if not isinstance(d.get("plugins"), list):
        d["plugins"] = []
    d["plugins"].append({"id": ID})

fd, tmp = tempfile.mkstemp(prefix=".shell.json.", suffix=".tmp", dir=home_cfg)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, os.stat(p).st_mode & 0o777)
    except OSError:
        pass
    os.replace(tmp, p)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    ;;
  *)
    echo "usage: plug-ctl.sh bind <keys> | unbind | bar on|off [section]" >&2
    exit 2
    ;;
esac
