#!/bin/bash
# Plug settings helper. Runs ONLY when the user applies a choice in Plug's
# settings view — never on its own.
#
#   plug-ctl.sh bind "SUPER + P"   manage Plug's hotkey as a marked block in
#                                  ~/.config/hypr/bindings.lua (replaces only
#                                  its own block, never other lines)
#   plug-ctl.sh unbind             remove that block
#   plug-ctl.sh bar on|off [sec]   add/remove the Plug icon in the bar layout
#                                  (~/.config/omarchy/shell.json)
#
# It is also the detached runner for the jobs that cannot run inside the panel:
#
#   plug-ctl.sh remove <id>        uninstall a plugin
#   plug-ctl.sh apply <id>         apply the reviewed update
#   plug-ctl.sh rollback <id>      restore the version before the last update
#   plug-ctl.sh install <url> <nm> install from the store
#   plug-ctl.sh enable|disable <id>  turn a plugin on or off
#
# Each of those ends with the shell reloading its plugins, and a reload unloads
# every open panel — Plug's own window included. A job running inside the panel
# is therefore killed at the moment its work lands, taking the result message
# with it, which is why these run detached from the panel and summon Plug back
# afterwards with what happened.
set -e

ID="io.github.weedwhitesandwine.plug"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> plug hotkey (managed by Plug settings — change it there)"
MARK_OUT="-- <<< plug hotkey"

# An opening marker whose terminator is missing used to swallow every line
# after it: `skip` is only cleared by the closing marker, so an unbalanced
# block ran to the end of the file and the rest of the user's keybindings were
# deleted without a word. A block that is not a matched, ordered pair is not a
# block this script understands.
# Where bindings.lua really lives. A dotfiles manager (stow, chezmoi) puts a
# symlink at ~/.config/hypr/bindings.lua pointing into its own repository;
# staging beside the LINK and renaming over it replaces the link with a plain
# file, orphaning the repo so every later apply stops reaching Hyprland — and a
# stage file on another filesystem turns the rename into a non-atomic copy.
# Resolving first means the write lands on the real file, in its own directory,
# and the link survives. Target and directory must both be the user's and
# writable by nobody else.
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

# Both of these read the file the write will land on — the resolved one —
# rather than the name it was reached by. Inspecting through the link and
# writing to its target leaves a window in which the link can be swung at
# another readable file between the two, and its contents would then be
# copied into bindings.lua.
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

strip_block() {
  local file="$1"
  # The block is written with a blank line above it, for legibility. That
  # blank is ours, so it has to come out with the block — stripping only the
  # marked lines left one behind on every re-bind, and three hotkey changes
  # meant three orphan blank lines in a file this plugin promises to leave
  # otherwise untouched. Blank lines the user has of their own are held and
  # re-emitted; exactly one, immediately above the opening marker, is dropped.
  awk '
    function flush(  i) { for (i = 0; i < pending; i++) print ""; pending = 0 }
    index($0, ">>> plug hotkey") { if (pending > 0) pending--; flush(); skip = 1; next }
    index($0, "<<< plug hotkey") { skip = 0; next }
    skip { next }
    $0 == "" { pending++; next }
    { flush(); print }
    END { flush() }
  ' "$file"
}

# ---------------------------------------------------------------- job helpers

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Is this id still referenced anywhere in the live shell config? Turning a
# plugin off clears ONE reference per call, and anything installed the usual
# way is referenced twice — once as a plugin, once as a bar widget — so a
# single call leaves an orphan behind pointing at a plugin that is on its way
# out. The config is the authority here, not the command's own "ok", which it
# reports even when there was nothing left to clear.
# Exit 0 = still referenced, 1 = not referenced, 2 = could not be read.
# Treating "could not read" as "not referenced" made clear_refs report success
# having changed nothing, so disable said "Disabled" while the plugin ran on,
# and remove deleted the directory with the config still pointing at it.
refs_left() {
  # head -c so the ceiling is at the read, matching every other read here.
  omarchy-shell shell listShellConfig 2>/dev/null | head -c 4194304 | python3 -c '
import json, sys
want = sys.argv[1]
try:
    c = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(c, dict):
    sys.exit(2)
def eid(w):
    return w.get("id") if isinstance(w, dict) else w
seen = []
lay = (c.get("bar") or {}).get("layout")
for sec in (lay.values() if isinstance(lay, dict) else (lay or [])):
    for w in (sec or []):
        seen.append(eid(w))
for w in (c.get("plugins") or []):
    seen.append(eid(w))
sys.exit(0 if want in seen else 1)' "$1"
}

# Is this plugin on? The shell calls a bar widget enabled only when it has a
# place in the bar, so a plugin whose owner switched its bar icon off reports
# as disabled while running perfectly well — its entry sits in the plugins
# list instead. Either location counts as on here: hiding an icon is not
# switching a plugin off, and nothing should drag a hidden icon back.
is_on() {
  if omarchy-shell shell listPlugins 2>/dev/null | head -c 4194304 | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in d if isinstance(d, list) else []:
    if p.get("id") == sys.argv[1]:
        sys.exit(0 if p.get("enabled") is True else 1)
sys.exit(1)' "$1"; then
    return 0
  fi
  refs_left "$1"
}

# Clear every reference, checking the config rather than trusting the reply.
# Two locations is the normal worst case; the cap stops a config that will not
# settle from spinning here forever.
clear_refs() {
  local id="$1" out i rc
  for i in 1 2 3 4 5; do
    refs_left "$id"; rc=$?
    if (( rc == 2 )); then
      echo "could not read the shell configuration"
      return 1
    fi
    (( rc == 1 )) && return 0
    out=$(omarchy-shell shell setPluginEnabled "$id" false 2>&1) || true
    [[ $out == "ok" ]] || { echo "${out:-setPluginEnabled produced no output}"; return 1; }
  done
  refs_left "$id"; rc=$?
  if (( rc == 0 )); then echo "still referenced"; return 1; fi
  if (( rc == 2 )); then echo "could not read the shell configuration"; return 1; fi
  return 0
}

# Bring Plug back up with the outcome. The shell may be mid-teardown, mid-
# rebuild, or (after an update) still starting up again, so wait for it to
# answer before summoning and keep trying for a while after that.
finish() {
  local highlight="$1" notice="$2" err="$3" payload i
  payload=$(python3 -c '
import json, sys
h, n, e = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if h: d["highlight"] = h
if e: d["error"] = e
elif n: d["notice"] = n
if len(sys.argv) > 4 and sys.argv[4]: d["tab"] = sys.argv[4]
print(json.dumps(d))' "$highlight" "$notice" "$err" "${4:-}")
  for i in $(seq 1 60); do
    [[ $(omarchy-shell shell ping 2>/dev/null) ]] && break
    sleep 0.5
  done
  # Let the panel teardown settle so the payload is queued for the NEW panel
  # rather than eaten by the dying one.
  sleep 0.6
  for i in $(seq 1 20); do
    [[ $(omarchy-shell shell summon "$ID" "$payload" 2>/dev/null) == "ok" ]] && return 0
    sleep 0.5
  done
  return 0
}

# The last line is what a failing command actually said; the rest is noise.
last_line() { printf '%s' "$1" | tail -n 1; }

# The same rule the engine applies to a plugin id, applied again here because
# this is where the value becomes a path and an argument to `omarchy plugin
# remove`. `local LC_ALL=C` so the character classes mean bytes rather than
# whatever the user's locale is willing to call a letter — without it this
# accepts `ábc` while the engine rejects it, and two guards that disagree are
# one guard with a gap between them.
valid_plugin_id() {
  local LC_ALL=C
  [[ $1 == *".."* ]] && return 1
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the settings view — a settings file can be edited or
    # restored from a backup without going near the UI. A hotkey is modifiers
    # plus one key and nothing else; anything that does not match that shape is
    # refused rather than escaped, because there is no reason for it to exist.
    # The shape a hotkey may have, held in a variable because it contains
# spaces — and it must contain literal spaces, not [[:space:]], which
# also matches a newline and a tab. The settings card checks a literal
# space, so anything looser here is a gap between the two guards: a
# newline passed this check, was refused by that one, and reached
# bindings.lua as an unterminated Lua string that cost the user every
# keybinding in the file on the next reload.
KEY_SHAPE='^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$'
if ! [[ $key =~ $KEY_SHAPE ]]; then
      echo "plug-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # Staged in the same directory as bindings.lua and renamed over it, so the
    # swap is one atomic step; mktemp creates the stage file exclusively under
    # a random name, so nothing can have been planted at it.
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
    # `|| true` because the whole point of the next forty lines is to report
    # what went wrong. Without it `set -e` ends the script the instant the
    # embedded program exits non-zero — which is every case it was written to
    # detect: a directory it does not own, a shell.json over the ceiling, JSON
    # it cannot parse. The refusal was reached, the message was produced, and
    # then the script died one line before the code that says so, leaving no
    # notice, no summon, and a panel waiting for a result that never came.
    # Exactly the silent failure this block's own comments claim to have fixed.
    barerr=$(python3 - "$2" "${3:-right}" 2>&1 >/dev/null <<'PY' || true
import json, os, stat, sys, tempfile
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.plug"
link = os.path.expanduser("~/.config/omarchy/shell.json")
# shell.json belongs to the user, not to this plugin, and it is read back
# before it is rewritten. The open refuses symlinks and non-regular files, so
# a planted link cannot redirect the read and a FIFO cannot block it forever.
#
# A dotfiles manager (stow, chezmoi) puts a symlink at this name pointing into
# its own repository, and refusing every symlink meant those users could not
# turn the bar icon on at all. Resolve the name and work on the file it really
# is: the link survives, the repository stays the thing that owns the content,
# and a link pointing at something that is not the user's own is still
# refused.
p = os.path.realpath(link)
MAX_SHELL_JSON = 4 * 1024 * 1024


def fail(why):
    """Say what went wrong. Every one of these used to be a silent exit 0, and
    the branch reported nothing at all, so "show in bar" could do nothing with
    no error anywhere."""
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
def eid(w): return w.get("id") if isinstance(w, dict) else w
# Its own entry, and nothing else: turning the icon on adds the one section it
# goes into, turning it off adds the plugins list it goes into, and no other
# key is invented on the way past.
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
# Staged under an unpredictable name created exclusively by mkstemp in the
# directory verified owner-only above, then renamed over the destination in
# one step.
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
)
    if [[ -n $barerr ]]; then
      finish "" "" "$(last_line "$barerr")"
    else
      # Back to Settings, which is the only place this can be pressed from.
      finish "" "Bar icon updated" "" "settings"
    fi
    ;;
  remove)
    id="$2"
    [[ -n $id ]] || exit 2
    err=""
    # Every reference goes first. The uninstall command clears only one itself,
    # and by the time it has deleted the directory an orphan entry points at
    # nothing.
    err=$(clear_refs "$id") || true
    if [[ -z $err ]]; then
      # Judge it by whether it succeeded, never by whether it printed
      # something: a command that dies silently prints nothing at all, and
      # reading that as success reported failed removals as clean ones.
      if out=$(omarchy plugin remove "$id" --yes 2>&1); then
        :
      else
        err=$(last_line "$out")
        [[ -n $err ]] || err="omarchy plugin remove failed"
      fi
    fi
    # A removed plugin leaves nothing of ours behind: its review record and
    # its restore bookkeeping go with it, rather than sitting in the state
    # directory for the rest of the machine's life.
    if [[ -z $err ]]; then
      python3 "$DIR/plugd.py" forget "$id" >/dev/null 2>&1 || true
    fi
    if [[ -n $err ]]; then finish "$id" "" "$err"; else finish "" "Removed $id" ""; fi
    ;;
  apply | rollback)
    verb="$1"
    id="$2"
    [[ -n $id ]] || exit 2
    err=""
    deferred=0
    # Set before it is read. This branch tests `$attached` further down but
    # never initialised it, so the value came from whatever the environment
    # happened to hold: an exported variable of that name would have made every
    # apply skip the summon and leave the panel gone with no result. Nothing
    # passes --attached here — the shell restart is the whole point of this
    # path — so it is fixed empty rather than parsed.
    attached=""
    # stdout only: merging stderr in meant one warning line made the JSON
    # unparseable, the parser read "unparseable" as "no error", and a REFUSED
    # update was reported as "Updated" — and then restarted the shell.
    if out=$(python3 "$DIR/plugd.py" "$verb" "$id" 2>/dev/null); then
      # Report what the engine reported: it answers with an error field rather
      # than a failing exit status when git refuses the operation.
      err=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict) and d.get("error"):
    print(str(d["error"]))')
    else
      err=$(last_line "$out")
      [[ -n $err ]] || err="plug engine failed"
    fi
    if [[ -z $err ]]; then
      # The new code is on disk, but the shell is still running the copy it
      # loaded at startup — and it keeps running it. Asking it to rescan its
      # plugins is not enough: a rescan re-reads which plugins exist, so
      # installs and removals show up, but already-loaded plugin code stays
      # cached. Only a restart actually picks up changed code, which is the
      # step that makes an update take effect at all. It is also what unloads
      # this panel, which is why this runs detached and summons Plug back.
      #
      # Never while the screen is locked: restarting the shell there takes the
      # lock screen with it. A locked screen means nobody pressed the button,
      # so the reload simply waits for the next restart.
      if omarchy-hyprland-session-locked 2>/dev/null; then
        deferred=1
      else
        omarchy-restart-shell >/dev/null 2>&1 || true
      fi
    fi
    if [[ $verb == apply ]]; then note="Updated $id"; else note="Restored $id to its previous version"; fi
    if (( deferred )); then note="$note — it loads when the shell next restarts"; fi
    if [[ -n $attached ]]; then
      [[ -n $err ]] && { echo "$err" >&2; exit 1; }
      exit 0
    fi
    if [[ -n $err ]]; then finish "$id" "" "$err"; else finish "$id" "$note" ""; fi
    ;;
  install)
    # install <url> <name> <reviewed-sha> <plugin-id> [--approved-version]
    #
    # What the reviewer read was one exact commit. A repository address is not
    # a commit — it is a pointer, and it can point somewhere else by the time
    # anything downloads it. So the repository is asked what it is at now,
    # without downloading it, and nothing is installed unless the answer is the
    # commit that was read. If it has moved, nothing lands on the disk at all;
    # the panel says so and offers the version that was approved, which comes
    # back here with --approved-version and is pinned after the install.
    url="$2"
    name="${3:-$2}"
    sha="${4:-}"
    pid="${5:-}"
    mode="${6:-}"
    [[ -n $url ]] || exit 2
    err=""
    moved=""

    # No reviewed commit, no install. Everything that makes this path safe —
    # the still-at check before the clone and the backstop that pins or removes
    # after it — is written as `if [[ -n $sha ]]`, so an empty one skipped both
    # and installed whatever HEAD was, which is the failure the whole path
    # exists to prevent. It was unreachable through the panel; unreachable is
    # not the same as refused, and this is the wrong place to rely on a caller.
    if [[ -z $sha ]]; then
      finish "" "" "nothing was installed: no reviewed version was recorded for it"
      exit 0
    fi

    if [[ -n $sha ]]; then
      now=$(python3 "$DIR/plugd.py" still-at "$url" "$sha" 2>/dev/null |
        python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("unreachable"); raise SystemExit
if not d.get("reachable"): print("unreachable")
elif d.get("same"): print("same")
else: print(d.get("now") or "unknown")')
      case "$now" in
        same) : ;;
        unreachable) err="could not reach the repository to check it" ;;
        *)
          if [[ $mode != "--approved-version" ]]; then
            # Nothing is installed. The panel decides what to offer.
            moved="$now"
          fi
          ;;
      esac
    fi

    if [[ -n $moved ]]; then
      # Tab-separated: a display name has spaces in it ("FPL Gaffer"), and
      # splitting on spaces told the user "FPL changed while you were reading
      # it" and took "Gaffer" for the commit.
      finish "" "" "$(printf 'MOVED\t%s\t%s' "$name" "$moved")"
      exit 0
    fi

    if [[ -z $err ]]; then
      # Always switched off, whichever route got here. Enabling as part of the
      # add means the shell loads and runs the code immediately, so the checks
      # below would be inspecting something that had already run — and a
      # branch that moved between the check above and this line would have
      # been loaded before anything noticed. Off first, verified, then on.
      if out=$(omarchy plugin add "$url" --yes 2>&1); then :; else
        err=$(last_line "$out")
        [[ -n $err ]] || err="omarchy plugin add failed"
      fi
    fi

    # Backstop: whatever the checks above concluded, what actually landed is
    # what matters. If it is not the reviewed commit, pin it to that commit;
    # if it cannot be pinned, remove it rather than leave unreviewed code
    # installed.
    if [[ -z $err && -n $sha && -z $pid ]]; then
      err="installed, but its plugin id was unknown so the version could not be checked"
    fi
    # The id has to be an id before it is a path. It arrives from the manifest
    # of a stranger's repository, and everything below joins it onto a
    # directory and hands it to `omarchy plugin remove`.
    if [[ -z $err && -n $pid ]] && ! valid_plugin_id "$pid"; then
      err="installed, but its plugin id is not a valid id, so the version could not be checked"
    fi
    if [[ -z $err && -n $sha && -n $pid ]]; then
      d="$HOME/.config/omarchy/plugins/$pid"
      # And it has to name the directory this install actually created.
      #
      # `omarchy plugin add` validates the id in the manifest of the commit it
      # fetches. This backstop was using the id from the commit that was
      # REVIEWED. With --approved-version after the author has pushed, those
      # are two different manifests and can carry two different ids — so a
      # reviewed manifest naming some other installed plugin sent the whole
      # block below at that plugin's directory: wrong sha, cat-file fails,
      # `omarchy plugin remove` deletes it, and the report says nothing was
      # installed while the attacker's unreviewed clone sits there under its
      # own id. The check that closes it is the obvious one — does this
      # directory's own manifest agree that this is its id.
      # Read the way every other read here is done, rather than the way that
      # is shortest. `[[ -f && ! -L ]]` followed by `open()` tests one file and
      # opens another — the name can be swapped in between — and `json.load` on
      # a descriptor has no ceiling, so a manifest of any size came into memory
      # before anything looked at it. The open refuses on its own terms
      # instead: no symlink, a regular file, non-blocking so a planted FIFO
      # cannot park here, and a byte over the ceiling means nothing is
      # returned rather than something enormous.
      landed=$(python3 -c '
import json, os, stat, sys
CEIL = 256 * 1024
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    print(""); raise SystemExit
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        print(""); raise SystemExit
    with os.fdopen(fd, "rb") as fh:
        fd = None
        raw = fh.read(CEIL + 1)
    if len(raw) > CEIL:
        print(""); raise SystemExit
    d = json.loads(raw.decode("utf-8", "replace"))
    v = d.get("id") if isinstance(d, dict) else None
    print(v if isinstance(v, str) else "")
except (OSError, ValueError):
    print("")
finally:
    if fd is not None:
        try: os.close(fd)
        except OSError: pass' "$d/manifest.json" 2>/dev/null || echo "")
      if [[ -d $d/.git && $landed != "$pid" ]]; then
        err="installed, but it did not arrive under the id that was reviewed — nothing was changed"
      elif [[ ! -d $d/.git ]]; then
        err="installed, but $pid is not where it was expected, so the version could not be checked"
      else
        head=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")
        if [[ $head != "$sha" ]]; then
          if git -C "$d" cat-file -t "$sha" >/dev/null 2>&1 &&
             git -C "$d" reset --hard "$sha" >/dev/null 2>&1 &&
             [[ $(git -C "$d" rev-parse HEAD 2>/dev/null) == "$sha" ]]; then
            :
          else
            omarchy plugin remove "$pid" --yes >/dev/null 2>&1 || true
            err="what arrived was not the version you approved — nothing was installed"
          fi
        fi
      fi
    fi

    # On, now that what landed has been confirmed to be what was read.
    # Pinning rewrites files inside the plugin folder and the shell disables a
    # plugin whose files change under it, so switching it on has to come after
    # that settles, and has to be confirmed rather than assumed — the first
    # attempt can be undone a moment later.
    if [[ -z $err ]]; then
      if [[ -z $pid ]]; then
        err="installed, but its plugin id was unknown so it could not be switched on — turn it on from the list"
      else
        for i in 1 2 3 4 5 6; do
          sleep 0.6
          is_on "$pid" && break
          out=$(omarchy-shell shell setPluginEnabled "$pid" true 2>&1) || true
        done
        is_on "$pid" || err="installed at the version you reviewed, but it could not be switched on — turn it on from the list"
      fi
    fi

    if [[ -n $err ]]; then finish "" "" "$err"; else finish "" "Installed $name" ""; fi
    ;;
  enable | disable)
    id="$2"
    # --attached: the panel is waiting for this and will re-read the state
    # itself, so there is nobody to summon and no reason to. Without it the
    # job summons Plug back, which is what a plugin that tears its own panel
    # down needs.
    attached=""
    [[ ${3:-} == "--attached" ]] && attached=1
    [[ -n $id ]] || exit 2
    err=""
    if [[ $1 == enable ]]; then
      out=$(omarchy-shell shell setPluginEnabled "$id" true 2>&1) || true
      [[ $out == "ok" ]] || err="${out:-setPluginEnabled produced no output}"
      # Judge it by the state, not the answer. Still off with no entry
      # anywhere means the switch did nothing: clear whatever is there and try
      # once more. A plugin that is merely hidden is already on and is left
      # exactly as its owner set it.
      if [[ -z $err ]] && ! is_on "$id"; then
        clear_refs "$id" >/dev/null 2>&1 || true
        out=$(omarchy-shell shell setPluginEnabled "$id" true 2>&1) || true
        [[ $out == "ok" ]] || err="${out:-setPluginEnabled produced no output}"
        if [[ -z $err ]] && ! is_on "$id"; then err="could not switch it on"; fi
      fi
      note="Enabled $id"
    else
      err=$(clear_refs "$id") || true
      note="Disabled $id"
    fi
    # `attached` was being set above and then never read, so this branch
    # summoned the panel on every toggle — the one case the flag exists to
    # prevent. A summon of a panel that is already open is not a no-op: the
    # shell delivers it straight to the live instance, whose open() resets the
    # cursor to the first row, forces the installed tab, drops any review on
    # screen, and clears the very job state that was guarding the row while
    # this script was still running. The exit code carries the outcome to the
    # waiting panel, which is what `--attached` means.
    if [[ -n $attached ]]; then
      [[ -n $err ]] && { echo "$err" >&2; exit 1; }
      exit 0
    fi
    if [[ -n $err ]]; then finish "$id" "" "$err"; else finish "$id" "$note" ""; fi
    ;;
  *)
    echo "usage: plug-ctl.sh bind <keys> | unbind | bar on|off [section] |" >&2
    echo "       remove <id> | apply <id> | rollback <id> | install <url> [name] |" >&2
    echo "       enable <id> | disable <id>" >&2
    exit 2
    ;;
esac
