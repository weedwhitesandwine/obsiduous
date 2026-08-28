pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The single owner of the index daemon and of everything it reports.
//
// A bar widget is instantiated once per monitor, so a plugin that started its
// daemon from the widget would run one full vault index per screen. Everything
// stateful lives here instead: one daemon however many bars are on the desk,
// one writer for the settings file, and every panel showing the same results
// at the same moment.
QtObject {
  id: root

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateHome: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    return (xdg && xdg.length > 0) ? xdg : (root.homeDir + "/.local/state")
  }
  readonly property string pluginDir: root.homeDir
    + "/.config/omarchy/plugins/io.github.weedwhitesandwine.obsiduous"
  readonly property string stateDir: root.stateHome + "/omarchy/obsiduous"
  readonly property string settingsPath: root.stateDir + "/settings.json"

  // ----------------------------------------------------------------- limits
  //
  // The daemon bounds its own output at the writer, which is where a bound
  // belongs, but this process lives for days and reads a pipe it does not
  // control the far end of once the daemon has been replaced on disk. So the
  // ceiling is applied again here, before anything is parsed.
  readonly property int lineCeiling: 4 * 1024 * 1024
  readonly property int settingsCeiling: 64 * 1024
  readonly property int maxResults: 60
  readonly property int maxVaults: 50
  readonly property int maxPreviewChars: 16 * 1024

  // ----------------------------------------------------------------- status
  property string vault: ""
  property string vaultName: ""
  property int noteCount: 0
  property bool indexed: false
  property bool truncated: false
  property string daemonMode: "idle"
  property bool daemonUp: false

  // ---------------------------------------------------------------- results
  property var results: []
  property int resultTotal: 0
  property string resultQuery: ""
  property bool searching: false
  property var vaults: []

  property string previewPath: ""
  property string previewTitle: ""
  property string previewText: ""
  property var previewTags: []
  property bool previewLoading: false

  property string lastCapture: ""
  property string captureError: ""

  // --------------------------------------------------------------- settings
  property string vaultPath: ""
  property string glyph: "󰇈"     // U+F01C8, a cut gem — see BarWidget
  property bool showPreview: true
  property string hotkey: ""                // "" means no hotkey bound
  property bool settingsLoaded: false

  // A hotkey is modifiers plus one key, and nothing else. It is checked here
  // and again, independently, inside obsiduous-ctl.sh, because that script can
  // be run without ever going near this UI and because the value lands inside
  // a Lua string in the user's bindings.lua. Anything not of this shape is
  // refused rather than escaped: there is no legitimate hotkey it could be.
  readonly property var hotkeyShape: /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/

  function validHotkey(key) {
    return typeof key === "string" && root.hotkeyShape.test(key)
  }

  property string hotkeyError: ""

  property Process ctl: Process { command: [] }

  function applyHotkey(key) {
    var wanted = String(key || "").trim().toUpperCase()
    if (wanted === "") {
      root.hotkeyError = ""
      root.hotkey = ""
      root.ctl.running = false
      root.ctl.command = ["bash", root.pluginDir + "/obsiduous-ctl.sh", "unbind"]
      root.ctl.running = true
      return
    }
    if (!root.validHotkey(wanted)) {
      root.hotkeyError = "Not a hotkey — one or more modifiers, then a single key"
      return
    }
    root.hotkeyError = ""
    root.hotkey = wanted
    root.ctl.running = false
    // The key goes as a positional argument, never interpolated into a shell
    // string that bash would then re-parse.
    root.ctl.command = ["bash", root.pluginDir + "/obsiduous-ctl.sh", "bind", wanted]
    root.ctl.running = true
  }

  // ------------------------------------------------------- request tracking
  //
  // The whole reason the old approach felt broken: a search launched while
  // another was in flight used to be dropped, so fast typing left the panel
  // showing results for a prefix of what had been typed. Every request now
  // carries an id, the newest id is remembered, and a reply for anything older
  // is discarded on arrival. Nothing is ever refused, so nothing is ever lost.
  property int nextRequestId: 1
  property int latestSearchId: 0
  property int latestPreviewId: 0

  function newId() {
    root.nextRequestId = root.nextRequestId + 1
    return root.nextRequestId
  }

  function send(payload) {
    if (!root.daemon.running) return false
    root.daemon.write(JSON.stringify(payload) + "\n")
    return true
  }

  function search(query) {
    root.latestSearchId = root.newId()
    root.searching = true
    if (!root.send({ c: "search", id: root.latestSearchId,
                     q: String(query || ""), limit: root.maxResults })) {
      root.searching = false
    }
  }

  function preview(relPath) {
    if (!root.showPreview) return
    root.latestPreviewId = root.newId()
    root.previewLoading = true
    root.previewPath = String(relPath || "")
    root.send({ c: "preview", id: root.latestPreviewId, p: root.previewPath })
  }

  function recordOpen(relPath) {
    root.send({ c: "open", p: String(relPath || "") })
  }

  // The mode is always explicit now: there are two Save buttons and each says
  // which one it is, so there is no remembered setting to get out of step with
  // what the panel appears to be about to do.
  function capture(text, title, mode) {
    if (mode !== "new" && mode !== "daily") return
    root.captureError = ""
    root.send({ c: "capture", id: root.newId(), text: String(text || ""),
                title: String(title || ""), mode: mode })
  }

  // Counts always. Asking only when the switcher opened made the numbers
  // depend on a reply landing between the keystroke and the delegate binding,
  // which is a race to lose for no gain: the daemon caches the walk for 30
  // seconds, so this costs about a millisecond and the counts are simply
  // there when the switcher appears.
  function listVaults() {
    root.send({ c: "vaults", id: root.newId(), counts: true })
  }
  function reindex() { root.send({ c: "reindex" }) }

  // The obsidian:// URI needs the vault's *registered* name, which the daemon
  // reads out of Obsidian's own config. Guessing it from the last path
  // component is wrong the moment somebody renamed a vault, which is exactly
  // the sort of thing that makes a plugin look broken for no visible reason.
  function noteUri(relPath) {
    var file = String(relPath || "").replace(/\.md$/, "")
    var name = root.vaultName !== "" ? root.vaultName : root.vault.split("/").pop()
    return "obsidian://open?vault=" + encodeURIComponent(name)
      + "&file=" + encodeURIComponent(file)
  }

  function openNote(relPath) {
    if (!relPath) return
    root.recordOpen(relPath)
    Quickshell.execDetached(["xdg-open", root.noteUri(relPath)])
  }

  function openVaultRoot() {
    if (root.vault === "") return
    var name = root.vaultName !== "" ? root.vaultName : root.vault.split("/").pop()
    Quickshell.execDetached(["xdg-open", "obsidian://open?vault=" + encodeURIComponent(name)])
  }

  // ------------------------------------------------------------ detail level
  //
  // Rescanning every couple of seconds while nobody is looking at the panel is
  // wasted work, so the daemon is told to drop to a lazy cadence whenever the
  // last panel closes.
  property int openPanels: 0
  readonly property string desiredMode: root.openPanels > 0 ? "active" : "idle"

  function retain() { root.openPanels = root.openPanels + 1 }
  function release() { root.openPanels = Math.max(0, root.openPanels - 1) }

  onDesiredModeChanged: root.pushMode()

  function pushMode() {
    root.send({ c: "mode", m: root.desiredMode })
  }

  // ------------------------------------------------------------- the daemon

  property int restartDelay: 1000

  property Process daemon: Process {
    // setpriv --pdeathsig means the daemon cannot outlive the shell even if
    // the shell dies without cleaning up: the kernel signals it directly.
    command: ["setpriv", "--pdeathsig", "TERM",
              "python3", root.pluginDir + "/obsiduous-indexd.py", root.vaultPath]
    stdinEnabled: true
    running: false

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.ingest(line) }
    }
    // Collected and discarded deliberately: an unread stderr pipe fills and
    // then blocks the writer, which would stop the daemon dead.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {}
    }

    onStarted: {
      root.restartDelay = 1000
      root.daemonUp = true
      root.pushMode()
    }
    onExited: function(code, status) { root.daemonStopped() }
  }

  property Timer restartTimer: Timer {
    repeat: false
    interval: root.restartDelay
    onTriggered: root.startDaemon()
  }

  function startDaemon() {
    if (root.daemon.running) return
    root.daemon.running = true
  }

  function daemonStopped() {
    root.daemonUp = false
    root.indexed = false
    root.searching = false
    // Backing off keeps a daemon that cannot start — no python3, a deleted
    // script — from being restarted in a tight loop for the life of the shell.
    root.restartDelay = Math.min(60000, Math.max(1000, root.restartDelay * 2))
    root.restartTimer.interval = root.restartDelay
    root.restartTimer.restart()
  }

  function restartDaemon() {
    if (root.daemon.running) {
      root.daemon.running = false   // onExited schedules the restart
    } else {
      root.startDaemon()
    }
  }

  // ------------------------------------------------------------- ingestion

  function asArray(value, cap) {
    return Array.isArray(value) ? value.slice(0, cap) : []
  }

  function asText(value, cap) {
    return (typeof value === "string") ? value.slice(0, cap) : ""
  }

  function ingest(line) {
    if (typeof line !== "string" || line.length === 0) return
    // The ceiling is here rather than inside the parse: a line this long is
    // not a reply, and JSON.parse on it would already have cost the memory.
    if (line.length > root.lineCeiling) return

    var message = null
    try {
      message = JSON.parse(line)
    } catch (error) {
      return
    }
    // Valid JSON of the wrong shape is still wrong.
    if (!message || typeof message !== "object" || Array.isArray(message)) return

    var kind = message.t

    if (kind === "status") {
      root.vault = root.asText(message.vault, 4096)
      root.vaultName = root.asText(message.vaultName, 200)
      root.noteCount = (typeof message.notes === "number") ? message.notes : 0
      root.indexed = message.indexed === true
      root.truncated = message.truncated === true
      if (message.mode === "active" || message.mode === "idle") {
        // The daemon reports the mode it is actually in, so a command written
        // while it was still starting — and therefore lost — is noticed here
        // and simply sent again, instead of leaving it in the wrong cadence
        // for as long as the panel stays open.
        root.daemonMode = message.mode
        if (message.mode !== root.desiredMode) root.pushMode()
      }

    } else if (kind === "results") {
      // A reply for a query that has since been superseded is stale by
      // definition; showing it would make the list flicker backwards.
      if (message.id !== root.latestSearchId) return
      root.results = root.asArray(message.items, root.maxResults)
      root.resultTotal = (typeof message.total === "number") ? message.total : 0
      root.resultQuery = root.asText(message.q, 200)
      root.searching = false

    } else if (kind === "preview") {
      if (message.id !== root.latestPreviewId) return
      root.previewLoading = false
      root.previewTitle = root.asText(message.title, 200)
      root.previewText = root.asText(message.text, root.maxPreviewChars)
      root.previewTags = root.asArray(message.tags, 12)

    } else if (kind === "vaults") {
      root.vaults = root.asArray(message.items, root.maxVaults)

    } else if (kind === "captured") {
      if (message.ok === true) {
        root.lastCapture = root.asText(message.path, 4096)
        root.captureError = ""
      } else {
        root.lastCapture = ""
        root.captureError = root.asText(message.msg, 200) || "capture failed"
      }
    }
  }

  // -------------------------------------------------------------- settings

  // Reading a file this process does not hold open means it can be anything by
  // the time it is opened — a link elsewhere, a pipe, or something far too
  // large. The open refuses on its own terms and the ceiling is applied to the
  // read, so a bad file yields nothing rather than something.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("\n")

  // 0700, because settings.json lives here and nobody else on the machine has
  // any business reading it. mkdir -m only applies to directories it creates,
  // which is the intent: an existing directory keeps whatever the user chose.
  property Process ensureStateDir: Process {
    command: ["mkdir", "-p", "-m", "700", root.stateDir]
  }

  property Process settingsReader: Process {
    command: ["python3", "-c", root.safeRead,
              root.settingsPath, String(root.settingsCeiling)]
    stdout: StdioCollector {
      id: settingsOut
      waitForEnd: true
      onStreamFinished: if (settingsOut.text !== "") root.applySettings(settingsOut.text)
    }
    onExited: function(code, status) {
      // Three outcomes, told apart on purpose. 2 is "no file yet", so the
      // defaults are the truth and saving is safe. 0 means it was read. 1 is a
      // refusal — too large, a link, not a plain file — and the gate stays
      // shut, because writing over a file we could not read would destroy it.
      if (root.settingsLoaded) return
      if (code === 2) {
        root.settingsLoaded = true
        root.afterSettings()
      }
    }
  }

  function applySettings(text) {
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      parsed = null
    }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      if (typeof parsed.vaultPath === "string")
        root.vaultPath = parsed.vaultPath.slice(0, 4096)
      // A glyph is one or two characters of display text. Anything longer is
      // not a glyph, and it is heading for the bar, so it is refused rather
      // than truncated.
      if (typeof parsed.glyph === "string" && parsed.glyph.length > 0
          && parsed.glyph.length <= 4)
        root.glyph = parsed.glyph
      if (typeof parsed.showPreview === "boolean") root.showPreview = parsed.showPreview
      // A restored or hand-edited settings file is exactly the case this
      // guards: a stored hotkey is re-checked on the way in, not trusted
      // because it was in our own file.
      if (typeof parsed.hotkey === "string"
          && (parsed.hotkey === "" || root.validHotkey(parsed.hotkey)))
        root.hotkey = parsed.hotkey
    }
    root.settingsLoaded = true
    root.afterSettings()
  }

  // The daemon is started only once the real vault path is known, so it does
  // not index the empty string first and then immediately index again.
  property bool daemonEverStarted: false

  function afterSettings() {
    if (root.daemonEverStarted) return
    root.daemonEverStarted = true
    root.startDaemon()
    root.listVaults()
  }

  onVaultPathChanged: {
    root.scheduleSettingsSave()
    if (root.daemonEverStarted) {
      root.results = []
      root.indexed = false
      root.send({ c: "vault", p: root.vaultPath })
    }
  }

  property bool savingNow: false

  property Timer settingsSaveTimer: Timer {
    repeat: false
    interval: 250
    onTriggered: root.flushSettings()
  }

  function scheduleSettingsSave() {
    if (root.settingsLoaded) root.settingsSaveTimer.restart()
  }

  // Written the way the reviewed plugins write from QML: staged under a random
  // name created by mktemp in the destination directory, which never follows a
  // symlink, then renamed into place — and only after that directory is
  // confirmed to be ours and not group- or world-writable. FileView.setText
  // would be shorter, but its staging name is not ours to reason about, and a
  // predictable stage name beside a config file is the shape that turns a
  // pre-planted symlink into the truncation of whatever it points at.
  //
  // The payload goes as a positional argument, never interpolated into the
  // shell string.
  readonly property string safeWrite:
    'd=$(dirname "$1") && mkdir -p -m 700 "$d" && [ -O "$d" ]'
    + ' && [ "$(( 8#$(stat -c %a "$d") & 8#022 ))" -eq 0 ]'
    + ' && t=$(mktemp "$1.XXXXXXXX") && printf "%s\n" "$2" > "$t"'
    + ' && chmod 600 "$t" && mv -f "$t" "$1"'

  property Process settingsWriter: Process { command: [] }

  function flushSettings() {
    root.savingNow = true
    var payload = JSON.stringify({
      vaultPath: root.vaultPath,
      glyph: root.glyph,
      showPreview: root.showPreview,
      hotkey: root.hotkey
    }, null, 2)

    root.settingsWriter.running = false
    root.settingsWriter.command = ["bash", "-c", root.safeWrite, "--",
                                   root.settingsPath, payload]
    root.settingsWriter.running = true
  }

  // A watcher only — it neither reads nor writes. FileView cannot stop short of
  // the end of a file, so by the time its text existed the whole of whatever
  // was on disk would already be in the shell; with blockAllReads and preload
  // off, and text() never called, onLoaded does not fire and onFileChanged
  // still does. Writing goes through safeWrite above.
  property FileView settingsFile: FileView {
    path: root.settingsPath
    blockAllReads: true
    preload: false
    printErrors: false
    watchChanges: true
    onFileChanged: {
      if (root.savingNow) { root.savingNow = false; return }
      root.settingsReader.running = false
      root.settingsReader.running = true
    }
  }

  onGlyphChanged: root.scheduleSettingsSave()
  onShowPreviewChanged: root.scheduleSettingsSave()
  onHotkeyChanged: root.scheduleSettingsSave()

  Component.onCompleted: {
    root.ensureStateDir.running = true
    root.settingsReader.running = true
  }
}
