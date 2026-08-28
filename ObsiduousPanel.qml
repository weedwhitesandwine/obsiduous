import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
// `import "."` makes the plugin directory a module, so the shell's own Panel
// and BarWidget types have to be namespaced. This file is deliberately not
// called Panel.qml for the same reason.
import qs.Ui as Ui
import "."
import "Model.js" as Model

Ui.Panel {
  id: root
  moduleName: "io.github.weedwhitesandwine.obsiduous"
  ipcTarget: "obsiduous"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // search | compose | settings
  property string mode: "search"
  property int selectedIndex: 0

  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // The popup card is its own surface and keeps its own palette. The bar's
  // foreground is animated to contrast the wallpaper behind a transparent bar,
  // so it can go near-black on a light wallpaper while this card stays dark —
  // using it in here is how a popup ends up dark-on-dark and unreadable.
  readonly property color foreground: Color.popups.text
  readonly property color dim: Util.alpha(Color.popups.text, 0.62)
  readonly property color faint: Util.alpha(Color.popups.text, 0.40)

  // Typing `vault:` turns the result list into a vault switcher. It lives in
  // the search field rather than behind the gear icon because switching vault
  // is a thing done mid-search — you start typing, realise you are in the
  // wrong vault, and should not have to leave what you were doing.
  readonly property string rawQuery: searchField.text
  readonly property bool vaultMode:
    root.mode === "search" && root.rawQuery.trim().toLowerCase().indexOf("vault:") === 0
  readonly property string vaultQuery: {
    if (!root.vaultMode) return ""
    var cut = root.rawQuery.toLowerCase().indexOf("vault:")
    return root.rawQuery.slice(cut + 6).trim().toLowerCase()
  }
  readonly property var vaultMatches: {
    if (!root.vaultMode) return []
    var all = ObsiduousState.vaults
    if (root.vaultQuery === "") return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      var entry = all[i]
      var name = String(entry.name || "").toLowerCase()
      var path = String(entry.path || "").toLowerCase()
      if (name.indexOf(root.vaultQuery) >= 0 || path.indexOf(root.vaultQuery) >= 0)
        out.push(entry)
    }
    return out
  }
  readonly property int rowCount:
    root.vaultMode ? root.vaultMatches.length : root.results.length

  onVaultModeChanged: {
    root.selectedIndex = 0
    if (root.vaultMode) ObsiduousState.listVaults()
  }

  readonly property var results: ObsiduousState.results
  readonly property bool previewVisible: ObsiduousState.showPreview
    && root.mode === "search" && !root.vaultMode && root.results.length > 0

  function open() {
    root.mode = "search"
    root.controller.show()
  }
  function close() { root.controller.hide() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // Tracked on the panel's own opened state rather than inside open(), so the
  // daemon's cadence stays balanced however the panel was closed: the key
  // catcher, a click elsewhere, or a switch to another popout.
  // A row reports containsMouse as the ListView settles under a stationary
  // pointer, which churned the selection 0 -> 2 -> 1 the instant the panel
  // appeared. Hover only takes over once the pointer has actually moved, so
  // opening the panel always lands on the first result no matter where the
  // mouse happens to be sitting.
  property bool pointerMoved: false

  onOpenedChanged: {
    if (root.opened) {
      root.pointerMoved = false
      ObsiduousState.retain()
      ObsiduousState.listVaults()
      searchField.text = ""
      root.selectedIndex = 0
      ObsiduousState.search("")
      searchField.forceActiveFocus()
    } else {
      ObsiduousState.release()
      root.mode = "search"
    }
  }

  Component.onDestruction: {
    if (root.opened) ObsiduousState.release()
  }

  function move(delta) {
    if (root.rowCount === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next > root.rowCount - 1) next = root.rowCount - 1
    root.selectedIndex = next
    if (root.vaultMode) vaultList.positionViewAtIndex(next, ListView.Contain)
    else resultList.positionViewAtIndex(next, ListView.Contain)
  }

  // Indexed directly rather than through the `selected` binding. A binding
  // that depends on selectedIndex is not guaranteed to have re-evaluated by
  // the time a change handler for selectedIndex runs, so reading it there
  // hands back the previously selected note — which is exactly how the preview
  // pane came to show the row below the highlighted one.
  function noteAt(index) {
    return (index >= 0 && index < root.results.length) ? root.results[index] : null
  }

  function activate() {
    if (root.vaultMode) {
      var entry = root.vaultMatches[root.selectedIndex]
      if (!entry || entry.exists === false) return
      ObsiduousState.vaultPath = String(entry.path || "")
      // Drop back into an empty search of the vault just switched to, rather
      // than leaving `vault:` sitting in the field matching nothing.
      searchField.text = ""
      searchField.forceActiveFocus()
      return
    }
    var note = root.noteAt(root.selectedIndex)
    if (!note) return
    ObsiduousState.openNote(note.path)
    root.close()
  }

  // Qt key code to the token obsiduous-ctl.sh and Hyprland both understand.
  // Returns "" for anything that has no place in a hotkey, including a bare
  // modifier press, which is what arrives while a combination is still being
  // held down.
  function keyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    switch (key) {
      case Qt.Key_Space:        return "SPACE"
      case Qt.Key_Return:       return "RETURN"
      case Qt.Key_Enter:        return "ENTER"
      case Qt.Key_Tab:          return "TAB"
      case Qt.Key_Backspace:    return "BACKSPACE"
      case Qt.Key_Delete:       return "DELETE"
      case Qt.Key_Insert:       return "INSERT"
      case Qt.Key_Home:         return "HOME"
      case Qt.Key_End:          return "END"
      case Qt.Key_PageUp:       return "PAGE_UP"
      case Qt.Key_PageDown:     return "PAGE_DOWN"
      case Qt.Key_Up:           return "UP"
      case Qt.Key_Down:         return "DOWN"
      case Qt.Key_Left:         return "LEFT"
      case Qt.Key_Right:        return "RIGHT"
      case Qt.Key_Comma:        return "COMMA"
      case Qt.Key_Period:       return "PERIOD"
      case Qt.Key_Slash:        return "SLASH"
      case Qt.Key_Minus:        return "MINUS"
      case Qt.Key_Equal:        return "EQUAL"
      case Qt.Key_Semicolon:    return "SEMICOLON"
      case Qt.Key_Apostrophe:   return "APOSTROPHE"
      case Qt.Key_QuoteLeft:    return "GRAVE"
      case Qt.Key_BracketLeft:  return "BRACKETLEFT"
      case Qt.Key_BracketRight: return "BRACKETRIGHT"
      case Qt.Key_Backslash:    return "BACKSLASH"
    }
    return ""
  }

  // Modifier order matches the convention already in bindings.lua.
  function hotkeyLabel(key, modifiers) {
    var name = root.keyName(key)
    if (name === "") return ""
    var mods = []
    if (modifiers & Qt.MetaModifier)    mods.push("SUPER")
    if (modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (modifiers & Qt.AltModifier)     mods.push("ALT")
    if (modifiers & Qt.ShiftModifier)   mods.push("SHIFT")
    if (mods.length === 0) return ""
    return mods.join(" + ") + " + " + name
  }

  function startCompose() {
    root.mode = "compose"
    ObsiduousState.captureError = ""
    ObsiduousState.lastCapture = ""
    composeField.text = ""
    composeField.forceActiveFocus()
  }

  function leaveCompose() {
    root.mode = "search"
    searchField.forceActiveFocus()
  }

  // Opens the folder the note sits in, rather than the note.
  function revealFolder() {
    var note = root.noteAt(root.selectedIndex)
    if (!note) return
    var folder = Model.folderOf(note.path)
    Quickshell.execDetached(["xdg-open",
      folder === "" ? ObsiduousState.vault : ObsiduousState.vault + "/" + folder])
    root.close()
  }

  function selectRow(index) {
    if (index === root.selectedIndex) return
    root.selectedIndex = index
  }

  // A new result set invalidates the old selection: keeping index 3 while the
  // list underneath it changed is how a launcher opens the wrong thing.
  Connections {
    target: ObsiduousState
    function onResultsChanged() {
      root.selectedIndex = 0
      if (root.results.length > 0 && ObsiduousState.showPreview)
        ObsiduousState.preview(root.results[0].path)
    }
  }

  onSelectedIndexChanged: {
    var note = root.noteAt(root.selectedIndex)
    if (note && ObsiduousState.showPreview) ObsiduousState.preview(note.path)
  }

  readonly property string footerText: {
    if (root.vaultMode) {
      return Model.fmtCount(root.vaultMatches.length, "vault", "vaults")
        + "   ·   ↑↓ move · ⏎ switch · esc back"
    }
    if (ObsiduousState.vault === "") return "No vault — type vault: to choose one"
    if (!ObsiduousState.indexed) return "Indexing…"
    if (ObsiduousState.searching && root.results.length === 0) return "Searching…"
    var total = ObsiduousState.resultTotal
    var shown = root.results.length
    var text = shown === total
      ? Model.fmtCount(total, "note", "notes")
      : shown + " of " + total
    return text + "   ·   ↑↓ move · click or ⏎ open · ⇧⏎ folder · Ctrl+N capture · esc close"
  }

  // ------------------------------------------------------------------ view

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(
      Style.space(root.previewVisible ? 760 : 440))
    contentHeight: panel.fittedContentHeight(
      Style.space(root.mode === "compose" ? 400 : 560))

    Item {
      anchors.fill: parent

      // --------------------------------------------------------- header

      // Anchored rather than arithmetic. A Row lays its children out left to
      // right and anchors.right does not right-align them, so the old version
      // padded with a spacer whose width was computed by hand — and got it
      // wrong, subtracting four children but only three of the four gaps. Two
      // groups pinned to the two edges cannot drift out of the card however
      // long the vault name is.
      Item {
        id: headerRow
        width: parent.width
        height: Math.max(titleText.implicitHeight, gearButton.implicitHeight)

        Text {
          id: titleText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Obsiduous"
          color: root.foreground
          font.bold: true
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Row {
          id: headerActions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Ui.PanelActionButton {
            id: captureButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.mode === "compose" ? "✕" : "+"
            tooltipText: root.mode === "compose" ? "Back to search" : "Capture a note"
            foreground: root.foreground
            onClicked: {
              if (root.mode === "compose") root.leaveCompose()
              else root.startCompose()
            }
          }

          Ui.PanelActionButton {
            id: gearButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.mode === "settings" ? "✕" : "󰒓"
            tooltipText: root.mode === "settings" ? "Back to search" : "Settings"
            foreground: root.foreground
            onClicked: {
              root.mode = (root.mode === "settings") ? "search" : "settings"
              if (root.mode === "search") searchField.forceActiveFocus()
            }
          }
        }

        // Takes whatever room is left between the two, and elides rather than
        // pushing the buttons off the edge.
        Text {
          id: vaultText
          textFormat: Text.PlainText
          anchors.left: titleText.right
          anchors.leftMargin: Style.spacing.sm
          anchors.right: headerActions.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          // A vault name comes off the filesystem, so it is somebody's data.
          text: ObsiduousState.vaultName
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---------------------------------------------------------- search

      Ui.TextField {
        id: searchField
        visible: root.mode === "search"
        anchors.top: headerRow.bottom
        anchors.topMargin: Style.spacing.md
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
        placeholderText: "Search notes — tag:, path:, in:daily, vault:"
        font.family: root.fontFamily

        // Every keystroke starts a search. Nothing is refused while another is
        // in flight; the singleton discards replies for superseded queries
        // instead, so typing at speed can never leave the list showing results
        // for a prefix of what was typed.
        onTextChanged: {
          if (root.vaultMode) return
          ObsiduousState.search(text)
        }

        Keys.onUpPressed: root.move(-1)
        Keys.onDownPressed: root.move(1)
        Keys.onPressed: function(event) {
          // Capture was reachable only by clicking the + button, which made
          // the one thing you might want to do without touching the mouse the
          // one thing that required it.
          if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
            root.startCompose(); event.accepted = true
          }
          else if (event.key === Qt.Key_PageDown) { root.move(8); event.accepted = true }
          else if (event.key === Qt.Key_PageUp) { root.move(-8); event.accepted = true }
          else if (event.key === Qt.Key_Tab) {
            root.switchPanel(1); event.accepted = true
          }
        }
        // The modifier has to be tested in here, not in Keys.onPressed.
        // QQuickKeysAttached dispatches the specific handler for a key first
        // and defaults it to accepted, so onPressed is never reached for
        // Return at all — a Shift+Enter branch living there silently did
        // nothing, and Shift+Enter simply opened the note like Enter.
        Keys.onReturnPressed: function(event) {
          if (event.modifiers & Qt.ShiftModifier) root.revealFolder()
          else root.activate()
        }
        Keys.onEnterPressed: function(event) {
          if (event.modifiers & Qt.ShiftModifier) root.revealFolder()
          else root.activate()
        }
        Keys.onEscapePressed: {
          if (searchField.text !== "") searchField.text = ""
          else root.close()
        }
      }

      // ----------------------------------------------------------- body

      Item {
        id: body
        anchors.top: root.mode === "search" ? searchField.bottom : headerRow.bottom
        anchors.topMargin: Style.spacing.md
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footerText.top
        anchors.bottomMargin: Style.spacing.sm

        // ------------------------------------------------------ results

        Item {
          id: resultsPane
          visible: root.mode === "search" && !root.vaultMode
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          width: root.previewVisible
            ? Math.round(parent.width * 0.46) : parent.width

          ListView {
            id: resultList
            anchors.fill: parent
            clip: true
            model: root.results
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex

            delegate: Rectangle {
              id: row
              required property int index
              readonly property var note: root.results[index] || ({})
              readonly property bool current: index === root.selectedIndex

              width: resultList.width
              height: rowColumn.implicitHeight + Style.spacing.sm * 2
              radius: Style.cornerRadius
              // Selection and hover have to be told apart at a glance: this row
              // is what Enter will open, and a hover fill that looks the same
              // makes the panel lie about that. The selected row keeps the
              // stronger fill and gains an accent edge; hover alone is fainter.
              color: row.current
                ? Style.selectedFillFor(root.foreground, Color.accent, Color.urgent)
                : (rowMouse.containsMouse
                   ? Util.alpha(root.foreground, 0.05)
                   : "transparent")

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.space(2)
                radius: width
                visible: row.current
                color: Color.accent
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                // containsMouse rather than onEntered. A crossing event never
                // happens when the panel opens underneath a pointer that is
                // already sitting still over a row, which left that row painted
                // as though it were selected while the selection — and the
                // preview, and what Enter would have opened — was elsewhere.
                onPositionChanged: {
                  root.pointerMoved = true
                  root.selectRow(row.index)
                }
                onContainsMouseChanged: {
                  if (containsMouse && root.pointerMoved) root.selectRow(row.index)
                }
                onClicked: {
                  root.selectedIndex = row.index
                  root.activate()
                }
              }

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                // Every Text below renders vault-derived data — a title, a
                // path, a line lifted out of somebody's note. QML's Text
                // defaults to AutoText, which sniffs for rich text, so a note
                // containing <img src="http://…"> would make the shell fetch
                // it. All of them are pinned to plain text.
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: row.note.title || ""
                  color: root.foreground
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.current
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: {
                    var parts = []
                    var folder = Model.folderOf(row.note.path || "")
                    if (folder !== "") parts.push(folder)
                    var when = Model.whenText(row.note.modified)
                    if (when !== "") parts.push(when)
                    if (row.note.fuzzy === true) parts.push("~ loose match")
                    return parts.join("  ·  ")
                  }
                  color: root.faint
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: row.note.snippet || ""
                  color: root.dim
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            visible: root.results.length === 0 && !ObsiduousState.searching
            width: parent.width - Style.spacing.lg * 2
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: ObsiduousState.vault === ""
              ? "Choose a vault in settings to get started."
              : (ObsiduousState.indexed ? "No notes match that." : "Indexing the vault…")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ------------------------------------------------- vault switcher

        ListView {
          id: vaultList
          visible: root.vaultMode
          anchors.fill: parent
          clip: true
          model: root.vaultMatches
          spacing: Style.spacing.xs
          boundsBehavior: Flickable.StopAtBounds
          currentIndex: root.selectedIndex

          delegate: Rectangle {
            id: vaultRow
            required property int index
            readonly property var entry: root.vaultMatches[index] || ({})
            readonly property bool current: index === root.selectedIndex
            readonly property bool missing: entry.exists === false

            width: vaultList.width
            height: vaultRowColumn.implicitHeight + Style.spacing.sm * 2
            radius: Style.cornerRadius
            color: vaultRow.current
              ? Style.selectedFillFor(root.foreground, Color.accent, Color.urgent)
              : (vaultMouse.containsMouse ? Util.alpha(root.foreground, 0.05) : "transparent")

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(2)
              radius: width
              visible: vaultRow.current
              color: Color.accent
            }

            MouseArea {
              id: vaultMouse
              anchors.fill: parent
              hoverEnabled: true
              onPositionChanged: {
                root.pointerMoved = true
                root.selectRow(vaultRow.index)
              }
              onContainsMouseChanged: {
                if (containsMouse && root.pointerMoved) root.selectRow(vaultRow.index)
              }
              onClicked: {
                root.selectedIndex = vaultRow.index
                root.activate()
              }
            }

            Row {
              id: vaultRowColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              // A vault name and path come off the filesystem like everything
              // else here, so both are pinned to plain text.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: String(vaultRow.entry.name || "")
                color: vaultRow.missing ? root.faint : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: vaultRow.entry.current === true
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: {
                  if (vaultRow.missing) return "missing"
                  var count = vaultRow.entry.notes
                  if (count === undefined || count === null) return ""
                  return count + (vaultRow.entry.partial === true ? "+" : "")
                    + (count === 1 ? " note" : " notes")
                }
                color: vaultRow.missing ? Color.urgent : root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                visible: vaultRow.entry.current === true
                text: "· current"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          visible: root.vaultMode && root.vaultMatches.length === 0
          text: "No vault matches that."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // ------------------------------------------------------ preview

        Rectangle {
          id: previewPane
          visible: root.previewVisible
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.right: parent.right
          anchors.left: resultsPane.right
          anchors.leftMargin: Style.spacing.md
          color: Util.alpha(Color.popups.text, 0.04)
          radius: Style.cornerRadius

          Column {
            id: previewHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.spacing.md
            spacing: 2

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: ObsiduousState.previewTitle
              color: root.foreground
              elide: Text.ElideRight
              font.bold: true
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: text !== ""
              text: {
                var tags = ObsiduousState.previewTags
                if (!tags || tags.length === 0) return ""
                var out = []
                for (var i = 0; i < tags.length; i++) out.push("#" + tags[i])
                return out.join("  ")
              }
              color: Color.accent
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Flickable {
            anchors.top: previewHeader.bottom
            anchors.topMargin: Style.spacing.sm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            anchors.bottomMargin: Style.spacing.md
            clip: true
            contentWidth: width
            contentHeight: previewBody.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Text {
              id: previewBody
              width: parent.width
              // The note's own body. Plain text is not a nicety here: this is
              // arbitrary Markdown from disk going into the shell's process.
              textFormat: Text.PlainText
              text: Model.previewBody(ObsiduousState.previewText, ObsiduousState.previewTitle)
              color: root.dim
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ------------------------------------------------------ compose

        Item {
          id: composePane
          visible: root.mode === "compose"
          anchors.fill: parent

          Ui.TextField {
            id: composeTitle
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            foreground: root.foreground
            placeholderText: "Title (optional, used when saving as a note)"
            font.family: root.fontFamily
          }

          Rectangle {
            id: composeBox
            anchors.top: composeTitle.bottom
            anchors.topMargin: Style.spacing.sm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: composeActions.top
            anchors.bottomMargin: Style.spacing.md
            color: Util.alpha(Color.popups.text, 0.04)
            radius: Style.cornerRadius

            ScrollView {
              anchors.fill: parent
              anchors.margins: Style.spacing.sm
              clip: true

              TextArea {
                id: composeField
                wrapMode: TextEdit.Wrap
                // The editor shows back exactly what was typed, and nothing
                // else. A TextEdit sniffs for rich text the same way Text does.
                textFormat: TextEdit.PlainText
                color: root.foreground
                placeholderTextColor: root.faint
                placeholderText: "Write a note…"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                background: null
                Keys.onEscapePressed: root.leaveCompose()
              }
            }
          }

          // Same fix as the header, and this is where the bug showed: the
          // status text's width was computed by subtracting Save, Cancel and
          // the spacer — but not the mode button — so the row was wider than
          // the panel by exactly that button and pushed Cancel and Save off
          // the right-hand edge of the card.
          Item {
            id: composeActions
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(saveNoteButton.implicitHeight, cancelButton.implicitHeight)

            Ui.Button {
              id: cancelButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Cancel"
              foreground: root.foreground
              bordered: true
              onClicked: root.leaveCompose()
            }

            // Two Save buttons that each name their destination, rather than a
            // Save whose meaning depends on a toggle sitting elsewhere. Where a
            // note lands is the one thing you want to be sure of before you
            // press the button, not after.
            Row {
              id: composeConfirm
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Ui.Button {
                id: saveNoteButton
                text: "Save as note"
                tooltipText: "Write a new Markdown file in the vault"
                foreground: Color.accent
                bordered: true
                enabled: composeField.text.trim() !== ""
                onClicked: {
                  ObsiduousState.capture(composeField.text, composeTitle.text, "new")
                  composeField.text = ""
                  composeTitle.text = ""
                }
              }

              Ui.Button {
                id: saveDailyButton
                text: "Save as daily note"
                tooltipText: "Append a timestamped line to today's daily note"
                foreground: Color.accent
                bordered: true
                enabled: composeField.text.trim() !== ""
                onClicked: {
                  ObsiduousState.capture(composeField.text, composeTitle.text, "daily")
                  composeField.text = ""
                  composeTitle.text = ""
                }
              }
            }

            Text {
              anchors.left: cancelButton.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: composeConfirm.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: ObsiduousState.captureError !== ""
                ? ObsiduousState.captureError
                : (ObsiduousState.lastCapture !== ""
                   ? "Saved to " + ObsiduousState.lastCapture : "")
              color: ObsiduousState.captureError !== "" ? Color.urgent : root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ----------------------------------------------------- settings

        Flickable {
          id: settingsPane
          visible: root.mode === "settings"
          anchors.fill: parent
          clip: true
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: settingsColumn
            width: settingsPane.width
            spacing: Style.spacing.lg

            Ui.PanelSectionHeader { text: "VAULT"; foreground: root.foreground }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              visible: ObsiduousState.vaults.length === 0
              text: "Obsidian's vault list could not be read. Set the path with:\n"
                + "omarchy bar set io.github.weedwhitesandwine.obsiduous vaultPath ~/vault"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: ObsiduousState.vaults
              delegate: Rectangle {
                required property int index
                readonly property var entry: ObsiduousState.vaults[index] || ({})
                readonly property bool current:
                  String(entry.path || "") === ObsiduousState.vaultPath

                width: settingsColumn.width
                height: vaultColumn.implicitHeight + Style.spacing.sm * 2
                radius: Style.cornerRadius
                color: current
                  ? Style.selectedFillFor(root.foreground, Color.accent, Color.urgent)
                  : (vaultMouse.containsMouse
                     ? Style.hoverFillFor(root.foreground, Color.accent, Color.urgent)
                     : "transparent")

                MouseArea {
                  id: vaultMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: ObsiduousState.vaultPath = String(entry.path || "")
                }

                Column {
                  id: vaultColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.margins: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 1

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: String(entry.name || "")
                    color: root.foreground
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: String(entry.path || "")
                      + (entry.exists === false ? "  (missing)" : "")
                    color: root.faint
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Ui.PanelSectionHeader { text: "PANEL"; foreground: root.foreground }

            Ui.Toggle {
              width: parent.width
              label: "Show the preview pane"
              description: "Read a note beside the results instead of opening Obsidian"
              foreground: root.foreground
              checked: ObsiduousState.showPreview
              onClicked: ObsiduousState.showPreview = !ObsiduousState.showPreview
            }

            Ui.PanelSectionHeader { text: "HOTKEY"; foreground: root.foreground }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              // A recorder, not a text field. Typing the letters S-U-P-E-R is
              // not how anybody expresses a hotkey: SUPER is a modifier, so
              // holding it produces no character and pressing SUPER+I in a
              // text field simply types "i". This captures the combination
              // actually pressed.
              Rectangle {
                id: hotkeyField
                width: Math.max(Style.space(140),
                  parent.width - applyHotkey.width - clearHotkey.width
                  - Style.spacing.sm * 2)
                height: applyHotkey.implicitHeight
                radius: Style.cornerRadius
                color: hotkeyField.recording
                  ? Style.focusFillFor(root.foreground, Color.accent, Color.urgent)
                  : Util.alpha(root.foreground, 0.04)
                border.width: 1
                border.color: hotkeyField.recording
                  ? Color.accent : Util.alpha(root.foreground, 0.25)

                property string captured: ObsiduousState.hotkey
                property bool recording: false

                activeFocusOnTab: true
                onActiveFocusChanged: if (!activeFocus) hotkeyField.recording = false

                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: hotkeyField.recording
                    ? "Press a combination…"
                    : (hotkeyField.captured !== ""
                       ? hotkeyField.captured : "Click, then press a hotkey")
                  color: hotkeyField.captured !== "" && !hotkeyField.recording
                    ? root.foreground : root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.italic: hotkeyField.captured === "" || hotkeyField.recording
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    hotkeyField.recording = true
                    hotkeyField.forceActiveFocus()
                  }
                }

                Keys.onPressed: function(event) {
                  if (!hotkeyField.recording) return
                  event.accepted = true
                  if (event.key === Qt.Key_Escape) {
                    hotkeyField.recording = false
                    return
                  }
                  // Modifiers arrive as key presses of their own while the
                  // combination is still being held; they are not the key.
                  var label = root.hotkeyLabel(event.key, event.modifiers)
                  if (label === "") return
                  hotkeyField.captured = label
                  hotkeyField.recording = false
                  ObsiduousState.hotkeyError = ""
                }
              }

              Ui.Button {
                id: applyHotkey
                text: "Bind"
                foreground: Color.accent
                bordered: true
                enabled: hotkeyField.captured !== ""
                onClicked: ObsiduousState.applyHotkey(hotkeyField.captured)
              }

              Ui.Button {
                id: clearHotkey
                text: "Clear"
                foreground: root.foreground
                bordered: true
                onClicked: {
                  ObsiduousState.applyHotkey("")
                  hotkeyField.captured = ""
                  hotkeyField.recording = false
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              visible: text !== ""
              text: {
                if (ObsiduousState.hotkeyError !== "") return ObsiduousState.hotkeyError
                if (hotkeyField.recording)
                  return "A combination Hyprland already uses never reaches here — "
                    + "if nothing appears, that key is taken."
                if (ObsiduousState.hotkey !== "")
                  return "Bound in a marked block in ~/.config/hypr/bindings.lua. "
                    + "Press Clear before uninstalling — removal deletes the script "
                    + "that would take it out."
                return ""
              }
              color: ObsiduousState.hotkeyError !== "" ? Color.urgent : root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Ui.PanelSectionHeader { text: "INDEX"; foreground: root.foreground }

            // The count is the part worth having on screen. The button is an
            // escape hatch and is labelled as one: rescanning is automatic, so
            // a Rebuild that looked like routine maintenance would just be a
            // mystery button inviting people to press it.
            Item {
              width: parent.width
              height: Math.max(indexCount.implicitHeight, rebuildButton.implicitHeight)

              Text {
                id: indexCount
                anchors.left: parent.left
                anchors.right: rebuildButton.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: {
                  if (ObsiduousState.vault === "") return "No vault selected"
                  if (!ObsiduousState.indexed) return "Indexing…"
                  return Model.fmtCount(ObsiduousState.noteCount, "note", "notes")
                    + " indexed"
                    + (ObsiduousState.truncated ? " · stopped at the ceiling" : "")
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Ui.Button {
                id: rebuildButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Rebuild"
                tooltipText: "Re-read every note from disk"
                foreground: root.foreground
                bordered: true
                onClicked: ObsiduousState.reindex()
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Rescanning happens on its own — every couple of seconds "
                + "while this panel is open, and a note is re-read whenever its "
                + "timestamp or size changes. Rebuild is only for a note edited "
                + "by something that kept both, which some sync tools do."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // --------------------------------------------------------- footer

      // The footer is the only place the keys are written down, so it is the
      // one caption in the panel that has to be read rather than glanced at.
      // Body size, and a step up from `faint` so it is not competing with the
      // background as well as with its own size.
      Text {
        id: footerText
        textFormat: Text.PlainText
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        elide: Text.ElideRight
        text: root.mode === "search" ? root.footerText : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }
}
