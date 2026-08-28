#!/bin/bash
# Obsiduous settings helper. Runs ONLY when the user makes a choice in the
# Obsiduous settings view — never on its own.
#
#   obsiduous-ctl.sh bind "SUPER + N"   manage Obsiduous's hotkey as a marked
#                                       block in ~/.config/hypr/bindings.lua
#                                       (replaces only its own block, never
#                                       another line)
#   obsiduous-ctl.sh unbind             remove that block
#   obsiduous-ctl.sh bar on|off [sec]   add/remove the bar icon in the layout
#                                       (~/.config/omarchy/shell.json)
set -e

ID="io.github.weedwhitesandwine.obsiduous"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> obsiduous hotkey (managed by Obsiduous settings — change it there)"
MARK_OUT="-- <<< obsiduous hotkey"
# Removing the plugin deletes this script, so nothing can take the block out on
# the way past — omarchy-plugin-remove disables, deletes and rescans, and runs
# nothing belonging to the plugin. The block is inert once the id no longer
# resolves, but somebody reading their own bindings.lua months later has no
# plugin left to ask. So the block says what it is and how to be rid of it.
MARK_NOTE="-- If Obsiduous has been uninstalled these lines do nothing: delete them."

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
    echo "obsiduous-ctl: refusing to write $real — it is not yours" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
  if (( 8#$mode & 8#022 )); then
    echo "obsiduous-ctl: refusing to write into $dir — it is writable by others" >&2
    return 1
  fi
  printf '%s' "$real"
}

# An opening marker whose closing marker is missing would otherwise swallow
# every line after it: a `skip` flag cleared only by the terminator runs an
# unbalanced block to the end of the file, and the rest of the user's
# keybindings go with it, silently. A half-removed block is an ordinary thing
# to find — a hand edit, a merge conflict in a dotfiles repo — so a block that
# is not a matched, ordered pair is not a block this script understands, and it
# refuses to touch the file at all.
#
# Both this and strip_block read the file the write will land on — the resolved
# one — rather than the name it was reached by. Inspecting through the link and
# writing to its target leaves a window in which the link can be swung at
# another readable file between the two.
check_markers() {
  local file="$1" opens closes
  opens=$(grep -c -- ">>> obsiduous hotkey" "$file" || true)
  closes=$(grep -c -- "<<< obsiduous hotkey" "$file" || true)
  if (( opens != closes )); then
    echo "obsiduous-ctl: refusing to edit $file — its obsiduous hotkey block is not a matched pair ($opens opening, $closes closing)" >&2
    return 1
  fi
  if (( opens > 1 )); then
    echo "obsiduous-ctl: refusing to edit $file — $opens obsiduous hotkey blocks, expected at most one" >&2
    return 1
  fi
  if (( opens == 1 )); then
    local o c
    o=$(grep -n -- ">>> obsiduous hotkey" "$file" | head -1 | cut -d: -f1)
    c=$(grep -n -- "<<< obsiduous hotkey" "$file" | head -1 | cut -d: -f1)
    if (( c < o )); then
      echo "obsiduous-ctl: refusing to edit $file — its obsiduous hotkey block closes before it opens" >&2
      return 1
    fi
  fi
  return 0
}

strip_block() {
  local file="$1"
  # The block is written with a blank line above it, for legibility. That blank
  # is ours, so it comes out with the block — stripping only the marked lines
  # leaves one behind on every re-bind, and three hotkey changes then mean
  # three orphan blank lines accumulating in a file the README promises is
  # otherwise untouched. Blank lines the user has of their own are held and
  # re-emitted; exactly one, immediately above the opening marker, is dropped.
  awk '
    function flush(  i) { for (i = 0; i < pending; i++) print ""; pending = 0 }
    index($0, ">>> obsiduous hotkey") { if (pending > 0) pending--; flush(); skip = 1; next }
    index($0, "<<< obsiduous hotkey") { skip = 0; next }
    skip { next }
    $0 == "" { pending++; next }
    { flush(); print }
    END { flush() }
  ' "$file"
}

# The shape a hotkey may have. Held in a variable because it contains spaces —
# and it must contain literal spaces, not [[:space:]], which also matches a
# newline and a tab. The settings card checks a literal space, so anything
# looser here is a gap between the two guards.
KEY_SHAPE='^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$'

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the settings card — this file can be run without ever
    # going near the UI. A hotkey is modifiers plus one key and nothing else;
    # anything that does not match that shape is refused rather than escaped,
    # because there is no reason for it to exist.
    if ! [[ $key =~ $KEY_SHAPE ]]; then
      echo "obsiduous-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # Staged in the same directory as bindings.lua and renamed over it, so the
    # swap is one atomic step — staging in /tmp and mv-ing across filesystems
    # degrades to a copy, which can leave a half-written config if interrupted.
    # mktemp creates the stage file exclusively under a random name, so nothing
    # can have been planted at it.
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers "$REAL_BIND" || exit 1
    strip_block "$REAL_BIND" > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      echo "$MARK_NOTE"
      printf 'o.bind("%s", "Obsiduous", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
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
    # The icon is visible when Obsiduous's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry lives in
    # the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-center}" <<'PY'
import json, os, stat, sys, tempfile
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "center"
ID = "io.github.weedwhitesandwine.obsiduous"

def refuse(why):
    sys.stderr.write("obsiduous-ctl: leaving shell.json alone — %s\n" % why)
    raise SystemExit(1)

link = os.path.expanduser("~/.config/omarchy/shell.json")
# A dotfiles manager (stow, chezmoi) puts a symlink at this name pointing into
# its own repository. Refusing every symlink means those users cannot toggle
# the icon at all — and a silent refusal has the settings card reporting
# success while nothing happened. Resolve the name and work on the file it
# really is, the same way the hotkey block does: the link survives, the
# repository stays the thing that owns the content, and a link pointing at
# something that is not the user's own is still refused.
p = os.path.realpath(link)
home_cfg = os.path.dirname(p)
try:
    st = os.stat(home_cfg)
except OSError:
    refuse("%s is not a directory this script can reach" % home_cfg)
if st.st_uid != os.getuid() or (st.st_mode & 0o022):
    refuse("%s is not yours, or is writable by others" % home_cfg)

# shell.json belongs to the user, not to this plugin, and it is read back
# before it is rewritten — so it gets the ceiling every other read here has,
# put at the read, with the extra byte that identifies an over-sized file.
# Refusing means leaving the file exactly as it stands, which is the right
# answer for a file this script cannot make sense of. The open refuses
# symlinks and non-regular files, so a link planted at the resolved name
# cannot redirect the read and a FIFO cannot block it forever.
MAX_SHELL_JSON = 4 * 1024 * 1024
try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError as exc:
    refuse("cannot read %s (%s)" % (p, exc.strerror))
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        refuse("%s is not a regular file" % p)
    with os.fdopen(fd, "rb") as f:
        raw = f.read(MAX_SHELL_JSON + 1)
except OSError as exc:
    refuse("cannot read %s (%s)" % (p, exc.strerror))
if len(raw) > MAX_SHELL_JSON:
    refuse("%s is larger than %d bytes" % (p, MAX_SHELL_JSON))
if os.stat(p).st_uid != os.getuid():
    refuse("%s is not yours" % p)
try:
    d = json.loads(raw.decode("utf-8", "replace"))
except ValueError:
    refuse("%s is not valid JSON" % p)

# Valid JSON of the wrong shape is not a config file, and setdefault will
# happily hand back a string to be subscripted. Each level is checked, and
# nothing is created that the entry does not actually need.
if not isinstance(d, dict):
    refuse("%s is not a JSON object" % p)
def eid(w): return w.get("id") if isinstance(w, dict) else w
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

# Staged under an unpredictable name created exclusively by mkstemp — which
# never follows a symlink — in a directory verified to be owned by us and
# writable by nobody else, then renamed over the destination in one step.
# Writing in place would truncate the user's shell configuration before
# rebuilding it, and a predictable stage name would let a pre-planted symlink
# turn this write into the truncation of whatever the link pointed at.
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
    echo "usage: obsiduous-ctl.sh {bind <KEY>|unbind|bar on|off [section]}" >&2
    exit 2
    ;;
esac
