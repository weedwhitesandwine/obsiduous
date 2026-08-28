#!/usr/bin/env python3
"""Obsiduous index daemon.

Holds one Obsidian vault's Markdown in memory and answers queries over a
JSON-line protocol on stdin/stdout. One process serves every bar and every
screen, because the shell instantiates a bar widget per monitor and the
singleton that owns this is what keeps that from becoming one daemon per bar.

Why in memory: a vault of ~1,800 notes is a few megabytes of Markdown and
reads in tens of milliseconds. Keeping it resident turns every keystroke into
a pure CPU scan instead of a fresh walk of the filesystem, which is the
difference between a search box and something that keeps up with typing.

Everything crossing into this process is treated as untrusted, including the
vault itself and this daemon's own state files: a note is somebody's data, a
state file may be a restored backup, and the shell that reads our stdout lives
for days. So:

  * every read opens O_NOFOLLOW|O_NONBLOCK, checks S_ISREG on the descriptor
    and reads ceiling+1 bytes, refusing above the ceiling. A planted symlink
    is refused rather than followed, and a planted FIFO cannot park the open
    forever.
  * every write stages through tempfile.mkstemp in the destination directory
    (random name, O_EXCL, never follows a link) and lands with os.replace,
    after verifying the directory is owner-only.
  * every line written to stdout is measured before it is written, and a line
    over the ceiling is replaced by a minimal payload. The bound belongs at
    the writer, because a reader cannot bound a stream it has already
    received.

Protocol, one JSON object per line each way. In:

    {"c": "vault",   "p": "/abs/path"}          switch vault, reindex
    {"c": "search",  "id": 7, "q": "text"}      query; filters live in q
    {"c": "preview", "id": 8, "p": "rel.md"}    first bytes of a note
    {"c": "open",    "p": "rel.md"}             record an open (frecency)
    {"c": "capture", "mode": "daily"|"new", "text": "...", "title": "..."}
    {"c": "mode",    "m": "active"|"idle"}      rescan cadence
    {"c": "reindex"}
    {"c": "vaults"}                             vaults Obsidian knows about

Out: {"t": "status"|"results"|"preview"|"captured"|"vaults"|"error", ...}
Every reply to a request carries back the "id" it answered, and every status
carries the current mode, so a command that was lost while the process was
still starting is noticed by the caller and simply sent again.
"""

import json
import os
import re
import stat
import sys
import tempfile
import time
import unicodedata

# ------------------------------------------------------------------ limits
#
# The ledger, in one place. Every one of these is a real ceiling applied where
# the bytes enter, not a comment about intent.
MAX_NOTE_BYTES = 512 * 1024        # per note; larger is indexed by name only
MAX_CORPUS_BYTES = 96 * 1024 * 1024  # whole in-memory corpus
MAX_NOTES = 20000
MAX_DIRS = 20000
MAX_JSON_BYTES = 1024 * 1024       # any JSON file we read back
MAX_COMMAND_BYTES = 256 * 1024     # one inbound command line
MAX_LINE_BYTES = 2 * 1024 * 1024   # one outbound reply line
MAX_QUERY_LEN = 200
MAX_RESULTS = 60
MAX_PREVIEW_BYTES = 16 * 1024
MAX_CAPTURE_BYTES = 256 * 1024
MAX_TITLE_LEN = 200
MAX_SNIPPET_LEN = 160
MAX_TAGS_PER_NOTE = 40
MAX_OPEN_HISTORY = 2000

SKIP_DIRS = frozenset((".obsidian", ".trash", ".git", ".stfolder", ".stversions",
                       "node_modules", ".obsidian-git"))

ACTIVE_RESCAN = 2.0                # seconds, while a panel is open
IDLE_RESCAN = 30.0                 # seconds, while nothing is looking

STATE_HOME = os.environ.get("XDG_STATE_HOME") or os.path.join(
    os.path.expanduser("~"), ".local", "state")
STATE_DIR = os.path.join(STATE_HOME, "omarchy", "obsiduous")
OPENS_PATH = os.path.join(STATE_DIR, "opens.json")


# ------------------------------------------------------------- safe io
#
# One implementation of each. A helper written a second time is a helper
# written wrong: every read in this file goes through safe_read and every
# write through safe_write, including the ones that look too small to bother.

def safe_read(path, ceiling):
    """Read at most `ceiling` bytes, or return None.

    Refuses a symlink, a non-regular file, and anything larger than the
    ceiling. Never blocks on a FIFO.
    """
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        with os.fdopen(fd, "rb") as handle:
            fd = None
            raw = handle.read(ceiling + 1)
    except OSError:
        return None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
    if len(raw) > ceiling:
        return None
    return raw


def read_json(path, ceiling=MAX_JSON_BYTES):
    """Parse JSON from a bounded read. Shape is the caller's problem."""
    raw = safe_read(path, ceiling)
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except (ValueError, UnicodeDecodeError):
        return None


def dir_is_owned(directory):
    """True when the directory exists, is ours, and is not group/world writable."""
    try:
        info = os.stat(directory)
    except OSError:
        return False
    if not stat.S_ISDIR(info.st_mode):
        return False
    if info.st_uid != os.getuid():
        return False
    return not (info.st_mode & 0o022)


def safe_write(path, data, mode=0o600):
    """Atomically replace `path`, staging through an unguessable name.

    A stage file at a predictable name is a symlink-planting target: a plain
    open() on `path + ".tmp"` truncates whatever the link points at. mkstemp
    gets a random name with O_EXCL and does not follow links.
    """
    directory = os.path.dirname(path) or "."
    if not dir_is_owned(directory):
        return False
    if isinstance(data, str):
        data = data.encode("utf-8")
    handle = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".obsiduous-", suffix=".tmp")
        handle = os.fdopen(fd, "wb")
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
        handle.close()
        handle = None
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        return True
    except OSError:
        if handle is not None:
            try:
                handle.close()
            except OSError:
                pass
        if tmp is not None and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return False


def ensure_state_dir():
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    except OSError:
        return False
    return dir_is_owned(STATE_DIR)


# ------------------------------------------------------------- bounded input

class BoundedLineReader(object):
    """Newline-delimited records, bounded where the bytes enter.

    sys.stdin.readline() buffers a whole record before anything can measure it,
    so a ceiling checked on the returned string has already been paid for — the
    allocation happened inside readline. That is the same reasoning the outbound
    side already applies at emit(): a stream cannot be bounded by its reader.

    This accumulates at most `ceiling` bytes. Once a record exceeds that, the
    buffer is dropped and the reader discards bytes until the terminating
    newline, so the over-long record costs one chunk of memory rather than its
    own length, and the stream stays in sync for whatever follows it.
    """

    CHUNK = 64 * 1024

    def __init__(self, stream, ceiling):
        self.fd = stream.fileno()
        self.ceiling = ceiling
        self.buf = bytearray()
        self.discarding = False

    def fileno(self):
        return self.fd

    def read(self):
        """Return a list of complete records, or None at end of stream.

        A refused record appears in the list as None, so the caller can report
        it without ever having held it.
        """
        try:
            chunk = os.read(self.fd, self.CHUNK)
        except OSError:
            return None
        if not chunk:
            return None

        records = []
        start = 0
        while start < len(chunk):
            newline = chunk.find(b"\n", start)
            if newline < 0:
                piece = chunk[start:]
                if not self.discarding:
                    if len(self.buf) + len(piece) > self.ceiling:
                        self.buf = bytearray()
                        self.discarding = True
                        records.append(None)
                    else:
                        self.buf.extend(piece)
                break

            piece = chunk[start:newline]
            if self.discarding:
                # The over-long record ends here; it was refused when it
                # crossed the ceiling and none of it was kept.
                self.discarding = False
                self.buf = bytearray()
            elif len(self.buf) + len(piece) > self.ceiling:
                self.buf = bytearray()
                records.append(None)
            else:
                self.buf.extend(piece)
                records.append(bytes(self.buf))
                self.buf = bytearray()
            start = newline + 1

        return records


# ------------------------------------------------------------------ output

def emit(payload):
    """Write one reply line, bounded at the writer.

    A SplitParser on the other end buffers until it sees the separator, so a
    ceiling checked after delivery has already been paid for. Measure here,
    and send a small truthful failure instead of a huge truthful answer.
    """
    try:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        line = json.dumps({"t": "error", "msg": "unserialisable reply"})
    if len(line.encode("utf-8")) > MAX_LINE_BYTES:
        line = json.dumps({
            "t": payload.get("t", "error") if isinstance(payload, dict) else "error",
            "id": payload.get("id") if isinstance(payload, dict) else None,
            "over": True,
            "msg": "reply exceeded the line ceiling and was dropped",
        })
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


# ------------------------------------------------------------------ vaults

def count_notes(path, ceiling=MAX_NOTES):
    """How many Markdown notes a vault holds, bounded.

    Stat-only and it stops at the ceiling, so an enormous or pathological tree
    cannot turn opening the switcher into a disk crawl. Reported as a count
    plus a flag saying whether the walk was cut short.
    """
    total = 0
    dirs_seen = 0
    try:
        for root, dirs, files in os.walk(path, followlinks=False):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
            dirs_seen += 1
            if dirs_seen > MAX_DIRS:
                return total, True
            for name in files:
                if name.endswith(".md"):
                    total += 1
                    if total >= ceiling:
                        return total, True
    except OSError:
        pass
    return total, False


def obsidian_vaults():
    """Vaults Obsidian itself knows about, newest-opened first.

    Reading ~/.config/obsidian/obsidian.json means the plugin can offer the
    real list instead of asking someone to go and find a folder, and it is
    also the only place the vault's registered name is authoritative — the
    obsidian:// URI needs that name, and guessing it from the last path
    component is wrong the moment a vault was renamed.
    """
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    found = []
    for candidate in (os.path.join(config, "obsidian", "obsidian.json"),
                      os.path.join(os.path.expanduser("~"),
                                   ".var/app/md.obsidian.Obsidian/config/obsidian/obsidian.json")):
        parsed = read_json(candidate)
        if not isinstance(parsed, dict):
            continue
        vaults = parsed.get("vaults")
        if not isinstance(vaults, dict):
            continue
        for ident, entry in list(vaults.items())[:200]:
            if not isinstance(entry, dict):
                continue
            path = entry.get("path")
            if not isinstance(path, str) or not path:
                continue
            timestamp = entry.get("ts")
            found.append({
                "id": str(ident)[:64],
                "path": path[:4096],
                "name": os.path.basename(path.rstrip("/"))[:MAX_TITLE_LEN],
                "ts": timestamp if isinstance(timestamp, (int, float)) else 0,
                "exists": os.path.isdir(path),
            })
        break
    found.sort(key=lambda item: item["ts"], reverse=True)
    return found[:50]


# moment.js tokens, longest first so YYYY is not eaten by YY.
_MOMENT = [("YYYY", "%Y"), ("MMMM", "%B"), ("dddd", "%A"), ("MMM", "%b"),
           ("ddd", "%a"), ("YY", "%y"), ("MM", "%m"), ("DD", "%d"),
           ("HH", "%H"), ("mm", "%M"), ("ss", "%S")]


def moment_to_strftime(fmt):
    out = []
    index = 0
    while index < len(fmt):
        for token, replacement in _MOMENT:
            if fmt.startswith(token, index):
                out.append(replacement)
                index += len(token)
                break
        else:
            character = fmt[index]
            out.append("%%" if character == "%" else character)
            index += 1
    return "".join(out)


ILLEGAL_IN_NAME = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


def contained_in(vault, target):
    """True when target really is inside vault, with symlinks resolved.

    os.path.normpath is string arithmetic: it collapses ".." and nothing else,
    so a folder inside the vault that is a symlink pointing out of it passes a
    normpath containment check and the write lands wherever the link goes. Both
    sides are resolved here, which also keeps working when the vault itself is
    a symlink — realpath resolves as far as the path exists, so a folder that
    has not been created yet still resolves to its parent's real location.
    """
    real_vault = os.path.realpath(vault)
    real_target = os.path.realpath(target)
    return real_target == real_vault or real_target.startswith(real_vault + os.sep)


def new_note_folder(vault):
    """Where Obsidian itself would put a new note.

    Obsidian has a preference for this and the user has already set it, so
    inventing a plugin-branded folder in somebody's vault is both presumptuous
    and wrong. "current" has no meaning without an open pane, so it falls back
    to the root, which is what Obsidian does when nothing is focused.
    """
    parsed = read_json(os.path.join(vault, ".obsidian", "app.json"))
    if isinstance(parsed, dict) and parsed.get("newFileLocation") == "folder":
        wanted = parsed.get("newFileFolderPath")
        if isinstance(wanted, str) and wanted.strip():
            target = os.path.normpath(os.path.join(vault, wanted.strip("/")[:512]))
            if contained_in(vault, target):
                return target
            # Configured to somewhere outside the vault. Refusing outright
            # would stop capture working at all over a setting the user may
            # not know is wrong, and silently writing there would break the
            # one thing this plugin promises about where notes go — so it
            # falls back to the root, which is both inside the vault and what
            # Obsidian does when no folder is nominated.
    return vault


def safe_note_name(title):
    """A filename from a title, keeping everything a filesystem allows.

    The old version allowed only word characters, spaces and hyphens, which
    quietly ate apostrophes and commas out of perfectly ordinary titles.
    """
    cleaned = ILLEGAL_IN_NAME.sub("", str(title or "")).strip()
    cleaned = cleaned.strip(".")          # no leading dot: not a hidden file
    return cleaned[:80].strip()


def daily_note_config(vault):
    """The vault's own Daily Notes settings, or Obsidian's defaults."""
    parsed = read_json(os.path.join(vault, ".obsidian", "daily-notes.json"))
    folder, fmt, template = "", "YYYY-MM-DD", ""
    if isinstance(parsed, dict):
        if isinstance(parsed.get("folder"), str):
            folder = parsed["folder"].strip("/")[:512]
        if isinstance(parsed.get("format"), str) and parsed["format"].strip():
            fmt = parsed["format"].strip()[:128]
        if isinstance(parsed.get("template"), str):
            template = parsed["template"].strip("/")[:512]
    return {"folder": folder, "format": fmt, "template": template}


# ------------------------------------------------------------------- index

FRONTMATTER_TAGS = re.compile(r"^tags\s*:\s*(.*)$", re.IGNORECASE)
INLINE_TAG = re.compile(r"(?:^|\s)#([A-Za-z0-9_][A-Za-z0-9_/-]{0,63})")
HEADING = re.compile(r"^#{1,6}\s+(.*\S)\s*$")


def parse_note(raw, rel):
    """Title, tags and searchable text from one note's bytes.

    Title order matches what Obsidian users expect: frontmatter title, then
    the first heading, then the filename.
    """
    text = raw.decode("utf-8", "replace")
    lines = text.split("\n")
    title = ""
    tags = []
    body_start = 0

    if lines and lines[0].strip() == "---":
        for index in range(1, min(len(lines), 200)):
            line = lines[index]
            if line.strip() in ("---", "..."):
                body_start = index + 1
                break
            match = FRONTMATTER_TAGS.match(line.strip())
            if match:
                blob = match.group(1).strip().strip("[]")
                for piece in re.split(r"[,\s]+", blob):
                    piece = piece.strip().strip("\"'#")
                    if piece and piece != "-":
                        tags.append(piece[:64])
            lowered = line.strip().lower()
            if lowered.startswith("title:") and not title:
                title = line.strip()[6:].strip().strip("\"'")[:MAX_TITLE_LEN]
            elif line.startswith("  - ") and tags:
                piece = line[4:].strip().strip("\"'#")
                if piece:
                    tags.append(piece[:64])

    if not title:
        for line in lines[body_start:body_start + 200]:
            match = HEADING.match(line)
            if match:
                title = match.group(1)[:MAX_TITLE_LEN]
                break
    if not title:
        title = os.path.basename(rel)[:-3][:MAX_TITLE_LEN]

    # Where the prose begins. Frontmatter is matched (that is where tags live)
    # but it is not what anyone wants shown back to them as the context line:
    # "tags: [meeting, harbour]" tells you nothing the row does not already say.
    body_offset = 0
    if body_start > 0:
        body_offset = len("\n".join(lines[:body_start])) + 1

    for match in INLINE_TAG.finditer(text[:64 * 1024]):
        tags.append(match.group(1)[:64])
        if len(tags) >= MAX_TAGS_PER_NOTE:
            break

    seen = set()
    unique = []
    for tag in tags:
        low = tag.lower()
        if low not in seen:
            seen.add(low)
            unique.append(tag)
    return title, unique[:MAX_TAGS_PER_NOTE], text, body_offset


class Index(object):
    def __init__(self):
        self.vault_counts = {}
        self.vault_counts_at = 0.0
        self.vault = ""
        self.vault_name = ""
        self.notes = {}          # rel -> dict
        self.corpus_bytes = 0
        self.truncated = False
        self.last_scan = 0.0
        self.opens = {}
        self.load_opens()

    # ---------------------------------------------------------- frecency
    def load_opens(self):
        parsed = read_json(OPENS_PATH, 4 * 1024 * 1024)
        opens = {}
        if isinstance(parsed, dict):
            for rel, entry in list(parsed.items())[:MAX_OPEN_HISTORY]:
                if not isinstance(rel, str) or not isinstance(entry, list):
                    continue
                if len(entry) != 2:
                    continue
                count, last = entry
                if isinstance(count, (int, float)) and isinstance(last, (int, float)):
                    opens[rel[:4096]] = [int(count), float(last)]
        self.opens = opens

    def save_opens(self):
        if not ensure_state_dir():
            return
        trimmed = sorted(self.opens.items(), key=lambda kv: kv[1][1], reverse=True)
        trimmed = dict(trimmed[:MAX_OPEN_HISTORY])
        self.opens = trimmed
        safe_write(OPENS_PATH, json.dumps(trimmed, separators=(",", ":")))

    def open_key(self, rel):
        """Frecency is per vault, not per relative path.

        Keying on the path alone meant "Inbox.md" in one vault inherited the
        open count of "Inbox.md" in another, so switching vaults carried a
        ranking across that had nothing to do with the notes being ranked.
        """
        return self.vault + "\0" + rel

    def record_open(self, rel):
        key = self.open_key(rel)
        entry = self.opens.get(key)
        now = time.time()
        if entry:
            entry[0] += 1
            entry[1] = now
        else:
            self.opens[key] = [1, now]
        self.save_opens()

    def frecency(self, rel):
        """Opened often and recently ranks up; the decay is a 30-day half-life."""
        entry = self.opens.get(self.open_key(rel))
        if not entry:
            return 0.0
        count, last = entry
        age_days = max(0.0, (time.time() - last) / 86400.0)
        return min(300.0, count * 60.0) * (0.5 ** (age_days / 30.0))

    # ------------------------------------------------------------- scan
    def set_vault(self, path):
        path = os.path.abspath(os.path.expanduser(path or ""))
        self.vault = path if os.path.isdir(path) else ""
        self.vault_name = os.path.basename(self.vault.rstrip("/")) if self.vault else ""
        if self.vault:
            for entry in obsidian_vaults():
                if os.path.abspath(entry["path"].rstrip("/")) == self.vault.rstrip("/"):
                    self.vault_name = entry["name"]
                    break
        self.notes = {}
        self.corpus_bytes = 0
        self.truncated = False
        self.last_scan = 0.0

    def scan(self):
        """Walk, then read only what changed.

        The walk is stat-only and costs milliseconds; the reads are what cost,
        so a note whose mtime and size are unchanged keeps the text already
        held. That makes the steady-state rescan effectively free and lets it
        run every couple of seconds while somebody is typing.
        """
        if not self.vault:
            return
        seen = set()
        dirs_visited = 0
        self.truncated = False
        for root, dirs, files in os.walk(self.vault, followlinks=False):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
            dirs_visited += 1
            if dirs_visited > MAX_DIRS:
                self.truncated = True
                break
            for name in files:
                if not name.endswith(".md"):
                    continue
                if len(seen) >= MAX_NOTES:
                    self.truncated = True
                    break
                full = os.path.join(root, name)
                rel = os.path.relpath(full, self.vault)
                try:
                    info = os.lstat(full)
                except OSError:
                    continue
                if not stat.S_ISREG(info.st_mode):
                    continue
                seen.add(rel)
                existing = self.notes.get(rel)
                if (existing and existing["mtime"] == info.st_mtime
                        and existing["size"] == info.st_size):
                    continue
                self.ingest(rel, full, info)

        for rel in [r for r in self.notes if r not in seen]:
            self.corpus_bytes -= len(self.notes[rel]["text"])
            del self.notes[rel]
        self.corpus_bytes = max(0, self.corpus_bytes)
        self.last_scan = time.time()

    def ingest(self, rel, full, info):
        previous = self.notes.get(rel)
        if previous:
            self.corpus_bytes -= len(previous["text"])

        raw = safe_read(full, MAX_NOTE_BYTES)
        if raw is None:
            # Too large, a link, or unreadable. It still exists, so it stays
            # findable by name — it just contributes no text.
            raw = b""
        if self.corpus_bytes + len(raw) > MAX_CORPUS_BYTES:
            raw = b""
            self.truncated = True

        title, tags, text, body_offset = parse_note(raw, rel)
        self.corpus_bytes += len(text)
        self.notes[rel] = {
            "rel": rel,
            "title": title,
            "title_low": title.lower(),
            "rel_low": rel.lower(),
            "tags": tags,
            "tags_low": [t.lower() for t in tags],
            "text": text,
            "text_low": text.lower(),
            "body_offset": body_offset,
            "mtime": info.st_mtime,
            "size": info.st_size,
        }


# ------------------------------------------------------------------ search

SEPARATORS = frozenset(" /\\-_.,:;()[]{}#'\"")


def fuzzy(needle, hay):
    """Subsequence match quality in 0..1, or None when the needle does not fit.

    A greedy forward pass finds a match, then a right-to-left pass pulls each
    character as late as it can go, turning a scattered match into the tightest
    one available. Bonuses go to characters at a word boundary and to runs of
    consecutive characters, because those are the ones a person meant to type.

    The result is normalised rather than raw, which is the whole point: a raw
    score grows with the length of the needle, so a long sprawling match on a
    long title would outrank a short tight one, and — worse — outrank a real
    substring hit somewhere else. A quality in 0..1 can be mapped into a band
    that sits *below* the bands for genuine substring matches, which is the
    correct order for a notes search: what you actually typed beats what your
    letters could be spelled out of.
    """
    need_len, hay_len = len(needle), len(hay)
    if need_len == 0:
        return 0.0
    if need_len > hay_len:
        return None

    positions = []
    cursor = 0
    for character in needle:
        found = hay.find(character, cursor)
        if found < 0:
            return None
        positions.append(found)
        cursor = found + 1

    for index in range(len(positions) - 2, -1, -1):
        limit = positions[index + 1]
        slot = hay.rfind(needle[index], positions[index], limit)
        if slot > positions[index]:
            positions[index] = slot

    raw = 0
    previous = -2
    for slot in positions:
        bonus = 1
        if slot == 0:
            bonus += 9
        elif hay[slot - 1] in SEPARATORS:
            bonus += 7
        elif hay[slot - 1].islower() and hay[slot].isupper():
            bonus += 4
        if slot == previous + 1:
            bonus += 6
        raw += bonus
        previous = slot

    # Best case is every character consecutive and on a boundary.
    best = need_len * 16.0
    span = positions[-1] - positions[0] + 1
    density = need_len / float(span)
    # An acronym is spread out by definition — "pfsnb" for "pfSense Networking
    # Bible" is sparse and still exactly right — so coherence credits letters
    # landing on word boundaries as well as letters landing close together.
    boundaries = sum(1 for slot in positions
                     if slot == 0 or hay[slot - 1] in SEPARATORS)
    coherence = max(density, boundaries / float(need_len))
    quality = (raw / best) * 0.6 + coherence * 0.4
    # An earlier match is a better one, but only slightly.
    quality *= 1.0 - min(0.15, positions[0] / (hay_len * 4.0))
    return max(0.0, min(1.0, quality))


# The floor only removes the truly absurd. It is deliberately low, because
# structurally there is nothing to tell "recipe" inside "Rejoicing in Answered
# Prayer" from "pfsnb" inside "pfSense Networking Bible" — both are sparse
# subsequences with letters on word boundaries, and the difference between them
# is meaning, which no scorer here can see. So fuzzy matches are not filtered
# on quality; they are *banded* below every genuine substring hit and capped in
# number. A scattered guess can be the last resort that saves a search, but it
# is never allowed to push a real hit off the top, and it cannot flood the list.
FUZZY_FLOOR = 0.22
MAX_FUZZY_RESULTS = 8


TOKEN = re.compile(r'(\w+):("[^"]*"|\S*)')


def parse_query(raw):
    """Split `tag:`, `path:` and `in:` filters out of the free text."""
    filters = {"tag": [], "path": [], "in": []}
    def take(match):
        key = match.group(1).lower()
        if key in filters:
            value = match.group(2).strip('"').strip().lower()
            if value:
                filters[key].append(value[:128])
            return " "
        return match.group(0)
    free = TOKEN.sub(take, raw).strip()
    free = re.sub(r"\s+", " ", free)
    return free, filters


def strip_diacritics(value):
    return "".join(c for c in unicodedata.normalize("NFKD", value)
                   if not unicodedata.combining(c))


def snippet_for(note, needle):
    """A line of context from the note, tidied for display.

    Two things are skipped on the way to it. Frontmatter, because "tags:
    [meeting, harbour]" is metadata and tells the reader nothing. And the title
    line, because the row already shows the title directly above.

    When every hit is one of those — a note matched only on its own heading —
    the answer is no snippet at all. Echoing the title back one line lower is
    not context, it just makes the row look like it is stuttering.
    """
    lowered = note["text_low"]
    text = note["text"]
    title_low = note["title_low"].strip()

    # Only the body is searched for context. Falling back to the earliest hit
    # anywhere put frontmatter straight back on screen — a note matching only
    # through its `tags:` line showed "tags: [reading, harbour]" as its one
    # line of context, which is the metadata this function exists to skip.
    where = lowered.find(needle, note.get("body_offset", 0))

    # A handful of candidates is plenty: past that the note is repeating
    # itself and the first line was as good as any.
    for _ in range(6):
        if where < 0:
            break
        start = text.rfind("\n", 0, where) + 1
        end = text.find("\n", where)
        if end < 0:
            end = len(text)
        line = text[start:end].strip()
        line = re.sub(r"^#{1,6}\s*", "", line)
        line = re.sub(r"\s+", " ", line).strip()
        if line and line.lower() != title_low:
            return _trim_snippet(line, where - start)
        where = lowered.find(needle, end + 1)

    return ""


def _trim_snippet(line, offset):
    """Keep the match visible when the line is longer than the row."""
    if len(line) <= MAX_SNIPPET_LEN:
        return line
    start = max(0, offset - 40)
    trimmed = line[start:start + MAX_SNIPPET_LEN]
    return ("…" if start else "") + trimmed + "…"


def search(index, raw_query, limit):
    free, filters = parse_query(raw_query[:MAX_QUERY_LEN])
    needle = strip_diacritics(free.lower())
    daily_folder = ""
    if filters["in"]:
        daily_folder = daily_note_config(index.vault)["folder"].lower()

    scored = []
    for note in index.notes.values():
        if filters["tag"]:
            if not all(any(wanted in tag for tag in note["tags_low"])
                       for wanted in filters["tag"]):
                continue
        if filters["path"]:
            if not all(wanted in note["rel_low"] for wanted in filters["path"]):
                continue
        if filters["in"]:
            matched = True
            for wanted in filters["in"]:
                if wanted in ("daily", "journal"):
                    if daily_folder and not note["rel_low"].startswith(daily_folder):
                        matched = False
                elif wanted not in note["rel_low"]:
                    matched = False
            if not matched:
                continue

        score = 0.0
        snippet = ""
        fuzzy_only = False
        if not needle:
            score = 1.0
        else:
            title_low = note["title_low"]
            rel_low = note["rel_low"]

            # Bands, highest first. The ordering is the design: an exact
            # substring of what was typed always outranks a fuzzy guess, and a
            # real hit in the body outranks a fuzzy guess at the title.
            hit = title_low.find(needle)
            if hit == 0:
                score = 1000.0
            elif hit > 0:
                score = 850.0 if title_low[hit - 1] in SEPARATORS else 700.0

            path_hit = rel_low.find(needle)
            if path_hit >= 0:
                score = max(score, 500.0)

            body_hit = note["text_low"].find(needle)
            if body_hit >= 0:
                snippet = snippet_for(note, needle)
                body_score = 400.0
                if body_hit == 0 or note["text_low"][body_hit - 1] in SEPARATORS:
                    body_score += 40.0
                # A word that recurs is more likely the subject of the note
                # than one mentioned once in passing, but the effect is capped
                # so a long note cannot buy its way to the top by repetition.
                occurrences = note["text_low"].count(needle)
                body_score += min(60.0, 20.0 * (occurrences - 1))
                score = max(score, body_score)

            if score == 0.0:
                quality = fuzzy(needle, title_low)
                if quality is not None and quality >= FUZZY_FLOOR:
                    score = 150.0 + quality * 230.0
                    fuzzy_only = True
                else:
                    quality = fuzzy(needle, rel_low)
                    if quality is not None and quality >= FUZZY_FLOOR:
                        score = 80.0 + quality * 120.0
                        fuzzy_only = True

            if score == 0.0:
                continue

        score += index.frecency(note["rel"])
        scored.append((score, note["mtime"], note, snippet, fuzzy_only))

    scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
    total = len(scored)
    results = []
    fuzzy_shown = 0
    for score, mtime, note, snippet, fuzzy_only in scored:
        if len(results) >= limit:
            break
        if fuzzy_only:
            if fuzzy_shown >= MAX_FUZZY_RESULTS:
                continue
            fuzzy_shown += 1
        results.append({
            "path": note["rel"],
            "title": note["title"],
            "modified": int(mtime),
            "snippet": snippet,
            "tags": note["tags"][:8],
            "score": round(score, 1),
            "fuzzy": fuzzy_only,
        })
    return results, total


# ----------------------------------------------------------------- capture

def capture(index, mode, text, title):
    """Write a note. The only thing this daemon ever writes inside the vault."""
    if not index.vault:
        return None, "no vault selected"
    if len(text.encode("utf-8")) > MAX_CAPTURE_BYTES:
        return None, "note is too large to capture"

    if mode == "daily":
        config = daily_note_config(index.vault)
        folder = os.path.join(index.vault, config["folder"]) if config["folder"] else index.vault
        stamp = time.strftime(moment_to_strftime(config["format"]))
        # A format can legitimately contain slashes (YYYY/MM/DD); anything that
        # climbs out of the vault is not a date and is refused.
        target = os.path.normpath(os.path.join(folder, stamp + ".md"))
        # Resolved, not merely normalised: the daily-notes folder can be a
        # symlink out of the vault just as easily as the new-note folder can.
        if not contained_in(index.vault, target):
            return None, "the daily note folder resolves outside the vault"
        try:
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        except OSError:
            return None, "could not create the daily note folder"
        existing = safe_read(target, MAX_NOTE_BYTES)
        stamp_line = time.strftime("%H:%M")
        block = "\n- **%s** %s\n" % (stamp_line, text.strip())
        if existing is None:
            body = "# %s\n%s" % (stamp, block)
        else:
            body = existing.decode("utf-8", "replace").rstrip("\n") + "\n" + block
        if not safe_write(target, body, mode=0o644):
            return None, "could not write the daily note"
        return os.path.relpath(target, index.vault), None

    folder = new_note_folder(index.vault)
    if not os.path.isdir(folder):
        try:
            # No mode argument: a folder inside somebody's vault should look
            # like the rest of their vault, not be tightened to 0700 by us.
            os.makedirs(folder, exist_ok=True)
        except OSError:
            return None, "could not create the note folder"

    stamp = time.strftime("%Y-%m-%d-%H%M%S")
    clean = safe_note_name(title)
    # Titled notes are named for their title, the way Obsidian names them.
    # Only an untitled one falls back to a timestamp, because it needs
    # something unique and there is nothing else to use.
    base = clean if clean else stamp
    target = os.path.join(folder, base + ".md")
    counter = 1
    while os.path.lexists(target):
        target = os.path.join(folder, "%s %d.md" % (base, counter))
        counter += 1
        if counter > 500:
            return None, "could not find a free filename"
    if not contained_in(index.vault, target):
        return None, "that note path resolves outside the vault"
    heading = clean or stamp
    body = "---\ncreated: %s\n---\n\n# %s\n\n%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%S"), heading, text.strip())
    if not safe_write(target, body, mode=0o644):
        return None, "could not write the note"
    return os.path.relpath(target, index.vault), None


# -------------------------------------------------------------------- main

def vault_list(index, with_counts):
    """Obsidian's vaults, plus whichever one is actually selected.

    A vault set by hand — through the manifest setting or a hand-edited
    settings file — is not in Obsidian's config, and leaving it out of the
    switcher would make the vault you are looking at the one vault you cannot
    see listed.
    """
    items = obsidian_vaults()
    known = set(os.path.abspath(str(item["path"]).rstrip("/")) for item in items)
    if index.vault and os.path.abspath(index.vault.rstrip("/")) not in known:
        items.insert(0, {
            "id": "",
            "path": index.vault,
            "name": index.vault_name or os.path.basename(index.vault.rstrip("/")),
            "ts": 0,
            "exists": os.path.isdir(index.vault),
        })

    for item in items:
        item["current"] = (index.vault != ""
                           and os.path.abspath(str(item["path"]).rstrip("/"))
                           == os.path.abspath(index.vault.rstrip("/")))

    if with_counts:
        # Cached briefly: the switcher can be opened repeatedly in a few
        # seconds, and walking every vault each time would be the one slow
        # thing in a plugin whose whole point is not being slow.
        now = time.time()
        if now - index.vault_counts_at > 30.0:
            index.vault_counts = {}
            index.vault_counts_at = now
        for item in items:
            path = str(item["path"])
            if item.get("exists") is False:
                item["notes"] = 0
                item["partial"] = False
                continue
            if path == index.vault:
                item["notes"] = len(index.notes)
                item["partial"] = index.truncated
                continue
            if path not in index.vault_counts:
                index.vault_counts[path] = count_notes(path)
            item["notes"], item["partial"] = index.vault_counts[path]
    return items


def status(index, mode):
    return {
        "t": "status",
        "vault": index.vault,
        "vaultName": index.vault_name,
        "notes": len(index.notes),
        "bytes": index.corpus_bytes,
        "truncated": index.truncated,
        "indexed": index.last_scan > 0,
        "mode": mode,
    }


def main():
    index = Index()
    mode = "idle"
    if len(sys.argv) > 1:
        index.set_vault(sys.argv[1])
        index.scan()
    emit(status(index, mode))

    import select
    reader = BoundedLineReader(sys.stdin, MAX_COMMAND_BYTES)
    pending = []
    while True:
        if not pending:
            interval = ACTIVE_RESCAN if mode == "active" else IDLE_RESCAN
            ready, _, _ = select.select([reader], [], [], interval)
            if not ready:
                before = len(index.notes)
                index.scan()
                if len(index.notes) != before:
                    emit(status(index, mode))
                continue
            records = reader.read()
            if records is None:
                return 0
            pending.extend(records)
            continue

        record = pending.pop(0)
        if record is None:
            emit({"t": "error", "msg": "command exceeded the ceiling and was discarded"})
            continue
        try:
            command = json.loads(record.decode("utf-8", "replace"))
        except ValueError:
            continue
        if not isinstance(command, dict):
            continue

        verb = command.get("c")
        ident = command.get("id")

        if verb == "mode":
            wanted = command.get("m")
            if wanted in ("active", "idle"):
                mode = wanted
                if mode == "active":
                    index.scan()
            # Echoed back so a command lost while this process was still
            # starting is visible to the caller, which simply re-sends it.
            emit(status(index, mode))

        elif verb == "vault":
            index.set_vault(command.get("p", ""))
            index.scan()
            emit(status(index, mode))

        elif verb == "vaults":
            emit({"t": "vaults", "id": ident,
                  "items": vault_list(index, command.get("counts") is True)})

        elif verb == "reindex":
            index.notes = {}
            index.corpus_bytes = 0
            index.scan()
            emit(status(index, mode))

        elif verb == "search":
            query = command.get("q")
            query = query if isinstance(query, str) else ""
            limit = command.get("limit")
            limit = limit if isinstance(limit, int) and 0 < limit <= MAX_RESULTS else 40
            results, total = search(index, query, limit)
            emit({"t": "results", "id": ident, "q": query[:MAX_QUERY_LEN],
                  "items": results, "total": total, "notes": len(index.notes)})

        elif verb == "preview":
            rel = command.get("p")
            note = index.notes.get(rel) if isinstance(rel, str) else None
            if note is None:
                emit({"t": "preview", "id": ident, "text": "", "missing": True})
            else:
                emit({"t": "preview", "id": ident, "path": note["rel"],
                      "title": note["title"], "tags": note["tags"][:12],
                      "modified": int(note["mtime"]),
                      "text": note["text"][:MAX_PREVIEW_BYTES]})

        elif verb == "open":
            rel = command.get("p")
            if isinstance(rel, str) and rel in index.notes:
                index.record_open(rel)

        elif verb == "capture":
            text = command.get("text")
            written, error = capture(
                index,
                command.get("mode") if command.get("mode") in ("daily", "new") else "new",
                text if isinstance(text, str) else "",
                command.get("title") if isinstance(command.get("title"), str) else "")
            if error:
                emit({"t": "captured", "id": ident, "ok": False, "msg": error})
            else:
                index.scan()
                emit({"t": "captured", "id": ident, "ok": True, "path": written})


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except BrokenPipeError:
        sys.exit(0)
